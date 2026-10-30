import 'dart:async';
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
        },
      ],
    };
    Future<void> sample(int value) => logger.dispatch({
      'command': 'logger_sample',
      'values': [
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
      expect(records.first, ['timestamp', '温度,设定@0/u1']);
      expect(records[1][1].toString(), '42');
      expect(records[2][1].toString(), '43');
      for (final record in records.skip(1)) {
        expect(record, hasLength(2));
        expect(DateTime.tryParse(record[0].toString()), isNotNull);
      }

      await logger.dispatch({...settings, 'append': true});
      await sample(44);
      await logger.close();
      final appended = codec.decode(
        (await file.readAsString()).replaceFirst('\ufeff', ''),
      );
      expect(appended, hasLength(4));
      expect(appended.last[1].toString(), '44');
      expect(appended.where((r) => r.first == 'timestamp'), hasLength(1));
    } finally {
      await logger.close();
      await dir.delete(recursive: true);
    }
  });
}
