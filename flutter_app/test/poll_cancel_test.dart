import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart' show debugPrint;

import 'package:flutter_test/flutter_test.dart';
import 'package:modbus_desktop/src/bridge_client.dart';
import 'package:modbus_desktop/src/backend/service.dart';
import 'package:modbus_desktop/src/session_controller.dart';

void main() {
  for (final transport in ['tcp', 'rtu_tcp']) {
    for (final local in [false, true]) {
      test('$transport local=$local stop releases an in-flight five-second read', () async {
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final seen = Completer<void>();
        Socket? peer;
        var requests = 0;
        server.listen((socket) {
          peer = socket;
          socket.listen((_) {
            requests++;
            if (!seen.isCompleted) seen.complete();
          });
        });
        final session = SessionController(
          NativeBridge(service: local ? NativeService() : null),
        );
        try {
          await session.command({
            'command': 'connect',
            'transport': transport,
            'host': '127.0.0.1',
            'port': server.port,
            'timeout': 5,
          });
          session.connected = true;
          session.registers.addAll([
            for (var i = 0; i < 2; i++)
              {
                'name': 'r$i',
                'address': i,
                'kind': 'holding_registers',
                'count': 1,
              },
          ]);
          session.registerMap.start(100);
          await seen.future.timeout(const Duration(seconds: 3));
          final elapsed = Stopwatch()..start();
          session.registerMap.stop();
          await session.waitForIdle().timeout(
            const Duration(milliseconds: 500),
          );
          elapsed.stop();
          await Future<void>.delayed(const Duration(milliseconds: 30));
          debugPrint(
            '$transport local=$local stop completed in ${elapsed.elapsedMilliseconds} ms',
          );
          expect(session.registerMap.reading, false);
          expect(session.connected, true);
          expect(
            requests,
            1,
            reason: 'Cancellation must not trigger grouped fallback reads',
          );
          expect(session.error, isNull);
        } finally {
          peer?.destroy();
          await session.shutdown();
          session.dispose();
          await server.close();
        }
      });
    }
  }
}
