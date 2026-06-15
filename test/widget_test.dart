import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pothole_finder/main.dart';

void main() {
  testWidgets('Road Quality Mapper UI smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const RoadQualityApp());

    // Verify that the title "Road Quality Mapper" is shown in the AppBar.
    expect(find.text('Road Quality Mapper'), findsOneWidget);

    // Verify that the initial state is 'Idle'.
    expect(find.text('Idle'), findsOneWidget);

    // Verify that 'Start' button is present.
    expect(find.text('Start'), findsOneWidget);

    // Verify that 'Stop' button is present.
    expect(find.text('Stop'), findsOneWidget);
  });
}
