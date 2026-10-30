import 'dart:io';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_libserialport/flutter_libserialport.dart';

import 'catalog.dart';
import 'devices.dart';
import 'files.dart';
import 'online.dart';
import 'registers.dart';
import 'wire.dart';

class NativeService {
  NativeService({NativeCatalog? catalog})
    : catalog = catalog ?? NativeCatalog() {
    online = NativeOnline(this.catalog);
    client.traffic = capture;
  }
  final NativeCatalog catalog;
  late final NativeOnline online;
  final client = ModbusClient(),
      devices = NativeDevices(),
      logger = NativeLogger();
  final traffic = <Json>[];
  int txBytes = 0, rxBytes = 0, operations = 0, errors = 0;
  double totalMs = 0;
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
    traffic.add({
      'direction': direction,
      'hex': hexBytes(packet.take(4096).toList()),
      'length': packet.length,
      'time': DateTime.now().toIso8601String(),
    });
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
    try {
      response = {'ok': true, 'result': await dispatch(d)};
    } catch (e) {
      response = {
        'ok': false,
        'error': {
          'type': e.runtimeType.toString(),
          'message': e is FormatException ? e.message : '$e',
          if (e is ModbusError) 'exception_code': e.code,
        },
      };
    }
    if (traffic.isNotEmpty) {
      operations++;
      if (response['ok'] != true) errors++;
      totalMs += clock.elapsedMicroseconds / 1000;
    }
    return {
      ...response,
      'connected': connected,
      'traffic': List<Json>.from(traffic),
      'statistics': {
        'tx_bytes': txBytes,
        'rx_bytes': rxBytes,
        'operations': operations,
        'errors': errors,
        'average_ms': operations == 0 ? 0 : totalMs / operations,
      },
    };
  }

  Future<Json> dispatch(Json d) async {
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
    if (['render_rows', 'read_rows', 'plan_reads'].contains(command)) {
      final raw = d['rows'];
      if (raw is! List || raw.isEmpty || raw.length > 4096) {
        throw const FormatException('rows must contain 1..4096 rows');
      }
      final unit = bounded(d['unit'] ?? 1, 'unit', 1, 247);
      final rows = raw.map((r) => row(r, unit)).toList();
      if (command == 'plan_reads') return {'groups': plan(rows)};
      if (command == 'render_rows') {
        return {
          'rows': [for (final r in rows) render(r, _validated(r))],
        };
      }
      advanceDemo();
      final clock = Stopwatch()..start(),
          results = List<List<dynamic>>.generate(rows.length, (_) => []);
      final groups = d['grouped'] == true
          ? plan(rows)
          : List.generate(rows.length, (i) => [i]);
      for (final group in groups) {
        final first = rows[group[0]];
        final start = group
                .map((i) => rows[i]['address'] as int)
                .reduce(math.min),
            end = group
                .map(
                  (i) =>
                      (rows[i]['address'] as int) + (rows[i]['count'] as int),
                )
                .reduce(math.max);
        try {
          final values = await client.read(
            first['unit_id'],
            first['kind'],
            start,
            end - start,
          );
          for (final i in group) {
            final offset = (rows[i]['address'] as int) - start;
            results[i] = values.sublist(
              offset,
              offset + (rows[i]['count'] as int),
            );
          }
        } catch (_) {
          if (group.length == 1) rethrow;
          for (final i in group) {
            final r = rows[i];
            results[i] = await client.read(
              r['unit_id'],
              r['kind'],
              r['address'],
              r['count'],
            );
          }
        }
      }
      return {
        'rows': [
          for (var i = 0; i < rows.length; i++) render(rows[i], results[i]),
        ],
        'elapsed_ms': clock.elapsedMicroseconds / 1000,
      };
    }
    final unit = bounded(d['unit'] ?? 1, 'unit', 1, 247);
    if (command == 'mask_write') {
      final a = bounded(d['address'] ?? 0, 'address', 0, 65535),
          and = bounded(d['and_mask'] ?? 65535, 'and_mask', 0, 65535),
          or = bounded(d['or_mask'] ?? 0, 'or_mask', 0, 65535);
      final p = [22, ...word(a), ...word(and), ...word(or)],
          r = await client.request(unit, p);
      if (p.join() != r.join()) {
        throw const FormatException('Invalid mask write response');
      }
      return {};
    }
    if (command == 'read_write') {
      final a = bounded(d['read_address'] ?? 0, 'read_address', 0, 65535),
          n = bounded(d['read_count'] ?? 1, 'read_count', 1, 125),
          wa = bounded(d['write_address'] ?? 0, 'write_address', 0, 65535);
      final values = (d['values'] as List)
          .map((v) => bounded(v, 'value', 0, 65535))
          .toList();
      bounded(values.length, 'count', 1, 121);
      if (a + n > 65536 || wa + values.length > 65536) {
        throw const FormatException('Address range exceeds 65535');
      }
      final r = await client.request(unit, [
        23,
        ...word(a),
        ...word(n),
        ...word(wa),
        ...word(values.length),
        values.length * 2,
        for (final v in values) ...word(v),
      ]);
      if (r.length != n * 2 + 2 || r[1] != n * 2) {
        throw const FormatException('Invalid read/write response');
      }
      return {'values': List.generate(n, (i) => u16(r, 2 + i * 2))};
    }
    if (command == 'diagnostics') {
      final action = d['action'] ?? 'loopback';
      if (action == 'loopback') {
        final value = bounded(d['data'] ?? 0xA5A5, 'data', 0, 65535),
            r = await client.request(unit, [8, 0, 0, ...word(value)]);
        return {'loopback': u16(r, 3) == value};
      }
      if (action == 'clear') {
        await client.request(unit, [8, 0, 10, 0, 0]);
        return {};
      }
      if (action == 'counters') {
        final counters = <String, int>{};
        for (final entry in const {
          11: 'bus_message_count',
          12: 'bus_communication_error_count',
          13: 'bus_exception_error_count',
          14: 'slave_message_count',
          15: 'slave_no_response_count',
          16: 'slave_nak_count',
          17: 'slave_busy_count',
          18: 'bus_character_overrun_count',
        }.entries) {
          try {
            final r = await client.request(unit, [8, ...word(entry.key), 0, 0]);
            counters[entry.value] = u16(r, 3);
          } on ModbusError {
            continue;
          }
        }
        return {'counters': counters};
      }
      throw const FormatException('Unknown diagnostic action');
    }
    if (command == 'device_id') {
      final objects = <String, String>{};
      var next = 0;
      final seen = <int>{};
      while (seen.add(next)) {
        final r = await client.request(unit, [43, 14, 1, next]);
        if (r.length < 7 || r[1] != 14) {
          throw const FormatException('Invalid device identification');
        }
        var offset = 7;
        for (var i = 0; i < r[6]; i++) {
          if (offset + 2 > r.length) {
            throw const FormatException('Truncated identification');
          }
          final id = r[offset], len = r[offset + 1];
          offset += 2;
          if (offset + len > r.length) {
            throw const FormatException('Truncated identification');
          }
          objects['$id'] = utf8.decode(
            r.sublist(offset, offset + len),
            allowMalformed: true,
          );
          offset += len;
        }
        if (r[4] == 0) break;
        next = r[5];
      }
      return {'objects': objects};
    }
    if (command == 'scan_unit') {
      final probes = d['probes'];
      if (probes is! List || probes.isEmpty || probes.length > 32) {
        throw const FormatException('probes must contain 1..32 probe objects');
      }
      final parsed = [for (final p in probes) row(p, unit)];
      final hits = <int>[];
      for (var i = 0; i < parsed.length; i++) {
        final r = parsed[i];
        try {
          await client.read(unit, r['kind'], r['address'], r['count']);
          hits.add(i);
        } catch (_) {
          continue;
        }
      }
      return {'unit': unit, 'hits': hits};
    }
    final kind = d['kind'] ?? 'holding_registers',
        address = bounded(d['address'] ?? 0, 'address', 0, 65535);
    if (!kinds.contains(kind)) {
      throw const FormatException('Unknown register area');
    }
    if (command == 'scan_address') {
      List<dynamic> values = [];
      try {
        values = await client.read(
          unit,
          kind,
          address,
          bitKind(kind) || address == 65535 ? 1 : 2,
        );
      } catch (_) {
        if (!bitKind(kind)) {
          try {
            values = await client.read(unit, kind, address, 1);
          } catch (_) {}
        }
      }
      return {
        'address': address,
        'values': values,
        'formats': {
          if (values.isNotEmpty && !bitKind(kind))
            for (final fmt in [
              'u16',
              'hex',
              's16',
              'u32',
              's32',
              'f32',
              'ascii',
            ])
              fmt: render(
                row({
                  'kind': kind,
                  'address': address,
                  'count': values.length,
                  'format': width(fmt) > values.length ? 'u16' : fmt,
                }),
                values,
              )['display'],
        },
      };
    }
    if (command == 'read') {
      advanceDemo();
      return {
        'values': await client.read(
          unit,
          kind,
          address,
          bounded(d['count'] ?? 1, 'count', 1, bitKind(kind) ? 2000 : 125),
        ),
      };
    }
    if (command == 'write') {
      await client.write(unit, kind, address, d['values'] as List);
      return {};
    }
    throw FormatException('Unknown command: $command');
  }

  List<dynamic> _validated(Json r) {
    validateRaw(r, r['values']);
    return r['values'];
  }
}
