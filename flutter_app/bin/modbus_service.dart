import 'dart:async';
import 'dart:io';

import 'package:modbus_desktop/src/remote/server.dart';
import 'package:flutter_libserialport/flutter_libserialport.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length == 1 && arguments.first == '--check-serial') {
    try {
      stdout.writeln(
        'libserialport loaded. Ports: ${SerialPort.availablePorts.join(', ')}',
      );
    } catch (error) {
      stderr.writeln(
        'Cannot load libserialport. Set LIBSERIALPORT_PATH to the native library: $error',
      );
      exitCode = 1;
    }
    return;
  }
  final origins = <String>{};
  var bind = '127.0.0.1', port = 18766;
  var directory =
      '${Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'] ?? Directory.current.path}/.modbus_connector/dart-service';
  try {
    for (var i = 0; i < arguments.length; i++) {
      final arg = arguments[i];
      if (arg == '--help') {
        stdout.writeln(
          'Usage: dart run bin/modbus_service.dart --origin http://localhost:8080 [--origin https://example.com] [--bind 127.0.0.1] [--port 18766] [--data-dir DIRECTORY]\nSet MODBUS_SERVICE_TOKEN (24..1024 characters), or use the generated token shown at startup.',
        );
        return;
      }
      if (i + 1 >= arguments.length) {
        throw FormatException('Missing value for $arg');
      }
      final value = arguments[++i];
      switch (arg) {
        case '--origin':
          origins.add(value);
        case '--bind':
          bind = value;
        case '--port':
          port = int.parse(value);
        case '--data-dir':
          directory = value;
        default:
          throw FormatException('Unknown option $arg');
      }
    }
    final configured = Platform.environment['MODBUS_SERVICE_TOKEN'];
    final token = configured ?? '${serviceIdentity()}${serviceIdentity()}';
    final host = await DartServiceHost.start(
      root: Directory(directory),
      token: token,
      origins: origins,
      bind: bind,
      port: port,
    );
    stdout.writeln('Dart Modbus service: ws://$bind:${host.port}/ws');
    stdout.writeln('Allowed browser origins: ${origins.join(', ')}');
    if (configured == null) stdout.writeln('Session access token: $token');
    final stopped = Completer<void>();
    final signals = <StreamSubscription<ProcessSignal>>[];
    void stop(ProcessSignal _) {
      if (!stopped.isCompleted) stopped.complete();
    }

    signals.add(ProcessSignal.sigint.watch().listen(stop));
    if (!Platform.isWindows) {
      signals.add(ProcessSignal.sigterm.watch().listen(stop));
    }
    await stopped.future;
    await host.close();
    for (final subscription in signals) {
      await subscription.cancel();
    }
  } catch (error) {
    stderr.writeln('Cannot start Dart Modbus service: $error');
    exitCode = 1;
  }
}
