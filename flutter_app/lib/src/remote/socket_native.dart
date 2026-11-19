import 'dart:io';

import 'socket_contract.dart';

Future<RemoteSocket> connectSocket(String url) async {
  var abandoned = false;
  final pending = WebSocket.connect(url).then((socket) {
    if (abandoned) socket.close();
    return socket;
  });
  try {
    return _Socket(await pending.timeout(const Duration(seconds: 5)));
  } catch (_) {
    abandoned = true;
    rethrow;
  }
}

class _Socket implements RemoteSocket {
  _Socket(this.socket);
  final WebSocket socket;
  @override
  Stream<String> get messages => socket.map((event) {
    if (event is! String) {
      throw const FormatException('Expected a text service message');
    }
    return event;
  });
  @override
  void send(String text) => socket.add(text);
  @override
  Future<void> close() async {
    await socket.close();
  }
}
