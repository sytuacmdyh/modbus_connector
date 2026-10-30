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

  /// Trim each occupied hundred-address page to the map's covered addresses.
  /// Build on demand when the preset menu opens, independently of view filters.
  List<({int pageStart, int start, int count})> get addressPresets {
    final pages = <int, ({int start, int end})>{};
    for (final row in rows) {
      final address = row['address'];
      final count = row['count'] ?? 1;
      if (address is! int ||
          count is! int ||
          address < 0 ||
          count < 1 ||
          address + count > 65536) {
        continue;
      }
      final end = address + count - 1;
      for (var page = address ~/ 100 * 100; page <= end; page += 100) {
        final startInPage = address.clamp(page, page + 99);
        final endInPage = end.clamp(page, page + 99);
        final previous = pages[page];
        pages[page] = (
          start: previous == null || startInPage < previous.start
              ? startInPage
              : previous.start,
          end: previous == null || endInPage > previous.end
              ? endInPage
              : previous.end,
        );
      }
    }
    return [
      for (final page in pages.keys.toList()..sort())
        (
          pageStart: page,
          start: pages[page]!.start,
          count: pages[page]!.end - pages[page]!.start + 1,
        ),
    ];
  }

  final Map<Map<String, dynamic>, DateTime> _lastRead = {};
  int _interval = 500;

  final Map<Map<String, dynamic>, List<dynamic>> _lastValues = {};
  final Map<Map<String, dynamic>, Timer> _valueHighlights = {};

  bool get editingLocked =>
      polling || reading || _pendingWrites > 0 || session.busy;
  bool valueChanged(Map<String, dynamic> row) =>
      _valueHighlights.containsKey(row);

  void _observeValueChanges(List<Map<String, dynamic>> next) {
    for (var i = 0; i < rows.length; i++) {
      final values = next[i]['values'];
      if (values is! List) continue;
      final row = rows[i];
      final previous = _lastValues[row];
      _lastValues[row] = List<dynamic>.of(values);
      if (previous == null || listEquals(previous, values)) continue;
      _valueHighlights.remove(row)?.cancel();
      _valueHighlights[row] = Timer(const Duration(seconds: 3), () {
        _valueHighlights.remove(row);
        if (!_disposed) notifyListeners();
      });
    }
  }

  void _clearValueChanges() {
    for (final timer in _valueHighlights.values) {
      timer.cancel();
    }
    _valueHighlights.clear();
    _lastValues.clear();
  }

  Completer<void>? _readDone;
  Future<void>? _writeTail;
  int _pendingWrites = 0;

  bool get canWrite =>
      session.connected &&
      !session.disconnecting &&
      (polling || session.canRead);

  /// Writes wait for the active read request; pending writes take priority over
  /// the next read group. The native service still receives one transaction at a time.
  Future<void> writeRow(
    int index, {
    List<dynamic>? values,
    String? text,
    String? action,
  }) async {
    if (!canWrite || index < 0 || index >= rows.length) return;
    final row = rows[index];
    if (!['coils', 'holding_registers'].contains(row['kind'])) return;
    final generation = _generation;
    final previous = _writeTail;
    final done = Completer<void>();
    _writeTail = done.future;
    ++_pendingWrites;
    bool accept() =>
        !_disposed &&
        generation == _generation &&
        session.connected &&
        !session.disconnecting &&
        rows.contains(row);
    bool written = false;
    try {
      if (previous != null) await previous;
      await _readDone?.future;
      await session.waitForIdle();
      if (!accept() || session.toolActive) return;
      if (text != null) {
        final encoded = await session.command({
          'command': 'encode_values',
          'row': row,
          'text': text,
        }, accept: accept);
        values = encoded?['values'] as List?;
      }
      if (!accept()) return;
      if (action != null) {
        final i = rows.indexOf(row);
        final raw = i < results.length ? results[i]['values'] : null;
        if (!['zero', 'one'].contains(action) &&
            (raw is! List || raw.isEmpty)) {
          return;
        }
        final first = raw is List && raw.isNotEmpty ? raw.first : 0;
        final current = first is bool
            ? (first ? 1 : 0)
            : (first as num).toInt();
        final value = switch (action) {
          'zero' => 0,
          'one' => 1,
          'increment' => current + 1,
          'decrement' => current - 1,
          'toggle' => current == 0 ? 1 : 0,
          _ => null,
        };
        if (value == null) return;
        final clamped = value.clamp(0, row['kind'] == 'coils' ? 1 : 65535);
        values = [row['kind'] == 'coils' ? clamped != 0 : clamped];
      }
      if (values == null) return;
      final reply = await session.command({
        'command': 'write',
        'unit': row['unit_id'] ?? session.unit,
        'kind': row['kind'],
        'address': row['address'],
        'values': values,
      }, accept: accept);
      written = reply != null;
    } finally {
      --_pendingWrites;
      done.complete();
      if (identical(_writeTail, done.future)) _writeTail = null;
    }
    if (written && accept() && _pendingWrites == 0) {
      await read(onlyIndices: {rows.indexOf(row)});
    }
  }

  /// Qt-compatible quick actions change the first raw word, independent of scale.
  Future<void> quickValue(int index, String action) =>
      writeRow(index, action: action);

  Future<void> read({bool dueOnly = false, Set<int>? onlyIndices}) async {
    if (reading ||
        _pendingWrites > 0 ||
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
    final done = _readDone = Completer<void>();
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
      // Publish the cycle's start/end, not every serialized bus transaction.
      // Independent maps can contain thousands of requests per cycle.
      List<List<int>> groups = List.generate(indices.length, (i) => [i]);
      if (session.mapGrouped) {
        final plan = await session.command(
          {
            'command': 'plan_reads',
            'rows': indices.map((i) => rows[i]).toList(),
            'unit': session.unit,
          },
          accept: accept,
          notify: false,
        );
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
        if (_pendingWrites > 0) break;
        final reply = await session.command(
          {
            'command': 'read_rows',
            'unit': session.unit,
            'grouped': session.mapGrouped,
            'rows': group.map((i) => rows[indices[i]]).toList(),
          },
          accept: accept,
          notify: false,
        );
        if (!accept()) return;
        if (reply == null) {
          if (!session.connected) return;
          for (final member in group) {
            final index = indices[member];
            next[index] = {
              'values': null,
              'display': '—',
              'numeric': null,
              'alarm': null,
            };
            _lastRead[rows[index]] = now;
          }
          continue;
        }
        final values = (reply['rows'] as List).cast<Map<String, dynamic>>();
        for (var n = 0; n < group.length; n++) {
          final index = indices[group[n]];
          next[index] = values[n];
          _lastRead[rows[index]] = now;
        }
      }
      _observeValueChanges(next);
      results
        ..clear()
        ..addAll(next);
      await session.evaluateExpressions(accept: accept, notify: false);
    } finally {
      reading = false;
      session.endTool();
      _readDone = null;
      done.complete();
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
    _clearValueChanges();
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
    _clearValueChanges();
    stop();
    super.dispose();
  }
}
