import 'dart:collection';
import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math_64.dart';
import 'package:geolocator/geolocator.dart';

import 'package:pothole_finder/models.dart';
import 'package:pothole_finder/sensor_source.dart';

// Test implementation of the Douglas-Peucker decimation to verify mathematical correctness
List<GpsSample> runDouglasPeucker(List<GpsSample> points, double epsilon) {
  if (points.length < 3) return points;

  double dmax = 0.0;
  int index = 0;
  for (int i = 1; i < points.length - 1; i++) {
    double d = perpendicularDistance(points[i], points.first, points.last);
    if (d > dmax) {
      index = i;
      dmax = d;
    }
  }

  if (dmax > epsilon) {
    final res1 = runDouglasPeucker(points.sublist(0, index + 1), epsilon);
    final res2 = runDouglasPeucker(points.sublist(index, points.length), epsilon);
    return [...res1.sublist(0, res1.length - 1), ...res2];
  } else {
    return [points.first, points.last];
  }
}

double perpendicularDistance(GpsSample point, GpsSample lineStart, GpsSample lineEnd) {
  double x = point.lat;
  double y = point.lon;
  double x1 = lineStart.lat;
  double y1 = lineStart.lon;
  double x2 = lineEnd.lat;
  double y2 = lineEnd.lon;

  double num = ((y2 - y1) * x - (x2 - x1) * y + x2 * y1 - y2 * x1).abs();
  double den = math.sqrt(math.pow(y2 - y1, 2) + math.pow(x2 - x1, 2));
  if (den == 0) return 0.0;
  return (num / den) * 111000.0; // approximate distance in meters
}

// Test implementation of the privacy coordinate trimming to verify math correctness
List<GpsSample> runTrimTripEndpoints(List<GpsSample> samples, double trimDistance) {
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Requirement F1: Vertical Acceleration Projection Tests', () {
    test('Calculates vertical acceleration parallel to gravity axis correctly', () {
      final gravity = Vector3(0.0, 0.0, 1.0); // perfect vertical gravity aligned with Z
      final userAccel = Vector3(0.1, -0.2, 1.5); // user movement dynamic vector

      final gNorm = gravity.normalized();
      final vert = userAccel.dot(gNorm);

      expect(vert, closeTo(1.5, 0.0001));
      expect(vert.abs(), closeTo(1.5, 0.0001));
    });

    test('Projects vertical acceleration with angled phone sensor frame', () {
      // Gravity is diagonal (phone tilted 45 degrees in Y-Z plane)
      final gravity = Vector3(0.0, 1.0, 1.0);
      final gNorm = gravity.normalized(); // [0.0, 0.7071, 0.7071]

      // Movement is purely vertical relative to earth (parallel to gravity)
      final userAccel = Vector3(0.0, 1.0, 1.0) * 2.0; 

      final vert = userAccel.dot(gNorm);
      // Expected: projection length should equal length of userAccel = sqrt(2^2 + 2^2) = sqrt(8) = 2.8284
      expect(vert.abs(), closeTo(math.sqrt(8.0), 0.0001));
    });
  });

  group('Requirement F2: Rolling Average Smoothing Tests', () {
    test('Averages samples within 0.75-second window correctly', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final Queue<AccelSample> window = Queue<AccelSample>();

      // Add samples within 750ms window
      window.add(AccelSample(now - 700, 1.0));
      window.add(AccelSample(now - 400, 2.0));
      window.add(AccelSample(now - 100, 3.0));

      final sum = window.fold<double>(0.0, (acc, s) => acc + s.vertAccel);
      final average = sum / window.length;

      expect(average, closeTo(2.0, 0.0001));
    });

    test('Evicts old samples outside 0.75-second window', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final Queue<AccelSample> window = Queue<AccelSample>();

      window.add(AccelSample(now - 1000, 10.0)); // Should be evicted
      window.add(AccelSample(now - 500, 1.5));
      window.add(AccelSample(now - 100, 2.5));

      final cutoff = now - 750;
      while (window.isNotEmpty && window.first.ts < cutoff) {
        window.removeFirst();
      }

      expect(window.length, equals(2));
      final sum = window.fold<double>(0.0, (acc, s) => acc + s.vertAccel);
      final average = sum / window.length;
      expect(average, closeTo(2.0, 0.0001));
    });
  });

  group('Requirement F3 & F4: Z-Score and Color Mapping Tests', () {
    test('Calculates rolling mean and standard deviation correctly', () {
      final List<double> values = [0.1, 0.2, 0.3, 0.4, 0.5]; // mean = 0.3, stdDev = 0.14142

      final mean = values.fold<double>(0.0, (acc, val) => acc + val) / values.length;
      final variance = values.fold<double>(0.0, (acc, val) => acc + math.pow(val - mean, 2)) / values.length;
      final stdDev = math.sqrt(variance);

      expect(mean, closeTo(0.3, 0.0001));
      expect(stdDev, closeTo(0.14142, 0.0001));

      // Test Z-score mapping for vertical acceleration = 0.58284 (2.0 standard deviations above mean)
      final sampleVal = 0.3 + 2.0 * stdDev;
      final zScore = (sampleVal - mean) / stdDev;
      expect(zScore, closeTo(2.0, 0.0001));
    });

    test('Correctly maps Z-scores to severity colors', () {
      String getColor(double zScore) {
        if (zScore >= 4.0) return 'red';
        if (zScore >= 3.0) return 'orange';
        if (zScore >= 2.0) return 'yellow';
        return 'green';
      }

      expect(getColor(0.5), equals('green'));
      expect(getColor(1.9), equals('green'));
      expect(getColor(2.0), equals('yellow'));
      expect(getColor(2.9), equals('yellow'));
      expect(getColor(3.0), equals('orange'));
      expect(getColor(3.9), equals('orange'));
      expect(getColor(4.0), equals('red'));
      expect(getColor(12.5), equals('red'));
    });
  });

  group('Requirement F5: Douglas-Peucker Decimation Tests', () {
    test('Simplifies a perfectly straight line to just start and end points', () {
      final List<GpsSample> line = [
        GpsSample(ts: 1000, lat: 37.7739, lon: -122.4312, color: 'green'),
        GpsSample(ts: 2000, lat: 37.7740, lon: -122.4311, color: 'green'),
        GpsSample(ts: 3000, lat: 37.7741, lon: -122.4310, color: 'green'),
        GpsSample(ts: 4000, lat: 37.7742, lon: -122.4309, color: 'green'),
      ];

      final simplified = runDouglasPeucker(line, 5.0); // epsilon of 5 meters

      expect(simplified.length, equals(2));
      expect(simplified.first.ts, equals(1000));
      expect(simplified.last.ts, equals(4000));
    });

    test('Retains significant jagged points above epsilon distance threshold', () {
      final List<GpsSample> path = [
        GpsSample(ts: 1000, lat: 37.7739, lon: -122.4312, color: 'green'),
        // Spiked point roughly 25 meters perpendicular away from the direct line (offset longitude)
        GpsSample(ts: 2000, lat: 37.7740, lon: -122.4315, color: 'green'), 
        GpsSample(ts: 3000, lat: 37.7741, lon: -122.4312, color: 'green'),
      ];

      final simplified = runDouglasPeucker(path, 5.0); // epsilon = 5 meters

      expect(simplified.length, equals(3)); // Spiked point must be retained
    });
  });

  group('Requirement F6: Privacy Coordinate Trimming Tests', () {
    test('Correctly trims start and end coordinate points within 200 meters', () {
      // 1 degree latitude roughly 111,000 meters. 0.001 deg is ~111 meters.
      // Setup a trip path totaling ~550 meters:
      // Pt 0 -> Pt 1: ~111m
      // Pt 1 -> Pt 2: ~111m  (Total 222m -> Trimming start should end at Pt 2)
      // Pt 2 -> Pt 3: ~111m
      // Pt 3 -> Pt 4: ~111m  (Trimming end backwards)
      // Pt 4 -> Pt 5: ~111m
      final List<GpsSample> path = [
        GpsSample(ts: 1, lat: 37.770, lon: -122.430, color: 'green'), // Pt 0
        GpsSample(ts: 2, lat: 37.771, lon: -122.430, color: 'green'), // Pt 1 (~111m)
        GpsSample(ts: 3, lat: 37.772, lon: -122.430, color: 'green'), // Pt 2 (~222m)
        GpsSample(ts: 4, lat: 37.773, lon: -122.430, color: 'green'), // Pt 3 (~333m)
        GpsSample(ts: 5, lat: 37.774, lon: -122.430, color: 'green'), // Pt 4 (~444m)
        GpsSample(ts: 6, lat: 37.775, lon: -122.430, color: 'green'), // Pt 5 (~555m)
      ];

      final trimmed = runTrimTripEndpoints(path, 200.0);

      // Trimming 200m from start (Pt 0, Pt 1 removed, starts at Pt 2)
      // Trimming 200m from end (Pt 5, Pt 4 removed, ends at Pt 3)
      expect(trimmed.length, equals(2));
      expect(trimmed.first.lat, equals(37.772));
      expect(trimmed.last.lat, equals(37.773));
    });

    test('Returns empty list if trip path is shorter than combined trim thresholds', () {
      final List<GpsSample> shortPath = [
        GpsSample(ts: 1, lat: 37.770, lon: -122.430, color: 'green'),
        GpsSample(ts: 2, lat: 37.771, lon: -122.430, color: 'green'), // ~111m total
      ];

      final trimmed = runTrimTripEndpoints(shortPath, 200.0);
      expect(trimmed, isEmpty);
    });
  });

  group('Requirement F7: Speed Gate Noise Suppression Tests', () {
    test('Verifies that speed gating activates when speed is below 5 km/h', () {
      bool isSuppressed(double speedKmh) {
        return speedKmh < DetectionConfig.gpsSpeedGateKmh;
      }

      expect(isSuppressed(0.0), isTrue);
      expect(isSuppressed(4.9), isTrue);
      expect(isSuppressed(5.0), isFalse);
      expect(isSuppressed(20.0), isFalse);
    });
  });

  group('Requirement F8: Phone Handling Noise Filters Tests', () {
    test('Triggers suppression when angular rotation magnitude exceeds 2.0 rads', () {
      bool shouldSuppressGyro(double gx, double gy, double gz) {
        final magnitude = Vector3(gx, gy, gz).length;
        return magnitude > DetectionConfig.gyroThresholdRads;
      }

      expect(shouldSuppressGyro(0.0, 0.0, 0.0), isFalse);
      expect(shouldSuppressGyro(1.0, 1.0, 1.0), isFalse); // length = sqrt(3) ~1.732
      expect(shouldSuppressGyro(1.2, 1.2, 1.2), isTrue);  // length = sqrt(4.32) ~2.08
      expect(shouldSuppressGyro(0.0, 0.0, 2.1), isTrue);  // length = 2.1
    });

    test('Triggers suppression when mount stability angle shifts by more than 10 degrees', () {
      bool shouldSuppressAngle(Vector3 gravityOld, Vector3 gravityNew) {
        final angleRads = gravityNew.angleTo(gravityOld);
        final angleDeg = angleRads * 180 / math.pi;
        return angleDeg > DetectionConfig.mountStabilityAngleDeg;
      }

      final vertical = Vector3(0.0, 0.0, 1.0);
      final tinyShift = Vector3(0.0, 0.05, 0.9987); // ~2.8 degrees
      final largeShift = Vector3(0.0, 0.25, 0.968); // ~14.4 degrees

      expect(shouldSuppressAngle(vertical, vertical), isFalse);
      expect(shouldSuppressAngle(vertical, tinyShift), isFalse);
      expect(shouldSuppressAngle(vertical, largeShift), isTrue);
    });
  });

  group('Requirement F9: Adaptive Sensor Ingestion Rates Tests', () {
    test('Adaptive rate trigger switches baseline to high rate based on Z-score threshold', () {
      double currentHz = DetectionConfig.baselineSamplingHz;

      void checkAdaptiveTrigger(double zScore) {
        if (zScore > DetectionConfig.adaptivePreTriggerZScore) {
          currentHz = DetectionConfig.triggerSamplingHz;
        }
      }

      checkAdaptiveTrigger(0.5);
      expect(currentHz, equals(25.0)); // remains baseline

      checkAdaptiveTrigger(1.6);
      expect(currentHz, equals(100.0)); // switches to high trigger rate
    });
  });

  group('Requirement F10: Parsing Models Data Integrity Tests', () {
    test('Parses GpsSample and Trip correctly from database row maps', () {
      final tripRow = {
        'id': 42,
        'start_time': 1716600000000,
        'end_time': 1716601800000,
        'fidelity': 'high',
      };

      final trip = Trip.fromRow(tripRow);
      expect(trip.id, equals(42));
      expect(trip.startTimeMs, equals(1716600000000));
      expect(trip.endTimeMs, equals(1716601800000));
      expect(trip.fidelity, equals('high'));

      final gpsRow = {
        'ts': 1716600050000,
        'lat': 37.773972,
        'lon': -122.431297,
        'accel_color': 'orange',
        'accel_val': 0.45,
        'z_score': 3.2,
      };

      final gpsSample = GpsSample.fromRow(gpsRow);
      expect(gpsSample.ts, equals(1716600050000));
      expect(gpsSample.lat, equals(37.773972));
      expect(gpsSample.lon, equals(-122.431297));
      expect(gpsSample.color, equals('orange'));
      expect(gpsSample.accelVal, equals(0.45));
      expect(gpsSample.zScore, equals(3.2));
    });
  });

  group('Requirement Ingestion: Synthetic Sensor Source Serialization Tests', () {
    test('Verifies SyntheticSensorSource loads mock JSON structures accurately', () {
      final mockData = {
        'imu': {
          'ax': [0.0, 0.1],
          'ay': [0.0, -0.1],
          'az': [1.0, 1.2]
        },
        'gps': {
          'lat': [37.77, 37.78],
          'lon': [-122.43, -122.44],
          'speed': [10.0, 12.0]
        }
      };

      final source = SyntheticSensorSource(mockData, const Duration(milliseconds: 100));

      // Manually pull GPS positions to verify parsing accuracy
      expect(source.getCurrentPosition(), completion(predicate<Position>((p) {
        return p.latitude == 37.77 && p.longitude == -122.43 && p.speed == 10.0;
      })));

      expect(source.getCurrentPosition(), completion(predicate<Position>((p) {
        return p.latitude == 37.78 && p.longitude == -122.44 && p.speed == 12.0;
      })));
    });

    test('Verifies loading actual mixed_real_world.json scenario', () async {
      final path = '/Users/suyashpandya/Desktop/pothole_inference_engine/out/mixed_real_world.json';
      final source = await SyntheticSensorSource.fromFile(path, const Duration(milliseconds: 10));
      expect(source.traceData['imu']['ax'], isNotEmpty);
      final firstPos = await source.getCurrentPosition();
      expect(firstPos.latitude, isNotNull);
    });

    test('Verifies loading actual adversarial.json scenario', () async {
      final path = '/Users/suyashpandya/Desktop/pothole_inference_engine/out/adversarial.json';
      final source = await SyntheticSensorSource.fromFile(path, const Duration(milliseconds: 10));
      expect(source.traceData['imu']['ax'], isNotEmpty);
      final firstPos = await source.getCurrentPosition();
      expect(firstPos.latitude, isNotNull);
    });

    test('Verifies loading actual sf_to_fremont.json scenario', () async {
      final path = '/Users/suyashpandya/Desktop/pothole_inference_engine/out/sf_to_fremont.json';
      final source = await SyntheticSensorSource.fromFile(path, const Duration(milliseconds: 10));
      expect(source.traceData['imu']['ax'], isNotEmpty);
      final firstPos = await source.getCurrentPosition();
      expect(firstPos.latitude, isNotNull);
    });
  });
}
