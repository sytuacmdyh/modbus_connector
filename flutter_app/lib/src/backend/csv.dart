import 'package:csv/csv.dart';

import 'registers.dart';

final csvCodec = Csv(lineDelimiter: '\n', autoDetect: false);
const csvColumns = [
  'name',
  'kind',
  'address',
  'count',
  'unit_id',
  'format',
  'scale',
  'offset',
  'unit',
  'order',
  'writable',
];
const aliases = {
  'type': 'kind',
  'addr': 'address',
  'start': 'address',
  'quantity': 'count',
  'length': 'count',
  'fmt': 'format',
  'byte_order': 'order',
  'byteorder': 'order',
  'slave': 'unit_id',
  'slave_id': 'unit_id',
  'unitid': 'unit_id',
};
Json csvCommand(Json d) {
  if (d['command'] == 'csv_parse') {
    final records = csvCodec.decode(
      (d['text'] as String).replaceFirst('\ufeff', ''),
    );
    final header = records.isEmpty
        ? <String>[]
        : records.first.map((v) => '$v').toList();
    final guessed = {
      for (final h in header)
        if (csvColumns.contains(h.trim().toLowerCase()) ||
            aliases.containsKey(h.trim().toLowerCase()))
          h: aliases[h.trim().toLowerCase()] ?? h.trim().toLowerCase(),
    };
    if (d['preview'] == true) return {'header': header, 'mapping': guessed};
    final mapping = Map<String, dynamic>.from(d['mapping'] as Map? ?? guessed);
    if (!['name', 'kind', 'address'].every(mapping.containsValue)) {
      throw const FormatException('Map name, kind and address columns');
    }
    final rows = <Json>[];
    for (final record in records.skip(1)) {
      final r = <String, dynamic>{
        for (var i = 0; i < header.length && i < record.length; i++)
          if (mapping.containsKey(header[i]))
            mapping[header[i]]: '${record[i]}'.trim(),
      };
      final a = int.tryParse(r['address'] ?? '');
      if (a == null) continue;
      r['address'] = a;
      final writable = r['writable'];
      if (writable == null || writable == '') {
        r.remove('writable');
      } else if (writable.toLowerCase() == 'true' ||
          writable.toLowerCase() == 'false') {
        r['writable'] = writable.toLowerCase() == 'true';
      } else {
        throw const FormatException(
          'CSV writable must be true, false or empty',
        );
      }
      r['count'] = int.tryParse(r['count'] ?? '') ?? 1;
      r['format'] = canonicalFormat(r['format']);
      if (!formats.contains(r['format'])) r['format'] = 'u16';
      r['kind'] = kinds.contains(r['kind']) ? r['kind'] : 'holding_registers';
      r['order'] = orders.contains(r['order']) ? r['order'] : null;
      r['scale'] = num.tryParse(r['scale'] ?? '') ?? 1;
      r['offset'] = num.tryParse(r['offset'] ?? '') ?? 0;
      for (final k in ['unit_id']) {
        final value = int.tryParse(r[k] ?? '');
        final low = k == 'unit_id' ? 1 : 100,
            high = k == 'unit_id' ? 247 : 600000;
        r[k] = value != null && value >= low && value <= high ? value : null;
      }
      rows.add({
        ...row(r),
        'unit_id': r['unit_id'],
        'order': r['order'],
        'log': true,
        'trend_enabled': true,
        'value_names': <String, String>{},
        'bitmask': false,
        'alarms': <dynamic>[],
      });
    }
    if (rows.isEmpty || rows.length > 4096) {
      throw const FormatException('CSV requires 1..4096 rows');
    }
    return {'rows': rows};
  }
  final rows = d['rows'] as List;
  if (rows.length > 4096) throw const FormatException('At most 4096 rows');
  final cols =
      (d['columns'] as List?) ??
      [...csvColumns, if (d['include_values'] == true) 'value'];
  if (cols.isEmpty || cols.any((c) => ![...csvColumns, 'value'].contains(c))) {
    throw const FormatException('Unknown CSV columns');
  }
  return {
    'text': csvCodec.encode([
      cols,
      for (final raw in rows)
        [
          for (final c in cols)
            c == 'value'
                ? (raw['values'] != null || raw['value'] != null
                      ? displayValue(
                          render(row(raw), raw['values'] ?? [raw['value']]),
                        )
                      : '')
                : (row(raw)[c] ?? ''),
        ],
    ]),
  };
}
