import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_libserialport/flutter_libserialport.dart';

import 'catalog.dart';
import '../diagnostics.dart';
import 'devices.dart';
import 'files.dart';
import 'online.dart';
import 'registers.dart';
import 'register_operations.dart';
import 'wire.dart';

class NativeService {
  NativeService({NativeCatalog? catalog, NativeLogger? logger})
    : catalog = catalog ?? NativeCatalog(),
      logger = logger ?? NativeLogger() {
    online = NativeOnline(this.catalog);
    client.traffic = capture;
  }
  final NativeCatalog catalog;
  late final NativeOnline online;
  final client = ModbusClient(), devices = NativeDevices();
  final NativeLogger logger;
  final traffic = <Json>[];
  void Function(List<Json> frames, Json statistics)? onTraffic;
  int txBytes = 0, rxBytes = 0, operations = 0, errors = 0;
  double totalMs = 0;
  Json get statistics => {
    'tx_bytes': txBytes,
    'rx_bytes': rxBytes,
    'operations': operations,
    'errors': errors,
    'average_ms': operations == 0 ? 0 : totalMs / operations,
  };
  ModbusServer? demo;
  DataStore? demoStore;
  final demoClock = Stopwatch();
  bool get connected => client.connected;
  void capture(String direction, List<int> packet) {
    if (direction == 'tx') {
      txBytes += packet.length;
    } else {
      rxBytes += packet.length;
    }
    if (traffic.length >= 256) traffic.removeAt(0);
    final frame = <String, dynamic>{
      'direction': direction,
      'hex': hexBytes(packet.take(4096).toList()),
      'length': packet.length,
      'time': DateTime.now().toIso8601String(),
    };
    traffic.add(frame);
    // Stream independently of command completion, including late/idle RX.
    onTraffic?.call([frame], statistics);
  }

  void advanceDemo() {
    if (demoStore != null) {
      demoStore!.set(
        'input_registers',
        0,
        List.generate(
          125,
          (i) =>
              (1000 +
                      500 *
                          math.sin(
                            demoClock.elapsedMilliseconds / 1000 + i / 5,
                          ))
                  .round(),
        ),
      );
    }
  }

  Future<void> disconnect() async {
    await client.close();
    await devices.close();
    await logger.close();
    await demo?.close();
    demo = null;
    demoStore = null;
    demoClock.stop();
  }

  Future<void> close() async {
    await online.close();
    await disconnect();
  }

  Future<Json> respond(Json d) async {
    traffic.clear();
    final clock = Stopwatch()..start();
    Json response;
    final lifecycle = [
      'connect',
      'disconnect',
      'shutdown',
      'device_start',
      'device_stop',
    ].contains(d['command']);
    if (lifecycle) {
      Diagnostics.current?.write('backend', "${d['command']} begin");
    }
    try {
      response = {'ok': true, 'result': await dispatch(d)};
      if (lifecycle) {
        Diagnostics.current?.write('backend', "${d['command']} complete");
      }
    } catch (e, stack) {
      if (e is! ReadCancelled) {
        Diagnostics.current?.write(
          'backend-error',
          "${d['command']}: $e",
          stack,
        );
      }
      response = {
        'ok': false,
        'error': {
          'type': e.runtimeType.toString(),
          'message': e is FormatException ? e.message : '$e',
          if (e is ReadTimeout) 'read_timeout': e.context,
          if (e is ModbusError) 'exception_code': e.code,
        },
      };
    }
    if (traffic.isNotEmpty) {
      operations++;
      if (response['ok'] != true &&
          response['error']['type'] != 'ReadCancelled') {
        errors++;
      }
      totalMs += clock.elapsedMicroseconds / 1000;
    }
    return {
      ...response,
      'connected': connected,
      // Direct-service consumers can use the bounded reply snapshot. Streaming
      // consumers already received every chunk, so do not send them twice.
      'traffic': onTraffic == null ? List<Json>.from(traffic) : const <Json>[],
      'statistics': statistics,
    };
  }

  ReadCancellation? _readCancellation;
  void cancelRead() => _readCancellation?.cancel();

  Future<Json> dispatch(Json d) async {
    if (d['command'] != 'read_rows') return _dispatch(d);
    final cancellation = _readCancellation = ReadCancellation();
    try {
      return await _dispatch(d);
    } finally {
      if (identical(_readCancellation, cancellation)) _readCancellation = null;
    }
  }

  Future<Json> _dispatch(Json d) async {
    final command = d['command'];
    if (command == 'hello') return {'protocol': 1};
    if (command == 'ports') {
      final result = <Json>[];
      for (final name in SerialPort.availablePorts) {
        final p = SerialPort(name);
        try {
          result.add({'port': name, 'description': p.description ?? name});
        } finally {
          p.dispose();
        }
      }
      return {'ports': result};
    }
    if (command == 'connect') {
      final raw = Map<String, dynamic>.from(d);
      final isDemo = d['transport'] == 'demo';
      Json params;
      if (isDemo) {
        params = {
          'transport': 'tcp',
          'host': '127.0.0.1',
          'port': 502,
          'timeout': d['timeout'] ?? 3,
        };
        finite(params['timeout'], 'timeout');
      } else {
        params = connection(raw);
      }
      await disconnect();
      try {
        if (isDemo) {
          demo = ModbusServer();
          demoStore = DataStore();
          demoStore!.set(
            'holding_registers',
            0,
            List.generate(125, (i) => 100 + i),
          );
          demoStore!.set('coils', 0, List.generate(2000, (i) => i.isEven));
          demoStore!.set(
            'discrete_inputs',
            0,
            List.generate(2000, (i) => i % 3 == 0),
          );
          final reservation = await ServerSocket.bind(
            InternetAddress.loopbackIPv4,
            0,
          );
          params['port'] = reservation.port;
          await reservation.close();
          await demo!.start(params, (u, pdu) async => demoStore!.handle(pdu));
          demoClock
            ..reset()
            ..start();
          advanceDemo();
        }
        await client.connect(params);
      } catch (_) {
        await disconnect();
        rethrow;
      }
      return {
        'description': isDemo ? 'Demo · local TCP simulator' : describe(params),
      };
    }
    if (command == 'disconnect' || command == 'shutdown') {
      await disconnect();
      return {};
    }
    if (command == 'evaluate_expressions') return evaluateExpressions(d);
    if ((command as String).startsWith('template_')) return catalog.dispatch(d);
    if (command.startsWith('cloud_') || command.startsWith('update_')) {
      return online.dispatch(d);
    }
    if (command.startsWith('logger_')) return logger.dispatch(d);
    if (['device_start', 'device_stop', 'device_status'].contains(command) ||
        ['sim_configure', 'sim_set', 'sniffer_snapshot'].contains(command)) {
      return devices.dispatch(d);
    }
    if (command.startsWith('csv_')) return csvCommand(d);
    if (command == 'encode_values') return {'values': encodeValues(d)};
    return RegisterOperations(
      client,
      beforeRead: advanceDemo,
      cancellation: _readCancellation,
    ).dispatch(d);
  }
}
