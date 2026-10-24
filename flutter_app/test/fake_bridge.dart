import 'dart:async';

import 'package:modbus_desktop/src/bridge_client.dart';

class FakeBridge extends BridgeTransport {
  final List<Map<String, dynamic>> calls = [];
  bool connected = false;
  bool closed = false;
  Completer<BridgeReply>? heldRead;
  Completer<BridgeReply>? heldConnect;
  int value = 100;

  @override
  Future<BridgeReply> request(
    Map<String, dynamic> command, {
    Duration? timeout,
  }) async {
    calls.add(command);
    switch (command['command']) {
      case 'connect':
        if (heldConnect != null) return heldConnect!.future;
        connected = true;
        return const BridgeReply({'description': 'test TCP'}, true);
      case 'disconnect':
        connected = false;
        return const BridgeReply({}, false);
      case 'read':
        if (heldRead != null) return heldRead!.future;
        return BridgeReply({
          'values': List.filled(command['count'] as int, value),
          'elapsed_ms': 1.2,
        }, connected);
      case 'write':
        value = (command['values'] as List).first as int;
        return BridgeReply({}, connected);
      case 'ports':
        return BridgeReply({'ports': <Map<String, dynamic>>[]}, connected);
    }
    throw StateError('Unexpected command: $command');
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}
