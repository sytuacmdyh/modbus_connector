import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:modbus_desktop/src/backend/service.dart';
import 'package:modbus_desktop/src/bridge_client.dart';
import 'package:modbus_desktop/src/session_controller.dart';
import 'package:modbus_desktop/src/translations.dart';

import 'fake_bridge.dart';

class TimeoutBridge extends FakeBridge {
  bool fail = true;
  int address = 20;
  @override
  Future<BridgeReply> request(
    Map<String, dynamic> command, {
    Duration? timeout,
  }) {
    if (fail && command['command'] == 'read_rows') {
      calls.add(command);
      throw BridgeException(
        'Modbus read timed out',
        connected: true,
        readTimeout: {
          'transport': 'tcp',
          'endpoint': 'localhost:502',
          'unit': 7,
          'function': 3,
          'address': address,
          'count': 1,
          'timeout_ms': 100,
        },
      );
    }
    return super.request(command, timeout: timeout);
  }
}

void main() {
  test(
    'read timeouts share a session limit across requests and successes',
    () async {
      var now = DateTime(2026);
      final bridge = TimeoutBridge();
      final session = SessionController(bridge, clock: () => now);
      addTearDown(session.dispose);
      await session.connect({
        'transport': 'tcp',
        'host': 'localhost',
        'port': 502,
        'timeout': 0.1,
      }, 7);
      session.registers.add({
        'kind': 'holding_registers',
        'address': 20,
        'count': 1,
      });
      session.clearLog();
      await session.registerMap.read();
      expect(session.logs, hasLength(1));
      final first = session.logs.single;
      expect(first.isError, isTrue);
      expect(first.message, contains('tcp localhost:502 · Unit 7 · FC 03'));
      expect(first.message, contains('Address 20 · Count 1 · Timeout 100 ms'));
      for (var i = 0; i < 30; i++) {
        bridge.address++;
        await session.registerMap.read();
      }
      expect(session.logs, hasLength(1));
      expect(session.error, contains('Address 50'));
      expect(session.connected, isTrue);
      bridge.fail = false;
      await session.registerMap.read();
      expect(session.error, isNull);
      bridge.fail = true;
      await session.registerMap.read();
      expect(session.logs, hasLength(1));
      now = now.add(const Duration(seconds: 5));
      await session.registerMap.read();
      expect(session.logs, hasLength(2));
      expect(session.logs.first.message, contains('32 timeout(s)'));
      appLanguage.value = 'zh_CN';
      addTearDown(() => appLanguage.value = 'en');
      expect(tr(session.logs.first.message), contains('读取超时'));
      expect(tr(session.logs.first.message), contains('本次汇总 32 次超时'));
      session.clearLog();
      await session.registerMap.read();
      expect(session.logs, hasLength(1));
    },
  );

  for (final local in [true, false]) {
    test(
      'native timeout preserves actual fallback request context local=$local',
      () async {
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final peers = <Socket>[];
        server.listen((peer) {
          peers.add(peer);
          peer.listen((_) {}); // Device accepts requests but never responds.
        });
        final session = SessionController(
          NativeBridge(service: local ? NativeService() : null),
        );
        try {
          await session.connect({
            'transport': 'tcp',
            'host': '127.0.0.1',
            'port': server.port,
            'timeout': 0.1,
          }, 1);
          session.registers.addAll([
            for (var i = 0; i < 2; i++)
              {
                'unit_id': 7,
                'kind': 'input_registers',
                'address': 20 + i,
                'count': 1,
              },
          ]);
          session.clearLog();
          await session.registerMap.read();
          // The merged 20..21 read fails, followed by an individual fallback at 20.
          expect(
            session.logs.single.message,
            contains('Unit 7 · FC 04 · Address 20 · Count 1 · Timeout 100 ms'),
          );
          expect(
            session.logs.single.message,
            contains('127.0.0.1:${server.port}'),
          );
          expect(session.connected, isTrue);
          expect(session.logs.single.isError, isTrue);
        } finally {
          await session.shutdown();
          for (final peer in peers) {
            peer.destroy();
          }
          await server.close();
          session.dispose();
        }
      },
    );
  }
}
