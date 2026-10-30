import 'dart:async';
import 'dart:isolate';

import 'backend/service.dart';
import 'backend/worker.dart';

class BridgeReply {
  const BridgeReply(this.result, this.connected);
  final Map<String, dynamic> result;
  final bool connected;
}

class BridgeException implements Exception {
  const BridgeException(this.message, {this.connected});
  final String message;
  final bool? connected;
  @override
  String toString() => message;
}

abstract class BridgeTransport {
  void Function(List<Map<String, dynamic>>, Map<String, dynamic>)? onTraffic;
  void Function(String)? onDiagnostic;
  void Function()? onExit;
  Future<BridgeReply> request(
    Map<String, dynamic> command, {
    Duration? timeout,
  });
  Future<void> close();
}

/// An owned Dart isolate keeps communication independent of Flutter rendering.
/// Tests may inject a local service to inspect state without crossing isolates.
class NativeBridge extends BridgeTransport {
  NativeBridge({NativeService? service, this.directory}) : _local = service;
  final NativeService? _local;
  final String? directory;
  NativeService get service =>
      _local ?? (throw StateError('Backend is isolated'));
  bool _closing = false, _dead = false;
  Future<BridgeReply>? _pending;
  Future<SendPort>? _starting;
  SendPort? _commands;
  ReceivePort? _messages, _exits, _errors;
  Completer<Map<String, dynamic>>? _response;
  Completer<void>? _closed;
  Future<void>? _closeTask;

  Future<SendPort> _start() => _starting ??= _spawn();
  Future<SendPort> _spawn() async {
    final ready = Completer<SendPort>();
    _messages = ReceivePort();
    _exits = ReceivePort();
    _errors = ReceivePort();
    void failed(String message) {
      if (_dead) return;
      _dead = true;
      final error = BridgeException(message, connected: false);
      if (!ready.isCompleted) ready.completeError(error);
      if (_response != null && !_response!.isCompleted) {
        _response!.completeError(error);
      }
      if (_closed != null && !_closed!.isCompleted) _closed!.complete();
      if (!_closing) onExit?.call();
    }

    _messages!.listen((dynamic message) {
      if (message is SendPort) {
        _commands = message;
        ready.complete(message);
      } else if (message is Map && message['closed'] == true) {
        _dead = true;
        if (_closed != null && !_closed!.isCompleted) _closed!.complete();
      } else if (_response != null && !_response!.isCompleted) {
        _response!.complete(Map<String, dynamic>.from(message as Map));
      }
    });
    _exits!.listen(
      (_) => failed('Native backend stopped. Reconnect to recover.'),
    );
    _errors!.listen((dynamic error) => failed('Native backend error: $error'));
    try {
      await Isolate.spawn(
        nativeWorker,
        [_messages!.sendPort, directory],
        onExit: _exits!.sendPort,
        onError: _errors!.sendPort,
        debugName: 'modbus-session',
      );
    } catch (error) {
      failed('$error');
    }
    return ready.future;
  }

  @override
  Future<BridgeReply> request(
    Map<String, dynamic> command, {
    Duration? timeout,
  }) {
    if (_closing) {
      throw const BridgeException('Backend is closing', connected: false);
    }
    if (_pending != null) {
      throw const BridgeException('Backend operation already in progress');
    }
    final result = _request(command, timeout);
    _pending = result;
    return result.whenComplete(() {
      if (identical(_pending, result)) _pending = null;
    });
  }

  Future<BridgeReply> _request(
    Map<String, dynamic> command,
    Duration? timeout,
  ) async {
    Map<String, dynamic> response;
    if (_local != null) {
      response = await _local.respond(command);
    } else {
      if (_dead) {
        _disposePorts();
        _starting = null;
        _dead = false;
      }
      final port = await _start();
      final waiting = _response = Completer<Map<String, dynamic>>();
      port.send(command);
      try {
        response = await waiting.future;
      } finally {
        if (identical(_response, waiting)) _response = null;
      }
    }
    onTraffic?.call(
      (response['traffic'] as List).cast<Map<String, dynamic>>(),
      Map<String, dynamic>.from(response['statistics'] as Map),
    );
    if (response['ok'] != true) {
      throw BridgeException(
        response['error']['message'],
        connected: response['connected'] == true,
      );
    }
    return BridgeReply(
      Map<String, dynamic>.from(response['result'] as Map),
      response['connected'] == true,
    );
  }

  void _disposePorts() {
    _messages?.close();
    _exits?.close();
    _errors?.close();
    _commands = null;
  }

  @override
  Future<void> close() => _closeTask ??= _close();

  Future<void> _close() async {
    _closing = true;
    try {
      await _pending;
    } catch (_) {
      /* The caller receives transaction errors. */
    }
    if (_local != null) {
      await _local.close();
    } else if (_commands != null && !_dead) {
      _closed = Completer<void>();
      _commands!.send({'command': '_close_worker'});
      await _closed!.future;
    }
    _disposePorts();
  }
}
