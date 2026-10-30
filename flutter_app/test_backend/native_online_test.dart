import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:modbus_desktop/src/backend/catalog.dart';
import 'package:modbus_desktop/src/backend/online.dart';
import 'package:modbus_desktop/src/backend/wire.dart';

Future<Map<String, dynamic>> finish(NativeOnline online) async {
  for (var i = 0; i < 1000; i++) {
    final status = await online.dispatch({'command': 'cloud_status'});
    if (status['running'] != true) return status;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  throw StateError('Cloud transfer did not finish');
}

void main() {
  test('Dart WebDAV snapshots history cache and credential isolation', () async {
    final root = await Directory.systemTemp.createTemp('native-dav-'),
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final files = <String, String>{};
    final requests = <String>[];
    final subscription = server.listen((request) async {
      try {
        final path = Uri.decodeComponent(request.uri.path)
            .replaceFirst(RegExp(r'/+$'), '');
        requests.add('${request.method} $path');
        if (request.method == 'PUT') {
          files[path] = await utf8.decoder.bind(request).join();
          request.response.statusCode = 201;
        } else if (request.method == 'MKCOL') {
          request.response.statusCode = 201;
        } else if (request.method == 'GET') {
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
      'username': 'operator',
      'password': 'secret',
      'mode': 'publisher',
    };
    final fixture = {
      'Acme/测试.json': {
        'name': '测试',
        'connection': {'type': 'RTU'},
        'registers': [
          {'address': 0},
        ],
      },
    };
    try {
      await atomicJson(catalog.file('cloud_templates.json'), fixture);
      await online.dispatch({
        'command': 'cloud_settings_save',
        'settings': settings,
      });
      expect(
        (await readJson(catalog.file('cloud.json')) as Map).containsKey(
          'password',
        ),
        false,
      );
      await online.dispatch({
        'command': 'cloud_start',
        'action': 'publish',
        'settings': settings,
      });
      final published = await finish(online);
      expect(published['error'], isNull, reason: '$published');
      final version = published['result']['version'];
      expect(files.keys, contains('/dav/templates/.versions/$version.json'));
      expect(files.keys, contains('/dav/templates/.catalog.json'));
      await online.dispatch({
        'command': 'cloud_start',
        'action': 'versions',
        'settings': settings,
      });
      expect((await finish(online))['result']['versions'], [version]);
      final consumer = {...settings, 'mode': 'consumer'},
          before = requests.length;
      await expectLater(
        online.dispatch({
          'command': 'cloud_start',
          'action': 'publish',
          'settings': consumer,
        }),
        throwsA(isA<DavException>()),
      );
      expect(requests.length, before);
      await online.dispatch({
        'command': 'cloud_start',
        'action': 'download',
        'settings': consumer,
      });
      expect((await finish(online))['error'], isNull);
      expect(await readJson(catalog.file('cloud_templates.json')), fixture);
      files['/dav/templates/.catalog.json'] = '{broken';
      await online.dispatch({
        'command': 'cloud_start',
        'action': 'download',
        'settings': consumer,
      });
      expect((await finish(online))['error'], isNotNull);
      expect(await readJson(catalog.file('cloud_templates.json')), fixture);
      await online.dispatch({
        'command': 'cloud_start',
        'action': 'activate',
        'version': version,
        'settings': settings,
      });
      expect((await finish(online))['error'], isNull);
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
