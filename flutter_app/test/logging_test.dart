import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:modbus_desktop/src/bridge_client.dart';
import 'package:modbus_desktop/src/session_controller.dart';

import 'fake_bridge.dart';

class LoggingBridge extends FakeBridge {
  final held = Completer<BridgeReply>();
  @override
  Future<BridgeReply> request(
    Map<String, dynamic> command, {
    Duration? timeout,
  }) async {
    if (command['command'] == 'read_rows') {
      calls.add(command);
      return held.future;
    }
    if ((command['command'] as String).startsWith('logger_')) {
      calls.add(command);
      return const BridgeReply({'active': true, 'rows_written': 1}, true);
    }
    return super.request(command, timeout: timeout);
  }
}

void main() {
  test(
    'stop logger waits for sampling I/O and prevents a late file write',
    () async {
      final bridge = LoggingBridge();
      final session = SessionController(bridge);
      await session.connect({'timeout': 0.1}, 1);
      await session.startLogging(
        {'path': 'test.csv', 'interval_ms': 1000},
        [
          {'name': 'x', 'address': 0},
        ],
      );
      final stopping = session.stopLogging();
      expect(bridge.calls.last['command'], 'read_rows');
      bridge.held.complete(
        const BridgeReply({
          'rows': [
            {
              'values': [5],
            },
          ],
        }, true),
      );
      await stopping;
      expect(session.logging, isFalse);
      expect(bridge.calls.last['command'], 'logger_stop');
      expect(
        bridge.calls.where((c) => c['command'] == 'logger_sample'),
        isEmpty,
      );
      session.dispose();
    },
  );
  test('alarm logs on transitions and can reenter after recovery', () {
    final session = SessionController(FakeBridge());
    final rows = [
      {'name': 'x', 'address': 0},
    ];
    final triggered = [
      {
        'alarm': {'condition': 'gt', 'value': 1, 'log': true},
        'display': '2',
      },
    ];
    session.observeAlarms(triggered, rows);
    session.observeAlarms(triggered, rows);
    expect(session.logs.length, 1);
    session.observeAlarms([
      {'alarm': null},
    ], rows);
    session.observeAlarms(triggered, rows);
    expect(session.logs.length, 3);
    expect(
      session.logs.any((l) => l.message.contains('ALARM cleared')),
      isTrue,
    );
    session.dispose();
  });
}
