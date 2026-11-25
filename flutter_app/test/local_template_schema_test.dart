import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:modbus_desktop/src/backend/template_schema.dart';

void main() {
  test(
    'local template preserves register metadata and converts legacy settings',
    () {
      final state = localTemplateState(
        jsonEncode({
          'name': 'Local device',
          'connection': {
            'type': 'TCP',
            'tcp_host': '192.0.2.1',
            'tcp_port': 502,
            'unit': 3,
          },
          'registers': [
            {
              'name': 'Mode',
              'address': 7,
              'format': 'dec',
              'writable': false,
              'value_names': {'0': 'Off', '1': 'On'},
            },
          ],
        }),
      );
      expect(state['connection']['transport'], 'tcp');
      expect(state['draft']['host'], '192.0.2.1');
      expect(state['unit'], 3);
      expect(state['registers'].single['format'], 'u16');
      expect(state['registers'].single['writable'], false);
      expect(state['registers'].single['value_names'], {'0': 'Off', '1': 'On'});
    },
  );

  test(
    'native simulator template retains simulator rows and configuration',
    () {
      final state = localTemplateState(
        jsonEncode({
          'name': 'Local simulator',
          'mode': 'simulator',
          'connection': {'transport': 'tcp', 'host': '127.0.0.1', 'port': 502},
          'registers': [],
          'sim_rows': [
            {'address': 10, 'format': 'u16', 'value': 12},
          ],
          'device_config': {'tick_ms': 2000},
        }),
      );
      expect(state['mode'], 'simulator');
      expect(state['sim_rows'].single['value'], 12);
      expect(state['device_config']['tick_ms'], 2000);
    },
  );

  test('malformed JSON, workspaces and invalid permissions are rejected', () {
    for (final text in [
      '{',
      'null',
      '[]',
      '{"tabs": [{}]}',
      jsonEncode({
        'name': 'Invalid',
        'connection': {},
        'registers': [
          {'writable': 'true'},
        ],
      }),
    ]) {
      expect(() => localTemplateState(text), throwsFormatException);
    }
  });
}
