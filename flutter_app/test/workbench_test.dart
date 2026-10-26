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
  testWidgets('rare map tools collapse and the table recovers their space', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = SessionController(FakeBridge());
    await tester.pumpWidget(ModbusApp(controller: session));
    final height = tester.getSize(find.byType(DesktopTable)).height;
    expect(find.byTooltip('CSV'), findsNothing);
    expect(find.byTooltip('Snapshot'), findsNothing);
    await tester.tap(find.text('More tools'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('CSV').hitTestable(), findsOneWidget);
    expect(find.byTooltip('Snapshot').hitTestable(), findsOneWidget);
    expect(find.byTooltip('Expressions').hitTestable(), findsOneWidget);
    expect(tester.getSize(find.byType(DesktopTable)).height, lessThan(height));
    await tester.tap(find.text('More tools'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('CSV'), findsNothing);
    expect(tester.getSize(find.byType(DesktopTable)).height, height);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });

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
    await tester.tap(find.text('Save and connect'));
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
    'activity stays on the right and can be hidden to widen the map',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bridge = FakeBridge();
      final session = SessionController(bridge);
      await tester.pumpWidget(ModbusApp(controller: session));
      for (var i = 0; i < 80; i++) {
        bridge.onDiagnostic?.call('Diagnostic $i');
      }
      await tester.pumpAndSettle();
      final map = tester.getRect(find.byType(RegisterMapPanel));
      final activity = tester.getRect(find.widgetWithText(Card, 'Activity'));
      expect(activity.left, greaterThan(map.right));
      expect((activity.bottom - map.bottom).abs(), lessThan(15));
      expect(
        tester.getSize(find.byType(DesktopTable)).height,
        greaterThan(500),
      );
      final logs = find.byKey(const ValueKey('activity-list'));
      await tester.drag(logs, const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(tester.widget<ListView>(logs).controller!.offset, greaterThan(0));
      await tester.tap(find.byTooltip('Clear log'));
      await tester.pumpAndSettle();
      expect(session.logs, isEmpty);
      await tester.tap(find.byTooltip('Hide activity'));
      await tester.pumpAndSettle();
      expect(find.text('Activity'), findsNothing);
      expect(
        tester.getSize(find.byType(RegisterMapPanel)).width,
        greaterThan(map.width + 250),
      );
      await tester.tap(find.byTooltip('Show activity'));
      await tester.pumpAndSettle();
      expect(find.text('Activity'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );

  testWidgets('minimum window uses a right drawer with errors and large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1350, 975);
    tester.view.devicePixelRatio = 1.5;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final bridge = FakeBridge();
    final session = SessionController(bridge);
    await tester.pumpWidget(ModbusApp(controller: session));
    await session.connect({'transport': 'tcp', 'timeout': 0.1}, 1);
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
    expect(find.text('Activity'), findsNothing);
    expect(tester.getSize(find.byType(DesktopTable)).height, greaterThan(120));
    await tester.tap(find.text('More tools'));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(DesktopTable)).height, greaterThan(120));
    await tester.tap(find.byTooltip('Show activity'));
    await tester.pumpAndSettle();
    expect(find.text('Activity'), findsOneWidget);
    expect(tester.getRect(find.byType(Drawer)).right, 900);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Dismiss error'));
    await tester.pumpAndSettle();
    expect(session.error, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });

  testWidgets(
    'connection settings apply atomically and cancel restores the draft',
    (tester) async {
      final session = SessionController(FakeBridge());
      session.draft.addAll({'serial': 'COM7', 'baud': '9600'});
      await tester.pumpWidget(ModbusApp(controller: session));
      expect(find.widgetWithText(TextFormField, 'Serial port'), findsNothing);
      await tester.tap(find.text('Connection settings'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Serial port'),
        'COM99',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Baud'),
        '31250',
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(session.draft['serial'], 'COM7');
      expect(session.draft['baud'], '9600');
      await tester.tap(find.text('Connection settings'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(
              find.widgetWithText(TextFormField, 'Serial port'),
            )
            .controller!
            .text,
        'COM7',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Baud'),
        '19200',
      );
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(session.draft['baud'], '19200');
      expect(session.connected, isFalse);
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();
      expect(session.connected, isTrue);
      expect(session.connectionConfig['baudrate'], 19200);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );

  testWidgets(
    'serial dropdown recovers errors, shows progress and supports selection and dismiss',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bridge = FakeBridge();
      final session = SessionController(bridge);
      await tester.pumpWidget(ModbusApp(controller: session));
      await tester.tap(find.text('Connection settings'));
      await tester.pumpAndSettle();
      bridge.heldPorts = Completer<BridgeReply>();
      await tester.tap(find.byTooltip('Serial ports'));
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
      await tester.tap(find.byTooltip('Serial ports'));
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
      await tester.tap(find.byTooltip('Baud'));
      await tester.pumpAndSettle();
      for (final baud in ['1200', '2400', '4800', '9600', '115200', '921600']) {
        expect(find.text(baud).last, findsOneWidget);
      }
      await tester.ensureVisible(find.text('19200'));
      await tester.tap(find.text('19200'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(find.widgetWithText(TextFormField, 'Baud'))
            .controller!
            .text,
        '19200',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Baud'),
        '31250',
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
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();
      expect(bridge.calls.last, containsPair('bytesize', 7));
      expect(bridge.calls.last, containsPair('baudrate', 31250));
      expect(bridge.calls.last, containsPair('parity', 'E'));
      expect(bridge.calls.last, containsPair('stopbits', 2));
      expect(session.unit, 12);
      expect(session.timeoutSeconds, 0.5);
      await tester.tap(find.text('Disconnect'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Connection settings'));
      await tester.pumpAndSettle();
      bridge.serialPorts = [];
      await tester.tap(find.byTooltip('Serial ports'));
      await tester.pumpAndSettle();
      expect(
        find.text('No serial ports found. You can type a port manually.'),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Find serial ports'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(
        find.text('No serial ports found. You can type a port manually.'),
        findsNothing,
      );
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
      await tester.tap(find.text('Connection settings'));
      await tester.pumpAndSettle();
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
      await tester.tap(find.text('Apply'));
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
      await tester.pumpAndSettle();
      await tester.tap(find.text('Connect'));
      await tester.pump();
      expect(find.text('Cancel connection'), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Connection settings'),
            )
            .onPressed,
        isNull,
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
