import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';

import 'settings_store.dart';

/// One writer per isolate/process; no open handles survive a clear operation.
class Diagnostics {
  Diagnostics(
    this.root, {
    String role = 'ui',
    this.maxBytes = 2 * 1024 * 1024,
    bool includeSystemDumps = true,
  }) : crashDumps = includeSystemDumps ? windowsDumps : null,
       name = 'app-$pid-${DateTime.now().microsecondsSinceEpoch}-$role';
  static Diagnostics? current;
  final Directory root;
  final Directory? crashDumps;
  final String name;
  final int maxBytes;
  String? lastError;
  Directory get logs => Directory('${root.path}/logs');

  static void initialize({String role = 'ui', String? directory}) {
    current = Diagnostics(
      directory == null ? SettingsStore().directory : Directory(directory),
      role: role,
    );
    current!.write(
      'startup',
      'version=${const String.fromEnvironment('APP_VERSION', defaultValue: 'development')} '
          'os=${Platform.operatingSystemVersion} dart=${Platform.version}',
    );
  }

  void write(String category, String message, [StackTrace? stack]) {
    try {
      logs.createSync(recursive: true);
      final file = File('${logs.path}/$name.jsonl');
      if (file.existsSync() && file.lengthSync() >= maxBytes) {
        final older = File('${file.path}.1');
        if (older.existsSync()) older.deleteSync();
        file.renameSync(older.path);
      }
      // Limit individual events too. Do not record command payloads/passwords.
      final line = jsonEncode({
        'time': DateTime.now().toIso8601String(),
        'pid': pid,
        'category': category,
        'message': message.length > 16384
            ? message.substring(0, 16384)
            : message,
        if (stack != null)
          'stack': stack.toString().substring(
            0,
            stack.toString().length.clamp(0, 16384),
          ),
      });
      file.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
      // Bound files across previous launches and worker isolates as well.
      final files = logFiles()
        ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
      for (final old in files.skip(32)) {
        old.deleteSync();
      }
      lastError = null;
    } catch (e) {
      // Diagnostics must never break communication or recursively log failures.
      lastError = '$e';
    }
  }

  List<File> logFiles() => !logs.existsSync()
      ? []
      : logs
            .listSync(followLinks: false)
            .whereType<File>()
            .where(
              (f) =>
                  RegExp(r'^app-[\w-]+\.jsonl(?:\.1)?$')
                      .hasMatch(f.uri.pathSegments.last),
            )
            .toList();

  static Directory? get windowsDumps =>
      Platform.isWindows && Platform.environment['LOCALAPPDATA'] != null
      ? Directory('${Platform.environment['LOCALAPPDATA']}/CrashDumps')
      : null;

  static List<File> dumpFiles(Directory? directory) =>
      directory == null || !directory.existsSync()
      ? []
      : directory
            .listSync(followLinks: false)
            .whereType<File>()
            .where(
              (f) => RegExp(
                r'^modbus_desktop\.exe(?:\(\d+\))?\.\d+\.dmp$',
                caseSensitive: false,
              ).hasMatch(f.uri.pathSegments.last),
            )
            .toList();

  Future<void> export(String path) {
    final rootPath = root.path, dumpPath = crashDumps?.path;
    final error = lastError;
    return Isolate.run(
      () => Diagnostics(Directory(rootPath)).exportBundle(
        path,
        dumps: dumpPath == null ? null : Directory(dumpPath),
        collectWindowsEvents: Platform.isWindows,
        loggingError: error,
      ),
    );
  }

  /// Public seam for archive tests without reading the user's Windows profile.
  Future<void> exportBundle(
    String path, {
    Directory? dumps,
    bool collectWindowsEvents = false,
    String? loggingError,
  }) async {
    final target = File(path).absolute;
    if (target.path.startsWith(
          '${logs.absolute.path}${Platform.pathSeparator}',
        ) ||
        (dumps != null &&
            target.path.startsWith(
              '${dumps.absolute.path}${Platform.pathSeparator}',
            ))) {
      throw const FormatException(
        'Choose an export location outside the log directory',
      );
    }
    final stage = await Directory.systemTemp.createTemp('modbus-diagnostics-');
    final notes = <String>[
      'Modbus Connector diagnostics',
      'Exported: ${DateTime.now().toIso8601String()}',
      'Contains application logs and available native crash dumps.',
      'Windows events are a snapshot; clearing logs does not clear system events.',
      'Crash dumps may contain process memory. Review before sharing.',
      if (loggingError != null) 'Log write error: $loggingError',
    ];
    try {
      final zip = ZipFileEncoder()..create('${stage.path}/diagnostics.zip');
      try {
        for (final group in {
          'logs': logFiles(),
          'crash-dumps': dumpFiles(dumps),
        }.entries) {
          for (final file in group.value) {
            // Snapshot before compression: other isolates can rotate or clear.
            try {
              final snapshot = File(
                '${stage.path}/${file.uri.pathSegments.last}',
              );
              await file.copy(snapshot.path);
              await zip.addFile(
                snapshot,
                '${group.key}/${file.uri.pathSegments.last}',
              );
            } on FileSystemException catch (e) {
              notes.add('Skipped ${file.uri.pathSegments.last}: $e');
            }
          }
        }
        if (collectWindowsEvents) {
          try {
            final env = Map<String, String>.from(Platform.environment)
              ..removeWhere((key, _) => key.toLowerCase() == 'psmodulepath');
            final process = await Process.start(
              'powershell.exe',
              [
                '-NoProfile',
                '-NonInteractive',
                '-Command',
                r'''[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; Get-WinEvent -FilterHashtable @{LogName='Application';Id=1000,1001;StartTime=(Get-Date).AddDays(-14)} -ErrorAction Stop | Where-Object {$_.Message -match 'modbus_desktop\.exe'} | Select-Object TimeCreated,Id,Message | ConvertTo-Json -Depth 3''',
              ],
              environment: env,
              includeParentEnvironment: false,
            );
            final stdout = process.stdout.transform(utf8.decoder).join();
            final stderr = process.stderr.transform(utf8.decoder).join();
            final code = await process.exitCode.timeout(
              const Duration(seconds: 20),
              onTimeout: () {
                process.kill();
                return -1;
              },
            );
            final output = await stdout, errors = await stderr;
            if (code != 0) notes.add('Windows event query ($code): $errors');
            final events = File('${stage.path}/windows-events.json');
            await events.writeAsString(output.isEmpty ? '[]' : output);
            await zip.addFile(events, 'windows-events.json');
          } catch (e) {
            notes.add('Windows events unavailable: $e');
          }
        }
        final readme = File('${stage.path}/README.txt');
        await readme.writeAsString(notes.join('\n'));
        await zip.addFile(readme, 'README.txt');
      } finally {
        await zip.close();
      }
      await File('${stage.path}/diagnostics.zip').copy(target.path);
    } finally {
      await stage.delete(recursive: true);
    }
  }

  void clear({Directory? dumps}) {
    for (final file in [...logFiles(), ...dumpFiles(dumps)]) {
      file.deleteSync();
    }
    lastError = null;
  }
}
