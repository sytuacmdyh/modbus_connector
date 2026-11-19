import 'dart:async';
import 'dart:math' as math;

import 'backend/csv.dart';
import 'backend/datastore.dart';
import 'backend/memory_channel.dart';
import 'backend/register_operations.dart';
import 'backend/registers.dart';
import 'backend/wire.dart';
import 'bridge_transport.dart';

/// In-page sessions use the same register operations as native sessions.
/// No service connection, filesystem or native device resources are required.
class LocalBridge extends BridgeTransport {
  LocalBridge({
    this._openChannel,
    this.listPorts,
    this.authorizePort,
    this.platformCommand,
    this.closePlatform,
  });
  final Future<Json> Function(Json)? platformCommand;
  final Future<void> Function()? closePlatform;
  @override
  bool get downloadableLogs => platformCommand != null;
  @override
  bool get bufferedLogging => downloadableLogs;
  final Future<Json?> Function()? authorizePort;
  @override
  List<String> get transports => const ['rtu', 'demo'];
  @override
  bool get supportsDeviceModes => false;
  @override
  bool get browserSerial => authorizePort != null;
  @override
  Future<Json?> selectSerialPort() =>
      authorizePort?.call() ?? super.selectSerialPort();
  final WireChannelFactory? _openChannel;
  final List<Json> Function()? listPorts;
  ModbusClient _client = ModbusClient();
  DataStore? _demo;
  final _clock = Stopwatch();
  Future<BridgeReply>? _pending;
  Future<void>? _closing;
  ReadCancellation? _cancellation;
  bool _closed = false;
  int _tx = 0, _rx = 0, _operations = 0, _errors = 0;
  double _totalMs = 0;
  Json get _statistics => {
    'tx_bytes': _tx,
    'rx_bytes': _rx,
    'operations': _operations,
    'errors': _errors,
    'average_ms': _operations == 0 ? 0 : _totalMs / _operations,
  };

  void _capture(String direction, List<int> bytes) {
    if (_closed) return;
    if (direction == 'tx') {
      _tx += bytes.length;
    } else {
      _rx += bytes.length;
    }
    onTraffic?.call([
      {
        'direction': direction,
        'hex': hexBytes(bytes.take(4096).toList()),
        'length': bytes.length,
        'time': DateTime.now().toIso8601String(),
      },
    ], _statistics);
  }

  @override
  Future<BridgeReply> request(Json command, {Duration? timeout}) {
    if (_closed) {
      throw const BridgeException('Backend is closing', connected: false);
    }
    if (_pending != null) {
      throw const BridgeException('Backend operation already in progress');
    }
    final result = _request(command);
    _pending = result;
    return result.whenComplete(() {
      if (identical(_pending, result)) _pending = null;
    });
  }

  Future<BridgeReply> _request(Json d) async {
    final before = _tx + _rx, clock = Stopwatch()..start();
    final cancellation = d['command'] == 'read_rows'
        ? ReadCancellation()
        : null;
    _cancellation = cancellation;
    try {
      final result = await _dispatch(d, cancellation);
      return BridgeReply(result, _client.connected);
    } catch (error) {
      if (_tx + _rx != before && error is! ReadCancelled) _errors++;
      throw BridgeException(
        error is FormatException ? error.message : '$error',
        connected: _client.connected,
        readTimeout: error is ReadTimeout ? error.context : null,
      );
    } finally {
      if (identical(_cancellation, cancellation)) _cancellation = null;
      if (_tx + _rx != before) {
        _operations++;
        _totalMs += clock.elapsedMicroseconds / 1000;
      }
      if (!_closed) onTraffic?.call(const [], _statistics);
    }
  }

  Future<Json> _dispatch(Json d, ReadCancellation? cancellation) async {
    final command = d['command'];
    if (command == 'hello') return {'protocol': 1};
    if (command == 'ports') return {'ports': listPorts?.call() ?? <Json>[]};
    if (command == 'connect') {
      final demo = d['transport'] == 'demo';
      final params = connection(
        demo
            ? {
                'transport': 'rtu',
                'port': 'memory-demo',
                'timeout': d['timeout'] ?? 3,
              }
            : d,
      );
      await _disconnect();
      if (demo) {
        final store = _demo = DataStore();
        store.set('holding_registers', 0, List.generate(125, (i) => 100 + i));
        store.set('coils', 0, List.generate(2000, (i) => i.isEven));
        store.set('discrete_inputs', 0, List.generate(2000, (i) => i % 3 == 0));
        _client = ModbusClient(
          openChannel: (_) async => MemoryModbusChannel(store),
        );
        _clock
          ..reset()
          ..start();
      } else {
        _client = ModbusClient(openChannel: _openChannel);
      }
      _client.traffic = _capture;
      try {
        await _client.connect(params);
      } catch (_) {
        await _disconnect();
        rethrow;
      }
      return {
        'description': demo ? 'Demo · in-memory simulator' : describe(params),
      };
    }
    if (command == 'disconnect' || command == 'shutdown') {
      await _disconnect();
      return {};
    }
    if (command == 'evaluate_expressions') return evaluateExpressions(d);
    if (command == 'encode_values') return {'values': encodeValues(d)};
    if (command is String && command.startsWith('csv_')) return csvCommand(d);
    if (command is String &&
        (command.startsWith('template_') || command.startsWith('logger_')) &&
        platformCommand != null) {
      return platformCommand!(d);
    }
    return RegisterOperations(
      _client,
      beforeRead: _advanceDemo,
      cancellation: cancellation,
    ).dispatch(d);
  }

  void _advanceDemo() {
    _demo?.set(
      'input_registers',
      0,
      List.generate(
        125,
        (i) =>
            (1000 + 500 * math.sin(_clock.elapsedMilliseconds / 1000 + i / 5))
                .round(),
      ),
    );
  }

  Future<void> _disconnect() async {
    await closePlatform?.call();
    await _client.close();
    _demo = null;
    _clock.stop();
  }

  @override
  void cancelPendingRead() => _cancellation?.cancel();
  @override
  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    cancelPendingRead();
    try {
      await _pending;
    } catch (_) {
      /* Delivered to request caller. */
    }
    await _disconnect();
  }
}
