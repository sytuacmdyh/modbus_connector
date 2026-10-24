import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:modbus_desktop/src/bridge_client.dart';
import 'package:modbus_desktop/src/workspace.dart';

import 'fake_bridge.dart';

void main() {
  test(
    'tabs own independent connections and closing waits for active I/O',
    () async {
      final workspace = WorkspaceController(bridgeFactory: FakeBridge.new);
      final first = workspace.sessions.first;
      workspace.add();
      final second = workspace.sessions.last;
      await first.connect({'transport': 'demo', 'timeout': 0.1}, 1);
      await second.connect({'transport': 'demo', 'timeout': 0.1}, 2);
      final bridge = first.bridge as FakeBridge;
      bridge.heldRead = Completer<BridgeReply>();
      final reading = first.read();
      final closing = workspace.remove(first);
      expect(bridge.closed, isFalse);
      await second.read();
      expect(second.values, isNotEmpty);
      bridge.heldRead!.complete(
        const BridgeReply({
          'values': [1],
          'elapsed_ms': 1,
        }, true),
      );
      await reading;
      await closing;
      expect(first.values, isEmpty);
      expect(bridge.closed, isTrue);
      expect(second.connected, isTrue);
      expect(workspace.selected, 0);
      await workspace.shutdown();
      workspace.dispose();
    },
  );
}
