import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'models.dart';

class WebDashboard extends StatefulWidget {
  const WebDashboard({super.key});

  @override
  State<WebDashboard> createState() => _WebDashboardState();
}

class _WebDashboardState extends State<WebDashboard> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final MapController _mapController = MapController();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Road Quality Global Dashboard'),
        backgroundColor: Theme.of(context).colorScheme.primaryContainer,
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: _firestore.collection('trips').snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }

          final tripsDocs = snapshot.data?.docs ?? [];
          final allPolylines = <Polyline>[];
          LatLng? lastKnownCenter;

          for (final doc in tripsDocs) {
            final data = doc.data() as Map<String, dynamic>;
            final samplesList = data['samples'] as List<dynamic>? ?? [];
            final samples = samplesList.map((s) {
              final map = s as Map<String, dynamic>;
              return GpsSample(
                ts: map['ts'] as int,
                lat: (map['lat'] as num).toDouble(),
                lon: (map['lon'] as num).toDouble(),
                color: map['color'] as String,
                accelVal: (map['accelVal'] as num?)?.toDouble() ?? 0.0,
                zScore: (map['z_score'] as num?)?.toDouble() ?? 0.0,
              );
            }).toList();

            if (samples.isNotEmpty) {
              lastKnownCenter = LatLng(samples.last.lat, samples.last.lon);
            }
            allPolylines.addAll(_buildPolylines(samples));
          }

          return FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter:
                  lastKnownCenter ?? const LatLng(37.773972, -122.431297),
              initialZoom: 12.0,
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.pothole_finder',
              ),
              PolylineLayer(polylines: allPolylines),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          // Quick way to center roughly around the data
          _mapController.move(const LatLng(37.773972, -122.431297), 12.0);
        },
        child: const Icon(Icons.center_focus_strong),
      ),
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
