import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modbus_desktop/src/bridge_client.dart';
import 'package:modbus_desktop/src/device_panel.dart';
import 'package:modbus_desktop/src/session_controller.dart';
import 'package:modbus_desktop/src/desktop_table.dart';

import 'fake_bridge.dart';

class DeviceBridge extends FakeBridge {
  bool running = false;
  @override
  Future<BridgeReply> request(
    Map<String, dynamic> command, {
    Duration? timeout,
  }) async {
    switch (command['command']) {
      case 'device_start':
        calls.add(command);
        running = true;
        return const BridgeReply({'running': true}, false);
      case 'device_stop':
        calls.add(command);
        running = false;
        return const BridgeReply({'running': false}, false);
      case 'sim_configure':
        calls.add(command);
        return const BridgeReply({}, false);
      case 'device_status':
        return BridgeReply({
          'simulator': running,
          'sniffer': running,
          'gateway': running,
          'rows': [],
          'events': [],
          'dropped': 0,
          'units': [],
        }, false);
    }
    return super.request(command, timeout: timeout);
  }
}

class CatalogBridge extends DeviceBridge {
  @override
  Future<BridgeReply> request(
    Map<String, dynamic> command, {
    Duration? timeout,
  }) async {
    if (command['command'] == 'template_list') {
      return const BridgeReply({
        'public': [
          {
            'name': 'Test device',
            'manufacturer': 'Test',
            'resource': 'Test/Device.json',
            'description': '',
          },
        ],
        'custom': [],
      }, false);
    }
    if (command['command'] == 'template_load') {
      return const BridgeReply({
        'state': {
          'mode': 'master',
          'registers': [
            {
              'name': 'Duplicate',
              'kind': 'holding_registers',
              'address': 0,
              'count': 1,
              'format': 'dec',
            },
            {
              'name': 'Imported',
              'kind': 'holding_registers',
              'address': 1,
              'count': 1,
              'format': 'dec',
              'value_names': {'0': 'Off', '1': 'On'},
            },
          ],
        },
        'template_id': null,
      }, false);
    }
    return super.request(command, timeout: timeout);
  }
}

class SniffBridge extends DeviceBridge {
  Completer<BridgeReply>? snapshot;
  List<Map<String, dynamic>> pending = [
    {
      'mode': 'sniffer',
      'event': 'traffic',
      'unit': 1,
      'line': 'unit-one-frame',
    },
    {
      'mode': 'sniffer',
      'event': 'traffic',
      'unit': 2,
      'line': 'unit-two-frame',
    },
  ];
  @override
  Future<BridgeReply> request(
    Map<String, dynamic> command, {
    Duration? timeout,
  }) async {
    if (command['command'] == 'sniffer_snapshot' && snapshot != null) {
      calls.add(command);
      return snapshot!.future;
    }
    if (command['command'] == 'device_status') {
      final events = pending;
      pending = [];
      return BridgeReply({
        'simulator': false,
        'sniffer': true,
        'gateway': false,
        'rows': [],
        'events': events,
        'dropped': 0,
        'units': [1, 2],
      }, false);
    }
    if (command['command'] == 'render_rows') {
      return BridgeReply({
        'rows': [
          for (final row in command['rows'] as List)
            {
              'values': row['values'],
              'display': (row['values'] as List).join(','),
              'numeric': (row['values'] as List).first,
              'alarm': null,
            },
        ],
      }, false);
    }
    return super.request(command, timeout: timeout);
  }
}

void main() {
  testWidgets(
    'snapshot remains with its requested unit after switching views',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bridge = SniffBridge()..snapshot = Completer<BridgeReply>();
      final session = SessionController(bridge)..mode = 'sniffer';
      session.sniffed.addAll({1: {}, 2: {}});
      await tester.pumpWidget(MaterialApp(home: DevicePanel(session: session)));
      await tester.tap(find.text('Refresh map'));
      await tester.pump();
      expect(bridge.calls.last['unit'], 1);
      await tester.tap(find.text('Unit 2'));
      await tester.pump();
      bridge.snapshot!.complete(
        const BridgeReply({
          'areas': {
            'holding_registers': {'7': 42},
          },
        }, false),
      );
      await tester.pumpAndSettle();
      expect(session.sniffed[1]!['holding_registers/7']!['value'], 42);
      expect(session.sniffed[2], isEmpty);
      expect(session.draft['sniffer_selected_unit'], 2);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );

  testWidgets(
    'all device serial forms discover/select ports and preserve manual settings',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final mode in ['simulator', 'sniffer', 'gateway']) {
        final bridge = DeviceBridge()
          ..serialPorts = [
            {'port': 'COM17', 'description': 'USB adapter'},
          ];
        final session = SessionController(bridge)..mode = mode;
        session.deviceConfig.addAll({
          'listen': {
            'transport': 'rtu',
            'port': 'COM3',
            'baudrate': 19200,
            'parity': 'E',
          },
          'target': {
            'transport': 'rtu',
            'port': 'COM4',
            'baudrate': 38400,
            'parity': 'O',
          },
        });
        await tester.pumpWidget(
          MaterialApp(
            home: DevicePanel(key: ValueKey(mode), session: session),
          ),
        );
        await tester.tap(find.byTooltip('Serial ports').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('COM17 · USB adapter'));
        await tester.pumpAndSettle();
        final listen = session.deviceConfig['listen'] as Map;
        expect(listen['port'], 'COM17');
        expect(listen['baudrate'], 19200);
        expect(listen['parity'], 'E');
        if (mode == 'gateway') {
          await tester.tap(find.byTooltip('Serial ports').last);
          await tester.pumpAndSettle();
          await tester.tap(find.text('COM17 · USB adapter'));
          await tester.pumpAndSettle();
          expect((session.deviceConfig['target'] as Map)['port'], 'COM17');
          expect((session.deviceConfig['target'] as Map)['baudrate'], 38400);
        }
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Serial port').first,
          '/dev/manual',
        );
        bridge.serialPorts = [];
        await tester.tap(find.byTooltip('Serial ports').first);
        await tester.pumpAndSettle();
        expect(
          find.text('No serial ports found. You can type a port manually.'),
          findsOneWidget,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect((session.deviceConfig['listen'] as Map)['port'], '/dev/manual');
        session.deviceRunning = true;
        session.notifyListeners();
        await tester.pump();
        expect(
          tester
              .widget<IconButton>(
                find.widgetWithIcon(IconButton, Icons.refresh).first,
              )
              .onPressed,
          isNull,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        session.dispose();
      }
    },
  );

  testWidgets('sniffer hides/restores views without losing captured values', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = SessionController(SniffBridge())..mode = 'sniffer';
    session.sniffed[1] = {
      'holding_registers/0': {
        'kind': 'holding_registers',
        'address': 0,
        'count': 1,
        'format': 'dec',
        'name': 'Voltage',
        'value': 42,
      },
    };
    await tester.pumpWidget(MaterialApp(home: DevicePanel(session: session)));
    await tester.tap(find.text('Manage views'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CheckboxListTile));
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(DesktopTable),
        matching: find.text('Voltage'),
      ),
      findsNothing,
    );
    expect(session.sniffed[1]!['holding_registers/0']!['value'], 42);
    await tester.tap(find.text('Manage views'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CheckboxListTile));
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Voltage'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'Search name / address'),
      'other',
    );
    await tester.pump();
    expect(find.text('Voltage'), findsNothing);
    expect(session.draft['sniffer_search'], 'other');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });

  testWidgets(
    'sniffer filters units and preserves view edits during new traffic',
    (tester) async {
      tester.view.physicalSize = const Size(900, 650);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bridge = SniffBridge();
      final session = SessionController(bridge)..mode = 'sniffer';
      session.sniffed[1] = {
        for (var i = 0; i < 2; i++)
          'holding_registers/$i': {
            'name': '',
            'unit_id': 1,
            'kind': 'holding_registers',
            'address': i,
            'count': 1,
            'format': 'dec',
            'value': i + 1,
          },
      };
      await tester.pumpWidget(MaterialApp(home: DevicePanel(session: session)));
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pump();
      await tester.scrollUntilVisible(
        find.text('unit-one-frame'),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('unit-two-frame'), findsNothing);
      await tester.tap(find.text('Selected unit only'));
      await tester.pump();
      expect(find.text('unit-two-frame'), findsOneWidget);
      final tile = find.text('0').first;
      await tester.ensureVisible(tile);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Wide');
      await tester.tap(find.text('dec').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('u32').last);
      await tester.pumpAndSettle();
      bridge.pending = [
        {
          'mode': 'sniffer',
          'event': 'values',
          'unit': 1,
          'kind': 'holding_registers',
          'address': 0,
          'values': [3, 4],
        },
      ];
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pump();
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(session.sniffed[1]!['holding_registers/0']!['name'], 'Wide');
      expect(session.sniffed[1]!['holding_registers/0']!['count'], 2);
      expect(session.sniffed[1]!['holding_registers/0']!['value'], 3);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );

  testWidgets('simulator imports template rows without duplicate addresses', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 650);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bridge = DeviceBridge();
    final session = SessionController(bridge)..mode = 'simulator';
    session.simRows.add({
      'name': 'Existing',
      'kind': 'holding_registers',
      'address': 0,
      'count': 1,
      'format': 'dec',
    });
    await tester.pumpWidget(
      MaterialApp(
        home: DevicePanel(
          session: session,
          utilityBridgeFactory: CatalogBridge.new,
        ),
      ),
    );
    await tester.tap(find.text('Load template rows'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Test device'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add rows to simulator'));
    await tester.pumpAndSettle();
    expect(session.simRows.map((r) => r['name']), ['Existing', 'Imported']);
    expect(session.simRows.last['value_names'], {'0': 'Off', '1': 'On'});
    expect(bridge.calls.any((c) => c['command'] == 'sim_configure'), isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });

  testWidgets(
    'simulator form starts/stops and mode panels fit minimum desktop',
    (tester) async {
      tester.view.physicalSize = const Size(900, 650);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bridge = DeviceBridge();
      final session = SessionController(bridge)..mode = 'simulator';
      await tester.pumpWidget(MaterialApp(home: DevicePanel(session: session)));
      await tester.tap(find.text('Start'));
      await tester.pumpAndSettle();
      expect(session.deviceRunning, isTrue);
      expect(bridge.calls.last['command'], 'device_start');
      await tester.tap(find.text('Stop'));
      await tester.pumpAndSettle();
      expect(bridge.running, isFalse);
      for (final mode in ['sniffer', 'gateway']) {
        session.mode = mode;
        await tester.pumpWidget(
          MaterialApp(
            home: DevicePanel(key: ValueKey(mode), session: session),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );
}
