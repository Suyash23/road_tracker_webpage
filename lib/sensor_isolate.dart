import 'dart:async';
import 'dart:collection';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import 'models.dart';
import 'road_db.dart';
import 'sensor_source.dart';

class IsolateInitMessage {
  IsolateInitMessage({
    required this.token,
    required this.sendPort,
    required this.tripId,
    required this.fidelity,
    this.replayFilePath,
  });
  final RootIsolateToken token;
  final SendPort sendPort;
  final int tripId;
  final String fidelity;
  final String? replayFilePath;
}

class IsolateDataMessage {
  IsolateDataMessage({
    required this.currentVibration,
    required this.recentVibrations,
    this.latestGps,
  });
  final double currentVibration;
  final List<AccelSample> recentVibrations;
  final GpsSample? latestGps;
}

void sensorIsolateEntry(IsolateInitMessage initMessage) async {
  BackgroundIsolateBinaryMessenger.ensureInitialized(initMessage.token);
  
  final processor = SensorProcessor(
    initMessage.tripId,
    initMessage.fidelity,
    initMessage.sendPort,
    initMessage.replayFilePath,
  );
  
  await processor.start();
}

class SensorProcessor {
  SensorProcessor(this.tripId, this.fidelity, this.sendPort, this.replayFilePath);

  final int tripId;
  final String fidelity;
  final SendPort sendPort;
  final String? replayFilePath;

  Timer? _batchTimer;
  Timer? _gpsTimer;

  SensorSource? _sensorSource;

  // DB Batching
  final List<Map<String, dynamic>> _gpsBatch = [];
  final List<Map<String, dynamic>> _accelBatch = [];

  // Sensors
  StreamSubscription<AccelerometerEvent>? _accelSub;
  StreamSubscription<UserAccelerometerEvent>? _userAccelSub;
  StreamSubscription<GyroscopeEvent>? _gyroSub;

  // State
  Vector3 _gravity = Vector3(0.0, 0.0, 9.81);
  final Queue<MapEntry<int, Vector3>> _gravityHistory = Queue();
  double _currentGpsSpeedKmh = 0.0;
  int _suppressUntilMs = 0;
  
  // Z-Score (Rolling 5 minutes)
  static const int _zScoreWindowMs = 5 * 60 * 1000;
  final Queue<double> _validVertWindow = Queue<double>();
  final Queue<int> _validVertTimeWindow = Queue<int>();
  double _currentMean = 0.0;
  double _currentStdDev = 1.0; // avoid div by zero
  
  // Charting & Smoothing
  static const int _rollingWindowMs = 750;
  static const int _graphWindowMs = 10000;
  final Queue<AccelSample> _accelWindow = Queue<AccelSample>();
  final Queue<AccelSample> _graphWindow = Queue<AccelSample>();
  double _lastSmoothed = 0.0;
  int _lastAccelMs = 0;
  
  // Adaptive Sampling
  double _currentAccelHz = DetectionConfig.baselineSamplingHz;

  Future<void> start() async {
    // Setup batch writer
    _batchTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) => _flushBatch());
    
    // Init source
    if (replayFilePath != null) {
      _sensorSource = await SyntheticSensorSource.fromFile(replayFilePath!, _getSensorInterval());
    } else {
      _sensorSource = RealSensorSource(_getSensorInterval());
    }
    
    // Setup sensors
    _startSensors();
    
    // GPS
    final gpsHz = _getFidelityGpsHz(fidelity);
    _startGps(gpsHz);
  }
  
  void _startSensors() {
    _startGyro();
    _startGravity();
    _startUserAccel();
  }

  void _startGyro() {
    try {
      _gyroSub = _sensorSource!.gyroscope.listen((event) {
        final magnitude = Vector3(event.x, event.y, event.z).length;
        if (magnitude > DetectionConfig.gyroThresholdRads) {
          final now = DateTime.now().millisecondsSinceEpoch;
          final targetMs = now + 200;
          if (targetMs > _suppressUntilMs) {
            _suppressUntilMs = targetMs;
          }
        }
      }, onError: (err) {
        // Safe stub for platforms without physical sensors
      });
    } catch (_) {}
  }

  void _startGravity() {
    try {
      _accelSub = _sensorSource!.accelerometer.listen((event) {
        final ax = event.x / 9.81;
        final ay = event.y / 9.81;
        final az = event.z / 9.81;
        final magnitude = Vector3(ax, ay, az).length;

        if ((magnitude - 1.0).abs() < 0.1) {
          const alpha = 0.95;
          _gravity = _gravity * alpha + Vector3(ax, ay, az) * (1 - alpha);

          final now = DateTime.now().millisecondsSinceEpoch;
          _gravityHistory.add(MapEntry(now, _gravity.clone()));

          final windowCutoff = now - DetectionConfig.mountStabilityWindowMs;
          while (_gravityHistory.isNotEmpty && _gravityHistory.first.key < windowCutoff) {
            _gravityHistory.removeFirst();
          }

          if (_gravityHistory.isNotEmpty) {
            final oldestGravity = _gravityHistory.first.value;
            final angleRads = _gravity.angleTo(oldestGravity);
            final angleDeg = degrees(angleRads);
            if (angleDeg > DetectionConfig.mountStabilityAngleDeg) {
              final targetMs = now + DetectionConfig.mountStabilitySuppressMs;
              if (targetMs > _suppressUntilMs) {
                _suppressUntilMs = targetMs;
              }
            }
          }
        }
      }, onError: (err) {
        // Safe stub for platforms without physical sensors
      });
    } catch (_) {}
  }

  void _startUserAccel() {
    try {
      _userAccelSub = _sensorSource!.userAccelerometer.listen((event) {
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - _lastAccelMs < (1000 / _currentAccelHz).round()) return;
        _lastAccelMs = now;

        final ux = event.x / 9.81;
        final uy = event.y / 9.81;
        final uz = event.z / 9.81;
        final gNorm = _gravity.normalized();

        final vert = Vector3(ux, uy, uz).dot(gNorm);
        double vertAbs = vert.abs();

        bool isSuppressed = now < _suppressUntilMs || _currentGpsSpeedKmh < DetectionConfig.gpsSpeedGateKmh;
        if (isSuppressed) {
          vertAbs = 0.0;
        } else {
          _updateZScoreBaseline(now, vertAbs);
        }

        _accelWindow.add(AccelSample(now, vertAbs));
        final cutoff = now - _rollingWindowMs;
        while (_accelWindow.isNotEmpty && _accelWindow.first.ts < cutoff) {
          _accelWindow.removeFirst();
        }

        final sum = _accelWindow.fold<double>(0.0, (acc, s) => acc + s.vertAccel);
        _lastSmoothed = _accelWindow.isEmpty ? 0.0 : sum / _accelWindow.length;
        
        final zScore = _currentStdDev > 0 ? (_lastSmoothed - _currentMean) / _currentStdDev : 0.0;

        // Adaptive Sampling Trigger
        if (!isSuppressed && zScore > DetectionConfig.adaptivePreTriggerZScore && _currentAccelHz != DetectionConfig.triggerSamplingHz) {
          _currentAccelHz = DetectionConfig.triggerSamplingHz;
          _rebindSensors();
          Future.delayed(const Duration(milliseconds: DetectionConfig.adaptiveBurstDurationMs), () {
            _currentAccelHz = DetectionConfig.baselineSamplingHz;
            _rebindSensors();
          });
        }

        _graphWindow.add(AccelSample(now, _lastSmoothed, zScore: zScore));
        final graphCutoff = now - _graphWindowMs;
        while (_graphWindow.isNotEmpty && _graphWindow.first.ts < graphCutoff) {
          _graphWindow.removeFirst();
        }

        _accelBatch.add({
          'trip_id': tripId,
          'ts': now,
          'ax': ux,
          'ay': uy,
          'az': uz,
          'vert_accel': vertAbs,
          'vert_accel_smoothed': _lastSmoothed,
          'z_score': zScore,
        });

        // Send to UI ~15Hz
        if (now % 66 < 20) {
          sendPort.send(IsolateDataMessage(
            currentVibration: _lastSmoothed,
            recentVibrations: _graphWindow.toList(),
          ));
        }
      }, onError: (err) {
        // Safe stub for platforms without physical sensors
      });
    } catch (_) {}
  }
  
  void _rebindSensors() {
    _gyroSub?.cancel();
    _accelSub?.cancel();
    _userAccelSub?.cancel();
    if (replayFilePath == null) {
      _sensorSource = RealSensorSource(_getSensorInterval());
    }
    _startSensors();
  }
  
  Duration _getSensorInterval() {
    return Duration(microseconds: (1000000 / _currentAccelHz).round());
  }
  
  void _updateZScoreBaseline(int now, double vertAbs) {
    _validVertTimeWindow.add(now);
    _validVertWindow.add(vertAbs);
    
    final cutoff = now - _zScoreWindowMs;
    while (_validVertTimeWindow.isNotEmpty && _validVertTimeWindow.first < cutoff) {
      _validVertTimeWindow.removeFirst();
      _validVertWindow.removeFirst();
    }
    
    if (_validVertWindow.length > 10) {
      final mean = _validVertWindow.fold<double>(0.0, (acc, val) => acc + val) / _validVertWindow.length;
      final variance = _validVertWindow.fold<double>(0.0, (acc, val) => acc + math.pow(val - mean, 2)) / _validVertWindow.length;
      _currentMean = mean;
      _currentStdDev = math.sqrt(variance);
      if (_currentStdDev < 0.001) _currentStdDev = 0.001; // Avoid div 0
    }
  }

  void _startGps(double gpsHz) {
    final intervalMs = (1000 / gpsHz).round();
    _gpsTimer = Timer.periodic(Duration(milliseconds: intervalMs), (_) async {
      Position position;
      try {
        position = await _sensorSource!.getCurrentPosition();
        if (position.accuracy > 25.0) return;
        _currentGpsSpeedKmh = position.speed * 3.6;
      } catch (_) {
        return;
      }

      final now = DateTime.now().millisecondsSinceEpoch;
      final zScore = _currentStdDev > 0 ? (_lastSmoothed - _currentMean) / _currentStdDev : 0.0;
      final color = _colorForZScore(zScore);

      _gpsBatch.add({
        'trip_id': tripId,
        'ts': now,
        'lat': position.latitude,
        'lon': position.longitude,
        'speed': position.speed,
        'accuracy': position.accuracy,
        'accel_color': color,
        'accel_val': _lastSmoothed,
        'z_score': zScore,
      });

      sendPort.send(IsolateDataMessage(
        currentVibration: _lastSmoothed,
        recentVibrations: _graphWindow.toList(),
        latestGps: GpsSample(
          ts: now,
          lat: position.latitude,
          lon: position.longitude,
          color: color,
          accelVal: _lastSmoothed,
          zScore: zScore,
        ),
      ));
    });
  }

  String _colorForZScore(double zScore) {
    if (zScore >= 4.0) return 'red'; // Severe
    if (zScore >= 3.0) return 'orange'; // Moderate-Severe
    if (zScore >= 2.0) return 'yellow'; // Mild
    return 'green';
  }

  double _getFidelityGpsHz(String fidelity) {
    switch (fidelity) {
      case 'high': return 1.0;
      case 'medium': return 0.5;
      case 'low': return 0.2;
      default: return 0.5;
    }
  }

  Future<void> _flushBatch() async {
    if (_gpsBatch.isEmpty && _accelBatch.isEmpty) return;
    
    final db = await RoadDb.instance.database;
    final batch = db.batch();
    
    for (final g in _gpsBatch) {
      batch.insert('gps_samples', g);
    }
    for (final a in _accelBatch) {
      batch.insert('accel_samples', a);
    }
    
    _gpsBatch.clear();
    _accelBatch.clear();
    
    await batch.commit(noResult: true);
  }

  void stop() {
    _accelSub?.cancel();
    _userAccelSub?.cancel();
    _gyroSub?.cancel();
    _batchTimer?.cancel();
    _gpsTimer?.cancel();
    _flushBatch();
  }
}
