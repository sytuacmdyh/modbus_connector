import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:modbus_desktop/src/backend/registers.dart' as registers;
import 'package:modbus_desktop/src/bridge_client.dart';
import 'package:modbus_desktop/src/session_controller.dart';

import 'fake_bridge.dart';

class ScheduleBridge extends FakeBridge {
  Completer<void>? pauseRead;
  final started = Completer<void>();
  final reads = <List<Map<String, dynamic>>>[];

  @override
  Future<BridgeReply> request(
    Map<String, dynamic> command, {
    Duration? timeout,
  }) async {
    if (command['command'] == 'plan_reads' ||
        command['command'] == 'read_rows') {
      calls.add(command);
      final rows = [
        for (final raw in command['rows'] as List)
          registers.row(raw, command['unit'] as int),
      ];
      if (command['command'] == 'plan_reads') {
        return BridgeReply({'groups': registers.plan(rows)}, connected);
      }
      reads.add(rows);
      if (!started.isCompleted) started.complete();
      await pauseRead?.future;
      return BridgeReply({
        'rows': [
          for (final row in rows)
            registers.render(row, [row['unit_id'] * 1000 + row['address']]),
        ],
      }, connected);
    }
    return super.request(command, timeout: timeout);
  }
}

Map<String, dynamic> row(int address, {int? unit, bool enabled = true}) => {
  'address': address,
  'count': 1,
  'unit_id': ?unit,
  'poll_enabled': enabled,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'interleaves merged groups and maps results back to unsorted rows',
    () async {
      final bridge = ScheduleBridge();
      final session = SessionController(bridge);
      addTearDown(session.dispose);
      await session.connect({'timeout': 0.1}, 2);
      final rows = [
        row(11),
        row(1, unit: 1),
        row(0),
        row(10, unit: 1),
        row(10),
        row(0, unit: 1),
        row(1),
        row(11, unit: 1),
        row(20, unit: 3, enabled: false),
      ];
      session.registers.addAll(rows);
      await session.registerMap.read();

      expect(bridge.reads.map((g) => g.first['unit_id']), [2, 1, 2, 1]);
      expect(bridge.reads.map((g) => g.map((r) => r['address']).toList()), [
        [0, 1],
        [0, 1],
        [10, 11],
        [10, 11],
      ]);
      for (var i = 0; i < rows.length - 1; i++) {
        expect(session.registerResults[i]['values'], [
          (rows[i]['unit_id'] ?? 2) * 1000 + rows[i]['address'],
        ]);
        expect(identical(session.registers[i], rows[i]), isTrue);
      }
      expect(session.registerResults.last['values'], isNull);

      bridge.reads.clear();
      await session.registerMap.read(onlyIndices: {0, 3, 8});
      expect(bridge.reads.map((g) => g.first['unit_id']), [2, 1, 3]);
      expect(bridge.reads.expand((g) => g).map((r) => r['address']), [
        11,
        10,
        20,
      ]);
      expect(session.registerResults.last['values'], [3020]);
    },
  );

  test('15 and 23 groups stay distributed across consecutive cycles', () async {
    final bridge = ScheduleBridge();
    final session = SessionController(bridge);
    addTearDown(session.dispose);
    await session.connect({'timeout': 0.1}, 1);
    session.registers.addAll([
      for (var i = 0; i < 15; i++) row(i * 10, unit: 2),
      for (var i = 0; i < 23; i++) row(i * 10, unit: 1),
    ]);
    await session.registerMap.read();
    await session.registerMap.read();
    expect(bridge.reads, hasLength(76));
    for (final unit in [1, 2]) {
      final positions = [
        for (var i = 0; i < bridge.reads.length; i++)
          if (bridge.reads[i].first['unit_id'] == unit) i,
      ];
      // At a simulated 100 ms per transaction (including the 50 ms gap),
      // neither station waits over 300 ms, even across the cycle boundary.
      for (var i = 1; i < positions.length; i++) {
        expect((positions[i] - positions[i - 1]) * 100, lessThanOrEqualTo(300));
      }
      final count = unit == 2 ? 15 : 23;
      expect(positions.map((i) => bridge.reads[i].first['address']), [
        for (var cycle = 0; cycle < 2; cycle++)
          for (var i = 0; i < count; i++) i * 10,
      ]);
    }
  });

  test(
    'single station preserves area order and protocol-sized groups',
    () async {
      final bridge = ScheduleBridge();
      final session = SessionController(bridge);
      addTearDown(session.dispose);
      await session.connect({'timeout': 0.1}, 7);
      session.registers.addAll([
        for (var i = 125; i >= 0; i--) row(i),
        {...row(0), 'kind': 'input_registers'},
      ]);
      await session.registerMap.read();
      expect(bridge.reads.map((g) => g.length), [125, 1, 1]);
      expect(bridge.reads.map((g) => g.first['address']), [0, 125, 0]);
      expect(bridge.reads.last.single['kind'], 'input_registers');
    },
  );

  test('queued write precedes remaining interleaved read groups', () async {
    final bridge = ScheduleBridge()..pauseRead = Completer<void>();
    final session = SessionController(bridge);
    addTearDown(session.dispose);
    await session.connect({'timeout': 0.1}, 1);
    session.registers.addAll([
      registers.row(row(0, unit: 1)),
      registers.row(row(10, unit: 1)),
      registers.row(row(0, unit: 2)),
    ]);
    session.registerMap.start(60000);
    await bridge.started.future;
    final writing = session.registerMap.writeRow(2, values: [42]);
    bridge.pauseRead!.complete();
    await writing;
    session.registerMap.stop();
    expect(bridge.calls.map((c) => c['command']), [
      'connect',
      'plan_reads',
      'read_rows',
      'write_row',
      'plan_reads',
      'read_rows',
    ]);
    expect(bridge.reads.map((g) => g.first['unit_id']), [1, 2]);
  });

  test(
    'stopping a cycle suppresses remaining groups and late results',
    () async {
      final bridge = ScheduleBridge()..pauseRead = Completer<void>();
      final session = SessionController(bridge);
      addTearDown(session.dispose);
      await session.connect({'timeout': 0.1}, 1);
      session.registers.addAll([row(0, unit: 1), row(0, unit: 2)]);
      final reading = session.registerMap.read();
      await bridge.started.future;
      session.registerMap.stop();
      bridge.pauseRead!.complete();
      await reading;
      expect(bridge.reads, hasLength(1));
      expect(session.registerResults, isEmpty);
      expect(session.registerMap.reading, isFalse);
    },
  );
}
