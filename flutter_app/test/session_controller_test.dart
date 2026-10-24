import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:modbus_desktop/src/bridge_client.dart';
import 'package:modbus_desktop/src/session_controller.dart';

import 'fake_bridge.dart';

const config = {
  'transport': 'tcp',
  'host': 'localhost',
  'port': 502,
  'timeout': 0.1,
};

void main() {
  late FakeBridge bridge;
  late SessionController session;
  setUp(() {
    bridge = FakeBridge();
    session = SessionController(bridge);
  });
  tearDown(() => session.dispose());

  test(
    'read/write refreshes the table and read-only areas never write',
    () async {
      await session.connect(config, 12);
      await session.read();
      expect(session.values.length, 50);
      expect(bridge.calls.last['unit'], 12);
      await session.write(2, 456);
      expect(session.values[2], 456);
      expect(
        bridge.calls.where((c) => c['command'] == 'write').single['address'],
        2,
      );
      session.setQuery(const ReadQuery(kind: 'input_registers'));
      await session.write(0, 1);
      expect(bridge.calls.where((c) => c['command'] == 'write').length, 1);
    },
  );

  testWidgets(
    'poll never overlaps; stop suppresses a late result and late error',
    (tester) async {
      await session.connect(config, 1);
      bridge.heldRead = Completer<BridgeReply>();
      session.intervalMs = 100;
      session.startPolling();
      await tester.pump(const Duration(seconds: 1));
      expect(bridge.calls.where((c) => c['command'] == 'read').length, 1);
      session.stopPolling();
      bridge.heldRead!.complete(
        const BridgeReply({
          'values': [999],
          'elapsed_ms': 1,
        }, true),
      );
      await tester.pump();
      expect(session.values, isEmpty);
      bridge.heldRead = Completer<BridgeReply>();
      session.startPolling();
      session.stopPolling();
      bridge.heldRead!.completeError(
        const BridgeException('old error', connected: true),
      );
      await tester.pump();
      expect(session.error, isNull);
      bridge.heldRead = null;
      await session.read();
      expect(session.values.first, 100);
    },
  );

  testWidgets('disconnect gates bus immediately and waits for transaction', (
    tester,
  ) async {
    await session.connect(config, 1);
    bridge.heldRead = Completer<BridgeReply>();
    final reading = session.read();
    final disconnecting = session.disconnect();
    expect(session.connected, isFalse);
    expect(session.canRead, isFalse);
    await session.read();
    await session.write(0, 4);
    expect(bridge.calls.last['command'], 'read');
    bridge.heldRead!.complete(
      const BridgeReply({
        'values': [99],
        'elapsed_ms': 1,
      }, true),
    );
    await reading;
    await disconnecting;
    expect(bridge.calls.last['command'], 'disconnect');
    expect(session.values, isEmpty);
    bridge.heldRead = null;
    await session.connect(config, 1);
    await session.read();
    expect(session.values.first, 100);
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
    'poll error stops timer; manual read recovers and history stays bounded',
    (tester) async {
      await session.connect(config, 1);
      bridge.heldRead = Completer<BridgeReply>();
      session.startPolling();
      bridge.heldRead!.completeError(
        const BridgeException('device timed out', connected: true),
      );
      await tester.pump();
      expect(session.polling, isFalse);
      expect(session.error, 'device timed out');
      bridge.heldRead = null;
      await session.read();
      expect(session.error, isNull);
      for (var i = 0; i < 320; i++) {
        await session.read();
      }
      expect(session.logs.length, lessThanOrEqualTo(300));
    },
  );

  test('invalid ranges rejected, including last address overflow', () {
    expect(
      () => const ReadQuery(address: 65535, count: 2).validate(),
      throwsA(isA<BridgeException>()),
    );
    expect(
      () => const ReadQuery(count: 126).validate(),
      throwsA(isA<BridgeException>()),
    );
    const ReadQuery(kind: 'coils', count: 2000).validate();
    const ReadQuery(address: 65535, count: 1).validate();
  });

  test(
    'bridge crash stops polling and shutdown closes the owned transport',
    () async {
      await session.connect(config, 1);
      bridge.onExit!();
      expect(session.connected, isFalse);
      expect(session.polling, isFalse);
      expect(session.error, contains('Reconnect'));
      expect(session.description, 'Disconnected');
      await session.shutdown();
      expect(bridge.closed, isTrue);
    },
  );
}
