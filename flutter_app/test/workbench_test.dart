import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modbus_desktop/main.dart';
import 'package:modbus_desktop/src/session_controller.dart';
import 'package:modbus_desktop/src/bridge_client.dart';
import 'package:modbus_desktop/src/desktop_table.dart';
import 'package:modbus_desktop/src/register_map.dart';

import 'fake_bridge.dart';

void main() {
  testWidgets('RTU form validates and Enter connects above the register map', (
    tester,
  ) async {
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
    expect(find.byType(RegisterMapPanel), findsOneWidget);
    expect(find.text('Read'), findsNothing);
    expect(find.text('Start polling'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });

  testWidgets(
    'register map replaces the quick range and virtualizes large maps',
    (tester) async {
      tester.view.physicalSize = const Size(900, 650);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = SessionController(FakeBridge());
      session.registers.addAll([
        for (var i = 0; i < 2000; i++)
          {
            'name': 'Coil $i',
            'kind': 'coils',
            'address': i,
            'count': 1,
            'format': 'dec',
          },
      ]);
      await tester.pumpWidget(ModbusApp(controller: session));
      expect(find.byType(InkWell).evaluate().length, lessThan(100));
      expect(find.text('Start · 0-based'), findsNothing);
      expect(find.byKey(const ValueKey('register-list')), findsNothing);
      expect(find.text('Register map').hitTestable(), findsOneWidget);
      expect(find.text('Add row').hitTestable(), findsOneWidget);
      expect(find.text('Read map').hitTestable(), findsOneWidget);
      expect(find.text('Poll map').hitTestable(), findsOneWidget);
      final tableList = find.descendant(
        of: find.byType(DesktopTable),
        matching: find.byType(ListView),
      );
      final table = tester.widget<ListView>(tableList).controller!;
      table.jumpTo(table.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(find.text('Coil 1999'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );

  testWidgets(
    'minimum window scrolls panes with errors and larger desktop text',
    (tester) async {
      // 150% display scale, with a further accessibility text scale.
      tester.view.physicalSize = const Size(1350, 975);
      tester.view.devicePixelRatio = 1.5;
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final bridge = FakeBridge();
      final session = SessionController(bridge);
      await tester.pumpWidget(ModbusApp(controller: session));
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();
      expect(find.text('Enter COM3 or /dev/ttyUSB0'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await session.connect({'transport': 'tcp', 'timeout': 0.1}, 1);
      for (var i = 0; i < 30; i++) {
        bridge.onDiagnostic?.call('Diagnostic $i');
      }
      bridge.heldRead = Completer<BridgeReply>();
      final reading = session.command({'command': 'read', 'count': 1});
      bridge.heldRead!.completeError(
        const BridgeException(
          'Device timed out. Check the connection and retry reading.',
          connected: true,
        ),
      );
      await reading;
      await tester.pumpAndSettle();
      expect(find.byTooltip('Dismiss error'), findsOneWidget);
      final page = tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .controller!;
      expect(page.position.maxScrollExtent, greaterThan(0));
      page.jumpTo(page.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.widgetWithText(Card, 'Activity')).bottom,
        lessThanOrEqualTo(638),
      );
      final logs = find.byKey(const ValueKey('activity-list'));
      final logScroll = tester.widget<ListView>(logs).controller!;
      await tester.drag(logs, const Offset(0, -100));
      await tester.pumpAndSettle();
      expect(logScroll.offset, greaterThan(0));
      expect(page.offset, greaterThan(0));
      await tester.tap(find.byTooltip('Clear log'));
      await tester.pumpAndSettle();
      expect(session.logs, isEmpty);
      expect(
        find.text('Connection and error events appear here'),
        findsOneWidget,
      );
      page.jumpTo(0);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Dismiss error'));
      await tester.pumpAndSettle();
      expect(session.error, isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );

  testWidgets(
    'serial refresh recovers errors, shows progress and supports selection and cancel',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bridge = FakeBridge();
      final session = SessionController(bridge);
      await tester.pumpWidget(ModbusApp(controller: session));
      bridge.heldPorts = Completer<BridgeReply>();
      await tester.tap(find.byTooltip('Find serial ports'));
      await tester.pump();
      expect(find.text('Cancel connection'), findsNothing);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Connect'))
            .onPressed,
        isNull,
      );
      bridge.heldPorts!.completeError(
        const BridgeException('Discovery failed'),
      );
      await tester.pumpAndSettle();
      expect(session.error, 'Discovery failed');
      bridge.heldPorts = null;
      bridge.serialPorts = [
        {'port': 'COM11', 'description': 'USB adapter'},
      ];
      await tester.tap(find.byTooltip('Find serial ports'));
      await tester.pumpAndSettle();
      expect(session.error, isNull);
      await tester.tap(find.text('COM11 · USB adapter'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(
              find.widgetWithText(TextFormField, 'Serial port'),
            )
            .controller!
            .text,
        'COM11',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Baud'),
        '19200',
      );
      for (final pair in [('Bits', '7'), ('Parity', 'Even'), ('Stop', '2')]) {
        await tester.tap(
          find.widgetWithText(
            pair.$1 == 'Parity'
                ? DropdownButtonFormField<String>
                : DropdownButtonFormField<int>,
            pair.$1,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(pair.$2).last);
        await tester.pumpAndSettle();
      }
      await tester.enterText(find.widgetWithText(TextFormField, 'Unit'), '12');
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Timeout, s'),
        '0.5',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(bridge.calls.last, containsPair('bytesize', 7));
      expect(bridge.calls.last, containsPair('baudrate', 19200));
      expect(bridge.calls.last, containsPair('parity', 'E'));
      expect(bridge.calls.last, containsPair('stopbits', 2));
      expect(session.unit, 12);
      expect(session.timeoutSeconds, 0.5);
      await tester.tap(find.text('Disconnect'));
      await tester.pumpAndSettle();
      bridge.serialPorts = [];
      await tester.tap(find.byTooltip('Find serial ports'));
      await tester.pumpAndSettle();
      expect(
        find.text('No serial ports found. You can type a port manually.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Find serial ports'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(SimpleDialog), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );

  testWidgets(
    'TCP validation, cancellation and reconnect work with the primary map',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bridge = FakeBridge();
      final session = SessionController(bridge);
      await tester.pumpWidget(ModbusApp(controller: session));
      await tester.tap(find.text('Serial RTU'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('TCP').last);
      await tester.pumpAndSettle();
      Future<void> enter(String label, String value) =>
          tester.enterText(find.widgetWithText(TextFormField, label), value);
      await enter('Host', '');
      await enter('Port', '70000');
      await enter('Unit', '0');
      await enter('Timeout, s', 'NaN');
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();
      expect(find.text('Required'), findsOneWidget);
      expect(find.text('1–65535'), findsOneWidget);
      expect(find.text('1–247'), findsOneWidget);
      expect(find.text('0.1–60'), findsOneWidget);
      expect(bridge.calls, isEmpty);
      await enter('Host', ' plc.local ');
      await enter('Port', '1502');
      await enter('Unit', '247');
      await enter('Timeout, s', '0.2');
      bridge.heldConnect = Completer<BridgeReply>();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(find.text('Cancel connection'), findsOneWidget);
      expect(
        tester
            .widget<TextFormField>(find.widgetWithText(TextFormField, 'Host'))
            .enabled,
        isFalse,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Read map'),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('Cancel connection'));
      await tester.pump();
      expect(find.text('Disconnecting…'), findsWidgets);
      bridge.heldConnect!.complete(
        const BridgeReply({'description': 'late TCP'}, true),
      );
      await tester.pumpAndSettle();
      expect(session.connected, isFalse);
      expect(bridge.calls.last['command'], 'disconnect');
      bridge.heldConnect = null;
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();
      expect(bridge.calls.last, {
        'command': 'connect',
        'transport': 'tcp',
        'host': 'plc.local',
        'port': 1502,
        'timeout': 0.2,
      });
      expect(session.unit, 247);
      await tester.tap(find.text('Disconnect'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();
      expect(session.connected, isTrue);
      expect(session.error, isNull);
      expect(session.registerResults, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );
}
