import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:modbus_desktop/src/backend/cloud_sync.dart';
import 'package:modbus_desktop/src/backend/dav_http_contract.dart';
import 'package:test/test.dart';

const version = '20261119T000000000001Z-deadbeef';
final settings = {'url': 'https://example.test/dav', 'mode': 'publisher'};
final catalog = {
  'Acme/设备.json': {
    'name': '设备',
    'connection': {'transport': 'demo'},
    'registers': [
      {'address': 0, 'writable': false},
    ],
  },
};
List<int> snapshot([dynamic templates]) => utf8.encode(
  jsonEncode({
    'schema': 1,
    'version': version,
    'templates': templates ?? catalog,
  }),
);

class Http extends DavHttpClient {
  Http(this.reply);
  final Future<DavResponse> Function(Uri, String) reply;
  final calls = <String>[];
  bool closed = false;
  @override
  Future<DavResponse> request(
    Uri uri, {
    required String method,
    required Map<String, String> headers,
    required Duration timeout,
    List<int>? body,
  }) {
    calls.add('$method ${uri.path}');
    return reply(uri, method);
  }

  @override
  void close() => closed = true;
}

Future<Map<String, dynamic>> finish(CloudSync sync) async {
  await sync.task;
  return sync.dispatch({'command': 'cloud_status'});
}

void main() {
  test('legacy publisher mode is discarded and every write action fails before client creation', () async {
    var clients = 0;
    Map<String, dynamic>? saved;
    final sync = CloudSync(
      loadSettings: () async => {
        ...settings,
        'password': 'hidden',
        'remember_password': false,
      },
      saveSettings: (data) async => saved = data,
      replaceCatalog: (_, _) async => fail('Unexpected cache write'),
      clientFactory: () {
        clients++;
        throw StateError('Unexpected network');
      },
    );
    expect(
      (await sync.dispatch({'command': 'cloud_settings_load'}))['settings'],
      isNot(contains('mode')),
    );
    await sync.dispatch({
      'command': 'cloud_settings_save',
      'settings': {...settings, 'password': 'hidden'},
    });
    expect(saved, isNot(contains('password')));
    expect(saved, isNot(contains('mode')));
    for (final action in ['publish', 'activate', 'upload', 'delete']) {
      await expectLater(
        sync.dispatch({
          'command': 'cloud_start',
          'action': action,
          'settings': settings,
        }),
        throwsA(isA<DavException>()),
      );
    }
    for (final bad in [
      {...settings, 'url': 'https://user:secret@example.test'},
      {...settings, 'templates_path': '../templates'},
      {...settings, 'timeout': 0},
      {...settings, 'username': 'x\nheader'},
    ]) {
      await expectLater(
        sync.dispatch({
          'command': 'cloud_start',
          'action': 'download',
          'settings': bad,
        }),
        throwsFormatException,
      );
    }
    expect(clients, 0);
    await sync.close();
  });

  test('a valid skill snapshot replaces only the catalog; malformed/auth/oversized replies preserve it', () async {
    Map<String, dynamic> cached = {'old': 'cache'};
    var response = DavResponse(200, snapshot());
    final http = Http((_, _) async => response);
    final sync = CloudSync(
      loadSettings: () async => {},
      saveSettings: (_) async {},
      replaceCatalog: (data, check) async {
        check();
        cached = data;
      },
      clientFactory: () => http,
    );
    await sync.dispatch({
      'command': 'cloud_start',
      'action': 'download',
      'settings': settings,
    });
    expect((await finish(sync))['result']['downloaded'], 1);
    expect(cached, catalog);
    for (final bad in [
      DavResponse(200, utf8.encode('{broken')),
      DavResponse(401, []),
      DavResponse(302, []),
      DavResponse(200, snapshot({'bad.json': catalog.values.first})),
      DavResponse(200, snapshot({})),
      DavResponse(200, Uint8List(cloudByteLimit + 1)),
    ]) {
      response = bad;
      await sync.dispatch({
        'command': 'cloud_start',
        'action': 'download',
        'settings': settings,
      });
      expect((await finish(sync))['error'], isNotNull);
      expect(cached, catalog);
    }
    expect(http.calls, everyElement('GET /dav/templates/.catalog.json'));
    await sync.close();
  });

  test('legacy directory reads stay scoped and do not replace a valid cache on partial failure', () async {
    var committed = false;
    String listing(String root, String entry, bool directory) =>
        '<d:multistatus xmlns:d="DAV:"><d:response><d:href>$root/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response><d:response><d:href>$entry</d:href><d:propstat><d:prop><d:resourcetype>${directory ? '<d:collection/>' : ''}</d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>';
    var outside = false;
    final http = Http((uri, method) async {
      if (method == 'GET') return const DavResponse(404, []);
      return DavResponse(
        207,
        utf8.encode(
          uri.path == '/dav/templates/'
              ? listing(
                  '/dav/templates',
                  outside ? 'https://other.test/Acme' : '/dav/templates/Acme/',
                  true,
                )
              : listing(
                  '/dav/templates/Acme',
                  '/dav/templates/Acme/missing.json',
                  false,
                ),
        ),
      );
    });
    final sync = CloudSync(
      loadSettings: () async => {},
      saveSettings: (_) async {},
      replaceCatalog: (_, _) async => committed = true,
      clientFactory: () => http,
    );
    for (final escape in [false, true]) {
      outside = escape;
      await sync.dispatch({
        'command': 'cloud_start',
        'action': 'download',
        'settings': settings,
      });
      expect((await finish(sync))['error'], isNotNull);
      expect(committed, false);
    }
    expect(
      http.calls.every(
        (s) => s.startsWith('GET ') || s.startsWith('PROPFIND '),
      ),
      true,
    );
    await sync.close();
  });

  test(
    'cancel and close suppress late responses and wait for the owned transfer',
    () async {
      for (final close in [false, true]) {
        final response = Completer<DavResponse>();
        final http = Http((_, _) => response.future);
        var committed = false;
        final sync = CloudSync(
          loadSettings: () async => {},
          saveSettings: (_) async {},
          replaceCatalog: (_, _) async => committed = true,
          clientFactory: () => http,
        );
        await sync.dispatch({
          'command': 'cloud_start',
          'action': 'download',
          'settings': settings,
        });
        await expectLater(
          sync.dispatch({
            'command': 'cloud_start',
            'action': 'download',
            'settings': settings,
          }),
          throwsFormatException,
        );
        var closed = false;
        final closing = close ? sync.close().then((_) => closed = true) : null;
        if (!close) await sync.dispatch({'command': 'cloud_cancel'});
        expect(http.closed, true);
        expect(closed, false);
        response.complete(DavResponse(200, snapshot()));
        final result = await finish(sync);
        await closing;
        expect(result['error'], contains('cancelled'));
        expect(committed, false);
        await sync.close();
      }
    },
  );
}
