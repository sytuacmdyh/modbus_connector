import 'dart:io';

import 'package:test/test.dart';
import 'package:modbus_desktop/src/backend/catalog.dart';
import 'package:modbus_desktop/src/backend/files.dart';
import 'package:modbus_desktop/src/backend/registers.dart';
import 'package:modbus_desktop/src/backend/service.dart';

void main() {
  test('row writes enforce access and span before any bus traffic', () async {
    final service = NativeService();
    addTearDown(service.close);
    expect(
      (await service.respond({
        'command': 'connect',
        'transport': 'demo',
      }))['ok'],
      true,
    );
    final descriptor = <String, dynamic>{
      'kind': 'holding_registers',
      'address': 10,
      'count': 1,
    };
    final before = service.txBytes;
    for (final patch in [
      {'writable': false},
      {'writable': 'false'},
      {'writable': null},
      {'writable': 0},
      {'kind': 'input_registers'},
      {'kind': 'input_registers', 'writable': true},
      {'kind': 'discrete_inputs', 'writable': true},
      {'kind': 'coils', 'writable': false},
    ]) {
      final reply = await service.respond({
        'command': 'write_row',
        'row': {...descriptor, ...patch},
        'values': [42],
      });
      expect(reply['ok'], false, reason: '$patch');
      expect(reply['traffic'], isEmpty);
      expect(service.txBytes, before);
    }
    for (final values in [
      [],
      [1, 2],
      [-1],
      [65536],
    ]) {
      final reply = await service.respond({
        'command': 'write_row',
        'row': descriptor,
        'values': values,
      });
      expect(reply['ok'], false);
      expect(service.txBytes, before);
    }
    // Even contradictory top-level addresses cannot override the row metadata.
    for (final access in <Json>[
      {},
      {'writable': true},
    ]) {
      final reply = await service.respond({
        'command': 'write_row',
        'row': {...descriptor, ...access, 'unit_id': 7},
        'unit': 1,
        'address': 99,
        'kind': 'coils',
        'values': [42],
      });
      expect(reply['ok'], true, reason: '$reply');
      final tx = (reply['traffic'] as List).firstWhere(
        (f) => f['direction'] == 'tx',
      );
      expect((tx['hex'] as String).split(' ').skip(6).toList(), [
        '07',
        '06',
        '00',
        '0A',
        '00',
        '2A',
      ]);
    }
    final read = await service.respond({
      'command': 'read_rows',
      'grouped': true,
      'rows': [
        {...descriptor, 'writable': false},
        {...descriptor, 'address': 11, 'writable': true},
      ],
    });
    expect(read['ok'], true);
    expect(read['result']['rows'][0]['values'], [42]);
    expect(read['result']['rows'][1]['values'], [111]);
    final coil = await service.respond({
      'command': 'write_row',
      'row': {...descriptor, 'kind': 'coils', 'writable': true},
      'values': [true],
    });
    expect(coil['ok'], true);
  });

  test('CSV round trip preserves explicit permissions and legacy omission', () {
    final rows = [
      {'name': '只读温度', 'address': 0, 'writable': false},
      {'name': '设定值', 'address': 1, 'writable': true},
      {'name': '旧模板', 'address': 2},
    ];
    final text = csvCommand({'command': 'csv_export', 'rows': rows})['text'];
    final parsed = csvCommand({'command': 'csv_parse', 'text': text})['rows'];
    expect(parsed[0]['writable'], false);
    expect(parsed[1]['writable'], true);
    expect(parsed[2].containsKey('writable'), false);
    for (final value in ['0', '1', 'no', 'null']) {
      expect(
        () => csvCommand({
          'command': 'csv_parse',
          'text': 'name,kind,address,writable\nx,holding_registers,0,$value\n',
        }),
        throwsFormatException,
      );
    }
    expect(
      () => csvCommand({
        'command': 'csv_parse',
        'text': 'name,kind,address,writable\nx,input_registers,0,true\n',
      }),
      throwsFormatException,
    );
  });

  test(
    'template versions retain access and reject invalid permissions',
    () async {
      final dir = await Directory.systemTemp.createTemp('write-access-');
      addTearDown(() => dir.delete(recursive: true));
      final catalog = NativeCatalog(directory: dir);
      Json state(bool writable) => {
        'name': 'test',
        'connection': {},
        'registers': [
          <String, dynamic>{
            'name': 'temperature',
            'address': 10,
            'writable': writable,
          },
        ],
      };
      final saved = await catalog.dispatch({
        'command': 'template_save',
        'name': 'test',
        'state': state(false),
      });
      final versions = await catalog.dispatch({
        'command': 'template_versions',
        'template_id': saved['id'],
      });
      await catalog.dispatch({
        'command': 'template_save',
        'template_id': saved['id'],
        'state': state(true),
      });
      for (final old in [true, false]) {
        final loaded = await catalog.dispatch({
          'command': 'template_load',
          'template_id': saved['id'],
          if (old) 'version_id': versions['versions'][0]['id'],
        });
        expect(loaded['state']['registers'][0]['writable'], !old);
      }
      for (final bad in ['false', null, 0]) {
        final invalid = state(false);
        invalid['registers'][0]['writable'] = bad;
        expect(() => flutterState(invalid), throwsFormatException);
        await expectLater(
          catalog.dispatch({
            'command': 'template_save',
            'name': 'bad',
            'state': invalid,
          }),
          throwsFormatException,
        );
      }
      final invalid = state(true);
      invalid['registers'][0]['kind'] = 'input_registers';
      expect(() => validateTemplate(invalid), throwsFormatException);
    },
  );
}
