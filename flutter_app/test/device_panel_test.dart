import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modbus_desktop/src/bridge_client.dart';
import 'package:modbus_desktop/src/device_panel.dart';
import 'package:modbus_desktop/src/session_controller.dart';

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
      await tester.ensureVisible(find.text('unit-one-frame'));
      expect(find.text('unit-two-frame'), findsNothing);
      await tester.tap(find.text('Selected unit only'));
      await tester.pump();
      expect(find.text('unit-two-frame'), findsOneWidget);
      final tile = find.textContaining('holding_registers @0');
      await tester.ensureVisible(tile);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Wide');
      await tester.tap(find.text('dec'));
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
