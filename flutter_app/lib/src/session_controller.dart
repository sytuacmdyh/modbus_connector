import 'dart:convert';

import 'register_map_controller.dart';

import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'bridge_client.dart';
import 'demo.dart';

const areas = <String, String>{
  'holding_registers': 'Holding registers · 03',
  'input_registers': 'Input registers · 04',
  'coils': 'Coils · 01',
  'discrete_inputs': 'Discrete inputs · 02',
};

const maxRegisterRows = 4096;

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
  SessionController(this.bridge, {DateTime Function()? clock}) {
    registerMap = RegisterMapController(this, clock: clock);
    registerMap.addListener(() {
      if (!_disposed) notifyListeners();
    });
    bridge.onTraffic = (frames, statistics) {
      if (_disposed || _closing) return;
      traffic.addAll(frames);
      while (traffic.length > 500) {
        traffic.removeFirst();
      }
      busStatistics = statistics;
    };
    bridge.onDiagnostic = (line) {
      if (_disposed) return;
      _log(line, isError: true);
      notifyListeners();
    };
    bridge.onExit = () {
      if (_disposed || _closing) return;
      connected = false;
      registerMap.stop();
      _cancelLogger();
      description = 'Disconnected';
      _setError('Python bridge stopped. Reconnect to recover.');
      notifyListeners();
    };
  }
  final BridgeTransport bridge;
  final Queue<Map<String, dynamic>> traffic = Queue();
  Map<String, dynamic> busStatistics = {};
  final List<Future<void> Function()> shutdownHooks = [];
  late final RegisterMapController registerMap;
  Map<String, dynamic> connectionConfig = {};
  final Map<String, dynamic> draft = {};
  final List<Map<String, dynamic>> registers = [];
  final List<Map<String, dynamic>> expressions = [];
  List<Map<String, dynamic>> expressionResults = [];
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
  bool toolActive = false;
  bool logging = false;
  bool mapGrouped = false;
  int loggedSamples = 0;
  Timer? _loggerTimer;
  int _loggerGeneration = 0;
  final Map<String, Object?> _activeAlarms = {};
  final Map<String, bool> _alarmLogs = {};
  Map<String, dynamic> loggingSettings = {};
  String description = 'Disconnected';
  String? error;
  int unit = 1;
  double timeoutSeconds = 3;
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
    notifyListeners();
  }

  final Queue<LogEntry> logs = Queue();
  Completer<void>? _operation;
  int _epoch = 0;
  bool _disposed = false;
  bool _closing = false;
  Future<void>? _shutdown;

  Map<String, dynamic> state() => {
    'mode': mode,
    'connection': connectionConfig,
    'draft': draft,
    'unit': unit,
    'registers': registers,
    'expressions': expressions,
    'map_grouped': mapGrouped,
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
      for (final key in ['address', 'count', 'interval']) {
        draft.remove(key);
      }
    }
    unit =
        (data['unit'] is int &&
            (data['unit'] as int) >= 1 &&
            (data['unit'] as int) <= 247)
        ? data['unit'] as int
        : 1;
    void rowsInto(Object? raw, List<Map<String, dynamic>> target) {
      if (raw is! List) return;
      if (raw.length > maxRegisterRows) {
        throw const BridgeException('Register maps support at most 4096 rows.');
      }
      for (final r in raw) {
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

    mapGrouped = data['map_grouped'] == true;
    if (data['expressions'] is List) {
      expressions.addAll(
        (data['expressions'] as List)
            .whereType<Map<String, dynamic>>()
            .where((e) => e['name'] is String && e['text'] is String)
            .take(512),
      );
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
    bool Function()? accept,
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
      if (epoch == _epoch && !_closing && (accept == null || accept())) {
        _setError(exception);
      }
    } finally {
      busy = false;
      _operation = null;
      done.complete();
      if (!_disposed) notifyListeners();
    }
  }

  Future<Map<String, dynamic>?> command(
    Map<String, dynamic> request, {
    bool Function()? accept,
  }) async {
    Map<String, dynamic>? result;
    await _run((epoch) async {
      final reply = await bridge.request(
        request,
        timeout:
            request['command'] == 'diagnostics' &&
                request['action'] == 'counters'
            ? deadline * 10
            : deadline,
      );
      if (epoch != _epoch || _closing || (accept != null && !accept())) return;
      result = reply.result;
      if (request['command'] == 'read_rows') {
        observeAlarms(
          (reply.result['rows'] as List).cast<Map<String, dynamic>>(),
          (request['rows'] as List).cast<Map<String, dynamic>>(),
        );
      }
      if (request['command'] != 'device_status') error = null;
    }, accept: accept);
    return result;
  }

  void beginTool() {
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
      if (numeric is num && row['trend_enabled'] != false) {
        recordPoint(
          key,
          '${row['name'] ?? row['kind']} @${row['address']}',
          numeric.toDouble(),
        );
      }
      final alarm = results[i]['alarm'] as Map?;
      final signature = alarm?.toString();
      if (alarm == null &&
          _activeAlarms[key] != null &&
          _alarmLogs[key] == true) {
        _log('ALARM cleared ${row['name']} @${row['address']}');
      }
      _alarmLogs[key] = alarm?['log'] == true;
      if (_activeAlarms[key] != signature && alarm != null) {
        if (alarm['log'] == true) {
          _log(
            'ALARM ${row['name']} @${row['address']}: ${results[i]['display']}',
            isError: true,
          );
        }
        if (alarm['sound'] == true) {
          unawaited(
            SystemSound.play(SystemSoundType.alert).catchError((Object _) {}),
          );
        }
      }
      _activeAlarms[key] = signature;
    }
  }

  Future<void> startLogging(
    Map<String, dynamic> settings,
    List<Map<String, dynamic>> rows, {
    List<Map<String, dynamic>> expressionRows = const [],
  }) async {
    if (logging || busy || !connected) return;
    final frozen = rows
        .map(
          (row) => <String, dynamic>{...row, 'unit_id': row['unit_id'] ?? unit},
        )
        .toList();
    final frozenExpressions = (jsonDecode(jsonEncode(expressionRows)) as List)
        .cast<Map<String, dynamic>>();
    final dependencies = frozenExpressions.isEmpty
        ? <Map<String, dynamic>>[]
        : registers
              .where((r) => !rows.contains(r))
              .map(
                (r) => <String, dynamic>{...r, 'unit_id': r['unit_id'] ?? unit},
              )
              .toList();
    final result = await command({
      'command': 'logger_start',
      ...settings,
      'rows': frozen,
      'expressions': frozenExpressions,
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
        final expressionValues = <String, num>{};
        final acquisition = [...frozen, ...dependencies];
        for (var index = 0; index < acquisition.length; index++) {
          final row = acquisition[index];
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
          if (index < frozen.length) {
            samples.add(results.single['values'] as List);
          }
          final numeric = results.single['numeric'];
          if (numeric is num) {
            expressionValues[row['name'] as String? ?? ''] = numeric;
          }
        }
        final reply = await bridge.request({
          'command': 'logger_sample',
          'values': samples,
          'expression_values': expressionValues,
        });
        if (generation != _loggerGeneration || epoch != _epoch || _closing) {
          return;
        }
        final expressionResults = (reply.result['expressions'] as List? ?? [])
            .cast<Map<String, dynamic>>();
        if (expressionResults.isNotEmpty) {
          observeAlarms(expressionResults, [
            for (var i = 0; i < frozenExpressions.length; i++)
              {
                'name': 'fx ${frozenExpressions[i]['name']}',
                'kind': 'expression',
                'address': i,
              },
          ]);
        }
        loggedSamples = reply.result['rows_written'] as int;
      }, accept: () => generation == _loggerGeneration);
      if (error != null && !_closing && logging) await stopLogging();
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
    if (!_disposed) notifyListeners();
    await _operation?.future;
    if (!_closing && !disconnecting) await command({'command': 'logger_stop'});
  }

  Future<void> evaluateExpressions({bool Function()? accept}) async {
    if (expressions.isEmpty) return;
    final values = <String, num>{};
    for (var i = 0; i < registers.length && i < registerResults.length; i++) {
      final value = registerResults[i]['numeric'];
      if (value is num) values[registers[i]['name'] as String? ?? ''] = value;
    }
    final reply = await command({
      'command': 'evaluate_expressions',
      'expressions': expressions,
      'map_grouped': mapGrouped,
      'values': values,
    }, accept: accept);
    if (reply != null) {
      expressionResults = (reply['rows'] as List).cast<Map<String, dynamic>>();
      observeAlarms(
        expressionResults,
        List.generate(
          expressions.length,
          (i) => {
            'name': 'fx ${expressions[i]['name']}',
            'address': i,
            'kind': 'expression',
          },
        ),
      );
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> changeMode(String next) async {
    if (next == mode || _closing) return;
    await disconnect();
    if (_closing || _disposed) return;
    deviceRunning = false;
    mode = next;
    notifyListeners();
  }

  Future<void> connect(Map<String, dynamic> config, int unitId) =>
      _run((epoch) async {
        error = null;
        registerMap.stop();
        registerResults.clear();
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
        if (connected && config['transport'] == 'demo' && registers.isEmpty) {
          registers.addAll(demoRegisters());
          registerMap.changed();
        }
        _log('Connected · $description · unit $unit');
      });

  Future<void> disconnect() async {
    if (disconnecting || _closing) return;
    registerMap.stop();
    _cancelLogger();
    disconnecting = true;
    connected = false;
    description = 'Disconnecting…';
    ++_epoch;
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
    registerMap.stop();
    _cancelLogger();
    ++_epoch;
    await _operation?.future;
    await Future.wait(shutdownHooks.toList().map((close) => close()));
    shutdownHooks.clear();
    await bridge.close();
  }

  @override
  void dispose() {
    _disposed = true;
    registerMap.dispose();
    _cancelLogger();
    bridge.onDiagnostic = null;
    bridge.onTraffic = null;
    bridge.onExit = null;
    unawaited(shutdown());
    super.dispose();
  }
}
