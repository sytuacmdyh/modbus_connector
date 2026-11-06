import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:test/test.dart';
import 'package:modbus_desktop/src/diagnostics.dart';

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('diagnostics-test-'));
  tearDown(() => root.deleteSync(recursive: true));
  test(
    'logs survive new instances, rotate, export and clear only owned files',
    () async {
      final log = Diagnostics(root, maxBytes: 150);
      log.write('error', 'first', StackTrace.current);
      log.write('session', 'second');
      expect(log.logFiles().length, 2);
      final dumpDir = Directory('${root.path}/dumps')..createSync();
      File('${dumpDir.path}/modbus_desktop.exe.42.dmp')
          .writeAsBytesSync([1, 2, 3]);
      final unrelated = File('${dumpDir.path}/other.exe.42.dmp')
        ..writeAsStringSync('keep');
      final settings = File('${root.path}/settings.json')
        ..writeAsStringSync('keep');
      final reloaded = Diagnostics(root);
      final out = '${root.path}/export.zip';
      await reloaded.exportBundle(out, dumps: dumpDir);
      final archive = ZipDecoder().decodeBytes(File(out).readAsBytesSync());
      expect(archive.files.where((f) => f.name.startsWith('logs/')).length, 2);
      expect(
        archive.findFile('crash-dumps/modbus_desktop.exe.42.dmp')!.content,
        [1, 2, 3],
      );
      expect(
        archive.files.any(
          (f) => f.name.contains('settings') || f.name.contains('other.exe'),
        ),
        false,
      );
      reloaded.clear(dumps: dumpDir);
      expect(reloaded.logFiles(), isEmpty);
      expect(unrelated.readAsStringSync(), 'keep');
      expect(settings.readAsStringSync(), 'keep');
      log.write('session', 'after clear');
      expect(
        jsonDecode(log.logFiles().single.readAsStringSync())['message'],
        'after clear',
      );
    },
  );
  test('file I/O failure never escapes into app', () {
    final file = File('${root.path}/file')..writeAsStringSync('x');
    final log = Diagnostics(Directory(file.path));
    log.write('error', 'event');
    expect(log.lastError, isNotNull);
  });
  test('export excludes symlinks and rejects internal destination', () async {
    final log = Diagnostics(root)..write('session', 'hello');
    if (!Platform.isWindows) {
      final secret = File('${root.path}/secret')..writeAsStringSync('secret');
      Link('${log.logs.path}/app-secret.jsonl').createSync(secret.path);
      expect(log.logFiles().length, 1);
    }
    await expectLater(
      log.exportBundle('${log.logs.path}/out.zip'),
      throwsFormatException,
    );
  });
}
