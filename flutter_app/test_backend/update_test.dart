import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:modbus_desktop/src/backend/update.dart';
import 'package:test/test.dart';

// Keep production URL validation while exercising real streaming sockets locally.
class LoopbackClient implements HttpClient {
  LoopbackClient(this.server);
  final HttpServer server;
  final client = HttpClient();
  @override
  Future<HttpClientRequest> getUrl(Uri url) =>
      client.getUrl(Uri.parse('http://127.0.0.1:${server.port}${url.path}'));
  @override
  void close({bool force = false}) => client.close(force: force);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final payload = [77, 90, ...List.generate(512, (i) => i % 256)];
  final digest = sha256.convert(payload).toString();
  const tag = 'v0.17.0';
  const name = 'modbus-connector-flutter-0.17.0-windows-x64-setup.exe';
  const url =
      'https://github.com/$updateRepository/releases/download/$tag/$name';
  Map<String, dynamic> release([Map<String, dynamic> asset = const {}]) => {
    'tag_name': tag,
    'draft': false,
    'prerelease': false,
    'body': 'Release notes',
    'assets': [
      {
        'name': name,
        'state': 'uploaded',
        'browser_download_url': url,
        'size': payload.length,
        'digest': 'sha256:$digest',
        ...asset,
      },
    ],
  };

  test(
    'stable Flutter installer requires matching name URL size and digest',
    () {
      expect(
        releaseResult(
          release(),
          '0.16.3',
          executable: 'installed',
        )['install_supported'],
        true,
      );
      expect(
        releaseResult(release(), '0.17.0', executable: 'installed')['newer'],
        false,
      );
      expect(releaseResult(release(), '0.9.0-beta.1')['newer'], true);
      expect(releaseResult(release(), '0.18.0')['newer'], false);
      expect(releaseResult(release(), '0.16.3')['install_supported'], false);
      for (final invalid in [
        {'name': 'modbus-connector-0.17.0-windows-x64-setup.exe'},
        {'browser_download_url': 'https://evil.example/setup.exe'},
        {'size': 0},
        {'size': 1.5},
        {'size': 1024 * 1024 * 1024 + 1},
        {'digest': null},
        {'digest': 'sha256:abc'},
        {'state': 'new'},
      ]) {
        expect(InstallerAsset.fromRelease(release(invalid)), isNull);
        expect(
          releaseResult(
            release(invalid),
            '0.16.3',
            executable: 'installed',
          )['install_supported'],
          false,
        );
      }
      for (final invalid in [
        {'draft': true},
        {'prerelease': true},
        {'tag_name': 'v1.0.0-beta.1'},
        {'body': []},
      ]) {
        expect(
          () => releaseResult({...release(), ...invalid}, '0.16.3'),
          throwsFormatException,
        );
      }
    },
  );

  test('unsafe download URLs rejected before opening a connection', () async {
    for (final value in [
      'http://github.com/setup.exe',
      'https://github.com.evil.example/setup.exe',
      'https://github.com@evil.example/setup.exe',
      'https://github.com:444/setup.exe',
      'https://evil@github.com/setup.exe',
    ]) {
      expect(
        () => validateInstallerUrl(Uri.parse(value)),
        throwsFormatException,
      );
    }
  });

  for (final mode in [
    'valid',
    'truncated',
    'oversized',
    'digest',
    'magic',
    'redirect',
    'cancel',
  ]) {
    test('download $mode verifies streams and cleans partial files', () async {
      final dir = await Directory.systemTemp.createTemp('update-download-');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final installer = UpdateInstaller(
        clientFactory: () => LoopbackClient(server),
      );
      final body = mode == 'magic' ? [0, 0, ...payload.skip(2)] : payload;
      server.listen((request) async {
        try {
          if (mode == 'redirect') {
            request.response.statusCode = 302;
            request.response.headers.set(
              'location',
              'https://evil.example/setup.exe',
            );
          } else {
            request.response.add(
              mode == 'truncated'
                  ? body.sublist(0, body.length - 1)
                  : mode == 'oversized'
                  ? [...body, 0]
                  : body,
            );
          }
          await request.response.close();
        } catch (_) {
          /* cancellation may close the socket */
        }
      });
      final target = File('${dir.path}/setup.exe');
      final asset = InstallerAsset(
        Uri.parse(url),
        payload.length,
        mode == 'digest' ? '0' * 64 : sha256.convert(body).toString(),
      );
      try {
        final download = installer.download(asset, target, (_) {
          if (mode == 'cancel') installer.cancel();
        });
        if (mode == 'valid') {
          await download;
          expect(await target.readAsBytes(), payload);
        } else {
          await expectLater(
            download,
            mode == 'cancel'
                ? throwsA(isA<UpdateCancelled>())
                : throwsFormatException,
          );
          expect(await target.exists(), false);
        }
        expect(await File('${target.path}.part').exists(), false);
      } finally {
        installer.cancel();
        await server.close(force: true);
        await dir.delete(recursive: true);
      }
    });
  }
}
