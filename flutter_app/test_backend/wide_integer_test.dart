import 'package:modbus_desktop/src/backend/registers.dart';
import 'package:modbus_desktop/src/backend/csv.dart';
import 'package:test/test.dart';

void main() {
  for (final format in ['u64', 's64']) {
    for (final order in ['ABCD', 'BADC', 'CDAB', 'DCBA']) {
      test(
        '$format $order preserves boundaries and adjacent large integers',
        () {
          final r = row({'format': format, 'order': order, 'count': 4});
          final texts = format == 'u64'
              ? [
                  '0',
                  '9007199254740993',
                  '9223372036854775807',
                  '18446744073709551614',
                  '18446744073709551615',
                ]
              : [
                  '-9223372036854775808',
                  '-9007199254740993',
                  '-1',
                  '9007199254740993',
                  '9223372036854775807',
                ];
          for (final text in texts) {
            final words = encodeValues({'row': r, 'text': text});
            expect(words, everyElement(inInclusiveRange(0, 65535)));
            expect(displayValue(render(r, words)), text);
            final exported =
                csvCommand({
                      'command': 'csv_export',
                      'rows': [
                        {...r, 'values': words},
                      ],
                      'columns': ['value'],
                    })['text']
                    as String;
            expect(exported, contains(text));
          }
        },
      );
    }
  }
  test('wide scaling, inverse rounding and clamping remain exact', () {
    final r = row({
      'format': 'u64',
      'count': 4,
      'scale': 0.01,
      'offset': -1.25,
      'unit': 'kWh',
    });
    const text = '184467440737095514.90';
    final words = encodeValues({'row': r, 'text': text});
    expect(words, [65535, 65535, 65535, 65535]);
    expect(displayValue(render(r, words)), '184467440737095514.9 kWh');
    final s = row({'format': 's64', 'count': 4});
    for (final pair in [
      ['2.5', '2'],
      ['3.5', '4'],
      ['-2.5', '-2'],
      ['-3.5', '-4'],
      ['-1e30', '-9223372036854775808'],
      ['1e30', '9223372036854775807'],
    ]) {
      expect(
        displayValue(render(s, encodeValues({'row': s, 'text': pair[0]}))),
        pair[1],
      );
    }
    expect(
      () => encodeValues({'row': r, 'text': 'NaN'}),
      throwsFormatException,
    );
    expect(
      () => encodeValues({'row': r, 'text': '1e99999'}),
      throwsFormatException,
    );
  });
}
