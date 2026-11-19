import 'dart:async';
import 'dart:convert';

import '../bridge_transport.dart';
import 'configuration.dart';
import 'socket.dart';

/// A lost reply never causes a command to be replayed. Reconnect is explicit.
class RemoteBridge extends BridgeTransport {
  RemoteBridge(this.configuration);
  final ServiceConfiguration configuration;
  RemoteSocket? _socket;
  StreamSubscription<String>? _subscription;
  Future<void>? _starting;
  Completer<Map<String, dynamic>>? _reply;
  Completer<Map<String, dynamic>>? _authentication;
  Future<BridgeReply>? _pending;
  Future<void>? _closing;
  bool _closed = false, _failed = false, _rejectNew = false;
  int _sequence = 0;
  int? _activeId, _readId;
  List<String> _transports = const ['rtu', 'tcp', 'rtu_tcp', 'rtu_udp', 'demo'];
  bool _deviceModes = true;
  Timer? _heartbeat;
  @override
  List<String> get transports => _transports;
  @override
  bool get supportsDeviceModes => _deviceModes;
  @override
  bool get downloadableLogs => true;

  Future<void> _start() => _starting ??= _connect();
  Future<void> _connect() async {
    if (configuration.token.isEmpty) {
      throw const BridgeException(
        'Enter the Dart service access token in Settings',
        connected: false,
      );
    }
    final authentication = _authentication = Completer<Map<String, dynamic>>();
    try {
      final socket = _socket = await connectSocket(configuration.endpoint);
      if (_closed) {
        await socket.close();
        throw const BridgeException('Backend is closing', connected: false);
      }
      _subscription = socket.messages.listen(
        _receive,
        onError: (Object error) => _fail('$error'),
        onDone: () => _fail(
          'Dart service disconnected. Reconnect explicitly; an unacknowledged write may have completed.',
        ),
      );
      socket.send(
        jsonEncode({
          'type': 'auth',
          'protocol': 1,
          'token': configuration.token,
        }),
      );
      final hello = await authentication.future.timeout(
        const Duration(seconds: 5),
      );
      if (hello['protocol'] != 1 || hello['transports'] is! List) {
        throw const FormatException('Unsupported Dart service protocol');
      }
      _transports = (hello['transports'] as List).cast<String>();
      _deviceModes = hello['device_modes'] == true;
      _heartbeat = Timer.periodic(const Duration(seconds: 10), (_) {
        if (!_closed && !_failed) _socket?.send(jsonEncode({'type': 'ping'}));
      });
    } catch (_) {
      _failed = true;
      await _socket?.close();
      rethrow;
    } finally {
      _authentication = null;
    }
  }

  void _receive(String text) {
    try {
      if (text.length > 32 * 1024 * 1024) {
        throw const FormatException('Service message is too large');
      }
      final message = jsonDecode(text) as Map<String, dynamic>;
      if (message['type'] == 'ready') {
        if (_authentication?.isCompleted == false) {
          _authentication!.complete(message);
        }
      } else if (message['type'] == 'auth_error') {
        _fail('Dart service authentication rejected');
      } else if (message['type'] == 'traffic') {
        onTraffic?.call(
          (message['traffic'] as List)
              .map((v) => Map<String, dynamic>.from(v as Map))
              .toList(),
          Map<String, dynamic>.from(message['statistics'] as Map),
        );
      } else if (message['type'] == 'reply' &&
          message['id'] == _activeId &&
          _reply?.isCompleted == false) {
        _reply!.complete(message);
      }
    } catch (error) {
      _fail('Invalid Dart service message: $error');
    }
  }

  void _fail(String message) {
    if (_failed || _closed) return;
    _failed = true;
    _heartbeat?.cancel();
    final error = BridgeException(message, connected: false);
    if (_authentication?.isCompleted == false) {
      _authentication!.completeError(error);
    }
    if (_reply?.isCompleted == false) _reply!.completeError(error);
    unawaited(_socket?.close());
    onDiagnostic?.call(message);
    onExit?.call();
  }

  @override
  Future<BridgeReply> request(
    Map<String, dynamic> command, {
    Duration? timeout,
  }) {
    if (_closed || _rejectNew) {
      throw const BridgeException('Backend is closing', connected: false);
    }
    if (_pending != null) {
      throw const BridgeException('Backend operation already in progress');
    }
    final future = _request(command, timeout);
    _pending = future;
    return future.whenComplete(() {
      if (identical(_pending, future)) _pending = null;
    });
  }

  Future<BridgeReply> _request(
    Map<String, dynamic> command,
    Duration? timeout,
  ) async {
    if (_failed) {
      // Only a deliberate connect may create a replacement server session.
      if (command['command'] != 'connect' && command['command'] != 'hello') {
        throw const BridgeException(
          'Dart service disconnected. Connect again before continuing.',
          connected: false,
        );
      }
      await _subscription?.cancel();
      _starting = null;
      _failed = false;
    }
    await _start();
    if (_closed) {
      throw const BridgeException('Backend is closing', connected: false);
    }
    final id = ++_sequence;
    _activeId = id;
    if (command['command'] == 'read_rows') _readId = id;
    final waiting = _reply = Completer<Map<String, dynamic>>();
    try {
      _socket!.send(
        jsonEncode({'type': 'request', 'id': id, 'command': command}),
      );
      final reply = await waiting.future.timeout(
        timeout ?? const Duration(seconds: 60),
      );
      if (reply['ok'] != true) {
        throw BridgeException(
          '${reply['error']['message']}',
          connected: reply['connected'] == true,
          readTimeout: reply['error']['read_timeout'] == null
              ? null
              : Map<String, dynamic>.from(
                  reply['error']['read_timeout'] as Map,
                ),
        );
      }
      return BridgeReply(
        Map<String, dynamic>.from(reply['result'] as Map),
        reply['connected'] == true,
      );
    } on TimeoutException {
      _fail(
        'Dart service reply timed out. Reconnect explicitly; an unacknowledged write may have completed.',
      );
      throw const BridgeException(
        'Dart service reply timed out',
        connected: false,
      );
    } finally {
      if (_activeId == id) {
        _activeId = null;
        _readId = null;
        _reply = null;
      }
    }
  }

  @override
  void cancelPendingRead() {
    final id = _readId;
    if (id != null && !_failed) {
      _socket?.send(jsonEncode({'type': 'cancel', 'id': id}));
    }
  }

  @override
  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    cancelPendingRead();
    _rejectNew = true;
    // The close reply is sent after the server awaits all owned resources.
    try {
      await _pending;
      if (_socket != null && !_failed) {
        await _request({'command': 'shutdown'}, const Duration(seconds: 15));
      }
    } catch (_) {
      /* The socket lease is the fallback after a network loss. */
    }
    _closed = true;
    _heartbeat?.cancel();
    await _socket?.close();
    await _subscription?.cancel();
  }
}
