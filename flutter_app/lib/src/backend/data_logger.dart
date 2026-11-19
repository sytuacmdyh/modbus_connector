import 'dart:convert';

import 'csv.dart';
import 'datastore.dart';
import 'registers.dart';

export 'csv.dart';

abstract class LogSink {
  Future<int> length();
  Future<void> writeString(String text);
  Future<void> flush();
  Future<void> close();
}

abstract class LogStorage {
  Future<String?> existing(String path);
  Future<LogSink> open(String path, {required bool append});
}

class DataLogger {
  DataLogger(this.storage);
  final LogStorage storage;
  LogSink? sink;
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
              '${r['name'] == '' ? r['kind'] : r['name']}@${r['unit_id']}_${r['address']}'
              '${r['unit'] == '' ? '' : ' (${r['unit']})'}',
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
      final path = d['path'] as String;
      final append = d['append'] ?? true;
      if (append is! bool) {
        throw const FormatException('append must be boolean');
      }
      final existing = append ? await storage.existing(path) : null;
      if (fmt == 'csv' && existing != null && existing.isNotEmpty) {
        final records = csvCodec.decode(existing.replaceFirst('\ufeff', ''));
        if (records.isNotEmpty &&
            jsonEncode(records[0]) != jsonEncode(columns)) {
          throw const FormatException(
            'CSV columns differ; choose a new file or disable append',
          );
        }
      }
      await close();
      sink = await storage.open(path, append: append);
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
            displayValue(
              render(
                format == 'csv' ? {...rows[i], 'unit': ''} : rows[i],
                raw[i],
              ),
            ),
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
          final lines = <String>[];
          for (var i = 0; i < displays.length; i++) {
            final r = i < rows.length
                ? rows[i]
                : {
                    'name': expressions[i - rows.length]['name'],
                    'address': i - rows.length,
                    'kind': 'expression',
                  };
            lines.add(
              '${jsonEncode({for (final f in fields) f: f == 'timestamp' ? stamp : r[f], 'value': displays[i]})}\n',
            );
          }
          // Commit a sample atomically for bounded browser storage.
          await sink!.writeString(lines.join());
          written += lines.length;
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
