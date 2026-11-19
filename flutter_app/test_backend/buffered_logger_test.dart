import 'dart:convert';

import 'package:modbus_desktop/src/backend/logger_buffer.dart';
import 'package:test/test.dart';

void main() {
  test(
    'bounded JSONL sample is atomic and retained after stop/overflow',
    () async {
      final logger = BufferedLogger(capacity: 150);
      await logger.dispatch({
        'command': 'logger_start',
        'path': 'segment.jsonl',
        'format': 'jsonl',
        'rows': [
          {'name': '精确计数', 'format': 'u64', 'count': 4},
          {'name': '第二个值'},
        ],
        'fields': ['name'],
        'append': false,
      });
      final sample = {
        'command': 'logger_sample',
        'values': [
          [65535, 65535, 65535, 65535],
          [42],
        ],
      };
      await logger.dispatch(sample);
      final before =
          (await logger.dispatch({'command': 'logger_export'}))['text']
              as String;
      expect(before, contains('18446744073709551615'));
      expect(
        const LineSplitter().convert(before).map(jsonDecode),
        hasLength(2),
      );
      await Future<void>.delayed(const Duration(milliseconds: 1010));
      await expectLater(logger.dispatch(sample), throwsFormatException);
      await logger.close();
      expect(
        (await logger.dispatch({'command': 'logger_export'}))['text'],
        before,
      );
      await logger.dispatch({
        'command': 'logger_start',
        'path': 'next.csv',
        'rows': [
          {'name': '新段'},
        ],
        'append': false,
      });
      expect(
        (await logger.dispatch({'command': 'logger_export'}))['text'],
        contains('新段'),
      );
      expect(
        (await logger.dispatch({'command': 'logger_export'}))['text'],
        isNot(contains('18446744073709551615')),
      );
      await logger.close();
    },
  );
}
