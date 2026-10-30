import 'dart:convert';
import 'dart:io';

import 'package:csv/csv.dart';

import 'registers.dart';
import 'devices.dart';

final csvCodec = Csv(lineDelimiter: '\n', autoDetect: false);
const csvColumns = [
  'name',
  'kind',
  'address',
  'count',
  'unit_id',
  'poll_ms',
  'format',
  'scale',
  'offset',
  'unit',
  'order',
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
  'interval': 'poll_ms',
  'poll': 'poll_ms',
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
      r['count'] = int.tryParse(r['count'] ?? '') ?? 1;
      r['format'] = formats.contains(r['format']) ? r['format'] : 'dec';
      r['kind'] = kinds.contains(r['kind']) ? r['kind'] : 'holding_registers';
      r['order'] = orders.contains(r['order']) ? r['order'] : null;
      r['scale'] = num.tryParse(r['scale'] ?? '') ?? 1;
      r['offset'] = num.tryParse(r['offset'] ?? '') ?? 0;
      for (final k in ['unit_id', 'poll_ms']) {
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
                      ? render(
                          row(raw),
                          raw['values'] ?? [raw['value']],
                        )['display']
                      : '')
                : (row(raw)[c] ?? ''),
        ],
    ]),
  };
}

class NativeLogger {
  RandomAccessFile? sink;
  List<Json> rows = [], expressions = [];
  List<String> fields = [];
  String format = 'csv';
  int written = 0, interval = 1000;
  int last = -86400000;
  final clock = Stopwatch()..start();
  Future<void> close() async {
    final f = sink;
    sink = null;
    await f?.close();
  }

  Future<void> write(String text) async {
    await sink!.writeString(text);
    written++;
  }

  Future<Json> dispatch(Json d) async {
    final cmd = d['command'];
    List<dynamic>? results;
    if (cmd == 'logger_start') {
      final descriptors = (d['rows'] as List).map((v) => row(v)).toList(),
          expr = (d['expressions'] as List? ?? [])
              .map((v) => Map<String, dynamic>.from(v))
              .toList();
      if (descriptors.length + expr.length < 1 ||
          descriptors.length + expr.length > 512) {
        throw const FormatException('Select 1..512 rows to log');
      }
      final fmt = d['format'] ?? 'csv';
      if (!['csv', 'jsonl'].contains(fmt) ||
          d['path'] is! String ||
          (d['path'] as String).trim().isEmpty) {
        throw const FormatException('Choose a path and csv/jsonl format');
      }
      final ms = bounded(
        d['interval_ms'] ?? 1000,
        'interval_ms',
        100,
        86400000,
      );
      final columns = [
        'timestamp',
        ...descriptors.map(
          (r) =>
              '${r['name'] == '' ? r['kind'] : r['name']}@${r['address']}/u${r['unit_id']}',
        ),
        ...expr.map((e) => 'fx ${e['name']}'),
      ];
      final selectedFields =
          (d['fields'] as List? ?? ['timestamp', 'name', 'address', 'kind'])
              .cast<String>();
      if (selectedFields.any(
        (f) => !['timestamp', 'name', 'address', 'kind'].contains(f),
      )) {
        throw const FormatException('Invalid log fields');
      }
      final f = File(d['path']);
      final append = d['append'] ?? true;
      if (append is! bool) {
        throw const FormatException('append must be boolean');
      }
      final exists = await f.exists();
      if (fmt == 'csv' && append && exists && await f.length() > 0) {
        final records = csvCodec.decode(
          (await f.readAsString()).replaceFirst('\ufeff', ''),
        );
        if (records.isNotEmpty &&
            jsonEncode(records[0]) != jsonEncode(columns)) {
          throw const FormatException(
            'CSV columns differ; choose a new file or disable append',
          );
        }
      }
      await close();
      sink = await f.open(mode: append ? FileMode.append : FileMode.write);
      rows = descriptors;
      expressions = expr;
      format = fmt;
      interval = ms;
      last = -86400000;
      written = 0;
      fields = selectedFields;
      if (fmt == 'csv' && await sink!.length() == 0) {
        await sink!.writeString('\ufeff${csvCodec.encode([columns])}\n');
      }
    } else if (cmd == 'logger_stop') {
      await close();
    } else if (cmd == 'logger_sample') {
      if (sink == null) throw const FormatException('Logger is not running');
      final raw = d['values'] as List;
      if (raw.length != rows.length) {
        throw const FormatException('Sample does not match logger columns');
      }
      for (var i = 0; i < rows.length; i++) {
        validateRaw(rows[i], raw[i]);
      }
      results = evaluateExpressions({
        'expressions': expressions,
        'values': d['expression_values'] ?? {},
      })['rows'];
      if (clock.elapsedMilliseconds - last >= interval) {
        final stamp = DateTime.now().toUtc().toIso8601String();
        final displays = [
          for (var i = 0; i < rows.length; i++)
            render(rows[i], raw[i])['display'],
          for (final e in results!) e['display'],
        ];
        if (format == 'csv') {
          // The encoder separates rows but does not terminate the final row.
          await write(
            '${csvCodec.encode([
              [stamp, ...displays],
            ])}\n',
          );
        } else {
          for (var i = 0; i < displays.length; i++) {
            final r = i < rows.length
                ? rows[i]
                : {
                    'name': expressions[i - rows.length]['name'],
                    'address': i - rows.length,
                    'kind': 'expression',
                  };
            await write(
              '${jsonEncode({for (final f in fields) f: f == 'timestamp' ? stamp : r[f], 'value': displays[i]})}\n',
            );
          }
        }
        await sink!.flush();
        last = clock.elapsedMilliseconds;
      }
    } else if (cmd != 'logger_status') {
      throw const FormatException('Unknown logger command');
    }
    return {
      'active': sink != null,
      'rows_written': written,
      'expressions': ?results,
    };
  }
}
