import 'package:flutter_test/flutter_test.dart';
import 'package:modbus_desktop/src/sniffer_views.dart';

void main() {
  test('sniffer view filters/hiding/sort preserve raw data needed for multiword values', () {
    final map = <String, Map<String, dynamic>>{
      'holding_registers/0': {
        'kind': 'holding_registers',
        'address': 0,
        'count': 2,
        'name': 'Voltage',
        'value': 1,
      },
      'holding_registers/1': {
        'kind': 'holding_registers',
        'address': 1,
        'count': 1,
        'hidden': true,
        'value': 2,
      },
      'input_registers/0': {
        'kind': 'input_registers',
        'address': 0,
        'count': 1,
        'name': 'Current',
        'value': 3,
      },
    };
    expect(visibleSnifferViews(map), hasLength(2));
    expect(
      visibleSnifferViews(map, area: 'holding_registers').single['values'],
      [1, 2],
    );
    expect(
      visibleSnifferViews(map, query: 'voltage').single['name'],
      'Voltage',
    );
    expect(visibleSnifferViews(map, area: 'coils'), isEmpty);
    map['holding_registers/1']!['hidden'] = false;
    expect(visibleSnifferViews(map, descending: true).first['address'], 1);
    expect(map, hasLength(3));
  });

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
