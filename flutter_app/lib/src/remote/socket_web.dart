import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'socket_contract.dart';

Future<RemoteSocket> connectSocket(String url) async {
  final socket = _Socket(web.WebSocket(url));
  try {
    await socket.ready.future.timeout(const Duration(seconds: 5));
    return socket;
  } catch (_) {
    await socket.close();
    rethrow;
  }
}

class _Socket implements RemoteSocket {
  _Socket(this.socket) {
    socket.onopen = ((web.Event _) {
      if (!ready.isCompleted) ready.complete();
    }).toJS;
    socket.onmessage = ((web.MessageEvent event) {
      final value = event.data;
      if (value != null && value.isA<JSString>()) {
        controller.add((value as JSString).toDart);
      } else {
        controller.addError(
          const FormatException('Expected a text service message'),
        );
      }
    }).toJS;
    socket.onerror = ((web.Event _) {
      final error = StateError(
        'Cannot connect to Dart service. Check URL, TLS, origin and browser local-network permission.',
      );
      if (!ready.isCompleted) {
        ready.completeError(error);
      } else if (!controller.isClosed) {
        controller.addError(error);
      }
    }).toJS;
    socket.onclose = ((web.Event _) {
      if (!ready.isCompleted) {
        ready.completeError(StateError('Dart service connection closed'));
      }
      unawaited(controller.close());
      if (!closed.isCompleted) closed.complete();
    }).toJS;
  }
  final web.WebSocket socket;
  final ready = Completer<void>();
  final closed = Completer<void>();
  final controller = StreamController<String>();
  @override
  Stream<String> get messages => controller.stream;
  @override
  void send(String text) {
    if (socket.readyState != web.WebSocket.OPEN) {
      throw StateError('Dart service connection closed');
    }
    socket.send(text.toJS);
  }

  @override
  Future<void> close() async {
    if (socket.readyState != web.WebSocket.CLOSED) socket.close();
    await closed.future.timeout(const Duration(seconds: 5), onTimeout: () {});
  }
}
