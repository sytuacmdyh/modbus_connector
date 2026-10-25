import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modbus_desktop/src/bridge_client.dart';
import 'package:modbus_desktop/src/scanner.dart';
import 'package:modbus_desktop/src/session_controller.dart';

import 'fake_bridge.dart';

class ScanBridge extends FakeBridge {
  Completer<BridgeReply>? held;
  @override
  Future<BridgeReply> request(
    Map<String, dynamic> command, {
    Duration? timeout,
  }) async {
    if (command['command'] == 'scan_unit') {
      calls.add(command);
      return held?.future ??
          Future.value(
            BridgeReply({
              'hits': command['unit'] == 2 ? [0] : [],
            }, true),
          );
    }
    return super.request(command, timeout: timeout);
  }
}

void main() {
  testWidgets('address scan results go directly into the register map', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = SessionController(ScanBridge());
    session.unit = 7;
    session.registers.add({
      'name': 'Existing',
      'kind': 'holding_registers',
      'address': 5,
      'count': 1,
    });
    session.scannerState.addAll({
      'addresses': true,
      'unit': 7,
      'selected': [5, 9],
      'hits': [
        {
          'address': 5,
          'values': [10],
        },
        {
          'address': 9,
          'values': [20],
        },
      ],
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<bool>(
              context: context,
              builder: (_) => ScannerDialog(session: session),
            ),
            child: const Text('Open scanner'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open scanner'));
    await tester.pumpAndSettle();
    expect(find.text('Open selected range'), findsNothing);
    await tester.tap(find.text('Add selected to register map'));
    await tester.pumpAndSettle();
    expect(find.byType(ScannerDialog), findsNothing);
    expect(session.registers.map((r) => r['address']), [5, 9]);
    expect(session.registers.last['unit_id'], 7);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });

  test(
    'scanner finds hits, reports progress and cancels without stale results',
    () async {
      final bridge = ScanBridge();
      final session = SessionController(bridge);
      await session.connect({'timeout': 0.1}, 1);
      final scanner = ScannerController(session);
      final probes = [
        {'kind': 'holding_registers', 'address': 0, 'count': 1},
      ];
      await scanner.scan(
        addresses: false,
        start: 1,
        end: 3,
        unit: 1,
        kind: 'holding_registers',
        probes: probes,
      );
      expect(scanner.done, 3);
      expect(scanner.hits.single['unit'], 2);
      final restored = SessionController(ScanBridge())
        ..restore(session.state());
      final recalled = ScannerController(restored);
      expect(recalled.hits.single['unit'], 2);
      expect(recalled.done, 3);
      expect(recalled.running, isFalse);
      expect(restored.connected, isFalse);
      recalled.dispose();
      restored.dispose();
      bridge.held = Completer<BridgeReply>();
      final scanning = scanner.scan(
        addresses: false,
        start: 1,
        end: 247,
        unit: 1,
        kind: 'holding_registers',
        probes: probes,
      );
      expect(session.canRead, isFalse);
      scanner.stop();
      bridge.held!.complete(
        const BridgeReply({
          'hits': [0],
        }, true),
      );
      await scanning;
      expect(scanner.hits, isEmpty);
      expect(scanner.done, 0);
      expect(session.canRead, isTrue);
      scanner.dispose();
      session.dispose();
    },
  );
}
