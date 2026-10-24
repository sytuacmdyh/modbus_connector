import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'bridge_client.dart';

const areas = <String, String>{
  'holding_registers': 'Holding registers · 03',
  'input_registers': 'Input registers · 04',
  'coils': 'Coils · 01',
  'discrete_inputs': 'Discrete inputs · 02',
};

class ReadQuery {
  const ReadQuery({
    this.kind = 'holding_registers',
    this.address = 0,
    this.count = 50,
  });
  final String kind;
  final int address;
  final int count;
  bool get isBit => kind == 'coils' || kind == 'discrete_inputs';
  bool get writable => kind == 'holding_registers' || kind == 'coils';
  Map<String, dynamic> toJson() => {
    'kind': kind,
    'address': address,
    'count': count,
  };
  void validate() {
    if (!areas.containsKey(kind) ||
        address < 0 ||
        count < 1 ||
        count > (isBit ? 2000 : 125) ||
        address + count > 65536) {
      throw const BridgeException(
        'Use a valid 0-based address range (125 registers or 2000 bits max).',
      );
    }
  }
}

class Sample {
  const Sample(this.time, this.value);
  final DateTime time;
  final double value;
}

class LogEntry {
  LogEntry(this.message, {this.isError = false}) : time = DateTime.now();
  final DateTime time;
  final String message;
  final bool isError;
}

class SessionController extends ChangeNotifier {
  SessionController(this.bridge) {
    bridge.onDiagnostic = (line) {
      if (_disposed) return;
      _log(line, isError: true);
      notifyListeners();
    };
    bridge.onExit = () {
      if (_disposed || _closing) return;
      connected = false;
      _cancelLogger();
      description = 'Disconnected';
      stopPolling();
      _setError('Python bridge stopped. Reconnect to recover.');
      notifyListeners();
    };
  }
  final BridgeTransport bridge;
  Map<String, dynamic> connectionConfig = {};
  final Map<String, dynamic> draft = {};
  final List<Map<String, dynamic>> registers = [];
  final List<Map<String, dynamic>> registerResults = [];
  final Map<String, List<Object?>> snapshots = {};
  String mode = 'master';
  bool deviceRunning = false;
  final Map<String, dynamic> deviceConfig = {};
  final List<Map<String, dynamic>> simRows = [];
  final Map<int, Map<String, Map<String, dynamic>>> sniffed = {};
  bool connected = false;
  bool busy = false;
  bool disconnecting = false;
  bool polling = false;
  bool toolActive = false;
  bool logging = false;
  int loggedSamples = 0;
  Timer? _loggerTimer;
  int _loggerGeneration = 0;
  final Map<String, Object?> _activeAlarms = {};
  Map<String, dynamic> loggingSettings = {};
  String description = 'Disconnected';
  String? error;
  int unit = 1;
  double timeoutSeconds = 3;
  int intervalMs = 500;
  ReadQuery query = const ReadQuery();
  List<Object> values = [];
  int selected = 0;
  double? elapsedMs;
  final Queue<Sample> samples = Queue();
  final Map<String, Queue<Sample>> histories = {};
  final Map<String, String> historyLabels = {};
  void recordPoint(String key, String label, double value) {
    if (!value.isFinite) return;
    if (!histories.containsKey(key) && histories.length >= 2048) {
      historyLabels.remove(histories.keys.first);
      histories.remove(histories.keys.first);
    }
    final points = histories.putIfAbsent(key, Queue<Sample>.new);
    final now = DateTime.now();
    if (points.isNotEmpty &&
        now.difference(points.last.time).inMilliseconds < 100) {
      return;
    }
    points.add(Sample(now, value));
    historyLabels[key] = label;
    while (points.length > 1000) {
      points.removeFirst();
    }
  }

  void clearHistory() {
    histories.clear();
    historyLabels.clear();
    samples.clear();
    notifyListeners();
  }

  final Queue<LogEntry> logs = Queue();
  Timer? _timer;
  Completer<void>? _operation;
  int _epoch = 0;
  int _readGeneration = 0;
  bool _disposed = false;
  bool _closing = false;
  Future<void>? _shutdown;
  DateTime? _lastSample;

  Map<String, dynamic> state() => {
    'mode': mode,
    'connection': connectionConfig,
    'draft': draft,
    'unit': unit,
    'query': query.toJson(),
    'interval_ms': intervalMs,
    'registers': registers,
    'sim_rows': simRows,
    'device_config': deviceConfig,
    'logging': loggingSettings,
    'scanner': scannerState,
    'custom_template_id': customTemplateId,
    'sniffed': {for (final e in sniffed.entries) '${e.key}': e.value},
  };
  final Map<String, dynamic> scannerState = {};
  String? customTemplateId;
  void restore(Map<String, dynamic> data) {
    if (connected || busy || deviceRunning) {
      throw StateError('Restore requires a disconnected session');
    }
    mode = ['master', 'simulator', 'sniffer', 'gateway'].contains(data['mode'])
        ? data['mode'] as String
        : 'master';
    if (data['connection'] is Map) {
      connectionConfig = Map<String, dynamic>.from(data['connection'] as Map);
    }
    if (data['draft'] is Map) {
      draft.addAll(Map<String, dynamic>.from(data['draft'] as Map));
    }
    unit =
        (data['unit'] is int &&
            (data['unit'] as int) >= 1 &&
            (data['unit'] as int) <= 247)
        ? data['unit'] as int
        : 1;
    final q = data['query'];
    if (q is Map) {
      try {
        final restored = ReadQuery(
          kind: q['kind'] as String,
          address: q['address'] as int,
          count: q['count'] as int,
        );
        restored.validate();
        query = restored;
      } catch (_) {
        query = const ReadQuery();
      }
    }
    if (data['interval_ms'] is int) {
      intervalMs = (data['interval_ms'] as int).clamp(100, 60000);
    }
    void rowsInto(Object? raw, List<Map<String, dynamic>> target) {
      if (raw is! List) return;
      for (final r in raw.take(512)) {
        if (r is Map<String, dynamic> &&
            areas.containsKey(r['kind']) &&
            r['address'] is int &&
            r['count'] is int &&
            (r['address'] as int) >= 0 &&
            (r['count'] as int) > 0 &&
            (r['address'] as int) + (r['count'] as int) <= 65536 &&
            [
              'dec',
              'hex',
              's16',
              'u32',
              's32',
              'f32',
              'u64',
              's64',
              'f64',
              'ascii',
              'ascii1',
            ].contains(r['format'] ?? 'dec') &&
            ['ABCD', 'CDAB', 'BADC', 'DCBA'].contains(r['order'] ?? 'ABCD')) {
          target.add(Map.of(r));
        }
      }
    }

    rowsInto(data['registers'], registers);
    rowsInto(data['sim_rows'], simRows);
    for (final entry in {
      'device_config': deviceConfig,
      'logging': loggingSettings,
      'scanner': scannerState,
    }.entries) {
      if (data[entry.key] is Map) {
        entry.value.addAll(Map<String, dynamic>.from(data[entry.key] as Map));
      }
    }
    if (data['custom_template_id'] is String) {
      customTemplateId = data['custom_template_id'] as String;
    }
    if (data['sniffed'] is Map) {
      for (final e in (data['sniffed'] as Map).entries) {
        final id = int.tryParse('${e.key}');
        if (id != null && id >= 1 && id <= 247 && e.value is Map) {
          sniffed[id] = {
            for (final cell in (e.value as Map).entries)
              if (cell.value is Map)
                '${cell.key}': Map<String, dynamic>.from(cell.value as Map),
          };
        }
      }
    }
  }

  bool get canRead => connected && !busy && !disconnecting && !toolActive;
  Duration get deadline =>
      Duration(milliseconds: (timeoutSeconds * 5000).round() + 10000);

  void _log(String message, {bool isError = false}) {
    logs.addFirst(LogEntry(message, isError: isError));
    while (logs.length > 300) {
      logs.removeLast();
    }
  }

  void _setError(Object value) {
    error = value.toString();
    _log(error!, isError: true);
    if (value is BridgeException && value.connected == false) {
      connected = false;
      description = 'Disconnected';
    }
  }

  void clearError() {
    error = null;
    notifyListeners();
  }

  void clearLog() {
    logs.clear();
    notifyListeners();
  }

  Future<void> _run(
    Future<void> Function(int epoch) action, {
    int? readGeneration,
  }) async {
    if (busy || disconnecting || _closing) return;
    busy = true;
    final done = Completer<void>();
    _operation = done;
    final epoch = _epoch;
    notifyListeners();
    try {
      await action(epoch);
    } catch (exception) {
      if (epoch == _epoch &&
          !_closing &&
          (readGeneration == null || readGeneration == _readGeneration)) {
        stopPolling();
        _setError(exception);
      }
    } finally {
      busy = false;
      _operation = null;
      done.complete();
      if (!_disposed) notifyListeners();
    }
  }

  Future<Map<String, dynamic>?> command(Map<String, dynamic> request) async {
    Map<String, dynamic>? result;
    await _run((epoch) async {
      final reply = await bridge.request(request, timeout: deadline);
      if (epoch != _epoch || _closing) return;
      result = reply.result;
      if (request['command'] == 'read_rows') {
        observeAlarms(
          (reply.result['rows'] as List).cast<Map<String, dynamic>>(),
          (request['rows'] as List).cast<Map<String, dynamic>>(),
        );
      }
      if (request['command'] != 'device_status') error = null;
    });
    return result;
  }

  void beginTool() {
    stopPolling();
    toolActive = true;
    notifyListeners();
  }

  void endTool() {
    toolActive = false;
    if (!_disposed) notifyListeners();
  }

  void observeAlarms(
    List<Map<String, dynamic>> results,
    List<Map<String, dynamic>> rows,
  ) {
    for (var i = 0; i < results.length; i++) {
      final row = rows[i];
      final key =
          '${row['unit_id'] ?? unit}/${row['kind']}/${row['address']}/${row['name']}';
      final numeric = results[i]['numeric'];
      if (numeric is num) {
        recordPoint(
          key,
          '${row['name'] ?? row['kind']} @${row['address']}',
          numeric.toDouble(),
        );
      }
      final alarm = results[i]['alarm'] as Map?;
      final signature = alarm?.toString();
      if (_activeAlarms[key] != signature && alarm != null) {
        if (alarm['log'] == true) {
          _log(
            'ALARM ${row['name']} @${row['address']}: ${results[i]['display']}',
            isError: true,
          );
        }
        if (alarm['sound'] == true) {
          unawaited(SystemSound.play(SystemSoundType.alert));
        }
      }
      _activeAlarms[key] = signature;
    }
  }

  Future<void> startLogging(
    Map<String, dynamic> settings,
    List<Map<String, dynamic>> rows,
  ) async {
    if (logging || busy || !connected) return;
    final frozen = rows.map((row) => Map<String, dynamic>.of(row)).toList();
    final result = await command({
      'command': 'logger_start',
      ...settings,
      'rows': frozen,
    });
    if (result == null) return;
    loggingSettings = Map.of(settings);
    logging = true;
    loggedSamples = 0;
    final generation = ++_loggerGeneration;
    Future<void> capture() async {
      if (!logging || busy || disconnecting || toolActive || _closing) return;
      await _run((epoch) async {
        final samples = <List>[];
        for (final row in frozen) {
          final reply = await bridge.request({
            'command': 'read_rows',
            'unit': unit,
            'rows': [row],
          }, timeout: deadline);
          if (generation != _loggerGeneration || epoch != _epoch || _closing) {
            return;
          }
          final results = (reply.result['rows'] as List)
              .cast<Map<String, dynamic>>();
          observeAlarms(results, [row]);
          samples.add(results.single['values'] as List);
        }
        final reply = await bridge.request({
          'command': 'logger_sample',
          'values': samples,
        });
        loggedSamples = reply.result['rows_written'] as int;
      });
      if (error != null) await stopLogging();
    }

    _loggerTimer = Timer.periodic(
      Duration(milliseconds: settings['interval_ms'] as int),
      (_) => unawaited(capture()),
    );
    unawaited(capture());
    notifyListeners();
  }

  void _cancelLogger() {
    _loggerTimer?.cancel();
    logging = false;
    ++_loggerGeneration;
  }

  Future<void> stopLogging() async {
    _cancelLogger();
    notifyListeners();
    await _operation?.future;
    if (!_closing && !disconnecting) await command({'command': 'logger_stop'});
  }

  Future<void> changeMode(String next) async {
    if (next == mode || _closing) return;
    await disconnect();
    deviceRunning = false;
    mode = next;
    notifyListeners();
  }

  Future<void> connect(Map<String, dynamic> config, int unitId) =>
      _run((epoch) async {
        stopPolling();
        error = null;
        values = [];
        elapsedMs = null;
        samples.clear();
        _lastSample = null;
        connectionConfig = Map.of(config);
        timeoutSeconds = (config['timeout'] as num).toDouble();
        _log('Connecting…');
        final reply = await bridge.request({
          'command': 'connect',
          ...config,
        }, timeout: deadline);
        if (epoch != _epoch || _closing) return;
        connected = reply.connected;
        unit = unitId;
        description = reply.result['description'] as String;
        _log('Connected · $description · unit $unit');
      });

  Future<void> disconnect() async {
    if (disconnecting || _closing) return;
    _cancelLogger();
    disconnecting = true;
    connected = false;
    description = 'Disconnecting…';
    ++_epoch;
    stopPolling();
    notifyListeners();
    await _operation?.future;
    try {
      await bridge.request({'command': 'disconnect'}, timeout: deadline);
      error = null;
      _log('Disconnected');
    } catch (exception) {
      _setError(exception);
    } finally {
      description = 'Disconnected';
      disconnecting = false;
      if (!_disposed) notifyListeners();
    }
  }

  void setQuery(ReadQuery next) {
    next.validate();
    if (busy || polling) return;
    query = next;
    values = [];
    elapsedMs = null;
    selected = 0;
    samples.clear();
    _lastSample = null;
    notifyListeners();
  }

  Future<void> read() async {
    if (!canRead) return;
    final generation = _readGeneration;
    await _run((epoch) async {
      final reply = await bridge.request({
        'command': 'read',
        'unit': unit,
        ...query.toJson(),
      }, timeout: deadline);
      if (epoch != _epoch || generation != _readGeneration || _closing) return;
      values = (reply.result['values'] as List).cast<Object>();
      elapsedMs = (reply.result['elapsed_ms'] as num).toDouble();
      error = null;
      _sample();
      for (var i = 0; i < values.length; i++) {
        final raw = values[i];
        recordPoint(
          '$unit/${query.kind}/${query.address + i}',
          '${query.kind} @${query.address + i}',
          raw is bool ? (raw ? 1 : 0) : (raw as num).toDouble(),
        );
      }
      if (!polling) {
        _log(
          'Read ${query.count} ${query.kind} @${query.address} · ${elapsedMs!.toStringAsFixed(1)} ms',
        );
      }
    }, readGeneration: generation);
  }

  Future<void> write(int index, int value) async {
    if (!canRead || !query.writable) return;
    if (index < 0 ||
        index >= query.count ||
        value < 0 ||
        value > (query.isBit ? 1 : 65535)) {
      throw const BridgeException('Value outside the register range');
    }
    final wasPolling = polling;
    stopPolling();
    await _run((epoch) async {
      await bridge.request({
        'command': 'write',
        'unit': unit,
        'kind': query.kind,
        'address': query.address + index,
        'values': [value],
      }, timeout: deadline);
      if (epoch != _epoch || _closing) return;
      error = null;
      _log('Wrote $value → ${query.kind} @${query.address + index}');
    });
    if (connected && !disconnecting && !_closing && error == null) {
      await read();
      if (wasPolling && error == null) startPolling();
    }
  }

  void startPolling() {
    if (!canRead || polling) return;
    polling = true;
    _log('Polling every $intervalMs ms');
    _timer = Timer.periodic(Duration(milliseconds: intervalMs), (_) {
      if (canRead) unawaited(read());
    });
    unawaited(read());
    notifyListeners();
  }

  void stopPolling() {
    _timer?.cancel();
    _timer = null;
    if (polling) _log('Polling stopped');
    polling = false;
    ++_readGeneration;
    if (!_disposed) notifyListeners();
  }

  void select(int index) {
    selected = index;
    samples.clear();
    _lastSample = null;
    _sample();
    notifyListeners();
  }

  void _sample() {
    if (selected >= values.length) return;
    final now = DateTime.now();
    if (_lastSample != null &&
        now.difference(_lastSample!).inMilliseconds < 100) {
      return;
    }
    final raw = values[selected];
    final value = raw is bool ? (raw ? 1.0 : 0.0) : (raw as num).toDouble();
    samples.add(Sample(now, value));
    _lastSample = now;
    while (samples.length > 300) {
      samples.removeFirst();
    }
  }

  Future<List<Map<String, dynamic>>> ports() async {
    if (busy || disconnecting || _closing) return [];
    var result = <Map<String, dynamic>>[];
    await _run((epoch) async {
      final reply = await bridge.request({'command': 'ports'});
      if (epoch != _epoch || _closing) return;
      error = null;
      result = (reply.result['ports'] as List).cast<Map<String, dynamic>>();
    });
    return result;
  }

  Future<void> shutdown() => _shutdown ??= _shutdownOwned();

  Future<void> _shutdownOwned() async {
    _closing = true;
    _cancelLogger();
    ++_epoch;
    stopPolling();
    await _operation?.future;
    await bridge.close();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _cancelLogger();
    bridge.onDiagnostic = null;
    bridge.onExit = null;
    unawaited(shutdown());
    super.dispose();
  }
}
