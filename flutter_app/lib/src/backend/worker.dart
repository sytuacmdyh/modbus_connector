import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'catalog.dart';
import 'service.dart';

// Pure Dart worker: native ports, protocol timers and servers never share the
// Flutter UI event loop. It runs inside the app process, without an interpreter.
void nativeWorker(List<dynamic> arguments) {
  final output = arguments[0] as SendPort;
  final directory = arguments[1] as String?;
  final service = NativeService(
    catalog: directory == null
        ? null
        : NativeCatalog(directory: Directory(directory)),
  );
  final input = ReceivePort();
  var tail = Future<void>.value();
  output.send(input.sendPort);
  input.listen((dynamic message) {
    tail = tail.then((_) async {
      final command = Map<String, dynamic>.from(message as Map);
      if (command['command'] == '_close_worker') {
        input.close();
        await service.close();
        Isolate.exit(output, {'closed': true});
      }
      output.send(await service.respond(command));
    });
  });
}
