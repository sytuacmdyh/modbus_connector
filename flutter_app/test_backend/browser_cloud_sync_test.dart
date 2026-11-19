@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:modbus_desktop/src/backend/catalog_web.dart';
import 'package:modbus_desktop/src/bridge_browser.dart';
import 'package:modbus_desktop/src/bridge_transport.dart';
import 'package:modbus_desktop/src/settings_store_web.dart';
import 'package:test/test.dart';
import 'package:web/web.dart' as web;

// Start `dart run tool/webdav_fixture.dart` before this test file.
const base = 'http://127.0.0.1:18867';

Future<Map<String, dynamic>> transfer(
  BridgeTransport bridge,
  String path, {
  String action = 'download',
  String? version,
}) async {
  await bridge.request({
    'command': 'cloud_start',
    'action': action,
    'version': ?version,
    'settings': {
      'url': '$base/$path',
      'username': 'operator',
      'password': 'test-only',
    },
  });
  for (var i = 0; i < 1000; i++) {
    final result = (await bridge.request({'command': 'cloud_status'})).result;
    if (result['running'] != true) return result;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('WebDAV transfer did not finish');
}

void main() {
  setUp(() {
    for (final key in [
      BrowserCatalog.publicStorageKey,
      BrowserCatalog.cloudSettingsKey,
    ]) {
      web.window.localStorage.removeItem(key);
    }
  });
  tearDown(() {
    for (final key in [
      BrowserCatalog.publicStorageKey,
      BrowserCatalog.cloudSettingsKey,
    ]) {
      web.window.localStorage.removeItem(key);
    }
  });

  test('real cross-origin fetch downloads skill catalog and opens it offline without a Dart service', () async {
    final bridge = createUtilityBridge();
    try {
      expect((await transfer(bridge, 'dav', action: 'test'))['error'], null);
      expect((await transfer(bridge, 'dav'))['result']['downloaded'], 1);
      final cached = web.window.localStorage.getItem(
        BrowserCatalog.publicStorageKey,
      );
      expect(cached, contains('WebDAV acceptance device'));
      final catalog = await BrowserCatalog().dispatch({
        'command': 'template_list',
      });
      expect(catalog['public'].single['manufacturer'], 'Acme');
      final loaded = await BrowserCatalog().dispatch({
        'command': 'template_load',
        'resource': 'Acme/WebDAV.json',
      });
      expect(loaded['state']['registers'], hasLength(2));
      expect(loaded['state']['registers'][1]['writable'], false);
      final history = await transfer(bridge, 'dav', action: 'versions');
      final version = history['result']['versions'].single as String;
      expect((await transfer(bridge, 'dav', version: version))['error'], null);
      expect((await transfer(bridge, 'legacy'))['error'], null);
      expect(
        web.window.localStorage.getItem(BrowserCatalog.publicStorageKey),
        cached,
      );
      for (final failure in [
        'bad',
        'unauthorized',
        'redirect',
        'nocors',
        'huge',
      ]) {
        final result = await transfer(bridge, failure);
        expect(result['error'], isNotNull, reason: failure);
        expect(
          web.window.localStorage.getItem(BrowserCatalog.publicStorageKey),
          cached,
          reason: failure,
        );
      }
      final requests = jsonDecode(
        (await (await web.window.fetch('$base/requests'.toJS).toDart)
                .text()
                .toDart)
            .toDart,
      );
      expect(
        (requests as List).every(
          (r) => ['GET', 'PROPFIND'].contains(r['method']),
        ),
        true,
      );
    } finally {
      await bridge.close();
    }
  });

  test('settings are independent from workspace; password persistence is opt-in and cancellation retains cache', () async {
    final bridge = createUtilityBridge();
    final settings = {
      'url': '$base/dav',
      'username': 'operator',
      'password': 'test-only',
      'mode': 'publisher',
    };
    try {
      await bridge.request({
        'command': 'cloud_settings_save',
        'settings': settings,
      });
      final stored = web.window.localStorage.getItem(
        BrowserCatalog.cloudSettingsKey,
      )!;
      expect(stored, isNot(contains('test-only')));
      expect(stored, isNot(contains('publisher')));
      await bridge.request({
        'command': 'cloud_settings_save',
        'settings': {...settings, 'remember_password': true},
      });
      final reopened = createUtilityBridge();
      try {
        expect(
          (await reopened.request({'command': 'cloud_settings_load'}))
              .result['settings']['password'],
          'test-only',
        );
      } finally {
        await reopened.close();
      }
      expect(
        web.window.localStorage.getItem(SettingsStore.storageKey) ?? '',
        isNot(contains('test-only')),
      );
      await transfer(bridge, 'dav');
      final old = web.window.localStorage.getItem(
        BrowserCatalog.publicStorageKey,
      );
      await bridge.request({
        'command': 'cloud_start',
        'action': 'download',
        'settings': {...settings, 'url': '$base/slow'},
      });
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await bridge.request({'command': 'cloud_cancel'});
      for (var i = 0; i < 100; i++) {
        if ((await bridge.request({'command': 'cloud_status'}))
                .result['running'] !=
            true) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(
        (await bridge.request({'command': 'cloud_status'})).result['error'],
        contains('cancelled'),
      );
      expect(
        web.window.localStorage.getItem(BrowserCatalog.publicStorageKey),
        old,
      );
      await expectLater(
        bridge.request({
          'command': 'cloud_start',
          'action': 'publish',
          'settings': settings,
        }),
        throwsA(isA<BridgeException>()),
      );
    } finally {
      await bridge.close();
    }
  });
}
