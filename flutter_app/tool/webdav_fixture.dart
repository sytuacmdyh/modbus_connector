// Local read-only WebDAV fixture for browser/native acceptance. No real accounts
// or uploaded templates are used. Run: dart run tool/webdav_fixture.dart [port]
import 'dart:async';
import 'dart:convert';
import 'dart:io';

const fixtureVersion = '20261119T000000000001Z-deadbeef';
final fixtureCatalog = {
  'Acme/WebDAV.json': {
    'name': 'WebDAV acceptance device',
    'description': 'Read-only synchronization fixture',
    'connection': {'transport': 'demo'},
    'registers': [
      {'name': 'Server setpoint', 'address': 0, 'format': 'u16'},
      {'name': 'Read-only status', 'address': 1, 'writable': false},
    ],
  },
};

String directory(String root, List<(String, bool)> entries) =>
    '<d:multistatus xmlns:d="DAV:">${[(root, true), ...entries].map((entry) => '<d:response><d:href>${Uri(path: entry.$1).toString()}</d:href><d:propstat><d:prop><d:resourcetype>${entry.$2 ? '<d:collection/>' : ''}</d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>').join()}</d:multistatus>';

Future<HttpServer> startWebDavFixture({int port = 18867}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  final requests = <Map<String, dynamic>>[];
  server.listen((request) async {
    final response = request.response;
    final path = Uri.decodeComponent(request.uri.path);
    try {
      final origin = request.headers.value('origin');
      final uri = origin == null ? null : Uri.tryParse(origin);
      if (!path.startsWith('/nocors/') &&
          uri != null &&
          uri.scheme == 'http' &&
          ['localhost', '127.0.0.1'].contains(uri.host)) {
        response.headers.set('Access-Control-Allow-Origin', origin!);
        response.headers.set('Vary', 'Origin');
        response.headers.set(
          'Access-Control-Allow-Methods',
          'GET, PROPFIND, OPTIONS',
        );
        response.headers.set(
          'Access-Control-Allow-Headers',
          'Authorization, Cache-Control, Content-Type, Depth',
        );
      }
      response.headers.contentType = ContentType.json;
      if (request.method == 'OPTIONS') {
        response.statusCode = 204;
        return;
      }
      if (path == '/healthz') {
        response.write('ok');
        return;
      }
      if (path == '/requests') {
        response.write(jsonEncode(requests));
        return;
      }
      requests.add({'method': request.method, 'path': path});
      if (!['GET', 'PROPFIND'].contains(request.method)) {
        response.statusCode = 405;
        return;
      }
      if (path.startsWith('/unauthorized/') ||
          request.headers.value('authorization') !=
              'Basic ${base64Encode(utf8.encode('operator:test-only'))}') {
        response.statusCode = 401;
        return;
      }
      if (path.startsWith('/redirect/')) {
        response.statusCode = 302;
        response.headers.set('Location', '/dav/templates/.catalog.json');
        return;
      }
      if (path.startsWith('/slow/')) {
        response.write('{');
        await response.flush();
        await Future<void>.delayed(const Duration(seconds: 5));
        response.write('}');
        return;
      }
      if (path.startsWith('/huge/')) {
        for (var i = 0; i < 17; i++) {
          response.add(List.filled(1024 * 1024, 32));
          await response.flush();
        }
        return;
      }
      if (path.startsWith('/bad/')) {
        response.write('{broken');
        return;
      }
      if (request.method == 'PROPFIND') {
        response.statusCode = 207;
        response.headers.contentType = ContentType('application', 'xml');
        final root = path.endsWith('/') ? path : '$path/';
        response.write(
          directory(
            root,
            path.contains('.versions')
                ? [('$root$fixtureVersion.json', false)]
                : path == '/legacy/templates/'
                ? [('/legacy/templates/Acme/', true)]
                : path == '/legacy/templates/Acme/'
                ? [('/legacy/templates/Acme/WebDAV.json', false)]
                : [],
          ),
        );
      } else if (path == '/legacy/templates/.catalog.json') {
        response.statusCode = 404;
      } else if (path == '/legacy/templates/Acme/WebDAV.json') {
        response.write(jsonEncode(fixtureCatalog.values.first));
      } else if (path.endsWith('/templates/.catalog.json') ||
          path.endsWith('/.versions/$fixtureVersion.json')) {
        response.write(
          jsonEncode({
            'schema': 1,
            'version': fixtureVersion,
            'templates': fixtureCatalog,
          }),
        );
      } else {
        response.statusCode = 404;
      }
    } catch (_) {
      // Browser cancellation intentionally closes responses while streaming.
    } finally {
      try {
        await response.close();
      } catch (_) {}
    }
  });
  return server;
}

Future<void> main(List<String> arguments) async {
  final server = await startWebDavFixture(
    port: arguments.isEmpty ? 18867 : int.parse(arguments.single),
  );
  stdout.writeln(
    'Read-only WebDAV fixture: http://127.0.0.1:${server.port}/dav',
  );
  ProcessSignal.sigint.watch().listen((_) async {
    await server.close(force: true);
    exit(0);
  });
  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen((_) async {
      await server.close(force: true);
      exit(0);
    });
  }
}
