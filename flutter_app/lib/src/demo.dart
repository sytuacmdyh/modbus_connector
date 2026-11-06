import 'translations.dart';

/// Fresh descriptors on every call; a demo never shares a device's mutable map.
List<Map<String, dynamic>> demoRegisters() => [
  for (final (name, kind, address, scale, unit) in [
    ('Demo signal A', 'input_registers', 0, 0.01, 'V'),
    ('Demo signal B', 'input_registers', 5, 0.01, 'V'),
    ('Demo setpoint', 'holding_registers', 0, 0.1, '°C'),
    ('Demo counter', 'holding_registers', 1, 1.0, ''),
    ('Demo switch', 'coils', 0, 1.0, ''),
    ('Demo contact', 'discrete_inputs', 0, 1.0, ''),
  ])
    {
      'name': tr(name),
      'kind': kind,
      'address': address,
      'count': 1,
      'format': 'u16',
      'order': 'ABCD',
      'scale': scale,
      'offset': 0,
      'unit': unit,
      'poll_enabled': true,
      'trend_enabled': kind == 'input_registers',
      if (kind == 'coils' || kind == 'discrete_inputs')
        'value_names': {'0': tr('Off'), '1': tr('On')},
    },
];

Map<String, dynamic> demoState() => {
  'mode': 'master',
  'connection': {'transport': 'demo', 'timeout': 1.0},
  'draft': {
    'transport': 'demo',
    'unit': '1',
    'timeout': '1',
    'map_interval': 500,
  },
  'unit': 1,
  'map_grouped': true,
  'registers': demoRegisters(),
};
