import 'dart:async';
import 'dart:convert';
import 'dart:io';

const macBundleIdentifier = 'com.modbusconnector.modbusDesktop';
const macApplicationName = 'Modbus Connector.app';

/// Bounded, cancellable native commands; cancellation also reaps the process.
Future<String> macCommand(
  String executable,
  List<String> arguments,
  void Function() checkCancel, {
  Duration timeout = const Duration(seconds: 120),
}) async {
  checkCancel();
  final process = await Process.start(executable, arguments);
  final stdout = process.stdout.transform(utf8.decoder).join();
  final stderr = process.stderr.transform(utf8.decoder).join();
  int? result;
  final exited = process.exitCode.then((value) => result = value);
  final deadline = DateTime.now().add(timeout);
  try {
    while (result == null) {
      checkCancel();
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('macOS update command timed out.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    checkCancel();
    final error = await stderr;
    if (result != 0) throw FileSystemException('$executable: $error');
    return (await stdout).trim();
  } finally {
    if (result == null) process.kill(ProcessSignal.sigkill);
    await exited;
    await stdout;
    await stderr;
  }
}

Future<String> macPlistValue(
  String plist,
  String key, [
  void Function()? checkCancel,
]) => macCommand('/usr/bin/plutil', [
  '-extract',
  key,
  'raw',
  '-o',
  '-',
  plist,
], checkCancel ?? () {});

Future<String?> installedMacExecutable() async {
  if (!Platform.isMacOS) return null;
  final executable = File(Platform.resolvedExecutable).absolute;
  final bundle = executable.parent.parent.parent;
  final home = Platform.environment['HOME'];
  final allowed = {
    '/Applications/$macApplicationName',
    if (home != null) '$home/Applications/$macApplicationName',
  };
  if (!allowed.contains(bundle.path) ||
      executable.path != '${bundle.path}/Contents/MacOS/Modbus Connector') {
    return null;
  }
  try {
    if (await bundle.resolveSymbolicLinks() != bundle.path ||
        await macPlistValue(
              '${bundle.path}/Contents/Info.plist',
              'CFBundleIdentifier',
            ) !=
            macBundleIdentifier) {
      return null;
    }
    // Same-volume staging and renames require a writable parent.
    final probe = await bundle.parent.createTemp('.modbus-write-check-');
    await probe.delete();
    return executable.path;
  } on Exception {
    return null;
  }
}

Future<void> validateMacBundle(
  Directory bundle,
  String version,
  void Function() checkCancel,
) async {
  if (await FileSystemEntity.type(bundle.path, followLinks: false) !=
      FileSystemEntityType.directory) {
    throw const FormatException('Update application is missing or is a link.');
  }
  final root = await bundle.resolveSymbolicLinks();
  var total = 0;
  var binaries = 0;
  await for (final entry in bundle.list(recursive: true, followLinks: false)) {
    checkCancel();
    if (entry is Link) {
      final target = await entry.resolveSymbolicLinks();
      if (!target.startsWith('$root/')) {
        throw const FormatException(
          'Update contains an external symbolic link.',
        );
      }
    } else if (entry is File) {
      total += await entry.length();
      if (total > 2 * 1024 * 1024 * 1024) {
        throw const FormatException('Update application is too large.');
      }
      final type = await macCommand('/usr/bin/file', [
        '-b',
        entry.path,
      ], checkCancel);
      if (type.contains('Mach-O')) {
        await macCommand('/usr/bin/lipo', [
          entry.path,
          '-verify_arch',
          'arm64',
          'x86_64',
        ], checkCancel);
        binaries++;
      }
    }
  }
  final plist = '$root/Contents/Info.plist';
  if (binaries == 0 ||
      await macPlistValue(plist, 'CFBundleIdentifier', checkCancel) !=
          macBundleIdentifier ||
      await macPlistValue(plist, 'CFBundleShortVersionString', checkCancel) !=
          version ||
      await macPlistValue(plist, 'CFBundleExecutable', checkCancel) !=
          'Modbus Connector') {
    throw const FormatException(
      'Update application identity or version mismatch.',
    );
  }
  final executable = '$root/Contents/MacOS/Modbus Connector';
  await macCommand('/usr/bin/lipo', [
    executable,
    '-verify_arch',
    'arm64',
    'x86_64',
  ], checkCancel);
  await macCommand('/usr/bin/codesign', [
    '--verify',
    '--deep',
    '--strict',
    root,
  ], checkCancel);
}

Future<void> stageMacUpdate(
  Directory work,
  File image,
  String version,
  void Function() checkCancel,
) async {
  // Mount outside work so abort cleanup can never traverse a mounted volume.
  final mount = await Directory.systemTemp.createTemp('modbus-update-volume-');
  try {
    await macCommand('/usr/bin/hdiutil', [
      'attach',
      '-readonly',
      '-nobrowse',
      '-noautoopen',
      '-quiet',
      '-mountpoint',
      mount.path,
      image.path,
    ], checkCancel);
    final source = Directory('${mount.path}/$macApplicationName');
    await validateMacBundle(source, version, checkCancel);
    final staged = Directory('${work.path}/$macApplicationName');
    await macCommand('/usr/bin/ditto', [source.path, staged.path], checkCancel);
    await validateMacBundle(staged, version, checkCancel);
  } finally {
    // Detach even if attach completed just as cancellation was requested.
    try {
      await macCommand(
        '/usr/bin/hdiutil',
        ['detach', '-force', mount.path],
        () {},
        timeout: const Duration(seconds: 30),
      );
    } on Exception {
      if (await mount.exists() && !await mount.list().isEmpty) {
        throw FileSystemException('Could not detach update image', mount.path);
      }
    }
    if (await mount.exists()) await mount.delete();
  }
}

String shellLiteral(String value) => "'${value.replaceAll("'", "'\"'\"'")}'";

/// The old bundle remains recoverable in work until the new app is launched.
String macUpdaterScript(Directory work, Directory destination, int parentPid) =>
    '''#!/bin/bash
set -euo pipefail
work=${shellLiteral(work.path)}
destination=${shellLiteral(destination.path)}
staged="\$work/$macApplicationName"
backup="\$work/previous.app"
replaced=0
finish() {
  code=\$?
  if [ "\$code" -ne 0 ]; then
    if [ -d "\$backup" ]; then
      if [ "\$replaced" -eq 1 ]; then /bin/mv "\$destination" "\$work/failed.app" || true; fi
      /bin/mv "\$backup" "\$destination" || true
    fi
    echo 'Update failed. The previous application was retained. See this directory for recovery files.' > "\$work/error.txt"
  fi
}
trap finish EXIT
/usr/bin/touch "\$work/ready"
deadline=\$((SECONDS + 120))
while [ ! -f "\$work/commit" ]; do
  kill -0 $parentPid 2>/dev/null || exit 1
  [ "\$SECONDS" -lt "\$deadline" ] || exit 1
  /bin/sleep 0.1
done
deadline=\$((SECONDS + 120))
while kill -0 $parentPid 2>/dev/null; do
  [ "\$SECONDS" -lt "\$deadline" ] || exit 1
  /bin/sleep 0.1
done
# A second instance must not keep running from the bundle being replaced.
while IFS= read -r command; do
  [ "\$command" != "\$destination/Contents/MacOS/Modbus Connector" ] || exit 1
done < <(/bin/ps -axo comm=)
[ -d "\$destination" ] && [ ! -L "\$destination" ]
/usr/bin/codesign --verify --deep --strict "\$staged"
/bin/mv "\$destination" "\$backup"
/bin/mv "\$staged" "\$destination"
replaced=1
/usr/bin/open -n "\$destination"
# Keep the prior version for explicit recovery; do not erase user files.
/usr/bin/touch "\$work/complete"
''';
