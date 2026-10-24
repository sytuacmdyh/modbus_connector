import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

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
      description = 'Disconnected';
      stopPolling();
      _setError('Python bridge stopped. Reconnect to recover.');
      notifyListeners();
    };
  }
  final BridgeTransport bridge;
  Map<String, dynamic> connectionConfig = {};
  final Map<String, dynamic> draft = {};
  bool connected = false;
  bool busy = false;
  bool disconnecting = false;
  bool polling = false;
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
  final Queue<LogEntry> logs = Queue();
  Timer? _timer;
  Completer<void>? _operation;
  int _epoch = 0;
  int _readGeneration = 0;
  bool _disposed = false;
  bool _closing = false;
  Future<void>? _shutdown;
  DateTime? _lastSample;

  bool get canRead => connected && !busy && !disconnecting;
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
    ++_epoch;
    stopPolling();
    await _operation?.future;
    await bridge.close();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    bridge.onDiagnostic = null;
    bridge.onExit = null;
    unawaited(shutdown());
    super.dispose();
  }
}
