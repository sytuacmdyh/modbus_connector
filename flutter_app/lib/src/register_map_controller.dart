import 'translations.dart';

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'session_controller.dart';

class RegisterMapController extends ChangeNotifier {
  RegisterMapController(this.session, {DateTime Function()? clock})
    : clock = clock ?? DateTime.now;
  final DateTime Function() clock;
  final SessionController session;
  bool reading = false;
  bool polling = false;
  bool _disposed = false;
  int _generation = 0;
  Timer? _timer;
  List<Map<String, dynamic>> get rows => session.registers;
  List<Map<String, dynamic>> get results => session.registerResults;
  final Map<Map<String, dynamic>, DateTime> _lastRead = {};
  int _interval = 500;

  /// Qt-compatible quick actions change the first raw word, independent of scale.
  Future<void> quickValue(int index, String action) async {
    if (reading ||
        session.busy ||
        session.toolActive ||
        !session.connected ||
        index < 0 ||
        index >= rows.length) {
      return;
    }
    final row = rows[index];
    if (!['coils', 'holding_registers'].contains(row['kind'])) return;
    final raw = index < results.length ? results[index]['values'] : null;
    if (!['zero', 'one'].contains(action) && (raw is! List || raw.isEmpty)) {
      return;
    }
    final first = raw is List && raw.isNotEmpty ? raw.first : 0;
    final current = first is bool ? (first ? 1 : 0) : (first as num).toInt();
    final value = switch (action) {
      'zero' => 0,
      'one' => 1,
      'increment' => current + 1,
      'decrement' => current - 1,
      'toggle' => current == 0 ? 1 : 0,
      _ => null,
    };
    if (value == null) return;
    stop();
    final clamped = value.clamp(0, row['kind'] == 'coils' ? 1 : 65535);
    final result = await session.command({
      'command': 'write',
      'unit': row['unit_id'] ?? session.unit,
      'kind': row['kind'],
      'address': row['address'],
      'values': [row['kind'] == 'coils' ? clamped != 0 : clamped],
    });
    if (result != null && !_disposed) await read(onlyIndices: {index});
  }

  Future<void> read({bool dueOnly = false, Set<int>? onlyIndices}) async {
    if (reading ||
        session.busy ||
        session.toolActive ||
        !session.connected ||
        rows.isEmpty) {
      return;
    }
    final now = clock();
    final indices = [
      for (var i = 0; i < rows.length; i++)
        if ((onlyIndices == null
                ? rows[i]['poll_enabled'] != false
                : onlyIndices.contains(i)) &&
            (!dueOnly ||
                !_lastRead.containsKey(rows[i]) ||
                now.difference(_lastRead[rows[i]]!).inMilliseconds >=
                    (rows[i]['poll_ms'] as int? ?? _interval)))
          i,
    ];
    if (indices.isEmpty) return;
    reading = true;
    final generation = _generation;
    session.beginTool();
    notifyListeners();
    bool accept() => !_disposed && generation == _generation;
    try {
      final next = List<Map<String, dynamic>>.generate(
        rows.length,
        (i) => i < results.length
            ? results[i]
            : {'values': null, 'display': '—', 'numeric': null, 'alarm': null},
      );
      List<List<int>> groups = List.generate(indices.length, (i) => [i]);
      if (session.mapGrouped) {
        final plan = await session.command({
          'command': 'plan_reads',
          'rows': indices.map((i) => rows[i]).toList(),
          'unit': session.unit,
        }, accept: accept);
        if (!accept()) return;
        if (plan == null) {
          stop();
          return;
        }
        groups = (plan['groups'] as List)
            .map((g) => (g as List).cast<int>())
            .toList();
      }
      for (final group in groups) {
        final reply = await session.command({
          'command': 'read_rows',
          'unit': session.unit,
          'grouped': session.mapGrouped,
          'rows': group.map((i) => rows[indices[i]]).toList(),
        }, accept: accept);
        if (!accept()) return;
        if (reply == null) {
          stop();
          return;
        }
        final values = (reply['rows'] as List).cast<Map<String, dynamic>>();
        for (var n = 0; n < group.length; n++) {
          final index = indices[group[n]];
          next[index] = values[n];
          _lastRead[rows[index]] = now;
        }
      }
      results
        ..clear()
        ..addAll(next);
      await session.evaluateExpressions(accept: accept);
    } finally {
      reading = false;
      session.endTool();
      if (!_disposed) notifyListeners();
    }
  }

  void start(int interval) {
    if (polling || !session.connected) return;
    _interval = interval;
    _lastRead.clear();
    polling = true;
    _timer = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => unawaited(read(dueOnly: true)),
    );
    unawaited(read());
    notifyListeners();
  }

  void stop() {
    polling = false;
    _timer?.cancel();
    ++_generation;
    if (!_disposed) notifyListeners();
  }

  void changed() {
    stop();
    results.clear();
    _lastRead.clear();
    notifyListeners();
  }

  String _rowKey(Map<String, dynamic> row) => jsonEncode([
    row['unit_id'] ?? session.unit,
    row['kind'],
    row['address'],
    row['count'],
    row['name'],
  ]);
  void capture(String name) {
    session.snapshots[name] = List.generate(
      rows.length,
      (i) => {
        'key': _rowKey(rows[i]),
        'name': '${rows[i]['name']} @${rows[i]['address']}',
        'values': i < results.length ? results[i]['values'] : null,
      },
    );
    notifyListeners();
  }

  List<String> diff(String name) {
    final before = {
      for (final e in session.snapshots[name] ?? [])
        if (e is Map) e['key']: e,
    };
    final changes = <String>[];
    for (var i = 0; i < rows.length; i++) {
      final old = before.remove(_rowKey(rows[i]));
      final after = i < results.length ? results[i]['values'] : null;
      if (old == null) {
        changes.add(
          '${rows[i]['name']} @${rows[i]['address']}: (${tr('added')}) $after',
        );
      } else if (jsonEncode(old['values']) != jsonEncode(after)) {
        changes.add('${old['name']}: ${old['values']} → $after');
      }
    }
    changes.addAll(
      before.values.map(
        (e) => '${e['name']}: (${tr('removed')}) ${e['values']}',
      ),
    );
    return changes;
  }

  @override
  void dispose() {
    _disposed = true;
    stop();
    super.dispose();
  }
}
