import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:modbus_desktop/src/backend/update.dart';
import 'package:modbus_desktop/src/settings_store.dart';
import 'package:modbus_desktop/src/workspace.dart';

import 'fake_bridge.dart';

class Handoff extends UpdateHandoff {
  Handoff(this.calls, {this.fail = false});
  final List<String> calls;
  final bool fail;
  @override
  Future<void> commit() async {
    calls.add('commit');
    if (fail) throw StateError('helper stopped');
  }

  @override
  Future<void> abort() async {
    calls.add('abort');
  }
}

class Store extends SettingsStore {
  Store(this.calls, {this.fail = false});
  final List<String> calls;
  final bool fail;
  @override
  Future<Map<String, dynamic>?> load({String? path}) async => null;
  @override
  Future<void> save(Map<String, dynamic> data, {String? path}) async {
    calls.add('save');
    if (fail) throw const FileSystemException('disk full');
  }
}

void main() {
  for (final failure in ['none', 'save', 'commit']) {
    test(
      'update $failure saves before handoff and closes resources before exit',
      () async {
        final calls = <String>[];
        final bridges = <FakeBridge>[];
        final workspace = WorkspaceController(
          store: Store(calls, fail: failure == 'save'),
          bridgeFactory: () {
            final b = FakeBridge();
            bridges.add(b);
            return b;
          },
        );
        while (workspace.loading) {
          await Future<void>.delayed(Duration.zero);
        }
        workspace.autoSave = false;
        workspace.autoCheckUpdates = false;
        expect(workspace.exportState()['auto_check_updates'], false);
        final handoff = Handoff(calls, fail: failure == 'commit');
        try {
          final operation = workspace.installUpdate(
            handoff,
            exitApplication: () async {
              expect(bridges.every((b) => b.closed), true);
              calls.add('exit');
            },
          );
          if (failure == 'none') {
            await operation;
            expect(calls, ['save', 'commit', 'exit']);
          } else {
            await expectLater(operation, throwsA(anything));
            expect(
              calls,
              failure == 'save'
                  ? ['save', 'abort']
                  : ['save', 'commit', 'abort'],
            );
            expect(workspace.closing, false);
            expect(bridges.single.closed, false);
          }
        } finally {
          await workspace.shutdown();
          workspace.dispose();
        }
      },
    );
  }
}
