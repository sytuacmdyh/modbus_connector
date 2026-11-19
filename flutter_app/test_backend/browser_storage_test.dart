@TestOn('browser')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:modbus_desktop/src/backend/catalog_web.dart';
import 'package:modbus_desktop/src/settings_store_web.dart';
import 'package:modbus_desktop/src/document_file_web.dart';
import 'package:test/test.dart';
import 'package:web/web.dart' as web;

void main() {
  setUp(() {
    web.window.localStorage.removeItem(SettingsStore.storageKey);
    web.window.localStorage.removeItem(BrowserCatalog.storageKey);
  });
  tearDown(() {
    web.window.localStorage.removeItem(SettingsStore.storageKey);
    web.window.localStorage.removeItem(BrowserCatalog.storageKey);
  });

  test('workspace persists explicitly, validates uploads and keeps previous state after invalid import', () async {
    final state = <String, dynamic>{
      'schema': 1,
      'autosave': false,
      'tabs': [
        {
          'mode': 'master',
          'connection': {'transport': 'demo'},
          'registers': [],
        },
      ],
    };
    final store = SettingsStore();
    expect(await store.load(), null);
    await store.save(state);
    expect(await SettingsStore().load(), state);
    final bad = DocumentFile.importBytes(
      Uint8List.fromList(utf8.encode('{"schema":1,"tabs":[]}')),
    );
    await expectLater(store.load(path: bad), throwsFormatException);
    expect(await store.load(), state);
    final imported = {...state, 'language': 'zh_CN'};
    final handle = DocumentFile.importBytes(
      Uint8List.fromList(utf8.encode(jsonEncode(imported))),
    );
    expect(await store.load(path: handle), imported);
    // Loading a file does not overwrite the saved workspace until explicit Save.
    expect(await store.load(), state);
  });

  test('custom template histories survive new adapters and reject deletion of the last version', () async {
    final catalog = BrowserCatalog();
    final state = <String, dynamic>{
      'connection': {'transport': 'demo'},
      'registers': [
        {
          'name': '温度',
          'kind': 'holding_registers',
          'address': 0,
          'count': 1,
          'writable': false,
        },
      ],
    };
    final saved = await catalog.dispatch({
      'command': 'template_save',
      'name': '设备',
      'state': state,
    });
    final id = saved['id'];
    final loaded = await BrowserCatalog().dispatch({
      'command': 'template_load',
      'template_id': id,
    });
    expect(loaded['state']['registers'][0]['writable'], false);
    final first = await catalog.dispatch({
      'command': 'template_versions',
      'template_id': id,
    });
    await expectLater(
      catalog.dispatch({
        'command': 'template_delete_version',
        'template_id': id,
        'version_id': first['versions'][0]['id'],
      }),
      throwsFormatException,
    );
    await catalog.dispatch({
      'command': 'template_save',
      'template_id': id,
      'state': state,
    });
    final history = await catalog.dispatch({
      'command': 'template_versions',
      'template_id': id,
    });
    expect(history['versions'], hasLength(2));
    await catalog.dispatch({
      'command': 'template_delete_version',
      'template_id': id,
      'version_id': history['versions'][0]['id'],
    });
    await catalog.dispatch({
      'command': 'template_rename',
      'template_id': id,
      'name': '新名称',
    });
    expect((await catalog.dispatch({'command': 'template_list'}))['custom'], [
      {'id': id, 'name': '新名称'},
    ]);
  });
}
