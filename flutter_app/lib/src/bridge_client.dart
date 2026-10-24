import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

/// One owned subprocess, one outstanding request. No shell or network listener.
class ProcessBridge extends BridgeTransport {
  Process? _process;
  Future<void>? _starting;
  Completer<BridgeReply>? _pending;
  StreamSubscription<String>? _stdout;
  StreamSubscription<String>? _stderr;
  int _id = 0;
  int? _pendingId;
  bool _closing = false;

  Future<void> _start() async {
    final configured =
        Platform.environment['MODBUS_PYTHON'] ??
        const String.fromEnvironment('MODBUS_PYTHON');
    final directory = File(Platform.resolvedExecutable).parent.path;
    final bundled = File(
      '$directory${Platform.pathSeparator}bridge${Platform.pathSeparator}'
      'modbus_bridge${Platform.isWindows ? '.exe' : ''}',
    );
    final useBundled = configured.isEmpty && await bundled.exists();
    final executable = useBundled
        ? bundled.path
        : configured.isNotEmpty
        ? configured
        : Platform.isWindows
        ? 'python'
        : 'python3';
    try {
      final process = await Process.start(
        executable,
        useBundled ? [] : ['-u', '-m', 'modbus_connector.flutter_bridge'],
        environment: {'PYTHONUNBUFFERED': '1', 'PYTHONIOENCODING': 'utf-8'},
      );
      _process = process;
      _stdout = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_receive, onError: (Object error) => _fail('$error'));
      _stderr = process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen((line) => onDiagnostic?.call(line));
      unawaited(
        process.exitCode.then((code) {
          if (identical(_process, process)) {
            _process = null;
            _fail('Bridge exited ($code). Reconnect to start it again.');
            if (!_closing) onExit?.call();
          }
        }),
      );
      final hello = await _exchange({
        'command': 'hello',
      }, const Duration(seconds: 15));
      if (hello.result['protocol'] != 1) {
        throw const BridgeException('Unsupported Python bridge protocol');
      }
    } catch (error) {
      _process?.kill();
      _process = null;
      throw BridgeException(
        'Could not start the Python bridge: $error. '
        'Install the Python package and set MODBUS_PYTHON to its interpreter.',
      );
    }
  }

  void _receive(String line) {
    try {
      final message = jsonDecode(line) as Map<String, dynamic>;
      if (message['id'] != _pendingId || _pending == null) return;
      final pending = _pending!;
      _pending = null;
      _pendingId = null;
      final connected = message['connected'] == true;
      onTraffic?.call(
        (message['traffic'] as List? ?? []).cast<Map<String, dynamic>>(),
        Map<String, dynamic>.from(message['statistics'] as Map? ?? {}),
      );
      if (message['ok'] == true) {
        pending.complete(
          BridgeReply(message['result'] as Map<String, dynamic>, connected),
        );
      } else {
        pending.completeError(
          BridgeException(
            (message['error'] as Map<String, dynamic>)['message'] as String,
            connected: connected,
          ),
        );
      }
    } catch (error) {
      _fail('Invalid response from Python bridge: $error');
      _process?.kill();
    }
  }

  void _fail(String message) {
    final pending = _pending;
    _pending = null;
    _pendingId = null;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(BridgeException(message, connected: false));
    }
  }

  Future<BridgeReply> _exchange(
    Map<String, dynamic> command,
    Duration timeout,
  ) async {
    if (_pending != null) {
      throw const BridgeException('Bridge operation already in progress');
    }
    final completer = Completer<BridgeReply>();
    _pending = completer;
    _pendingId = ++_id;
    try {
      _process!.stdin.writeln(jsonEncode({...command, 'id': _pendingId}));
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      _process?.kill();
      throw const BridgeException(
        'Bridge timed out. Reconnect to recover.',
        connected: false,
      );
    } finally {
      if (identical(_pending, completer)) {
        _pending = null;
        _pendingId = null;
      }
    }
  }

  @override
  Future<BridgeReply> request(
    Map<String, dynamic> command, {
    Duration? timeout,
  }) async {
    if (_closing) {
      throw const BridgeException('Bridge is closing', connected: false);
    }
    if (_process == null) {
      _starting ??= _start();
      try {
        await _starting;
      } finally {
        _starting = null;
      }
    }
    if (_closing) {
      throw const BridgeException('Bridge is closing', connected: false);
    }
    return _exchange(command, timeout ?? const Duration(seconds: 20));
  }

  @override
  Future<void> close() async {
    _closing = true;
    try {
      await _starting;
    } catch (_) {
      // A failed startup has already released its process.
    }
    // EOF releases the backend even if the native window closes abruptly.
    final process = _process;
    if (process != null) {
      await process.stdin.close();
      try {
        await process.exitCode.timeout(const Duration(seconds: 3));
      } on TimeoutException {
        process.kill();
        await process.exitCode;
      }
    }
    await _stdout?.cancel();
    await _stderr?.cancel();
  }
}
