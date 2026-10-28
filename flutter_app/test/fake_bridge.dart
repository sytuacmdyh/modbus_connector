import 'dart:async';

import 'package:modbus_desktop/src/bridge_client.dart';

class FakeBridge extends BridgeTransport {
  final List<Map<String, dynamic>> calls = [];
  bool connected = false;
  bool closed = false;
  Completer<BridgeReply>? heldRead;
  Completer<BridgeReply>? heldConnect;
  Completer<BridgeReply>? heldPorts;
  List<Map<String, dynamic>> serialPorts = [];
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
          'values': List.filled(
            command['count'] as int,
            command['kind'] == 'coils' || command['kind'] == 'discrete_inputs'
                ? value != 0
                : value,
          ),
          'elapsed_ms': 1.2,
        }, connected);
      case 'read_rows':
        if (heldRead != null) return heldRead!.future;
        return BridgeReply({
          'rows': [
            for (final row in (command['rows'] as List).cast<Map>())
              {
                'values': List.filled(
                  row['count'] as int? ?? 1,
                  ['coils', 'discrete_inputs'].contains(row['kind'])
                      ? value != 0
                      : value,
                ),
                'display': '$value',
                'numeric': value,
                'alarm': null,
              },
          ],
        }, connected);
      case 'plan_reads':
        return BridgeReply({
          'groups': [
            for (var i = 0; i < (command['rows'] as List).length; i++) [i],
          ],
        }, connected);
      case 'write':
        final raw = (command['values'] as List).first;
        value = raw is bool ? (raw ? 1 : 0) : raw as int;
        return BridgeReply({}, connected);
      case 'ports':
        if (heldPorts != null) return heldPorts!.future;
        return BridgeReply({'ports': serialPorts}, connected);
    }
    throw StateError('Unexpected command: $command');
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}
