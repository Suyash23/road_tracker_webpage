class GpsSample {
  GpsSample({
    required this.ts,
    required this.lat,
    required this.lon,
    required this.color,
    this.accelVal = 0.0,
    this.zScore = 0.0,
  });

  final int ts;
  final double lat;
  final double lon;
  final String color;
  final double accelVal;
  final double zScore;

  factory GpsSample.fromRow(Map<String, Object?> row) {
    return GpsSample(
      ts: row['ts'] as int,
      lat: row['lat'] as double,
      lon: row['lon'] as double,
      color: (row['accel_color'] as String?) ?? 'green',
      accelVal: (row['accel_val'] as num?)?.toDouble() ?? 0.0,
      zScore: (row['z_score'] as num?)?.toDouble() ?? 0.0,
    );
  }
}

class AccelSample {
  AccelSample(this.ts, this.vertAccel, {this.zScore = 0.0});
  final int ts;
  final double vertAccel;
  final double zScore;
}

class FidelityPreset {
  const FidelityPreset(this.gpsHz, this.accelHz);
  final double gpsHz;
  final double accelHz;
}

class Trip {
  Trip({
    required this.id,
    required this.startTimeMs,
    this.endTimeMs,
    required this.fidelity,
  });

  final int id;
  final int startTimeMs;
  final int? endTimeMs;
  final String fidelity;

  factory Trip.fromRow(Map<String, Object?> row) {
    return Trip(
      id: row['id'] as int,
      startTimeMs: row['start_time'] as int,
      endTimeMs: row['end_time'] as int?,
      fidelity: row['fidelity'] as String,
    );
  }
}

class DetectionConfig {
  // A1: Phone Handling Filters
  static const double gpsSpeedGateKmh = 5.0;
  static const double gyroThresholdRads = 2.0;
  static const double mountStabilityAngleDeg = 10.0;
  static const int mountStabilityWindowMs = 1000;
  static const int mountStabilitySuppressMs = 3000;

  // A7: Privacy Trimming
  static const double trimDistanceMeters = 200.0;

  // A4: Adaptive Sampling
  static const double baselineSamplingHz = 25.0;
  static const double triggerSamplingHz = 100.0;
  static const double adaptivePreTriggerZScore = 1.5;
  static const int adaptiveBurstDurationMs = 1000;
  static const double batterySaverBaselineHz = 10.0;
  static const double batterySaverTriggerHz = 50.0;
}
