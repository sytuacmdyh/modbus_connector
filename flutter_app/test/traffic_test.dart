import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modbus_desktop/src/session_controller.dart';
import 'package:modbus_desktop/src/traffic_panel.dart';

import 'fake_bridge.dart';

void main() {
  testWidgets(
    'traffic is bounded, filterable and pause does not stop capture',
    (tester) async {
      tester.view.physicalSize = const Size(900, 650);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bridge = FakeBridge();
      final session = SessionController(bridge);
      bridge.onTraffic!(
        [
          for (var i = 0; i < 10010; i++)
            {'time': '$i', 'direction': 'tx', 'hex': '01 03 AA'},
          {
            'time': '2026-11-16T22:05:47.688123',
            'direction': 'rx',
            'hex': '01 03 BB',
          },
        ],
        {'operations': 20},
      );
      expect(session.traffic.length, 10000);
      expect(session.traffic.first['time'], '11');
      expect(session.traffic.last['time'], '2026-11-16T22:05:47.688123');
      final traffic = TrafficController(session);
      addTearDown(traffic.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                TrafficToolbar(controller: traffic),
                Expanded(child: TrafficPanel(controller: traffic)),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('traffic-direction')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('RX').last);
      await tester.pumpAndSettle();
      expect(find.text('22:05:47.688  RX  01 03 BB'), findsOneWidget);
      expect(find.textContaining('01 03 AA'), findsNothing);
      await tester.tap(find.byTooltip('Pause display'));
      await tester.pumpAndSettle();
      bridge.onTraffic!([
        {'time': 'new', 'direction': 'rx', 'hex': '01 03 CC'},
      ], {});
      await tester.pump();
      expect(find.textContaining('01 03 CC'), findsNothing);
      await tester.tap(find.byTooltip('Resume display'));
      await tester.pumpAndSettle();
      expect(find.textContaining('01 03 CC'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'CC');
      await tester.pump();
      expect(find.textContaining('01 03 BB'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
      expect(bridge.onTraffic, isNull);
    },
  );
}
