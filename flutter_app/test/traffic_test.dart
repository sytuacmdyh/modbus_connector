import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modbus_desktop/src/session_controller.dart';
import 'package:modbus_desktop/src/traffic_dialog.dart';

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
          for (var i = 0; i < 510; i++)
            {'time': '$i', 'direction': 'tx', 'hex': '01 03 AA'},
          {'time': 'rx', 'direction': 'rx', 'hex': '01 03 BB'},
        ],
        {'operations': 20},
      );
      expect(session.traffic.length, 500);
      await tester.pumpWidget(
        MaterialApp(home: TrafficDialog(session: session)),
      );
      await tester.tap(find.text('RX'));
      await tester.pumpAndSettle();
      expect(find.textContaining('01 03 BB'), findsOneWidget);
      expect(find.textContaining('01 03 AA'), findsNothing);
      await tester.tap(find.text('Pause display'));
      await tester.pumpAndSettle();
      bridge.onTraffic!([
        {'time': 'new', 'direction': 'rx', 'hex': '01 03 CC'},
      ], {});
      session.notifyListeners();
      await tester.pump();
      expect(find.textContaining('01 03 CC'), findsNothing);
      await tester.tap(find.text('Resume display'));
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
