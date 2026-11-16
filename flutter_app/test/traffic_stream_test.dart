import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:modbus_desktop/src/backend/service.dart';
import 'package:modbus_desktop/src/backend/wire.dart';
import 'package:modbus_desktop/src/bridge_client.dart';
import 'package:modbus_desktop/src/session_controller.dart';

Future<void> waitForTraffic(SessionController session, int count) async {
  if (session.traffic.length >= count) return;
  final ready = Completer<void>();
  void changed() {
    if (session.traffic.length >= count && !ready.isCompleted) ready.complete();
  }

  session.trafficUpdates.addListener(changed);
  try {
    await ready.future.timeout(const Duration(milliseconds: 500));
  } finally {
    session.trafficUpdates.removeListener(changed);
  }
}

void main() {
  for (final local in [true, false]) {
    test(
      'TX and RX stream before a multi-read completes local=$local',
      () async {
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final requests = <List<int>>[];
        final first = Completer<void>(), second = Completer<void>();
        var automaticReplies = false;
        Socket? peer;
        server.listen((socket) {
          peer = socket;
          final parser = FrameParser(tcp: true);
          socket.listen((bytes) {
            for (final request in parser.feed(bytes)) {
              requests.add(request);
              if (requests.length == 1) first.complete();
              if (requests.length == 2) second.complete();
              if (automaticReplies) {
                socket.add([...request.take(4), 0, 5, request[6], 3, 2, 0, 42]);
              }
            }
          });
        });
        final bridge = NativeBridge(service: local ? NativeService() : null);
        final session = SessionController(bridge);
        Future<BridgeReply>? reading;
        void reply(List<int> request, int value) {
          peer!.add([...request.take(4), 0, 5, request[6], 3, 2, 0, value]);
        }

        try {
          await session.connect({
            'transport': 'tcp',
            'host': '127.0.0.1',
            'port': server.port,
            'timeout': 5,
          }, 1);
          var sessionEvents = 0;
          session.addListener(() => sessionEvents++);
          var complete = false;
          reading = bridge
              .request({
                'command': 'read_rows',
                'unit': 1,
                'rows': [
                  for (final address in [0, 10])
                    {
                      'kind': 'holding_registers',
                      'address': address,
                      'count': 1,
                    },
                ],
              })
              .whenComplete(() => complete = true);
          unawaited(reading.then<void>((_) {}, onError: (Object _) {}));
          await first.future.timeout(const Duration(seconds: 3));
          // The device has not replied: TX must already be visible.
          await waitForTraffic(session, 1);
          expect(session.traffic.single['direction'], 'tx');
          expect(session.busStatistics['tx_bytes'], 12);
          expect(complete, isFalse);
          reply(requests.first, 42);
          await second.future.timeout(const Duration(seconds: 3));
          await waitForTraffic(session, 3);
          expect(session.traffic.map((frame) => frame['direction']), [
            'tx',
            'rx',
            'tx',
          ]);
          expect(complete, isFalse);
          expect(session.busStatistics['operations'], 0);
          reply(requests.last, 43);
          final result = await reading;
          expect((result.result['rows'] as List).map((row) => row['values']), [
            [42],
            [43],
          ]);
          // Completion publishes final statistics without replaying streamed frames.
          expect(session.traffic, hasLength(4));
          expect(session.busStatistics['operations'], 1);
          expect(session.busStatistics['rx_bytes'], 22);
          // Late/unsolicited bytes must appear even without another command.
          peer!.add([0x12, 0x34, 0, 0, 0, 5, 1, 3, 2, 0, 99]);
          await waitForTraffic(session, 5);
          expect(
            session.traffic.last['hex'],
            '12 34 00 00 00 05 01 03 02 00 63',
          );
          expect(session.busStatistics['rx_bytes'], 33);
          expect(sessionEvents, 0);

          // A long command must stream all chunks, beyond the old 256 snapshot.
          automaticReplies = true;
          session.clearTraffic();
          await bridge.request({
            'command': 'read_rows',
            'unit': 1,
            'rows': [
              for (var address = 0; address < 130; address++)
                {'kind': 'holding_registers', 'address': address, 'count': 1},
            ],
          });
          expect(session.traffic, hasLength(260));
          expect(
            session.traffic.where((frame) => frame['direction'] == 'tx'),
            hasLength(130),
          );
          expect(session.busStatistics['operations'], 2);

          // Clearing during a pending read must not replay TX on cancellation.
          automaticReplies = false;
          final cancelledRead = bridge.request({
            'command': 'read_rows',
            'unit': 1,
            'rows': [
              {'kind': 'holding_registers', 'address': 42, 'count': 1},
            ],
          });
          final cancelled = expectLater(
            cancelledRead,
            throwsA(
              isA<BridgeException>().having(
                (error) => error.message,
                'message',
                contains('cancelled'),
              ),
            ),
          );
          await waitForTraffic(session, 261);
          session.clearTraffic();
          bridge.cancelPendingRead();
          await cancelled;
          expect(session.traffic, isEmpty);
          expect(session.busStatistics['operations'], 3);
          expect(session.busStatistics['errors'], 0);
        } finally {
          bridge.cancelPendingRead();
          if (reading != null) {
            try {
              await reading;
            } catch (_) {}
          }
          await session.shutdown();
          session.dispose();
          peer?.destroy();
          await server.close();
        }
      },
    );
  }
}
