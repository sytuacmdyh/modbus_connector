import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'catalog.dart';
import '../diagnostics.dart';
import 'service.dart';

// Pure Dart worker: native ports, protocol timers and servers never share the
// Flutter UI event loop. It runs inside the app process, without an interpreter.
void nativeWorker(List<dynamic> arguments) {
  final output = arguments[0] as SendPort;
  final directory = arguments[1] as String?;
  Diagnostics.initialize(role: 'worker', directory: directory);
  final service = NativeService(
    catalog: directory == null
        ? null
        : NativeCatalog(directory: Directory(directory)),
  );
  final input = ReceivePort();
  var tail = Future<void>.value();
  int? activeId;
  output.send(input.sendPort);
  input.listen((dynamic message) {
    final command = Map<String, dynamic>.from(message as Map);
    // Cancellation bypasses the serialized command queue and has no reply.
    if (command['command'] == '_cancel_read') {
      if (activeId == command['request_id']) service.cancelRead();
      return;
    }
    tail = tail.then((_) async {
      activeId = command['_request_id'] as int?;
      if (command['command'] == '_close_worker') {
        input.close();
        await service.close();
        Isolate.exit(output, {'closed': true});
      }
      try {
        output.send(await service.respond(command));
      } finally {
        activeId = null;
      }
    });
  });
}
