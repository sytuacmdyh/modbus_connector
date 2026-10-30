import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:modbus_desktop/src/bridge_client.dart';
import 'package:modbus_desktop/src/session_controller.dart';

import 'fake_bridge.dart';

class FailingWriteBridge extends FakeBridge {
  @override
  Future<BridgeReply> request(
    Map<String, dynamic> command, {
    Duration? timeout,
  }) {
    if (command['command'] == 'write') {
      calls.add(command);
      return Future.error(
        const BridgeException('illegal data value', connected: true),
      );
    }
    return super.request(command, timeout: timeout);
  }
}

const config = {
  'transport': 'tcp',
  'host': 'localhost',
  'port': 502,
  'timeout': 0.1,
};

void main() {
  test('grouped map reads stay enabled for new and legacy state', () {
    final controller = SessionController(FakeBridge());
    addTearDown(controller.dispose);
    expect(controller.mapGrouped, isTrue);
    controller.restore({'map_grouped': false});
    expect(controller.mapGrouped, isTrue);
    controller.mapGrouped = false;
    expect(controller.mapGrouped, isTrue);
  });

  late FakeBridge bridge;
  late SessionController session;
  late DateTime now;
  setUp(() {
    bridge = FakeBridge();
    now = DateTime(2026);
    session = SessionController(bridge, clock: () => now);
    session.registers.add({
      'name': 'Value',
      'kind': 'holding_registers',
      'address': 2,
      'count': 1,
      'format': 'dec',
    });
  });
  tearDown(() => session.dispose());

  test(
    'read/write refreshes the table and read-only areas never write',
    () async {
      await session.connect(config, 12);
      await session.registerMap.read();
      expect(session.registerResults.length, 1);
      expect(bridge.calls.last['unit'], 12);
      await session.registerMap.quickValue(0, 'increment');
      expect(session.registerResults.single['values'], [101]);
      expect(
        bridge.calls.where((c) => c['command'] == 'write').single['address'],
        2,
      );
      session.registers.single['kind'] = 'input_registers';
      await session.registerMap.quickValue(0, 'one');
      expect(bridge.calls.where((c) => c['command'] == 'write').length, 1);
    },
  );

  testWidgets(
    'poll never overlaps; stop suppresses a late result and late error',
    (tester) async {
      await session.connect(config, 1);
      bridge.heldRead = Completer<BridgeReply>();
      session.registerMap.start(100);
      await tester.pump(const Duration(seconds: 1));
      expect(bridge.calls.where((c) => c['command'] == 'read_rows').length, 1);
      session.registerMap.stop();
      bridge.heldRead!.complete(
        const BridgeReply({
          'rows': [
            {
              'values': [999],
              'numeric': 999,
            },
          ],
        }, true),
      );
      await tester.pump();
      expect(session.registerResults, isEmpty);
      bridge.heldRead = Completer<BridgeReply>();
      session.registerMap.start(100);
      await tester.pump();
      session.registerMap.stop();
      bridge.heldRead!.completeError(
        const BridgeException('old error', connected: true),
      );
      await tester.pump();
      expect(session.error, isNull);
      bridge.heldRead = null;
      await session.registerMap.read();
      expect(session.registerResults.single['values'], [100]);
    },
  );

  testWidgets('disconnect gates bus immediately and waits for transaction', (
    tester,
  ) async {
    await session.connect(config, 1);
    bridge.heldRead = Completer<BridgeReply>();
    final reading = session.registerMap.read();
    await tester.pump();
    final disconnecting = session.disconnect();
    expect(session.connected, isFalse);
    expect(session.canRead, isFalse);
    await session.registerMap.read();
    await session.registerMap.quickValue(0, 'one');
    expect(bridge.calls.last['command'], 'read_rows');
    bridge.heldRead!.complete(
      const BridgeReply({
        'rows': [
          {
            'values': [99],
            'numeric': 99,
          },
        ],
      }, true),
    );
    await reading;
    await disconnecting;
    expect(bridge.calls.last['command'], 'disconnect');
    expect(session.registerResults, isEmpty);
    bridge.heldRead = null;
    await session.connect(config, 1);
    await session.registerMap.read();
    expect(session.registerResults.single['values'], [100]);
  });

  test('cancel during connect cannot revive session', () async {
    bridge.heldConnect = Completer<BridgeReply>();
    final connecting = session.connect(config, 1);
    final disconnecting = session.disconnect();
    bridge.heldConnect!.complete(
      const BridgeReply({'description': 'late'}, true),
    );
    await connecting;
    await disconnecting;
    expect(session.connected, isFalse);
    expect(session.description, 'Disconnected');
    expect(bridge.calls.last['command'], 'disconnect');
  });

  testWidgets(
    'recoverable poll errors keep the timer running and recover next cycle',
    (tester) async {
      await session.connect(config, 1);
      bridge.heldRead = Completer<BridgeReply>();
      session.registerMap.start(100);
      bridge.heldRead!.completeError(
        const BridgeException('device timed out', connected: true),
      );
      await tester.pump();
      expect(session.registerMap.polling, isTrue);
      expect(session.error, 'device timed out');
      bridge.heldRead = null;
      now = now.add(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));
      expect(session.error, isNull);
      expect(session.registerResults.single['values'], [100]);
      session.registerMap.stop();
      for (var i = 0; i < 320; i++) {
        await session.registerMap.read();
      }
      expect(session.logs.length, lessThanOrEqualTo(300));
    },
  );

  test('trends require explicit opt-in and respect disabled rows', () async {
    await session.connect(config, 1);
    await session.registerMap.read();
    expect(session.histories, isEmpty);
    session.registers.single['trend_enabled'] = true;
    await session.registerMap.read();
    expect(session.histories, hasLength(1));
    session.clearHistory();
    session.registers.single['trend_enabled'] = false;
    await session.registerMap.read();
    expect(session.histories, isEmpty);
  });

  testWidgets('write waits for the active read and preserves polling', (
    tester,
  ) async {
    await session.connect(config, 1);
    final held = bridge.heldRead = Completer<BridgeReply>();
    session.registerMap.start(100);
    await tester.pump();
    final writing = session.registerMap.quickValue(0, 'one');
    await tester.pump();
    expect(bridge.calls.where((c) => c['command'] == 'write'), isEmpty);
    bridge.heldRead = null;
    held.complete(
      const BridgeReply({
        'rows': [
          {
            'values': [100],
            'numeric': 100,
          },
        ],
      }, true),
    );
    await tester.pump();
    await writing;
    expect(bridge.calls.where((c) => c['command'] == 'write'), hasLength(1));
    expect(session.registerMap.polling, isTrue);
    await tester.pump(const Duration(milliseconds: 200));
    expect(session.registerResults.single['values'], [1]);
    session.registerMap.stop();
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets(
    'queued writes precede the next read group and keep their order',
    (tester) async {
      await session.connect(config, 1);
      session.registers.add({...session.registers.single, 'address': 3});
      final held = bridge.heldRead = Completer<BridgeReply>();
      session.registerMap.start(100);
      await tester.pump();
      final first = session.registerMap.writeRow(0, values: [21]);
      final second = session.registerMap.writeRow(1, values: [22]);
      await tester.pump();
      bridge.heldRead = null;
      held.complete(
        const BridgeReply({
          'rows': [
            {
              'values': [100],
              'numeric': 100,
            },
          ],
        }, true),
      );
      await tester.pump();
      await Future.wait([first, second]);
      expect(
        bridge.calls
            .where((c) => c['command'] != 'plan_reads')
            .skip(1)
            .take(3)
            .map((c) => c['command']),
        ['read_rows', 'write', 'write'],
      );
      expect(
        bridge.calls
            .where((c) => c['command'] == 'write')
            .map((c) => c['values']),
        [
          [21],
          [22],
        ],
      );
      expect(session.registerMap.polling, isTrue);
      session.registerMap.stop();
    },
  );

  testWidgets('disconnect cancels a queued write before it reaches the bus', (
    tester,
  ) async {
    await session.connect(config, 1);
    final held = bridge.heldRead = Completer<BridgeReply>();
    session.registerMap.start(100);
    final writing = session.registerMap.writeRow(0, values: [21]);
    final disconnecting = session.disconnect();
    held.complete(const BridgeReply({'rows': []}, true));
    await tester.pump();
    await Future.wait([writing, disconnecting]);
    expect(bridge.calls.where((c) => c['command'] == 'write'), isEmpty);
    expect(session.registerMap.polling, isFalse);
  });

  testWidgets('failed write logs the error without stopping polling', (
    tester,
  ) async {
    session.dispose();
    bridge = FailingWriteBridge();
    session = SessionController(bridge);
    session.registers.add({
      'name': 'Value',
      'kind': 'holding_registers',
      'address': 2,
      'count': 1,
    });
    await session.connect(config, 1);
    session.registerMap.start(100);
    await tester.pump();
    await session.registerMap.quickValue(0, 'one');
    expect(
      session.logs.any(
        (e) => e.isError && e.message.contains('illegal data value'),
      ),
      isTrue,
    );
    expect(session.registerMap.polling, isTrue);
    await tester.pump(const Duration(milliseconds: 200));
    expect(session.registerResults.single['values'], [100]);
    session.registerMap.stop();
  });

  testWidgets('disconnected read stops polling', (tester) async {
    await session.connect(config, 1);
    bridge.heldRead = Completer<BridgeReply>();
    session.registerMap.start(100);
    bridge.heldRead!.completeError(
      const BridgeException('connection lost', connected: false),
    );
    await tester.pump();
    expect(session.connected, isFalse);
    expect(session.registerMap.polling, isFalse);
  });

  test('old quick-range state is ignored without starting I/O', () {
    session.restore({
      'query': {'kind': 'coils', 'address': 4, 'count': 50},
      'interval_ms': 100,
      'draft': {
        'address': '4',
        'count': '50',
        'interval': '100',
        'host': 'plc.local',
      },
    });
    expect(session.state().containsKey('query'), isFalse);
    expect(session.state().containsKey('interval_ms'), isFalse);
    expect(session.draft, {'host': 'plc.local'});
    expect(bridge.calls, isEmpty);
  });

  test(
    'demo seeds an empty map but preserves an existing device map',
    () async {
      final original = session.registers.single;
      await session.connect({'transport': 'demo', 'timeout': 0.1}, 1);
      expect(session.registers.single, same(original));
      await session.disconnect();
      session.registers.clear();
      await session.connect({'transport': 'demo', 'timeout': 0.1}, 1);
      expect(session.registers, hasLength(6));
      expect(session.registers.map((r) => r['kind']).toSet(), hasLength(4));
    },
  );

  test(
    'bridge crash stops polling and shutdown closes the owned transport',
    () async {
      await session.connect(config, 1);
      bridge.onExit!();
      expect(session.connected, isFalse);
      expect(session.registerMap.polling, isFalse);
      expect(session.error, contains('Reconnect'));
      expect(session.description, 'Disconnected');
      await session.shutdown();
      expect(bridge.closed, isTrue);
    },
  );
}
