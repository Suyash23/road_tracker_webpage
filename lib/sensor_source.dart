import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:geolocator/geolocator.dart';

abstract class SensorSource {
  Stream<AccelerometerEvent> get accelerometer;
  Stream<UserAccelerometerEvent> get userAccelerometer;
  Stream<GyroscopeEvent> get gyroscope;
  Future<Position> getCurrentPosition();
}

class RealSensorSource implements SensorSource {
  final Duration interval;
  RealSensorSource(this.interval);

  @override
  Stream<AccelerometerEvent> get accelerometer => accelerometerEventStream(samplingPeriod: interval);
  
  @override
  Stream<UserAccelerometerEvent> get userAccelerometer => userAccelerometerEventStream(samplingPeriod: interval);
  
  @override
  Stream<GyroscopeEvent> get gyroscope => gyroscopeEventStream(samplingPeriod: interval);

  @override
  Future<Position> getCurrentPosition() {
    return Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
    );
  }
}

class SyntheticSensorSource implements SensorSource {
  final Map<String, dynamic> traceData;
  final Duration interval;
  int _idx = 0;
  int _gpsIdx = 0;
  
  // Streams
  late final StreamController<AccelerometerEvent> _accelCtrl;
  late final StreamController<UserAccelerometerEvent> _userAccelCtrl;
  late final StreamController<GyroscopeEvent> _gyroCtrl;
  
  Timer? _timer;

  SyntheticSensorSource(this.traceData, this.interval) {
    _accelCtrl = StreamController<AccelerometerEvent>.broadcast();
    _userAccelCtrl = StreamController<UserAccelerometerEvent>.broadcast();
    _gyroCtrl = StreamController<GyroscopeEvent>.broadcast();
    
    _startPlayback();
  }
  
  void _startPlayback() {
    final ax = List<double>.from(traceData['imu']['ax']);
    final ay = List<double>.from(traceData['imu']['ay']);
    final az = List<double>.from(traceData['imu']['az']);
    
    _timer = Timer.periodic(interval, (_) {
      if (_idx >= az.length) {
        _timer?.cancel();
        return;
      }
      
      // We simulate gravity on accel
      _accelCtrl.add(AccelerometerEvent(0, 0, 9.81, DateTime.now()));
      
      // And the dynamic movement on userAccel
      // Multiply by 9.81 since JSON trace is in g's, sensor_plus is in m/s^2
      _userAccelCtrl.add(UserAccelerometerEvent(
        ax[_idx] * 9.81, 
        ay[_idx] * 9.81, 
        (az[_idx] - 1.0) * 9.81,
        DateTime.now()
      ));
      
      _gyroCtrl.add(GyroscopeEvent(0, 0, 0, DateTime.now()));
      
      _idx++;
    });
  }

  @override
  Stream<AccelerometerEvent> get accelerometer => _accelCtrl.stream;
  
  @override
  Stream<UserAccelerometerEvent> get userAccelerometer => _userAccelCtrl.stream;
  
  @override
  Stream<GyroscopeEvent> get gyroscope => _gyroCtrl.stream;

  @override
  Future<Position> getCurrentPosition() async {
    final lats = List<double>.from(traceData['gps']['lat']);
    final lons = List<double>.from(traceData['gps']['lon']);
    final speeds = List<double>.from(traceData['gps']['speed']);
    
    if (_gpsIdx >= lats.length) _gpsIdx = lats.length - 1;
    
    final p = Position(
      longitude: lons[_gpsIdx],
      latitude: lats[_gpsIdx],
      timestamp: DateTime.now(),
      accuracy: 5.0,
      altitude: 0.0,
      altitudeAccuracy: 0.0,
      heading: 0.0,
      headingAccuracy: 0.0,
      speed: speeds[_gpsIdx],
      speedAccuracy: 0.0,
    );
    _gpsIdx++;
    return p;
  }
  
  static Future<SyntheticSensorSource> fromFile(String path, Duration interval) async {
    final file = File(path);
    final contents = await file.readAsString();
    final data = jsonDecode(contents);
    return SyntheticSensorSource(data, interval);
  }
}
