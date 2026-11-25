@TestOn('vm || browser')
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:modbus_desktop/src/backend/wire.dart';
import 'package:modbus_desktop/src/backend/csv.dart';
import 'package:modbus_desktop/src/backend/datastore.dart';
import 'package:modbus_desktop/src/bridge_local.dart';
import 'package:modbus_desktop/src/bridge_transport.dart';
import 'package:test/test.dart';

class MemoryChannel implements WireChannel {
  final incoming = StreamController<Uint8List>();
  final sent = <List<int>>[];
  bool closed = false;
  void Function(List<int>)? respond;
  @override
  Stream<Uint8List> get stream => incoming.stream;
  @override
  Future<void> write(List<int> bytes, {ReadCancellation? cancellation}) async {
    cancellation?.check();
    sent.add(List.of(bytes));
    respond?.call(bytes);
  }

  void receive(List<int> bytes) => incoming.add(Uint8List.fromList(bytes));
  @override
  Future<void> close() async {
    closed = true;
    await incoming.close();
  }
}

void main() {
  test(
    'local session demo uses the shared read/write contract without a service',
    () async {
      final bridge = LocalBridge();
      try {
        expect(
          (await bridge.request({'command': 'hello'})).result['protocol'],
          1,
        );
        expect(
          (await bridge.request({'command': 'connect', 'transport': 'demo'}))
              .connected,
          true,
        );
        final row = {'kind': 'holding_registers', 'address': 0, 'count': 1};
        final initial = await bridge.request({
          'command': 'read_rows',
          'rows': [row],
        });
        expect(initial.result['rows'][0]['values'], [100]);
        await expectLater(
          bridge.request({
            'command': 'write_row',
            'row': {...row, 'writable': false},
            'values': [42],
          }),
          throwsA(isA<BridgeException>()),
        );
        await bridge.request({
          'command': 'write_row',
          'row': row,
          'values': [42],
        });
        final after = await bridge.request({
          'command': 'read_rows',
          'rows': [row],
        });
        expect(after.result['rows'][0]['values'], [42]);
        expect(
          (await bridge.request({'command': 'disconnect'})).connected,
          false,
        );
      } finally {
        await bridge.close();
      }
    },
  );

  test('shared CSV round trip retains Unicode and write permissions', () {
    final exported = csvCommand({
      'command': 'csv_export',
      'rows': [
        {
          'name': '温度',
          'kind': 'holding_registers',
          'address': 7,
          'count': 1,
          'writable': false,
        },
      ],
    });
    final parsed = csvCommand({
      'command': 'csv_parse',
      'text': exported['text'],
    });
    final row = (parsed['rows'] as List).single;
    expect(row['name'], '温度');
    expect(row['address'], 7);
    expect(row['writable'], false);
  });

  test(
    'shared memory simulator reads and writes without any network server',
    () {
      final store = DataStore();
      expect(store.handle([6, 0, 7, 0, 42]), [6, 0, 7, 0, 42]);
      expect(store.handle([3, 0, 7, 0, 1]), [3, 2, 0, 42]);
      expect(store.handle([3, 0xff, 0xff, 0, 1]), [0x83, 2]);
      expect(store.handle([5, 0, 8, 0xff, 0]), [5, 0, 8, 0xff, 0]);
      expect(store.handle([1, 0, 8, 0, 1]), [1, 1, 1]);
    },
  );

  const parameters = {
    'transport': 'rtu',
    'port': 'browser-serial-1',
    'timeout': 0.1,
  };
  test('portable client validates before opening any channel', () async {
    var opened = 0;
    final client = ModbusClient(
      openChannel: (_) async {
        opened++;
        return MemoryChannel();
      },
    );
    await expectLater(
      client.connect({...parameters, 'baudrate': -1}),
      throwsFormatException,
    );
    expect(opened, 0);
    await client.close();
  });

  test('RTU fragmented noise recovery, exact words, write acknowledgement and traffic', () async {
    final channel = MemoryChannel();
    final client = ModbusClient(openChannel: (_) async => channel);
    final frames = <String>[];
    client.traffic = (direction, bytes) => frames.add(direction);
    channel.respond = (bytes) {
      final response = bytes[1] == 3
          ? rtuFrame(bytes[0], [3, 4, 0xff, 0xff, 0x80, 0])
          : rtuFrame(bytes[0], bytes.sublist(1, 6));
      channel.receive([0xff, ...response.take(3)]);
      channel.receive(response.sublist(3));
    };
    await client.connect(parameters);
    expect(await client.read(1, 'holding_registers', 0, 2), [65535, 32768]);
    await client.write(1, 'holding_registers', 0, [42]);
    expect(channel.sent.last, rtuFrame(1, [6, 0, 0, 0, 42]));
    // Each noise prefix is retained, followed by one complete response.
    expect(frames, ['tx', 'rx', 'rx', 'tx', 'rx', 'rx']);
    await client.close();
    expect(channel.closed, true);
    expect(client.connected, false);
  });

  test(
    'cancel returns promptly and excludes late RTU response from next read',
    () async {
      final channel = MemoryChannel();
      final client = ModbusClient(openChannel: (_) async => channel);
      await client.connect(parameters);
      final firstSent = Completer<void>();
      channel.respond = (_) => firstSent.complete();
      final cancel = ReadCancellation();
      final first = client.read(
        1,
        'holding_registers',
        0,
        1,
        cancellation: cancel,
      );
      final cancelled = expectLater(first, throwsA(isA<ReadCancelled>()));
      await firstSent.future;
      cancel.cancel();
      await cancelled;
      channel.receive(rtuFrame(1, [3, 2, 0, 99]));
      channel.respond = (_) => channel.receive(rtuFrame(1, [3, 2, 0, 42]));
      expect(await client.read(1, 'holding_registers', 1, 1), [42]);
      await client.close();
    },
  );

  test('transport close fails active read and releases the channel', () async {
    final channel = MemoryChannel();
    final client = ModbusClient(openChannel: (_) async => channel);
    await client.connect(parameters);
    final sent = Completer<void>();
    channel.respond = (_) => sent.complete();
    final reading = expectLater(
      client.read(1, 'holding_registers', 0, 1),
      throwsA(isA<WireDisconnected>()),
    );
    await sent.future;
    await client.close();
    await reading;
    expect(channel.closed, true);
  });

  test(
    'fragmented RTU responses log one frame and coalesced frames split',
    () async {
      final channel = MemoryChannel();
      final client = ModbusClient(openChannel: (_) async => channel);
      final received = <List<int>>[];
      client.traffic = (direction, bytes) {
        if (direction == 'rx') received.add(List.of(bytes));
      };
      final frame = rtuFrame(2, [3, 4, 0, 1, 0, 2]);
      channel.respond = (_) {
        for (final byte in frame) {
          channel.receive([byte]);
        }
      };
      await client.connect(parameters);
      expect(await client.read(2, 'holding_registers', 0, 2), [1, 2]);
      expect(received, [frame]);
      channel.receive([...frame, ...frame]);
      await Future<void>.delayed(Duration.zero);
      expect(received, [frame, frame, frame]);
      channel.receive([2, 3, 4]);
      await Future<void>.delayed(Duration.zero);
      await client.close();
      expect(received.last, [2, 3, 4]);
    },
  );

  test(
    'RTU unit switch and write readback wait 50 ms after latest RX',
    () async {
      final channel = MemoryChannel();
      final client = ModbusClient(openChannel: (_) async => channel);
      final clock = Stopwatch()..start();
      int? lastRx;
      final gaps = <int>[];
      client.traffic = (direction, bytes) {
        if (direction == 'rx') lastRx = clock.elapsedMicroseconds;
      };
      channel.respond = (bytes) {
        if (lastRx != null) gaps.add(clock.elapsedMicroseconds - lastRx!);
        channel.receive(
          bytes[1] == 6 ? bytes : rtuFrame(bytes[0], [3, 2, 0, 42]),
        );
      };
      await client.connect(parameters);
      await client.read(2, 'holding_registers', 0, 1);
      // Traffic arriving during the wait must restart the silence period.
      final late = Timer(const Duration(milliseconds: 30), () {
        channel.receive(rtuFrame(2, [3, 2, 0, 99]));
      });
      await client.write(1, 'holding_registers', 851, [1]);
      await client.read(1, 'holding_registers', 851, 1);
      expect(gaps, hasLength(2));
      expect(gaps, everyElement(greaterThanOrEqualTo(50000)));
      late.cancel();
      await client.close();
    },
  );

  test('cancelling during RTU silence sends no request', () async {
    final channel = MemoryChannel();
    final client = ModbusClient(openChannel: (_) async => channel);
    channel.respond = (_) => channel.receive(rtuFrame(1, [3, 2, 0, 42]));
    await client.connect(parameters);
    await client.read(1, 'holding_registers', 0, 1);
    final cancel = ReadCancellation();
    final next = client.read(
      1,
      'holding_registers',
      1,
      1,
      cancellation: cancel,
    );
    final check = expectLater(next, throwsA(isA<ReadCancelled>()));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    cancel.cancel();
    await check;
    expect(channel.sent, hasLength(1));
    await client.close();
  });
}
