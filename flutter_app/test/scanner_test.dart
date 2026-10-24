import 'dart:async';

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
