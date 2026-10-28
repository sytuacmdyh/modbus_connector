import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:modbus_desktop/src/settings_store.dart';
import 'package:modbus_desktop/src/workspace.dart';

import 'fake_bridge.dart';

void main() {
  test('workspace persists independently, restores disconnected and rejects malformed import', () async {
    final root = await Directory.systemTemp.createTemp('modbus-flutter-test');
    try {
      final store = SettingsStore(directory: Directory('${root.path}/flutter'));
      final qt = File('${root.path}/settings.json');
      await qt.writeAsString('qt settings');
      final workspace = WorkspaceController(bridgeFactory: FakeBridge.new);
      workspace.sessions.first.registers.add({
        'name': 'Speed',
        'kind': 'holding_registers',
        'address': 5,
        'count': 1,
        'format': 'dec',
      });
      workspace.sessions.first.draft['map_table'] = {
        'order': ['value', 'name'],
        'widths': {'name': 222},
      };
      workspace.autoSave = false;
      workspace.sessions.first.draft['host'] = 'plc.local';
      workspace.add();
      workspace.sessions.last.mode = 'simulator';
      await store.save(workspace.exportState());
      workspace.dispose();
      final restored = WorkspaceController(
        bridgeFactory: FakeBridge.new,
        store: store,
      );
      while (restored.loading) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(restored.autoSave, isFalse);
      expect((restored.sessions.first.draft['map_table'] as Map)['widths'], {
        'name': 222,
      });
      expect(restored.sessions.length, 2);
      expect(restored.sessions.first.registers.single['name'], 'Speed');
      expect(restored.sessions.first.connected, isFalse);
      expect(restored.sessions.last.mode, 'simulator');
      expect(restored.selected, 1);
      final bad = File('${root.path}/bad.json');
      await bad.writeAsString('{"schema":1,"tabs":[]}');
      await restored.load(path: bad.path);
      expect(restored.stateError, isNotNull);
      expect(restored.sessions.length, 2);
      expect(await qt.readAsString(), 'qt settings');
      await restored.shutdown();
      restored.dispose();
    } finally {
      await root.delete(recursive: true);
    }
  });
}
