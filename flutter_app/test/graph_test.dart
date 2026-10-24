import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modbus_desktop/src/graph_dialog.dart';
import 'package:modbus_desktop/src/session_controller.dart';

import 'fake_bridge.dart';

void main() {
  test('nearest sample uses timestamps across uneven sample intervals', () {
    final origin = DateTime(2026);
    final samples = [
      Sample(origin, 1),
      Sample(origin.add(const Duration(seconds: 1)), 2),
      Sample(origin.add(const Duration(seconds: 100)), 3),
    ];
    expect(
      nearestGraphSample(
        samples,
        origin.add(const Duration(seconds: 3)),
      )!.value,
      2,
    );
    expect(
      nearestGraphSample(
        samples,
        origin.add(const Duration(seconds: 90)),
      )!.value,
      3,
    );
    expect(nearestGraphSample([], origin), isNull);
  });

  testWidgets(
    'graph shows multiple numeric curves, statistics, pause and normalization',
    (tester) async {
      tester.view.physicalSize = const Size(900, 650);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = SessionController(FakeBridge());
      session.recordPoint('a', 'Voltage', 230);
      session.recordPoint('b', 'Current', 5);
      await tester.pumpWidget(MaterialApp(home: GraphDialog(session: session)));
      expect(find.textContaining('Voltage:'), findsOneWidget);
      expect(find.textContaining('Current:'), findsOneWidget);
      await tester.tap(find.text('Normalize each curve'));
      await tester.pump();
      await tester.tap(find.text('Pause chart'));
      await tester.pump();
      expect(find.text('Resume chart'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );
}
