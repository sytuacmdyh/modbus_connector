import 'dart:io';

import 'package:path/path.dart' as p;

/// Build a standalone host for this OS/architecture with the matching library.
Future<void> main(List<String> arguments) async {
  if (arguments.length != 1 || !File(arguments.single).existsSync()) {
    stderr.writeln(
      'Usage: dart run tool/package_service.dart /absolute/path/to/native/libserialport',
    );
    exitCode = 1;
    return;
  }
  final output = Directory('build/dart-service');
  await output.create(recursive: true);
  final executable = p.join(
    output.path,
    Platform.isWindows ? 'modbus-service.exe' : 'modbus-service',
  );
  final compiled = await Process.start(Platform.resolvedExecutable, [
    'compile',
    'exe',
    'bin/modbus_service.dart',
    '-o',
    executable,
  ], mode: ProcessStartMode.inheritStdio);
  final result = await compiled.exitCode;
  if (result != 0) {
    exitCode = result;
    return;
  }
  final library = Platform.isWindows
      ? 'serialport.dll'
      : Platform.isMacOS
      ? 'libserialport.dylib'
      : 'libserialport.so';
  await File(arguments.single).copy(p.join(output.path, library));
  for (final source in await Directory('assets/licenses').list().toList()) {
    if (source is File) {
      await Directory(p.join(output.path, 'licenses')).create(recursive: true);
      await source.copy(
        p.join(output.path, 'licenses', p.basename(source.path)),
      );
    }
  }
  if (Platform.isWindows) {
    await File(p.join(output.path, 'start-service.cmd')).writeAsString(
      '@echo off\r\nset "LIBSERIALPORT_PATH=%~dp0serialport.dll"\r\n"%~dp0modbus-service.exe" %*\r\n',
    );
  } else {
    final launcher = File(p.join(output.path, 'start-service.sh'));
    await launcher.writeAsString(
      r'''#!/bin/sh
MODBUS_SERVICE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export LIBSERIALPORT_PATH="$MODBUS_SERVICE_DIR/LIBRARY"
exec "$MODBUS_SERVICE_DIR/modbus-service" "$@"
'''
          .replaceAll('LIBRARY', library),
    );
    await Process.run('chmod', ['+x', launcher.path]);
  }
  stdout.writeln(
    'Standalone service: ${output.absolute.path}. Include the whole folder and licenses when distributing.',
  );
}
