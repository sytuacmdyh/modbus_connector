import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modbus_desktop/main.dart';
import 'package:modbus_desktop/src/session_controller.dart';

import 'fake_bridge.dart';

void main() {
  testWidgets(
    'RTU form validates, Enter connects, writes validate and Escape cancels',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bridge = FakeBridge();
      final session = SessionController(bridge);
      await tester.pumpWidget(ModbusApp(controller: session));
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();
      expect(find.text('Enter COM3 or /dev/ttyUSB0'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Serial port'),
        'COM7',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(session.connected, isTrue);
      expect(bridge.calls.first['transport'], 'rtu');
      expect(bridge.calls.first['port'], 'COM7');
      expect(bridge.calls.first['baudrate'], 9600);
      await tester.tap(find.text('Read'));
      await tester.pumpAndSettle();
      expect(session.values.first, 100);
      expect(session.canRead, isTrue);
      await tester.tap(find.byTooltip('Write address 0'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextFormField),
        ),
        '70000',
      );
      await tester.tap(find.text('Write'));
      await tester.pumpAndSettle();
      expect(find.text('0–65535'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(bridge.calls.where((c) => c['command'] == 'write'), isEmpty);
      await tester.tap(find.byTooltip('Write address 0'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextFormField),
        ),
        '0x2A',
      );
      await tester.tap(find.text('Write'));
      await tester.pumpAndSettle();
      expect(session.values.first, 42);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Start · 0-based'),
        '10',
      );
      await tester.pump();
      expect(find.text('Read to apply range'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.edit_outlined).first,
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('Read'));
      await tester.pumpAndSettle();
      expect(session.query.address, 10);
      expect(bridge.calls.last['address'], 10);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );

  testWidgets(
    'large bit table is virtualized and minimum desktop layout has no overflow',
    (tester) async {
      tester.view.physicalSize = const Size(900, 650);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = SessionController(FakeBridge());
      session.setQuery(const ReadQuery(kind: 'coils', count: 2000));
      await tester.pumpWidget(ModbusApp(controller: session));
      expect(find.byType(InkWell).evaluate().length, lessThan(100));
      expect(find.byTooltip('Write address 1999'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );
}
