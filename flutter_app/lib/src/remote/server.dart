import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../bridge_native.dart';
import '../bridge_transport.dart';

const serviceCommands = {
  'hello',
  'ports',
  'connect',
  'disconnect',
  'shutdown',
  'read_rows',
  'render_rows',
  'plan_reads',
  'write_row',
  'encode_values',
  'evaluate_expressions',
  'read',
  'write',
  'mask_write',
  'read_write',
  'diagnostics',
  'device_id',
  'scan_unit',
  'scan_address',
  'csv_import',
  'csv_export',
  'logger_start',
  'logger_stop',
  'logger_status',
  'logger_sample',
  'logger_export',
  'template_convert_workspace',
  'template_list',
  'template_load',
  'template_save',
  'template_versions',
  'template_rename',
  'template_delete',
  'template_delete_version',
  'device_start',
  'device_stop',
  'device_status',
  'sim_configure',
  'sim_set',
  'sniffer_snapshot',
};

String serviceIdentity() => List.generate(
  16,
  (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();

/// Authenticated native resources belong to a single WebSocket and its lease.
class DartServiceHost {
  DartServiceHost._(this.http, this.root, this.token, this.origins, this.lease);
  final HttpServer http;
  final Directory root;
  final String token;
  final Set<String> origins;
  final Duration lease;
  final _sessions = <_Session>{};
  bool _closing = false;
  int get port => http.port;
  int get sessionCount => _sessions.length;
  static Future<DartServiceHost> start({
    required Directory root,
    required String token,
    required Set<String> origins,
    String bind = '127.0.0.1',
    int port = 18766,
    Duration lease = const Duration(seconds: 45),
  }) async {
    if (token.length < 24 || token.length > 1024) {
      throw const FormatException('Use an access token of 24..1024 characters');
    }
    for (final origin in origins) {
      final uri = Uri.tryParse(origin);
      if (uri == null ||
          !['http', 'https'].contains(uri.scheme) ||
          uri.host.isEmpty ||
          uri.origin != origin ||
          uri.userInfo.isNotEmpty) {
        throw const FormatException(
          'Origins must be exact http(s) origins, without a trailing slash',
        );
      }
    }
    await root.create(recursive: true);
    final server = DartServiceHost._(
      await HttpServer.bind(bind, port),
      root,
      token,
      Set.unmodifiable(origins),
      lease,
    );
    server.http.listen((request) {
      unawaited(server._accept(request));
    });
    return server;
  }

  Future<void> _accept(HttpRequest request) async {
    try {
      final origin = request.headers.value('origin');
      if (_closing ||
          request.uri.path != '/ws' ||
          request.uri.hasQuery ||
          (origin != null && !origins.contains(origin)) ||
          !WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
        return;
      }
      if (_sessions.length >= 64) {
        request.response.statusCode = HttpStatus.serviceUnavailable;
        await request.response.close();
        return;
      }
      final socket = await WebSocketTransformer.upgrade(request);
      if (_closing || _sessions.length >= 64) {
        await socket.close();
        return;
      }
      socket.pingInterval = const Duration(seconds: 15);
      final session = _Session(this, socket);
      _sessions.add(session);
      session.start();
    } catch (_) {
      // No command payloads, credentials or handshake headers are logged.
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<void> close() async {
    _closing = true;
    await http.close(force: true);
    await Future.wait(_sessions.toList().map((s) => s.close()));
  }
}

class _Session {
  _Session(this.host, this.socket);
  final DartServiceHost host;
  final WebSocket socket;
  NativeBridge? bridge;
  StreamSubscription<dynamic>? subscription;
  Timer? authTimer, leaseTimer;
  Future<void>? _closing, _operation;
  bool authenticated = false, closing = false;
  int? activeId;
  int lastId = 0;
  String? logPath;
  bool connected = false;
  final id = serviceIdentity();
  Directory get directory => Directory('${host.root.path}/sessions/$id');
  void start() {
    authTimer = Timer(const Duration(seconds: 5), () => unawaited(close()));
    subscription = socket.listen(
      _message,
      onDone: () => unawaited(close()),
      onError: (Object _) => unawaited(close()),
    );
  }

  void send(Map<String, dynamic> message) {
    if (!closing && socket.readyState == WebSocket.open) {
      socket.add(jsonEncode(message));
    }
  }

  void _renew() {
    leaseTimer?.cancel();
    leaseTimer = Timer(host.lease, () => unawaited(close()));
  }

  void _message(dynamic raw) {
    if (closing) return;
    try {
      if (raw is! String || raw.length > 4 * 1024 * 1024) {
        throw const FormatException('Invalid message size or type');
      }
      final message = jsonDecode(raw) as Map<String, dynamic>;
      if (!authenticated) {
        final supplied = message['token'];
        if (message['type'] != 'auth' ||
            message['protocol'] != 1 ||
            supplied is! String ||
            !_tokenEquals(supplied, host.token)) {
          send({'type': 'auth_error'});
          unawaited(close());
          return;
        }
        authenticated = true;
        authTimer?.cancel();
        _renew();
        bridge = NativeBridge(
          directory: host.root.path,
          loggerMaxBytes: 20 * 1024 * 1024,
        );
        bridge!.onTraffic = (traffic, statistics) => send({
          'type': 'traffic',
          'traffic': traffic,
          'statistics': statistics,
        });
        bridge!.onExit = () => unawaited(close());
        send({
          'type': 'ready',
          'protocol': 1,
          'transports': bridge!.transports,
          'device_modes': true,
          'downloadable_logs': true,
          'log_limit_bytes': 20 * 1024 * 1024,
          'lease_seconds': host.lease.inSeconds,
        });
        return;
      }
      _renew();
      if (message['type'] == 'ping') {
        send({'type': 'pong'});
        return;
      }
      if (message['type'] == 'cancel') {
        if (message['id'] == activeId) bridge!.cancelPendingRead();
        return;
      }
      final requestId = message['id'];
      if (message['type'] != 'request' ||
          requestId is! int ||
          requestId <= lastId ||
          message['command'] is! Map) {
        throw const FormatException('Invalid request');
      }
      if (_operation != null) {
        send({
          'type': 'reply',
          'id': requestId,
          'ok': false,
          'connected': false,
          'error': {'message': 'Backend operation already in progress'},
        });
        return;
      }
      lastId = requestId;
      activeId = requestId;
      final command = Map<String, dynamic>.from(message['command'] as Map);
      _operation = _run(command, requestId);
      unawaited(
        _operation!.whenComplete(() {
          _operation = null;
          activeId = null;
        }),
      );
    } catch (_) {
      unawaited(close());
    }
  }

  Future<void> _run(Map<String, dynamic> raw, int requestId) async {
    try {
      final command = raw['command'];
      if (!serviceCommands.contains(command)) {
        throw const FormatException(
          'Command is unavailable through the Dart service',
        );
      }
      // Never accept worker controls, desktop updates, cloud actions or paths.
      final data = {...raw}..removeWhere((key, _) => key.startsWith('_'));
      if (command == 'logger_start') {
        final name = data['path'];
        if (name is! String ||
            name.length > 160 ||
            !RegExp(r'^[\w\- .\u0080-\uFFFF]+\.(csv|jsonl)$').hasMatch(name) ||
            name.contains('..')) {
          throw const FormatException(
            'Use a log filename ending in .csv or .jsonl, without directories',
          );
        }
        data['path'] = '${directory.path}/$name';
      }
      BridgeReply reply;
      if (command == 'logger_export') {
        final path = logPath;
        if (path == null) {
          throw const FormatException('No service log to download');
        }
        await bridge!.request({'command': 'logger_stop'});
        final file = File(path);
        if (await file.length() > 20 * 1024 * 1024) {
          throw const FormatException('Log exceeds download limit');
        }
        reply = BridgeReply({
          'path': file.uri.pathSegments.last,
          'text': await file.readAsString(),
        }, connected);
      } else {
        reply = await bridge!.request(data);
        connected = reply.connected;
        if (command == 'logger_start') logPath = data['path'] as String;
      }
      send({
        'type': 'reply',
        'id': requestId,
        'ok': true,
        'connected': reply.connected,
        'result': reply.result,
      });
    } catch (error) {
      if (error is BridgeException && error.connected != null) {
        connected = error.connected!;
      }
      send({
        'type': 'reply',
        'id': requestId,
        'ok': false,
        'connected': connected,
        'error': {
          'message': error is FormatException ? error.message : '$error',
          if (error is BridgeException && error.readTimeout != null)
            'read_timeout': error.readTimeout,
        },
      });
    }
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    closing = true;
    authTimer?.cancel();
    leaseTimer?.cancel();
    bridge?.cancelPendingRead();
    final socketClosed = socket.close().timeout(
      const Duration(seconds: 3),
      onTimeout: () {},
    );
    await _operation;
    await bridge?.close();
    await socketClosed;
    await subscription?.cancel();
    if (await directory.exists()) await directory.delete(recursive: true);
    host._sessions.remove(this);
  }
}

bool _tokenEquals(String a, String b) {
  var difference = a.length ^ b.length;
  for (var i = 0; i < b.length; i++) {
    difference |= (i < a.length ? a.codeUnitAt(i) : 0) ^ b.codeUnitAt(i);
  }
  return difference == 0;
}
