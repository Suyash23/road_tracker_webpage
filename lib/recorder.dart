import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'models.dart';
import 'road_db.dart';
import 'sensor_isolate.dart';

class RoadRecorder extends ChangeNotifier {
  RoadRecorder(this._db);

  final RoadDb _db;

  bool _isRecording = false;
  bool get isRecording => _isRecording;

  String _fidelity = 'medium';
  String get fidelity => _fidelity;

  final ValueNotifier<double> currentVibration = ValueNotifier(0.0);
  final ValueNotifier<List<AccelSample>> recentVibrations = ValueNotifier([]);

  int? _activeTripId;
  final List<GpsSample> _gpsSamples = [];
  List<GpsSample> get gpsSamples => List.unmodifiable(_gpsSamples);

  SensorProcessor? _processor;
  ReceivePort? _receivePort;

  Future<void> loadLatestTrip() async {
    final tripId = await _db.getLatestTripId();
    if (tripId == null) return;
    await loadTrip(tripId);
  }

  Future<void> loadTrip(int tripId) async {
    final rows = await _db.getGpsSamples(tripId);
    _gpsSamples
      ..clear()
      ..addAll(rows.map(GpsSample.fromRow));
    notifyListeners();
  }

  void setFidelity(String value) {
    if (_isRecording) return;
    _fidelity = value;
    notifyListeners();
  }

  Future<void> start({String? replayFilePath}) async {
    if (_isRecording) return;

    if (replayFilePath == null) {
      final permission = await _ensurePermissions();
      if (!permission) return;
    }

    final tripId = await _db.insertTrip(
      startTimeMs: DateTime.now().millisecondsSinceEpoch,
      fidelity: _fidelity,
    );
    _activeTripId = tripId;
    _gpsSamples.clear();
    recentVibrations.value = [];
    currentVibration.value = 0.0;

    _isRecording = true;
    notifyListeners();

    WakelockPlus.enable();

    _receivePort = ReceivePort();
    _receivePort!.listen((message) {
      if (message is IsolateDataMessage) {
        currentVibration.value = message.currentVibration;
        recentVibrations.value = message.recentVibrations;
        if (message.latestGps != null) {
          _gpsSamples.add(message.latestGps!);
          notifyListeners();
        }
      }
    });

    _processor = SensorProcessor(
      tripId,
      _fidelity,
      _receivePort!.sendPort,
      replayFilePath,
    );
    await _processor!.start();
  }

  Future<void> stop() async {
    if (!_isRecording) return;

    _processor?.stop();
    _processor = null;
    _receivePort?.close();
    _receivePort = null;

    final tripId = _activeTripId;
    final endTime = DateTime.now().millisecondsSinceEpoch;
    if (tripId != null) {
      await _db.endTrip(tripId: tripId, endTimeMs: endTime);

      // A7: Privacy Trimming
      final trimmedSamples = _trimTripEndpoints(
        _gpsSamples,
        DetectionConfig.trimDistanceMeters,
      );

      // Upload to Firestore
      try {
        final docRef = FirebaseFirestore.instance.collection('trips').doc();
        await docRef.set({
          'startTimeMs': trimmedSamples.isNotEmpty
              ? trimmedSamples.first.ts
              : endTime,
          'endTimeMs': endTime,
          'fidelity': _fidelity,
          'samples': trimmedSamples
              .map(
                (s) => {
                  'ts': s.ts,
                  'lat': s.lat,
                  'lon': s.lon,
                  'color': s.color,
                  'accelVal': s.accelVal,
                  'z_score': s.zScore,
                },
              )
              .toList(),
        });
      } catch (e) {
        debugPrint('Failed to upload to Firestore: $e');
      }
    }

    _activeTripId = null;
    _isRecording = false;
    notifyListeners();

    WakelockPlus.disable();
  }

  Future<bool> _ensurePermissions() async {
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.deniedForever ||
        permission == LocationPermission.denied) {
      return false;
    }
    if (permission == LocationPermission.whileInUse) {
      permission = await Geolocator.requestPermission();
    }
    return permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse;
  }

  List<GpsSample> _trimTripEndpoints(List<GpsSample> samples, double trimDistance) {
    if (samples.length < 2) return samples;

    int startIndex = 0;
    double startDist = 0.0;
    for (int i = 0; i < samples.length - 1; i++) {
      final s1 = samples[i];
      final s2 = samples[i + 1];
      startDist += Geolocator.distanceBetween(s1.lat, s1.lon, s2.lat, s2.lon);
      if (startDist >= trimDistance) {
        startIndex = i + 1;
        break;
      }
    }
    if (startDist < trimDistance) return [];

    int endIndex = samples.length - 1;
    double endDist = 0.0;
    for (int i = samples.length - 1; i > startIndex; i--) {
      final s1 = samples[i];
      final s2 = samples[i - 1];
      endDist += Geolocator.distanceBetween(s1.lat, s1.lon, s2.lat, s2.lon);
      if (endDist >= trimDistance) {
        endIndex = i - 1;
        break;
      }
    }
    if (endDist < trimDistance) return [];

    return samples.sublist(startIndex, endIndex + 1);
  }
}
