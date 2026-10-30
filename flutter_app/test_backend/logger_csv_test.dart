import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:csv/csv.dart';
import 'package:modbus_desktop/src/backend/files.dart';
import 'package:test/test.dart';

void main() {
  test('CSV logger separates header, samples and appended sessions', () async {
    final dir = await Directory.systemTemp.createTemp('logger-csv-');
    final logger = NativeLogger();
    final file = File('${dir.path}/values.csv');
    final settings = {
      'command': 'logger_start',
      'path': file.path,
      'interval_ms': 100,
      'rows': [
        {
          'name': '温度,设定',
          'kind': 'holding_registers',
          'address': 0,
          'count': 1,
          'unit_id': 1,
          'format': 'dec',
          'scale': 0.1,
          'offset': 1,
          'unit': '°C',
        },
        {'name': '计数', 'address': 1},
      ],
    };
    Future<void> sample(int value) => logger.dispatch({
      'command': 'logger_sample',
      'values': [
        [value],
        [value],
      ],
    });
    try {
      await logger.dispatch({...settings, 'append': false});
      await sample(42);
      await Future<void>.delayed(const Duration(milliseconds: 110));
      await sample(43);
      await logger.close();
      final text = await file.readAsString();
      expect(
        text.split('\n'),
        hasLength(4),
        reason: 'Header and each sample must end with a newline',
      );
      final codec = Csv(lineDelimiter: '\n', autoDetect: false);
      final records = codec.decode(text.replaceFirst('\ufeff', ''));
      expect(records, hasLength(3));
      expect(records.first, ['timestamp', '温度,设定@1_0 (°C)', '计数@1_1']);
      expect(records[1].skip(1).map((v) => v.toString()), ['5.2', '42']);
      expect(records[2].skip(1).map((v) => v.toString()), ['5.3', '43']);
      for (final record in records.skip(1)) {
        expect(record, hasLength(3));
        expect(DateTime.tryParse(record[0].toString()), isNotNull);
      }

      await logger.dispatch({...settings, 'append': true});
      await sample(44);
      await logger.close();
      final appended = codec.decode(
        (await file.readAsString()).replaceFirst('\ufeff', ''),
      );
      expect(appended, hasLength(4));
      expect(appended.last.skip(1).map((v) => v.toString()), ['5.4', '44']);
      expect(appended.where((r) => r.first == 'timestamp'), hasLength(1));
      final before = await file.readAsBytes();
      await expectLater(
        logger.dispatch({
          ...settings,
          'append': true,
          'rows': [
            {...(settings['rows'] as List).first as Map, 'unit': '°F'},
            (settings['rows'] as List).last,
          ],
        }),
        throwsFormatException,
      );
      expect(await file.readAsBytes(), before);
    } finally {
      await logger.close();
      await dir.delete(recursive: true);
    }
  });

  for (final format in ['csv', 'jsonl']) {
    test('$format logger preserves text labels and JSONL units', () async {
      final dir = await Directory.systemTemp.createTemp('logger-units-');
      final logger = NativeLogger();
      final file = File('${dir.path}/values.$format');
      try {
        await logger.dispatch({
          'command': 'logger_start',
          'path': file.path,
          'format': format,
          'rows': [
            {'name': '温度', 'address': 0, 'unit': '°C'},
            {
              'name': '状态',
              'address': 1,
              'unit': '°C',
              'value_names': {'1': '°C 模式'},
            },
            {'name': '文本', 'address': 2, 'format': 'ascii', 'unit': 'C'},
          ],
        });
        await logger.dispatch({
          'command': 'logger_sample',
          'values': [
            [42],
            [1],
            [0x4143],
          ],
        });
        await logger.close();
        final text = await file.readAsString();
        if (format == 'csv') {
          final records = csvCodec.decode(text.replaceFirst('\ufeff', ''));
          expect(records.first, [
            'timestamp',
            '温度@1_0 (°C)',
            '状态@1_1 (°C)',
            '文本@1_2 (C)',
          ]);
          expect(records.last.skip(1).map((v) => v.toString()), [
            '42',
            '°C 模式 (1)',
            'AC',
          ]);
        } else {
          final records = const LineSplitter().convert(text).map(jsonDecode);
          expect(records.map((r) => r['value']), ['42 °C', '°C 模式 (1)', 'AC']);
        }
      } finally {
        await logger.close();
        await dir.delete(recursive: true);
      }
    });
  }
}
