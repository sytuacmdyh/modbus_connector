import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:modbus_desktop/src/backend/wire.dart';
import 'package:modbus_desktop/src/backend/devices.dart';
import 'package:modbus_desktop/src/bridge_client.dart';

import 'serial_lifetime_test.dart' show Port, Config;

class StalledPort extends Port {
  int writes = 0;
  @override
  int write(Uint8List bytes, {int timeout = -1}) {
    writes++;
    return 0;
  }
}

void main() {
  for (final transport in ['tcp', 'rtu_tcp', 'rtu_udp']) {
    test(
      '$transport cancels promptly and rejects abandoned reply on restart',
      () async {
        final reserve = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        final port = reserve.port;
        await reserve.close();
        final server = ModbusServer(), client = ModbusClient();
        final params = <String, dynamic>{
          'transport': transport,
          'host': '127.0.0.1',
          'port': port,
          'timeout': 0.4,
        };
        final seen = Completer<void>();
        var requests = 0;
        Future<List<int>> respond(int unit, List<int> pdu) async {
          requests++;
          if (requests == 1) {
            seen.complete();
            await Future<void>.delayed(const Duration(milliseconds: 150));
            return [3, 2, 0, 99];
          }
          return [3, 2, 0, 42];
        }

        RawDatagramSocket? udp;
        if (transport == 'rtu_udp') {
          udp = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
          params['port'] = udp.port;
          udp.listen((event) async {
            if (event != RawSocketEvent.read) return;
            final packet = udp!.receive();
            if (packet == null) return;
            final reply = await respond(
              1,
              packet.data.sublist(1, packet.data.length - 2),
            );
            udp!.send(rtuFrame(1, reply), packet.address, packet.port);
          });
        } else {
          await server.start(params, respond);
        }
        try {
          await client.connect(params);
          final cancellation = ReadCancellation();
          final pending = client.read(
            1,
            'holding_registers',
            0,
            1,
            cancellation: cancellation,
          );
          final cancelled = expectLater(pending, throwsA(isA<ReadCancelled>()));
          await seen.future;
          cancellation.cancel();
          await cancelled.timeout(const Duration(milliseconds: 100));
          if (transport != 'tcp') {
            final draining = ReadCancellation();
            final another = client.read(
              1,
              'holding_registers',
              1,
              1,
              cancellation: draining,
            );
            final stopped = expectLater(another, throwsA(isA<ReadCancelled>()));
            await Future<void>.delayed(const Duration(milliseconds: 10));
            draining.cancel();
            await stopped.timeout(const Duration(milliseconds: 100));
            expect(requests, 1);
          }
          expect(await client.read(1, 'holding_registers', 2, 1), [42]);
          expect(client.connected, true);
        } finally {
          await client.close();
          await server.close();
          udp?.close();
        }
      },
    );
  }
  test('read cancelled while worker starts is never sent', () async {
    final bridge = NativeBridge();
    final pending = bridge.request({'command': 'read_rows'});
    bridge.cancelPendingRead();
    await expectLater(
      pending,
      throwsA(
        isA<BridgeException>().having(
          (e) => e.message,
          'message',
          'Read cancelled',
        ),
      ),
    );
    expect((await bridge.request({'command': 'hello'})).result['protocol'], 1);
    await bridge.close();
  });
  test(
    'cancelled serial transmission cannot keep writing after close',
    () async {
      final port = StalledPort(),
          config = Config(),
          cancel = ReadCancellation();
      final channel = SerialChannel(
        {
          'port': 'test',
          'baudrate': 9600,
          'bytesize': 8,
          'parity': 'N',
          'stopbits': 1,
        },
        createPort: (_) => port,
        createConfig: () => config,
      );
      final writing = expectLater(
        channel.write([1, 2, 3], cancellation: cancel),
        throwsA(isA<ReadCancelled>()),
      );
      cancel.cancel();
      await writing.timeout(const Duration(milliseconds: 100));
      channel.close();
      final writes = port.writes;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(port.writes, writes);
      expect(config.frees, 1);
    },
  );
}
