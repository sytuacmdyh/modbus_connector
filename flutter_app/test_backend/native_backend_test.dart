import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:modbus_desktop/src/backend/catalog.dart';
import 'package:modbus_desktop/src/backend/expression.dart';
import 'package:modbus_desktop/src/backend/files.dart';
import 'package:modbus_desktop/src/backend/service.dart';
import 'package:modbus_desktop/src/backend/wire.dart';
import 'package:modbus_desktop/src/bridge_client.dart';

Future<int> freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = s.port;
  await s.close();
  return port;
}

void compare(dynamic actual, dynamic expected, [String path = '']) {
  if (expected is num && actual is num) {
    expect(
      actual,
      closeTo(expected.toDouble(), expected.abs() * 1e-12 + 1e-9),
      reason: path,
    );
  } else if (expected is Map) {
    expect(actual, isA<Map>(), reason: path);
    for (final key in expected.keys) {
      if (key == 'error' && expected[key] != null) {
        expect(actual[key], isNotNull);
        continue;
      }
      compare(actual[key], expected[key], '$path/$key');
    }
  } else if (expected is List) {
    expect(actual, isA<List>(), reason: path);
    expect((actual as List).length, expected.length, reason: path);
    for (var i = 0; i < expected.length; i++) {
      compare(actual[i], expected[i], '$path/$i');
    }
  } else {
    expect(actual, expected, reason: path);
  }
}

Future<Map<String, dynamic>> call(
  NativeBridge b,
  String cmd, [
  Map<String, dynamic> d = const {},
]) async {
  return (await b
          .request({'command': cmd, ...d})
          .timeout(const Duration(seconds: 3)))
      .result;
}

void main() {
  final oracle = jsonDecode(
    File('test_backend/fixtures/python_backend.json').readAsStringSync(),
  ) as List;
  group('Python behavioral oracle', () {
    for (var i = 0; i < oracle.length; i++) {
      test('case $i ${oracle[i]['request']}', () async {
        final service = NativeService();
        try {
          final reply = await service.respond(
            Map<String, dynamic>.from(oracle[i]['request']),
          );
          expect(reply['ok'], true, reason: '$reply');
          compare(reply['result'], oracle[i]['result']);
        } finally {
          await service.close();
        }
      });
    }
  });
  test('expression grammar rejects code and bounds recursion', () {
    for (final text in [
      'import os',
      '__import__(1)',
      '[a].x',
      'a[0]',
      '1<2',
      '[ ]',
      '1;2',
      'sin(x=1)',
    ]) {
      expect(() => Expression(text), throwsFormatException, reason: text);
    }
    expect(
      () => Expression(
        '${List.filled(150, '(').join()}1${List.filled(150, ')').join()}',
      ),
      throwsFormatException,
    );
    expect(Expression('2**3**2').evaluate({}), 512);
    expect(() => Expression('[missing]').evaluate({}), throwsStateError);
  });
  test('CRC and frame fragmentation', () {
    expect(crc16([1, 3, 0, 0, 0, 10]), 0xcdc5);
    final frame = rtuFrame(1, [3, 2, 0, 42]);
    final parser = FrameParser(tcp: false);
    expect(parser.feed(frame.sublist(0, 3)), isEmpty);
    expect(parser.feed(frame.sublist(3)), [frame]);
    expect(parser.feed([255, 255, ...frame]), [frame]);
  });
  for (final transport in ['tcp', 'rtu_tcp']) {
    test('$transport simulator advanced functions gateway shutdown', () async {
      final sim = NativeBridge(service: NativeService()),
          master = NativeBridge(service: NativeService()),
          gateway = NativeBridge(service: NativeService()),
          forwarded = NativeBridge(service: NativeService());
      final port = await freePort(), proxy = await freePort();
      try {
        await call(sim, 'sim_configure', {
          'rows': [
            {
              'kind': 'holding_registers',
              'count': 2,
              'values': [12, 34],
            },
            {
              'kind': 'input_registers',
              'values': [99],
            },
            {
              'kind': 'coils',
              'values': [true],
            },
            {
              'kind': 'discrete_inputs',
              'values': [false],
            },
          ],
        });
        await call(sim, 'device_start', {
          'mode': 'simulator',
          'listen': {'transport': transport, 'host': '127.0.0.1', 'port': port},
          'tick_ms': 100,
        });
        await call(master, 'connect', {
          'transport': transport,
          'host': '127.0.0.1',
          'port': port,
          'timeout': 0.2,
        });
        expect((await call(master, 'read', {'count': 2}))['values'], [12, 34]);
        expect(
          (await call(master, 'read', {'kind': 'input_registers'}))['values'],
          [99],
        );
        expect((await call(master, 'read', {'kind': 'coils'}))['values'], [
          true,
        ]);
        expect(
          (await call(master, 'read', {'kind': 'discrete_inputs'}))['values'],
          [false],
        );
        await call(master, 'write', {
          'values': [100, 200],
        });
        await call(master, 'mask_write', {'and_mask': 0xff00, 'or_mask': 7});
        expect((await call(master, 'read'))['values'], [7]);
        expect(
          (await call(master, 'read_write', {
            'read_count': 2,
            'values': [8, 9],
          }))['values'],
          [8, 9],
        );
        expect((await call(master, 'diagnostics'))['loopback'], true);
        expect(
          (await call(master, 'device_id'))['objects'],
          containsPair('0', 'Modbus Connector'),
        );
        await expectLater(
          call(master, 'read', {'address': 10000}),
          throwsA(isA<BridgeException>()),
        );
        expect(master.service.connected, true);
        await call(gateway, 'device_start', {
          'mode': 'gateway',
          'listen': {'transport': 'tcp', 'host': '127.0.0.1', 'port': proxy},
          'target': {'transport': transport, 'host': '127.0.0.1', 'port': port},
          'units': [1],
        });
        await call(forwarded, 'connect', {
          'transport': 'tcp',
          'host': '127.0.0.1',
          'port': proxy,
        });
        expect((await call(forwarded, 'read', {'count': 2}))['values'], [8, 9]);
        await expectLater(
          call(forwarded, 'read', {'unit': 2}),
          throwsA(isA<BridgeException>()),
        );
      } finally {
        await forwarded.close();
        await gateway.close();
        await master.close();
        await sim.close();
      }
      await expectLater(
        Socket.connect(InternetAddress.loopbackIPv4, port),
        throwsA(isA<SocketException>()),
      );
    });
  }
  test('demo scanner rules and traffic', () async {
    final b = NativeBridge(service: NativeService());
    final traffic = <Map<String, dynamic>>[];
    b.onTraffic = (t, _) => traffic.addAll(t);
    try {
      await call(b, 'connect', {'transport': 'demo'});
      expect(
        (await call(b, 'read', {'kind': 'input_registers'}))['values'][0],
        inInclusiveRange(500, 1500),
      );
      await call(b, 'write', {
        'values': [235],
      });
      expect((await call(b, 'read'))['values'], [235]);
      expect(traffic.map((f) => f['direction']), containsAll(['tx', 'rx']));
      expect(
        (await call(b, 'scan_unit', {
          'probes': [
            {'kind': 'holding_registers'},
          ],
        }))['hits'],
        [0],
      );
      await call(b, 'disconnect');
      await call(b, 'sim_configure', {
        'rows': [
          {
            'name': 'Counter',
            'rule_text': 'prev+1',
            'values': [3],
          },
        ],
      });
      b.service.devices.started.start();
      b.service.devices.tick();
      expect(b.service.devices.store.get('holding_registers', 0, 1), [4]);
      b.service.devices.tick();
      expect(b.service.devices.store.get('holding_registers', 0, 1), [5]);
    } finally {
      await b.close();
    }
  });
  test('CSV Unicode custom histories and logging', () async {
    final dir = await Directory.systemTemp.createTemp('native-catalog-');
    final catalog = NativeCatalog(directory: dir);
    try {
      final state = {
        'connection': {'transport': 'tcp', 'host': '127.0.0.1', 'port': 502},
        'registers': [
          {'name': '温度,水', 'address': 10, 'count': 1},
        ],
        'draft': {'custom': 'keep'},
        'unit': 7,
        'sim_rows': [
          {
            'name': 'Simulation',
            'values': [3],
          },
        ],
      };
      final text = csvCommand({
        'command': 'csv_export',
        'rows': state['registers'],
      })['text'];
      expect(
        csvCommand({'command': 'csv_parse', 'text': text})['rows'][0]['name'],
        '温度,水',
      );
      final saved = await catalog.dispatch({
        'command': 'template_save',
        'state': state,
        'name': '测试',
      });
      expect(
        (await catalog.dispatch({
          'command': 'template_load',
          'template_id': saved['id'],
        }))['state']['draft']['custom'],
        'keep',
      );
      final restored = (await catalog.dispatch({
        'command': 'template_load',
        'template_id': saved['id'],
      }))['state'];
      expect(restored['unit'], 7);
      expect(restored['sim_rows'][0]['name'], 'Simulation');
      await catalog.dispatch({
        'command': 'template_save',
        'state': state,
        'template_id': saved['id'],
      });
      final versions =
          (await catalog.dispatch({
                'command': 'template_versions',
                'template_id': saved['id'],
              }))['versions']
              as List;
      expect(versions.length, 2);
      await catalog.dispatch({
        'command': 'template_delete_version',
        'template_id': saved['id'],
        'version_id': versions[0]['id'],
      });
      await expectLater(
        catalog.dispatch({
          'command': 'template_delete_version',
          'template_id': saved['id'],
          'version_id': versions[1]['id'],
        }),
        throwsFormatException,
      );
      final logger = NativeLogger();
      await logger.dispatch({
        'command': 'logger_start',
        'path': '${dir.path}/values.csv',
        'rows': state['registers'],
        'append': false,
      });
      await logger.dispatch({
        'command': 'logger_sample',
        'values': [
          [42],
        ],
      });
      await logger.close();
      final log = await File('${dir.path}/values.csv').readAsString();
      expect((await File('${dir.path}/values.csv').readAsBytes()).take(3), [
        239,
        187,
        191,
      ]);
      expect(log, contains('42'));
      expect(log, contains('温度'));
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
