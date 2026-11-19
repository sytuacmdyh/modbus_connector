import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:modbus_desktop/src/backend/catalog.dart';
import 'package:modbus_desktop/src/backend/online.dart';
import 'package:modbus_desktop/src/backend/wire.dart';

import '../tool/webdav_fixture.dart';

Future<Map<String, dynamic>> finish(NativeOnline online) async {
  for (var i = 0; i < 1000; i++) {
    final status = await online.dispatch({'command': 'cloud_status'});
    if (status['running'] != true) return status;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  throw StateError('Cloud transfer did not finish');
}

void main() {
  test(
    'native HTTP aborts an active stream and never follows a redirect',
    () async {
      final root = await Directory.systemTemp.createTemp('native-dav-cancel-');
      final server = await startWebDavFixture(port: 0);
      final catalog = NativeCatalog(directory: root);
      final online = NativeOnline(catalog);
      final settings = {
        'url': 'http://127.0.0.1:${server.port}/dav',
        'username': 'operator',
        'password': 'test-only',
      };
      try {
        await online.dispatch({
          'command': 'cloud_start',
          'action': 'download',
          'settings': settings,
        });
        expect((await finish(online))['error'], null);
        for (final path in ['redirect', 'slow']) {
          await online.dispatch({
            'command': 'cloud_start',
            'action': 'download',
            'settings': {
              ...settings,
              'url': 'http://127.0.0.1:${server.port}/$path',
            },
          });
          if (path == 'slow') {
            await Future<void>.delayed(const Duration(milliseconds: 100));
            await online.dispatch({'command': 'cloud_cancel'});
          }
          final result = await finish(online)
              .timeout(const Duration(seconds: 3));
          expect(
            result['error'],
            path == 'slow' ? contains('cancelled') : contains('302'),
          );
          expect(
            await readJson(catalog.file('cloud_templates.json')),
            fixtureCatalog,
          );
        }
      } finally {
        await online.close();
        await server.close(force: true);
        await root.delete(recursive: true);
      }
    },
  );
  test(
    'cancellation before cache commit retains the old file and removes staging',
    () async {
      final root = await Directory.systemTemp.createTemp('native-dav-commit-');
      final file = File('${root.path}/cloud_templates.json');
      try {
        await atomicJson(file, {'old': true});
        await expectLater(
          atomicJson(
            file,
            fixtureCatalog,
            beforeCommit: () => throw const DavException('cancelled'),
          ),
          throwsA(isA<DavException>()),
        );
        expect(await readJson(file), {'old': true});
        expect((await root.list().toList()).map((f) => f.path), [file.path]);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
  test('read-only WebDAV consumes skill snapshots, preserves cache and isolates credentials', () async {
    final root = await Directory.systemTemp.createTemp('native-dav-'),
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    const version = '20261119T000000000001Z-deadbeef';
    final fixture = {
      'Acme/测试.json': {
        'name': '测试',
        'connection': {'type': 'RTU'},
        'registers': [
          {'address': 0, 'writable': false},
        ],
      },
    };
    final snapshot = jsonEncode({
      'schema': 1,
      'version': version,
      'templates': fixture,
    });
    final files = <String, String>{
      '/dav/templates/.catalog.json': snapshot,
      '/dav/templates/.versions/$version.json': snapshot,
    };
    final requests = <String>[];
    final authorization = <String?>[];
    final subscription = server.listen((request) async {
      try {
        final path = Uri.decodeComponent(request.uri.path)
            .replaceFirst(RegExp(r'/+$'), '');
        requests.add('${request.method} $path');
        authorization.add(request.headers.value('authorization'));
        if (request.method == 'GET') {
          if (files.containsKey(path)) {
            request.response.write(files[path]);
          } else {
            request.response.statusCode = 404;
          }
        } else if (request.method == 'PROPFIND') {
          request.response.statusCode = 207;
          request.response.headers.contentType = ContentType(
            'application',
            'xml',
          );
          request.response.write(
            '<d:multistatus xmlns:d="DAV:"><d:response><d:href>$path/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>',
          );
          for (final key in files.keys.where(
            (k) =>
                k.startsWith('$path/') &&
                !k.substring(path.length + 1).contains('/'),
          )) {
            request.response.write(
              '<d:response><d:href>$key</d:href><d:propstat><d:prop><d:resourcetype/></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>',
            );
          }
          request.response.write('</d:multistatus>');
        } else {
          request.response.statusCode = 405;
        }
        await request.response.close();
      } catch (_) {
        await request.response.close();
      }
    });
    final catalog = NativeCatalog(directory: root),
        online = NativeOnline(NativeCatalog(directory: root));
    final settings = {
      'url': 'http://127.0.0.1:${server.port}/dav',
      'username': 'operator', 'password': 'secret',
      'mode': 'publisher', // A legacy setting must never re-enable writes.
    };
    try {
      await online.dispatch({
        'command': 'cloud_settings_save',
        'settings': settings,
      });
      final saved = await readJson(catalog.file('cloud.json')) as Map;
      expect(saved.containsKey('password'), false);
      expect(saved.containsKey('mode'), false);
      for (final action in ['publish', 'activate', 'upload', 'delete']) {
        await expectLater(
          online.dispatch({
            'command': 'cloud_start',
            'action': action,
            'version': version,
            'settings': settings,
          }),
          throwsA(isA<DavException>()),
        );
      }
      expect(requests, isEmpty);
      for (final method in ['PUT', 'MKCOL', 'DELETE', 'MOVE', 'POST']) {
        await expectLater(
          online.cloud.request(settings, method, 'templates/test.json'),
          throwsA(isA<DavException>()),
        );
      }
      expect(requests, isEmpty);
      for (final action in ['test', 'versions', 'download']) {
        await online.dispatch({
          'command': 'cloud_start',
          'action': action,
          'settings': settings,
        });
        final result = await finish(online);
        expect(result['error'], isNull, reason: '$result');
        if (action == 'versions') {
          expect(result['result']['versions'], [version]);
        }
      }
      expect(await readJson(catalog.file('cloud_templates.json')), fixture);
      final loaded = await catalog.dispatch({
        'command': 'template_load',
        'resource': 'Acme/测试.json',
      });
      expect(loaded['state']['registers'][0]['writable'], false);
      files['/dav/templates/.catalog.json'] = '{broken';
      await online.dispatch({
        'command': 'cloud_start',
        'action': 'download',
        'settings': settings,
      });
      expect((await finish(online))['error'], isNotNull);
      expect(await readJson(catalog.file('cloud_templates.json')), fixture);
      await online.dispatch({
        'command': 'cloud_start',
        'action': 'download',
        'version': version,
        'settings': settings,
      });
      expect((await finish(online))['error'], isNull);
      expect(await readJson(catalog.file('cloud_templates.json')), fixture);
      expect(
        requests.every(
          (r) => r.startsWith('GET ') || r.startsWith('PROPFIND '),
        ),
        true,
      );
      expect(
        authorization,
        everyElement('Basic ${base64Encode(utf8.encode('operator:secret'))}'),
      );
      expect(
        files['/dav/templates/.catalog.json'],
        '{broken',
      ); // No server mutation.
      await online.dispatch({
        'command': 'cloud_settings_save',
        'settings': {...settings, 'remember_password': true},
      });
      expect(
        (await online.dispatch({
          'command': 'cloud_settings_load',
        }))['settings']['password'],
        'secret',
      );
    } finally {
      await online.close();
      await subscription.cancel();
      await server.close(force: true);
      await root.delete(recursive: true);
    }
  });
  test('Dart RTU over UDP validates CRC and source', () async {
    final server = await RawDatagramSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        ),
        client = ModbusClient();
    final sub = server.listen((event) {
      if (event == RawSocketEvent.read) {
        final packet = server.receive();
        if (packet == null) return;
        expect(
          crc16(packet.data.sublist(0, packet.data.length - 2)),
          packet.data[packet.data.length - 2] | packet.data.last << 8,
        );
        server.send(
          rtuFrame(packet.data[0], [3, 2, 0, 42]),
          packet.address,
          packet.port,
        );
      }
    });
    try {
      await client.connect({
        'transport': 'rtu_udp',
        'host': '127.0.0.1',
        'port': server.port,
        'timeout': 0.5,
      });
      expect(await client.read(1, 'holding_registers', 0, 1), [42]);
    } finally {
      await client.close();
      await sub.cancel();
      server.close();
    }
  });
  test('cloud paths and credentials reject redirects/traversal inputs', () {
    for (final url in [
      'file:///tmp/data',
      'https://user:pass@example.test',
      'https://example.test/?secret=yes',
      'https://example.test/%2e%2e/',
    ]) {
      expect(() => cloudSettings({'url': url}), throwsFormatException);
    }
    expect(() => relativePath('../templates'), throwsFormatException);
  });
}
