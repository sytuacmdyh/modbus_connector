import 'package:flutter_test/flutter_test.dart';
import 'package:modbus_desktop/src/sniffer_views.dart';

void main() {
  test('multiword sniffer views require same-area consecutive words', () {
    final map = <String, Map<String, dynamic>>{
      'holding_registers/1': {
        'kind': 'holding_registers',
        'address': 1,
        'count': 1,
        'value': 2,
      },
      'holding_registers/0': {
        'kind': 'holding_registers',
        'address': 0,
        'count': 2,
        'value': 1,
        'format': 'u32',
      },
      'input_registers/2': {
        'kind': 'input_registers',
        'address': 2,
        'count': 1,
        'value': 3,
      },
    };
    final views = snifferViews(map);
    expect(views.first['values'], [1, 2]);
    map['holding_registers/0']!['count'] = 4;
    expect(snifferViews(map).first['values'], isNull);
    expect(map['holding_registers/0']!['value'], 1);
  });
}
