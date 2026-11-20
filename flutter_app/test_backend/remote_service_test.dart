@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:modbus_desktop/src/remote/server.dart';
import 'package:modbus_desktop/src/remote/bridge.dart';
import 'package:modbus_desktop/src/remote/configuration.dart';
import 'package:modbus_desktop/src/bridge_transport.dart';
import 'package:modbus_desktop/src/backend/datastore.dart';
import 'package:modbus_desktop/src/backend/wire_protocol.dart';
import 'package:test/test.dart';

const token = 'acceptance-token-with-at-least-24-characters';
Future<void> waitUntil(bool Function() check) async {
  final end = DateTime.now().add(const Duration(seconds: 8));
  while (!check()) {
    if (DateTime.now().isAfter(end)) {
      fail('Timed out waiting for session cleanup');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late Directory directory;
  late DartServiceHost host;
  late String url;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('modbus-service-test-');
    host = await DartServiceHost.start(
      root: directory,
      token: token,
      origins: {'http://localhost:8080'},
      port: 0,
      lease: const Duration(seconds: 2),
    );
    url = 'ws://127.0.0.1:${host.port}/ws';
  });
  tearDown(() async {
    await host.close();
    await directory.delete(recursive: true);
  });
  for (final transport in ['tcp', 'rtu_tcp']) {
    test(
      '$transport simulator and gateway run through separate service sessions',
      () async {
        final sim = RemoteBridge(ServiceConfiguration(url, token));
        final gateway = RemoteBridge(ServiceConfiguration(url, token));
        final master = RemoteBridge(ServiceConfiguration(url, token));
        Future<int> freePort() async {
          final socket = await ServerSocket.bind(
            InternetAddress.loopbackIPv4,
            0,
          );
          final port = socket.port;
          await socket.close();
          return port;
        }

        final upstream = await freePort(), proxy = await freePort();
        try {
          await sim.request({
            'command': 'sim_configure',
            'rows': [
              {
                'kind': 'holding_registers',
                'count': 2,
                'values': [12, 34],
              },
            ],
          });
          await sim.request({
            'command': 'device_start',
            'mode': 'simulator',
            'listen': {
              'transport': transport,
              'host': '127.0.0.1',
              'port': upstream,
            },
            'tick_ms': 100,
          });
          await gateway.request({
            'command': 'device_start',
            'mode': 'gateway',
            'listen': {'transport': 'tcp', 'host': '127.0.0.1', 'port': proxy},
            'target': {
              'transport': transport,
              'host': '127.0.0.1',
              'port': upstream,
            },
            'units': [1],
          });
          await master.request({
            'command': 'connect',
            'transport': 'tcp',
            'host': '127.0.0.1',
            'port': proxy,
            'timeout': 0.5,
          });
          expect(
            (await master.request({'command': 'read', 'count': 2}))
                .result['values'],
            [12, 34],
          );
          await master.request({
            'command': 'write',
            'values': [100, 200],
          });
          await master.request({
            'command': 'mask_write',
            'and_mask': 0xff00,
            'or_mask': 7,
          });
          expect(
            (await master.request({
              'command': 'read_write',
              'read_count': 2,
              'values': [8, 9],
            })).result['values'],
            [8, 9],
          );
          expect(
            (await master.request({'command': 'device_id'})).result['objects'],
            containsPair('0', 'Modbus Connector'),
          );
          expect(
            (await master.request({'command': 'scan_address', 'address': 0}))
                .result['values'],
            [8, 9],
          );
          expect(
            (await gateway.request({'command': 'device_status'}))
                .result['gateway'],
            true,
          );
        } finally {
          await master.close();
          await gateway.close();
          await sim.close();
        }
        await waitUntil(() => host.sessionCount == 0);
        for (final port in [upstream, proxy]) {
          await expectLater(
            Socket.connect(InternetAddress.loopbackIPv4, port),
            throwsA(isA<SocketException>()),
          );
        }
      },
    );
  }
  test(
    'RTU over UDP service validates frames and round-trips reads and writes',
    () async {
      final peer = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final store = DataStore()..set('holding_registers', 0, [123, 456]);
      final packets = <List<int>>[];
      final listener = peer.listen((event) {
        if (event != RawSocketEvent.read) return;
        Datagram? packet;
        while ((packet = peer.receive()) != null) {
          final bytes = packet!.data;
          packets.add(bytes.toList());
          if (bytes.length < 4 ||
              crc16(bytes.sublist(0, bytes.length - 2)) !=
                  (bytes[bytes.length - 2] | bytes.last << 8)) {
            continue;
          }
          peer.send(
            rtuFrame(
              bytes.first,
              store.handle(bytes.sublist(1, bytes.length - 2)),
            ),
            packet.address,
            packet.port,
          );
        }
      });
      final bridge = RemoteBridge(ServiceConfiguration(url, token));
      try {
        await bridge.request({
          'command': 'connect',
          'transport': 'rtu_udp',
          'host': '127.0.0.1',
          'port': peer.port,
          'timeout': 0.5,
        });
        expect(
          (await bridge.request({'command': 'read', 'count': 2}))
              .result['values'],
          [123, 456],
        );
        await bridge.request({
          'command': 'write',
          'values': [65535, 1],
        });
        expect(
          (await bridge.request({'command': 'read', 'count': 2}))
              .result['values'],
          [65535, 1],
        );
        expect(packets, hasLength(3));
      } finally {
        await bridge.close();
        await listener.cancel();
        peer.close();
      }
    },
  );
  test(
    'origin and authentication are required before creating a worker',
    () async {
      await expectLater(
        WebSocket.connect(
          url,
          headers: {'Origin': 'https://untrusted.invalid'},
        ),
        throwsA(isA<WebSocketException>()),
      );
      final socket = await WebSocket.connect(
        url,
        headers: {'Origin': 'http://localhost:8080'},
      );
      socket.add(
        jsonEncode({'type': 'auth', 'protocol': 1, 'token': 'invalid'}),
      );
      expect(jsonDecode(await socket.first as String)['type'], 'auth_error');
      await socket.close();
      await waitUntil(() => host.sessionCount == 0);
    },
  );
  test('sessions isolate writes, export safe logs, reject host paths and close owned resources', () async {
    final a = RemoteBridge(ServiceConfiguration(url, token));
    final b = RemoteBridge(ServiceConfiguration(url, token));
    try {
      await a.request({'command': 'connect', 'transport': 'demo'});
      await b.request({'command': 'connect', 'transport': 'demo'});
      expect(a.transports, contains('tcp'));
      expect(a.supportsDeviceModes, isTrue);
      await a.request({
        'command': 'write_row',
        'row': {'address': 0},
        'values': [123],
      });
      Future<int> value(RemoteBridge bridge) async =>
          ((await bridge.request({
                        'command': 'read_rows',
                        'rows': [
                          {'address': 0},
                        ],
                      })).result['rows'][0]['values']
                      as List)
                  .first
              as int;
      expect(await value(a), 123);
      expect(await value(b), 100);
      await expectLater(
        a.request({
          'command': 'logger_start',
          'path': '../../outside.csv',
          'rows': [
            {'address': 0},
          ],
        }),
        throwsA(isA<BridgeException>()),
      );
      await expectLater(
        a.request({'command': 'update_check'}),
        throwsA(isA<BridgeException>()),
      );
      await expectLater(
        a.request({'command': '_close_worker'}),
        throwsA(isA<BridgeException>()),
      );
      await a.request({
        'command': 'logger_start',
        'path': 'remote.csv',
        'rows': [
          {'address': 0},
        ],
        'append': false,
      });
      await a.request({
        'command': 'logger_sample',
        'values': [
          [123],
        ],
      });
      final exported = await a.request({'command': 'logger_export'});
      expect(exported.connected, isTrue);
      expect(exported.result['path'], 'remote.csv');
      expect(exported.result['text'], contains('123'));
      expect(
        (await directory.list(recursive: true).toList()).whereType<File>().any(
          (file) => file.uri.pathSegments.last == 'remote.csv',
        ),
        isTrue,
      );
    } finally {
      await a.close();
      await b.close();
    }
    await waitUntil(() => host.sessionCount == 0);
    expect(
      await Directory('${directory.path}/sessions').list().toList(),
      isEmpty,
    );
  });
  test('unresponsive browser lease releases its native session', () async {
    final socket = await WebSocket.connect(url);
    final messages = StreamIterator(socket);
    socket.add(jsonEncode({'type': 'auth', 'protocol': 1, 'token': token}));
    expect(await messages.moveNext(), isTrue);
    expect(jsonDecode(messages.current as String)['type'], 'ready');
    await waitUntil(() => host.sessionCount == 0);
    await messages.cancel();
    await socket.close();
  });
  test('read cancellation bypasses the request queue', () async {
    final stalled = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    Socket? peer;
    final sawRead = Completer<void>();
    final listener = stalled.listen((socket) {
      peer = socket;
      socket.listen((_) {
        if (!sawRead.isCompleted) sawRead.complete();
      });
    });
    final bridge = RemoteBridge(ServiceConfiguration(url, token));
    try {
      await bridge.request({
        'command': 'connect',
        'transport': 'tcp',
        'host': '127.0.0.1',
        'port': stalled.port,
        'timeout': 10,
      });
      final read = bridge.request({
        'command': 'read_rows',
        'rows': [
          {'address': 0},
        ],
      });
      final assertion = expectLater(
        read,
        throwsA(
          isA<BridgeException>().having(
            (e) => e.message,
            'message',
            contains('cancel'),
          ),
        ),
      );
      await sawRead.future;
      bridge.cancelPendingRead();
      await assertion;
      await bridge.request({'command': 'disconnect'});
    } finally {
      await bridge.close();
      peer?.destroy();
      await listener.cancel();
      await stalled.close();
    }
  });
  test('lease loss rejects writes until an explicit reconnect creates a new session', () async {
    final bridge = RemoteBridge(ServiceConfiguration(url, token));
    var exited = false;
    bridge.onExit = () => exited = true;
    try {
      await bridge.request({'command': 'connect', 'transport': 'demo'});
      await waitUntil(() => exited);
      await expectLater(
        bridge.request({
          'command': 'write_row',
          'row': {'address': 0},
          'values': [999],
        }),
        throwsA(
          isA<BridgeException>().having(
            (error) => error.connected,
            'connected',
            false,
          ),
        ),
      );
      await waitUntil(() => host.sessionCount == 0);
      await bridge.request({'command': 'connect', 'transport': 'demo'});
      final value = await bridge.request({
        'command': 'read_rows',
        'rows': [
          {'address': 0},
        ],
      });
      expect(value.result['rows'][0]['values'], [100]);
    } finally {
      await bridge.close();
    }
  });
}
