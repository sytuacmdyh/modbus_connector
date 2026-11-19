import 'registers.dart';

Json map(dynamic d) => Map<String, dynamic>.from(d as Map? ?? {});
void validateTemplate(dynamic v) {
  if (v is! Map ||
      v['name'] is! String ||
      (v['name'] as String).isEmpty ||
      v['connection'] is! Map ||
      v['registers'] is! List) {
    throw const FormatException('Invalid template');
  }
  for (final raw in v['registers']) {
    validateRowAccess(map(raw));
  }
}

void validateCatalog(dynamic catalog) {
  if (catalog is! Map || catalog.isEmpty || catalog.length > 1000) {
    throw const FormatException('Invalid cloud template catalog');
  }
  for (final e in catalog.entries) {
    final key = e.key;
    if (key is! String ||
        key.split('/').length != 2 ||
        !key.endsWith('.json') ||
        key.startsWith('.')) {
      throw const FormatException('Invalid template resource');
    }
    relativePath(key);
    validateTemplate(e.value);
  }
}

String relativePath(String value) {
  if (value.isEmpty ||
      value.split('/').any((p) => p.isEmpty || p == '.' || p == '..') ||
      RegExp(r'[\\\x00\r\n?#]').hasMatch(value)) {
    throw const FormatException("Enter a relative cloud path without '..'.");
  }
  return value;
}

Json flutterState(Json s) {
  for (final raw in s['registers'] as List? ?? []) {
    validateRowAccess(map(raw));
  }
  var c = map(s['connection']);
  final options = map(s['registers_options']),
      extra = map(map(s['registers_options'])['flutter']);
  if (!c.containsKey('transport')) {
    final transport =
        {
          'TCP': 'tcp',
          'RTU over TCP': 'rtu_tcp',
          'RTU over UDP': 'rtu_udp',
        }[c['type']] ??
        'rtu';
    c = {
      'transport': transport,
      'host': c['tcp_host'] ?? '127.0.0.1',
      'port': transport == 'rtu'
          ? c['rtu_port'] ?? ''
          : int.parse('${c['tcp_port'] ?? 502}'),
      'baudrate': int.parse('${c['rtu_baud'] ?? 9600}'),
      'bytesize': int.parse('${c['rtu_bytesize'] ?? 8}'),
      'parity': c['rtu_parity'] ?? 'N',
      'stopbits': int.parse('${c['rtu_stopbits'] ?? 1}'),
      'timeout': c['timeout'] ?? 3,
    };
  }
  final mode =
      {'sim': 'simulator', 'slave': 'simulator'}[s['mode']] ??
      s['mode'] ??
      'master';
  var device = map(extra['device_config'] ?? s['device_config']);
  final sim = map(s['sim']);
  if (device.isEmpty && mode == 'simulator') {
    final server = map(sim['server']);
    device = {
      'listen': flutterState({
        'connection': {
          ...server,
          'tcp_host': server['host'] ?? '127.0.0.1',
          'tcp_port': server['port'] ?? 1502,
        },
      })['connection'],
      'tick_ms': sim['tick_ms'] ?? 1000,
      'units_text': server['unit'] == null || server['unit'] == 'any'
          ? ''
          : '${server['unit']}',
    };
  }
  if (device.isEmpty && mode == 'gateway') {
    final g = map(s['gateway']);
    device = {
      for (final k in ['listen', 'target'])
        k: flutterState({'connection': map(g[k])})['connection'],
      'units_text': g['units'] ?? '',
    };
  }
  if (device.isEmpty && mode == 'sniffer') {
    device = {
      'listen': {'transport': 'rtu', ...map(map(s['sniffer'])['params'])},
    };
  }
  List<Json> normalize(dynamic rows) => [
    for (final raw in rows as List? ?? [])
      {
        'name': '',
        'kind': 'holding_registers',
        'address': 0,
        'count': 1,
        'scale': 1,
        'offset': 0,
        'unit': '',
        ...map(raw),
        // Convert legacy `dec` rows at the catalog boundary.  Session restore
        // remains tolerant of the alias for hand-authored/old state files.
        'format': canonicalFormat(raw['format']),
        'order': raw['order'] ?? options['order'] ?? 'ABCD',
        for (final k in ['unit_id', 'poll_ms'])
          k: raw[k] == null || raw[k] == '' ? null : int.parse('${raw[k]}'),
      },
  ];
  final sniffed = <String, dynamic>{};
  for (final entry in map(s['sniffer'])['units'] as List? ?? []) {
    final recovered = <String, dynamic>{};
    for (final raw in entry['rows'] as List? ?? []) {
      final values = raw['value'] as List? ?? [];
      for (var i = 0; i < values.length; i++) {
        final a = (raw['address'] as int) + i;
        recovered['${raw['kind']}/$a'] = {
          ...map(raw),
          'address': a,
          'value': values[i],
          'count': 1,
        };
      }
    }
    sniffed['${entry['unit']}'] = recovered;
  }
  String column(dynamic k) =>
      {'type': 'kind', 'poll_enabled': 'poll'}[k] ?? '$k';
  return {
    ...s,
    ...extra,
    'connection': c,
    'mode': mode,
    'device_config': device,
    'unit': extra['unit'] ?? s['unit'] ?? map(s['connection'])['unit'] ?? 1,
    'registers': normalize(s['registers']),
    'sim_rows': normalize(extra['sim_rows'] ?? s['sim_rows'] ?? sim['rows']),
    'expressions': [
      for (final e in s['expressions'] as List? ?? [])
        if (e is Map) {...map(e), 'text': e['text'] ?? e['expr'] ?? ''},
    ],
    // Grouped reads are always enabled.  Keep the field in converted state so
    // older workspace/template consumers continue to recognize it; legacy
    // `false` values are intentionally ignored.
    'map_grouped': true,
    'sniffed': extra['sniffed'] ?? s['sniffed'] ?? sniffed,
    'draft': {
      'transport': c['transport'],
      'host': '${c['host'] ?? '127.0.0.1'}',
      'port': c['transport'] == 'rtu' ? '502' : '${c['port'] ?? 502}',
      'serial': c['transport'] == 'rtu' ? '${c['port'] ?? ''}' : '',
      'baud': '${c['baudrate'] ?? 9600}',
      'parity': c['parity'] ?? 'N',
      'bits': c['bytesize'] ?? 8,
      'stop': c['stopbits'] ?? 1,
      'timeout': '${c['timeout'] ?? 3}',
      'map_table': {
        // Missing legacy preferences must use the current table defaults.
        // An explicitly saved empty hidden list still means "show all".
        if (options['column_order'] is List)
          'order': [for (final k in options['column_order']) column(k)],
        if (options['hidden_columns'] is List)
          'hidden': [for (final k in options['hidden_columns']) column(k)],
      },
      ...map(s['draft']),
      ...map(extra['draft']),
    },
  };
}
