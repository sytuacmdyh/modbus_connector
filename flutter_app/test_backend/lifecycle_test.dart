import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:modbus_desktop/src/bridge_client.dart';
import 'package:modbus_desktop/src/backend/devices.dart';
import 'package:modbus_desktop/src/backend/files.dart';
import 'package:modbus_desktop/src/backend/registers.dart';
import 'package:modbus_desktop/src/backend/wire.dart';

Future<int> reserve() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = s.port;
  await s.close();
  return port;
}

void main() {
  test(
    'owned Dart isolate connects, serializes requests, closes and reconnects',
    () async {
      final backend = NativeBridge();
      final connect = backend.request({
        'command': 'connect',
        'transport': 'demo',
      });
      expect(
        () => backend.request({'command': 'hello'}),
        throwsA(isA<BridgeException>()),
      );
      expect((await connect).connected, true);
      expect((await backend.request({'command': 'read'})).result['values'], [
        100,
      ]);
      await backend.request({'command': 'disconnect'});
      expect(
        (await backend.request({'command': 'connect', 'transport': 'demo'}))
            .connected,
        true,
      );
      final reading = backend.request({'command': 'read'});
      await Future.wait([backend.close(), backend.close()]);
      expect((await reading).result['values'], [100]);
      expect(
        () => backend.request({'command': 'hello'}),
        throwsA(isA<BridgeException>()),
      );
    },
  );
  for (final transport in ['tcp', 'rtu_tcp']) {
    test(
      '$transport timeout drains late replies and polling can recover',
      () async {
        final port = await reserve(),
            server = ModbusServer(),
            client = ModbusClient();
        var requests = 0;
        final params = {
          'transport': transport,
          'host': '127.0.0.1',
          'port': port,
          'timeout': 0.1,
        };
        await server.start(params, (unit, pdu) async {
          requests++;
          if (requests == 1) {
            await Future<void>.delayed(const Duration(milliseconds: 150));
            return [3, 2, 0, 99];
          }
          return [3, 2, 0, 42];
        });
        try {
          await client.connect(params);
          await expectLater(
            client.read(1, 'holding_registers', 0, 1),
            throwsA(isA<TimeoutException>()),
          );
          expect(client.connected, true);
          expect(await client.read(1, 'holding_registers', 1, 1), [42]);
          final before = requests;
          await expectLater(
            client.read(1, 'holding_registers', 65535, 2),
            throwsFormatException,
          );
          expect(
            requests,
            before,
            reason: 'invalid ranges must not reach the wire',
          );
        } finally {
          await client.close();
          await server.close();
        }
      },
    );
  }
  test(
    'sniffer recovers CRC frames after noise and ignores malformed payloads',
    () async {
      final devices = NativeDevices(),
          parser = FrameParser(tcp: false, sniff: true);
      try {
        // A plausible but incomplete frame before a complete request must not block it.
        final request = rtuFrame(2, [3, 0, 10, 0, 2]);
        devices.feedSniffer([1, 3, 250, ...request], parser);
        final response = rtuFrame(2, [3, 4, 0, 123, 1, 200]);
        devices.feedSniffer(response.sublist(0, 4), parser);
        devices.feedSniffer(response.sublist(4), parser);
        expect(devices.recovered[2]!['holding_registers'], {10: 123, 11: 456});
        devices.feedSniffer(rtuFrame(2, [16, 0, 20, 0, 100, 2, 0, 1]), parser);
        expect(
          devices.recovered[2]!['holding_registers']!.containsKey(20),
          false,
        );
        devices.feedSniffer(rtuFrame(2, [5, 0, 3, 255, 0]), parser);
        expect(devices.recovered[2]!['coils']![3], true);
        // Exceptions clear the pending address so unsolicited replies cannot reuse it.
        devices.feedSniffer(rtuFrame(2, [3, 0, 30, 0, 1]), parser);
        devices.feedSniffer(rtuFrame(2, [131, 2]), parser);
        devices.feedSniffer(rtuFrame(2, [3, 2, 0, 7]), parser);
        expect(
          devices.recovered[2]!['holding_registers']!.containsKey(30),
          false,
        );
      } finally {
        await devices.close();
      }
    },
  );
  test(
    'logger rejects invalid fields before truncating an existing file',
    () async {
      final dir = await Directory.systemTemp.createTemp('native-log-'),
          logger = NativeLogger();
      final f = File('${dir.path}/preserve.jsonl');
      await f.writeAsString('existing data');
      try {
        await expectLater(
          logger.dispatch({
            'command': 'logger_start',
            'path': f.path,
            'format': 'jsonl',
            'append': false,
            'rows': [{}],
            'fields': ['unknown'],
          }),
          throwsFormatException,
        );
        expect(await f.readAsString(), 'existing data');
      } finally {
        await logger.close();
        await dir.delete(recursive: true);
      }
    },
  );
  test('engineering writes preserve scaled decimals and separators', () {
    final descriptor = {
      'kind': 'holding_registers',
      'count': 1,
      'format': 'dec',
      'scale': 0.1,
      'offset': 0,
    };
    expect(encodeValues({'row': descriptor, 'text': '23.5'}), [235]);
    expect(
      encodeValues({
        'row': {...descriptor, 'count': 2},
        'text': '23.5, 24.5',
      }),
      [235, 245],
    );
    expect(
      encodeValues({
        'row': {...descriptor, 'count': 2},
        'text': '23.5\n24.5',
      }),
      [235, 245],
    );
  });
  test('wide integers clamp without signed 64 bit overflow', () {
    expect(encodeNumber(18446744073709551616.0, 'u64'), [
      65535,
      65535,
      65535,
      65535,
    ]);
    expect(encodeNumber(-18446744073709551616.0, 's64'), [32768, 0, 0, 0]);
    expect(encodeNumber(18446744073709551616.0, 's64'), [
      32767,
      65535,
      65535,
      65535,
    ]);
  });
}
