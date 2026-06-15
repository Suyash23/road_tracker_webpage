import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

class RoadDb {
  RoadDb._();

  static final RoadDb instance = RoadDb._();
  Database? _db;

  Future<Database> get database async {
    final existing = _db;
    if (existing != null) {
      return existing;
    }
    final dir = await getApplicationSupportDirectory();
    final dbPath = p.join(dir.path, 'road_quality.db');
    final db = await openDatabase(
      dbPath,
      version: 3,
      onConfigure: (db) async {
        // WAL mode removed to prevent SqfliteDarwinDatabase Code=0 error on macOS
      },
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE trips (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            start_time INTEGER NOT NULL,
            end_time INTEGER,
            fidelity TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE gps_samples (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            trip_id INTEGER NOT NULL,
            ts INTEGER NOT NULL,
            lat REAL NOT NULL,
            lon REAL NOT NULL,
            speed REAL,
            accuracy REAL,
            accel_color TEXT,
            accel_val REAL,
            z_score REAL DEFAULT 0.0,
            FOREIGN KEY (trip_id) REFERENCES trips(id)
          )
        ''');
        await db.execute('''
          CREATE TABLE accel_samples (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            trip_id INTEGER NOT NULL,
            ts INTEGER NOT NULL,
            ax REAL NOT NULL,
            ay REAL NOT NULL,
            az REAL NOT NULL,
            vert_accel REAL,
            vert_accel_smoothed REAL,
            z_score REAL DEFAULT 0.0,
            FOREIGN KEY (trip_id) REFERENCES trips(id)
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_gps_trip_ts ON gps_samples(trip_id, ts)',
        );
        await db.execute(
          'CREATE INDEX idx_accel_trip_ts ON accel_samples(trip_id, ts)',
        );
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
            'ALTER TABLE gps_samples ADD COLUMN accel_val REAL DEFAULT 0.0',
          );
        }
        if (oldVersion < 3) {
          await db.execute(
            'ALTER TABLE gps_samples ADD COLUMN z_score REAL DEFAULT 0.0',
          );
          await db.execute(
            'ALTER TABLE accel_samples ADD COLUMN z_score REAL DEFAULT 0.0',
          );
        }
      },
    );
    _db = db;
    return db;
  }

  Future<int> insertTrip({
    required int startTimeMs,
    required String fidelity,
  }) async {
    final db = await database;
    return db.insert('trips', {
      'start_time': startTimeMs,
      'fidelity': fidelity,
    });
  }

  Future<void> endTrip({required int tripId, required int endTimeMs}) async {
    final db = await database;
    await db.update(
      'trips',
      {'end_time': endTimeMs},
      where: 'id = ?',
      whereArgs: [tripId],
    );
  }

  Future<int?> getLatestTripId() async {
    final db = await database;
    final rows = await db.query(
      'trips',
      columns: ['id'],
      orderBy: 'start_time DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['id'] as int;
  }

  Future<List<Map<String, Object?>>> getAllTrips() async {
    final db = await database;
    return db.query('trips', orderBy: 'start_time DESC');
  }

  Future<List<Map<String, Object?>>> getGpsSamples(int tripId) async {
    final db = await database;
    return db.query(
      'gps_samples',
      where: 'trip_id = ?',
      whereArgs: [tripId],
      orderBy: 'ts ASC',
    );
  }

  Future<void> insertGpsSample({
    required int tripId,
    required int ts,
    required double lat,
    required double lon,
    double? speed,
    double? accuracy,
    String? accelColor,
    double? accelVal,
    double? zScore,
  }) async {
    final db = await database;
    await db.insert('gps_samples', {
      'trip_id': tripId,
      'ts': ts,
      'lat': lat,
      'lon': lon,
      'speed': speed,
      'accuracy': accuracy,
      'accel_color': accelColor,
      'accel_val': accelVal,
      'z_score': zScore,
    });
  }

  Future<void> insertAccelSample({
    required int tripId,
    required int ts,
    required double ax,
    required double ay,
    required double az,
    double? vertAccel,
    double? vertAccelSmoothed,
    double? zScore,
  }) async {
    final db = await database;
    await db.insert('accel_samples', {
      'trip_id': tripId,
      'ts': ts,
      'ax': ax,
      'ay': ay,
      'az': az,
      'vert_accel': vertAccel,
      'vert_accel_smoothed': vertAccelSmoothed,
      'z_score': zScore,
    });
  }
}
