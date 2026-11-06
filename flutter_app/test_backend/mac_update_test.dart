import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:modbus_desktop/src/backend/mac_update.dart';
import 'package:modbus_desktop/src/backend/update.dart';
import 'package:test/test.dart';

import 'update_test.dart' show LoopbackClient;

void main() {
  test(
    'real universal signed bundle stages from a read-only DMG and rejects tampering',
    () async {
      final root = await Directory.systemTemp.createTemp('modbus-native-dmg-');
      addTearDown(() => root.delete(recursive: true));
      final source = await Directory('${root.path}/source').create();
      final bundle = Directory('${source.path}/$macApplicationName');
      final binaries = await Directory('${bundle.path}/Contents/MacOS')
          .create(recursive: true);
      final code = await File('${root.path}/main.c')
          .writeAsString('int main(void) { return 0; }');
      for (final arch in ['arm64', 'x86_64']) {
        await macCommand('/usr/bin/clang', [
          '-target',
          '$arch-apple-macos12',
          code.path,
          '-o',
          '${root.path}/$arch',
        ], () {});
      }
      await macCommand('/usr/bin/lipo', [
        '-create',
        '${root.path}/arm64',
        '${root.path}/x86_64',
        '-output',
        '${binaries.path}/Modbus Connector',
      ], () {});
      await File('${bundle.path}/Contents/Info.plist')
          .writeAsString('''<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$macBundleIdentifier</string>
<key>CFBundleExecutable</key><string>Modbus Connector</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.17.0</string>
</dict></plist>''');
      await macCommand('/usr/bin/codesign', [
        '--force',
        '--sign',
        '-',
        bundle.path,
      ], () {});
      await validateMacBundle(bundle, '0.17.0', () {});
      await expectLater(
        validateMacBundle(bundle, '0.18.0', () {}),
        throwsFormatException,
      );
      final image = File('${root.path}/update.dmg');
      await macCommand('/usr/bin/hdiutil', [
        'create',
        '-format',
        'UDZO',
        '-srcfolder',
        source.path,
        image.path,
      ], () {});
      final work = await Directory('${root.path}/work').create();
      await stageMacUpdate(work, image, '0.17.0', () {});
      expect(
        await File(
          '${work.path}/$macApplicationName/Contents/MacOS/Modbus Connector',
        ).exists(),
        true,
      );
      await File('${bundle.path}/Contents/Info.plist')
          .writeAsString('\n', mode: FileMode.append);
      await expectLater(
        validateMacBundle(bundle, '0.17.0', () {}),
        throwsA(isA<FileSystemException>()),
      );
    },
    skip: !Platform.isMacOS,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  final bytes = [
    ...List.filled(1024, 0),
    ...'koly'.codeUnits,
    ...List.filled(508, 0),
  ];
  const version = '0.17.0';
  const name = 'modbus-connector-flutter-$version-macos-universal.dmg';
  const url =
      'https://github.com/$updateRepository/releases/download/v$version/$name';
  final digest = sha256.convert(bytes).toString();
  Map<String, dynamic> release({String assetName = name}) => {
    'tag_name': 'v$version',
    'draft': false,
    'prerelease': false,
    'body': '',
    'assets': [
      {
        'name': assetName,
        'state': 'uploaded',
        'browser_download_url': url,
        'size': bytes.length,
        'digest': 'sha256:$digest',
      },
    ],
  };

  test(
    'macOS requires the matching universal DMG and preserves platform metadata',
    () {
      final asset = InstallerAsset.fromRelease(release(), platform: 'macos')!;
      expect(InstallerAsset.fromJson(asset.toJson()).platform, 'macos');
      expect(asset.version, version);
      expect(InstallerAsset.fromRelease(release()), isNull);
      expect(
        InstallerAsset.fromRelease(
          release(assetName: 'macos-arm64.dmg'),
          platform: 'macos',
        ),
        isNull,
      );
      expect(
        releaseResult(
          release(),
          '0.16.0',
          platform: 'macos',
          executable: 'installed',
        )['install_supported'],
        true,
      );
      expect(
        releaseResult(
          release(),
          '0.16.0',
          platform: 'macos',
        )['install_supported'],
        false,
      );
      expect(
        () => InstallerAsset.fromJson({...asset.toJson(), 'version': '0.18.0'}),
        throwsFormatException,
      );
      expect(
        () => InstallerAsset.fromJson({...asset.toJson(), 'platform': 'other'}),
        throwsFormatException,
      );
    },
  );

  for (final valid in [true, false]) {
    test('DMG streaming verifies UDIF trailer: valid=$valid', () async {
      final payload = [...bytes];
      if (!valid) payload[payload.length - 512] = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.add(payload);
        await request.response.close();
      });
      final directory = await Directory.systemTemp.createTemp(
        'modbus-dmg-test-',
      );
      addTearDown(() async {
        await server.close(force: true);
        await directory.delete(recursive: true);
      });
      final asset = InstallerAsset(
        Uri.parse(url),
        payload.length,
        sha256.convert(payload).toString(),
        platform: 'macos',
        version: version,
      );
      final file = File('${directory.path}/update.dmg');
      final operation = UpdateInstaller(
        clientFactory: () => LoopbackClient(server),
      ).download(asset, file, (_) {});
      if (valid) {
        await operation;
        expect(await file.readAsBytes(), payload);
      } else {
        await expectLater(operation, throwsFormatException);
        expect(await file.exists(), false);
      }
      expect(await File('${file.path}.part').exists(), false);
    });
  }

  test('native command cancellation reaps the child promptly', () async {
    var cancelled = false;
    final timer = Timer(
      const Duration(milliseconds: 150),
      () => cancelled = true,
    );
    addTearDown(timer.cancel);
    final watch = Stopwatch()..start();
    await expectLater(
      macCommand('/bin/sleep', ['30'], () {
        if (cancelled) throw const UpdateCancelled();
      }),
      throwsA(isA<UpdateCancelled>()),
    );
    expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
  }, skip: !Platform.isMacOS);

  test('bundle validation rejects links escaping the application', () async {
    final root = await Directory.systemTemp.createTemp('modbus-links-');
    addTearDown(() => root.delete(recursive: true));
    final app = await Directory('${root.path}/App.app').create();
    await Link('${app.path}/external').create(root.path);
    await expectLater(
      validateMacBundle(app, version, () {}),
      throwsFormatException,
    );
  }, skip: !Platform.isMacOS);

  for (final scenario in ['abort', 'success', 'launch failure']) {
    test('macOS handoff: $scenario', () async {
      final root = await Directory.systemTemp.createTemp(
        "modbus handoff 'test-",
      );
      addTearDown(() => root.delete(recursive: true));
      final app = await Directory('${root.path}/$macApplicationName').create();
      await File('${app.path}/old').writeAsString('old');
      final work = await Directory('${root.path}/work').create();
      final stage = await Directory('${work.path}/$macApplicationName')
          .create();
      await File('${stage.path}/new').writeAsString('new');
      final parent = await Process.start('/bin/sleep', ['30']);
      addTearDown(() async {
        parent.kill();
        await parent.exitCode;
      });
      // Mock only signature validation and application launch; execute the real
      // handshake, process wait, quoted paths, rename and rollback on macOS.
      final script = macUpdaterScript(work, app, parent.pid)
          .replaceAll('/usr/bin/codesign', '/usr/bin/true')
          .replaceAll(
            '/usr/bin/open',
            scenario == 'launch failure' ? '/usr/bin/false' : '/usr/bin/true',
          );
      final file = await File('${work.path}/install.sh').writeAsString(script);
      final helper = await Process.start('/bin/bash', [file.path]);
      helper.stdout.drain<void>();
      helper.stderr.drain<void>();
      addTearDown(() async {
        helper.kill();
        await helper.exitCode;
      });
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!await File('${work.path}/ready').exists()) {
        if (DateTime.now().isAfter(deadline)) {
          fail('Helper did not become ready');
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      if (scenario != 'abort') {
        await File('${work.path}/commit').writeAsString('install');
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(await File('${app.path}/old').exists(), true);
      }
      parent.kill();
      await parent.exitCode;
      final code = await helper.exitCode.timeout(const Duration(seconds: 5));
      if (scenario == 'success') {
        expect(code, 0);
        expect(await File('${app.path}/new').exists(), true);
        expect(await File('${work.path}/previous.app/old').exists(), true);
      } else {
        expect(code, isNot(0));
        expect(await File('${app.path}/old').exists(), true);
        expect(await File('${work.path}/error.txt').exists(), true);
      }
    }, skip: !Platform.isMacOS);
  }
}
