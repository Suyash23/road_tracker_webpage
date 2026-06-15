import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'dart:math' as math;
import 'dart:io';
import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart'; // for kIsWeb
import 'package:geolocator/geolocator.dart';
import 'package:fl_chart/fl_chart.dart';

import 'firebase_options.dart';
import 'history.dart';
import 'models.dart';
import 'recorder.dart';
import 'road_db.dart';
import 'web_dashboard.dart';
import 'package:file_picker/file_picker.dart' as fp;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const RoadQualityApp());
}

class RoadQualityApp extends StatelessWidget {
  const RoadQualityApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Road Quality Mapper',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: kIsWeb ? const WebDashboard() : const RoadQualityHome(),
    );
  }
}

class RoadQualityHome extends StatefulWidget {
  const RoadQualityHome({super.key});

  @override
  State<RoadQualityHome> createState() => _RoadQualityHomeState();
}

class _RoadQualityHomeState extends State<RoadQualityHome> {
  late final RoadRecorder _recorder;
  final MapController _mapController = MapController();

  @override
  void initState() {
    super.initState();
    _recorder = RoadRecorder(RoadDb.instance);
    _recorder.loadLatestTrip();
  }

  @override
  void dispose() {
    _recorder.stop();
    _recorder.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _recorder,
      builder: (context, _) {
        final samples = _recorder.gpsSamples;
        final polylines = _buildPolylines(samples);
        final center = samples.isNotEmpty
            ? LatLng(samples.last.lat, samples.last.lon)
            : const LatLng(37.773972, -122.431297);

        return Scaffold(
          appBar: AppBar(
            title: const Text('Road Quality Mapper'),
            backgroundColor: Theme.of(context).colorScheme.primaryContainer,
            actions: [
              PopupMenuButton<String>(
                onSelected: (value) async {
                  if (value == 'history') {
                    final tripId = await Navigator.of(context).push<int>(
                      MaterialPageRoute(
                        builder: (_) => const TripsHistoryScreen(),
                      ),
                    );
                    if (tripId != null) {
                      _recorder.loadTrip(tripId);
                    }
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(value: 'history', child: Text('History')),
                ],
              ),
            ],
          ),
          body: Column(
            children: [
              _StatusBar(
                isRecording: _recorder.isRecording,
                currentVibration: _recorder.currentVibration,
                recentVibrations: _recorder.recentVibrations,
              ),
              Expanded(
                child: FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(initialCenter: center, initialZoom: 14.0),
                  children: [
                    TileLayer(
                      urlTemplate:
                          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.example.pothole_finder',
                    ),
                    PolylineLayer(polylines: polylines),
                  ],
                ),
              ),
              _Controls(
                isRecording: _recorder.isRecording,
                fidelity: _recorder.fidelity,
                onStart: _recorder.start,
                onStop: _recorder.stop,
                onFidelityChanged: _recorder.setFidelity,
                onReplaySelected: (path) => _recorder.start(replayFilePath: path),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton(
            onPressed: () async {
              try {
                final position = await Geolocator.getCurrentPosition(
                  locationSettings: const LocationSettings(
                    accuracy: LocationAccuracy.medium,
                  ),
                );
                _mapController.move(
                  LatLng(position.latitude, position.longitude),
                  15.0,
                );
              } catch (e) {
                debugPrint('Could not get location: $e');
              }
            },
            child: const Icon(Icons.my_location),
          ),
        );
      },
    );
  }

  List<Polyline> _buildPolylines(List<GpsSample> samples) {
    if (samples.length < 2) return [];

    final List<List<GpsSample>> segments = [];
    List<GpsSample> currentSegment = [samples.first];

    for (int i = 1; i < samples.length; i++) {
      final prev = samples[i - 1];
      final curr = samples[i];
      
      final timeGap = curr.ts - prev.ts;
      // approximate distance: 1 deg ~ 111,000 m
      final dx = (curr.lon - prev.lon) * math.cos(prev.lat * math.pi / 180.0) * 111000.0;
      final dy = (curr.lat - prev.lat) * 111000.0;
      final distGap = math.sqrt(dx * dx + dy * dy);

      if (timeGap > 10000 || distGap > 100.0) {
        segments.add(currentSegment);
        currentSegment = [curr];
      } else {
        currentSegment.add(curr);
      }
    }
    segments.add(currentSegment);

    final List<Polyline> polylines = [];

    for (final segment in segments) {
      if (segment.length < 2) continue;

      // A3: Douglas-Peucker Decimation (epsilon ~5m)
      final decimated = _douglasPeucker(segment, 5.0);

      List<LatLng> currentPoints = [];
      String currentColor = decimated.first.color;

      for (final sample in decimated) {
        if (sample.color != currentColor && currentPoints.length >= 2) {
          polylines.add(_polylineForColor(currentPoints, currentColor));
          currentPoints = [currentPoints.last];
          currentColor = sample.color;
        }
        currentPoints.add(LatLng(sample.lat, sample.lon));
      }

      if (currentPoints.length >= 2) {
        polylines.add(_polylineForColor(currentPoints, currentColor));
      }
    }

    return polylines;
  }

  List<GpsSample> _douglasPeucker(List<GpsSample> points, double epsilon) {
    if (points.length < 3) return points;

    double dmax = 0.0;
    int index = 0;
    for (int i = 1; i < points.length - 1; i++) {
      double d = _perpendicularDistance(points[i], points.first, points.last);
      if (d > dmax) {
        index = i;
        dmax = d;
      }
    }

    if (dmax > epsilon) {
      final res1 = _douglasPeucker(points.sublist(0, index + 1), epsilon);
      final res2 = _douglasPeucker(points.sublist(index, points.length), epsilon);
      return [...res1.sublist(0, res1.length - 1), ...res2];
    } else {
      return [points.first, points.last];
    }
  }

  double _perpendicularDistance(GpsSample point, GpsSample lineStart, GpsSample lineEnd) {
    double x = point.lat;
    double y = point.lon;
    double x1 = lineStart.lat;
    double y1 = lineStart.lon;
    double x2 = lineEnd.lat;
    double y2 = lineEnd.lon;

    double num = ((y2 - y1) * x - (x2 - x1) * y + x2 * y1 - y2 * x1).abs();
    double den = math.sqrt(math.pow(y2 - y1, 2) + math.pow(x2 - x1, 2));
    if (den == 0) return 0.0;
    // approximate distance in meters (1 deg ~= 111,000 meters)
    return (num / den) * 111000.0;
  }

  Polyline _polylineForColor(List<LatLng> points, String color) {
    return Polyline(points: points, strokeWidth: 5.0, color: _mapColor(color));
  }

  Color _mapColor(String color) {
    switch (color) {
      case 'yellow':
        return Colors.amber;
      case 'red':
        return Colors.redAccent;
      default:
        return Colors.green;
    }
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({
    required this.isRecording,
    required this.currentVibration,
    required this.recentVibrations,
  });

  final bool isRecording;
  final ValueNotifier<double> currentVibration;
  final ValueNotifier<List<AccelSample>> recentVibrations;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: isRecording
          ? Colors.red.withValues(alpha: 0.1)
          : Colors.green.withValues(alpha: 0.1),
      child: Column(
        children: [
          Text(
            isRecording ? 'Recording...' : 'Idle',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (isRecording)
            ValueListenableBuilder<double>(
              valueListenable: currentVibration,
              builder: (context, val, _) {
                return Text('Live Vibration: ${val.toStringAsFixed(2)} g');
              },
            ),
          ValueListenableBuilder<List<AccelSample>>(
            valueListenable: recentVibrations,
            builder: (context, samples, _) {
              if (!isRecording || samples.isEmpty) {
                return const SizedBox.shrink();
              }

              double maxY = 0;
              for (final s in samples) {
                if (s.vertAccel > maxY) {
                  maxY = s.vertAccel;
                }
              }
              maxY = maxY * 1.1; // Add some padding
              if (maxY < 0.1) {
                maxY = 0.1; // Ensure minimum scale so it doesn't look flat
              }

              final spots = samples.map((s) {
                final x =
                    (s.ts - samples.last.ts) /
                    1000.0; // Seconds relative to now
                return FlSpot(x, s.vertAccel);
              }).toList();

              return Container(
                height: 100,
                padding: const EdgeInsets.only(top: 8),
                child: LineChart(
                  LineChartData(
                    minX: -10,
                    maxX: 0,
                    minY: 0,
                    maxY: maxY,
                    lineBarsData: [
                      LineChartBarData(
                        spots: spots,
                        isCurved: false,
                        color: Colors.blueAccent,
                        barWidth: 2,
                        dotData: const FlDotData(show: false),
                      ),
                    ],
                    titlesData: const FlTitlesData(show: false),
                    borderData: FlBorderData(show: false),
                    gridData: const FlGridData(show: false),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.isRecording,
    required this.fidelity,
    required this.onStart,
    required this.onStop,
    required this.onFidelityChanged,
    required this.onReplaySelected,
  });

  final bool isRecording;
  final String fidelity;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final ValueChanged<String> onFidelityChanged;
  final ValueChanged<String> onReplaySelected;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: isRecording ? null : onStart,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Start'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: isRecording ? onStop : null,
                  icon: const Icon(Icons.stop),
                  label: const Text('Stop'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'high', label: Text('High')),
              ButtonSegment(value: 'medium', label: Text('Medium')),
              ButtonSegment(value: 'low', label: Text('Low')),
            ],
            selected: {fidelity},
            onSelectionChanged: (values) {
              if (values.isEmpty) return;
              onFidelityChanged(values.first);
            },
          ),
          const SizedBox(height: 8),
          const _FidelityLegend(),
          const SizedBox(height: 16),
          GestureDetector(
            onLongPress: () async {
              if (isRecording) return;
              _showScenarioPicker(context);
            },
            child: const Text(
              'v1.0.0',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  void _showScenarioPicker(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return FutureBuilder(
          future: _fetchScenarios(),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(child: Text('Error: ${snapshot.error}'));
            }
            final scenarios = snapshot.data as List<dynamic>;
            return ListView.builder(
              itemCount: scenarios.length,
              itemBuilder: (context, index) {
                final id = scenarios[index]['id'];
                return ListTile(
                  leading: const Icon(Icons.map),
                  title: Text(id.toString().toUpperCase()),
                  onTap: () async {
                    Navigator.pop(context);
                    await _simulateAndLoad(context, id);
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  Future<List<dynamic>> _fetchScenarios() async {
    final client = HttpClient();
    final request = await client.getUrl(Uri.parse('http://localhost:8000/scenarios'));
    final response = await request.close();
    final stringData = await response.transform(utf8.decoder).join();
    final jsonResponse = jsonDecode(stringData);
    return jsonResponse['scenarios'];
  }

  Future<void> _simulateAndLoad(BuildContext context, String id) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    try {
      final client = HttpClient();
      // POST simulate
      final simReq = await client.postUrl(Uri.parse('http://localhost:8000/simulate/$id'));
      final simRes = await simReq.close();
      await simRes.drain();
      
      // GET data
      final dataReq = await client.getUrl(Uri.parse('http://localhost:8000/data/$id'));
      final dataRes = await dataReq.close();
      final stringData = await dataRes.transform(utf8.decoder).join();
      
      // Save to temp file
      final Directory tempDir = await getTemporaryDirectory();
      await tempDir.create(recursive: true);
      final File file = File('${tempDir.path}/$id.json');
      await file.writeAsString(stringData);
      
      if (context.mounted) {
        Navigator.pop(context); // Close loading dialog
        onReplaySelected(file.path);
      }
    } catch (e) {
      if (context.mounted) {
        Navigator.pop(context); // Close loading dialog
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }
}

class _FidelityLegend extends StatelessWidget {
  const _FidelityLegend();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: const [
        Text('High: GPS 1 Hz, accel 100 Hz'),
        Text('Medium: GPS 0.5 Hz, accel 50 Hz'),
        Text('Low: GPS 0.2 Hz, accel 20 Hz'),
      ],
    );
  }
}

