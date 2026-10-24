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
  Future<void> read({bool dueOnly = false}) async {
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
        if (rows[i]['poll_enabled'] != false &&
            (!dueOnly ||
                !_lastRead.containsKey(rows[i]) ||
                now.difference(_lastRead[rows[i]]!).inMilliseconds >=
                    (rows[i]['poll_ms'] as int? ?? _interval)))
          i,
    ];
    if (indices.isEmpty) return;
    reading = true;
    final generation = _generation;
    session.beginTool(stopQuickPolling: false);
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
      await session.evaluateExpressions();
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
          '${rows[i]['name']} @${rows[i]['address']}: (added) $after',
        );
      } else if (jsonEncode(old['values']) != jsonEncode(after)) {
        changes.add('${old['name']}: ${old['values']} → $after');
      }
    }
    changes.addAll(
      before.values.map((e) => '${e['name']}: (removed) ${e['values']}'),
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
