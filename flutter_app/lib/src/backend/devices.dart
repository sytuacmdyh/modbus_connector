import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'expression.dart';
import 'registers.dart';
import 'wire.dart';

class DataStore {
  final areas = <String, Map<int, dynamic>>{for (final k in kinds) k: {}};
  List<dynamic> get(String k, int a, int n) =>
      List.generate(n, (i) => areas[k]![a + i] ?? (bitKind(k) ? false : 0));
  void set(String k, int a, List<dynamic> values) {
    if (a < 0 || a + values.length > 10000) throw ModbusError(2);
    for (var i = 0; i < values.length; i++) {
      areas[k]![a + i] = bitKind(k)
          ? values[i] == true || values[i] == 1
          : values[i];
    }
  }

  void Function(String, int, List<dynamic>)? onWrite;
  List<int> handle(List<int> pdu) {
    if (pdu.isEmpty) return [];
    final fc = pdu[0];
    try {
      if (pdu.length < 5 && fc != 43) throw ModbusError(3);
      final a = pdu.length >= 3 ? u16(pdu, 1) : 0,
          n = pdu.length >= 5 ? u16(pdu, 3) : 0;
      void range(int address, int count, [int limit = 125]) {
        if (count < 1 || count > limit) throw ModbusError(3);
        if (address + count > 10000) throw ModbusError(2);
      }

      void write(String k, int address, List<dynamic> values) {
        set(k, address, values);
        onWrite?.call(k, address, values);
      }

      if (fc >= 1 && fc <= 4) {
        final k = kinds[fc - 1], bit = fc <= 2;
        range(a, n, bit ? 2000 : 125);
        if (pdu.length != 5) throw ModbusError(3);
        final v = get(k, a, n);
        final bytes = bit
            ? List.generate((n + 7) ~/ 8, (i) {
                var b = 0;
                for (var j = 0; j < 8 && i * 8 + j < n; j++) {
                  if (v[i * 8 + j] == true) b |= 1 << j;
                }
                return b;
              })
            : [for (final x in v) ...word(x)];
        return [fc, bytes.length, ...bytes];
      }
      if (fc == 5 || fc == 6) {
        range(a, 1);
        if (pdu.length != 5 || (fc == 5 && n != 0 && n != 65280)) {
          throw ModbusError(3);
        }
        write(fc == 5 ? 'coils' : 'holding_registers', a, [
          fc == 5 ? n == 65280 : n,
        ]);
        return pdu;
      }
      if (fc == 15 || fc == 16) {
        range(a, n, fc == 15 ? 1968 : 123);
        if (pdu.length < 6) throw ModbusError(3);
        final bytes = fc == 15 ? (n + 7) ~/ 8 : n * 2;
        if (pdu[5] != bytes || pdu.length != bytes + 6) throw ModbusError(3);
        write(
          fc == 15 ? 'coils' : 'holding_registers',
          a,
          fc == 15
              ? List.generate(n, (i) => pdu[6 + i ~/ 8] & (1 << (i % 8)) != 0)
              : List.generate(n, (i) => u16(pdu, 6 + i * 2)),
        );
        return pdu.sublist(0, 5);
      }
      if (fc == 22) {
        range(a, 1);
        if (pdu.length != 7) throw ModbusError(3);
        final or = u16(pdu, 5), old = get('holding_registers', a, 1)[0] as int;
        write('holding_registers', a, [(old & n) | (or & (~n & 65535))]);
        return pdu;
      }
      if (fc == 23) {
        if (pdu.length < 10) throw ModbusError(3);
        range(a, n);
        final wa = u16(pdu, 5), wn = u16(pdu, 7);
        range(wa, wn, 121);
        if (pdu[9] != wn * 2 || pdu.length != 10 + wn * 2) throw ModbusError(3);
        write(
          'holding_registers',
          wa,
          List.generate(wn, (i) => u16(pdu, 10 + i * 2)),
        );
        return [
          fc,
          n * 2,
          for (final v in get('holding_registers', a, n)) ...word(v),
        ];
      }
      if (fc == 8) {
        if (pdu.length != 5) throw ModbusError(3);
        return [fc, ...word(a), ...word(a == 0 ? n : 0)];
      }
      if (fc == 43) {
        if (pdu.length != 4 || pdu[1] != 14) throw ModbusError(3);
        const objects = ['Modbus Connector', 'Dart Simulator', '1.0'];
        return [
          43,
          14,
          pdu[2],
          1,
          0,
          0,
          3,
          for (var i = 0; i < 3; i++) ...[
            i,
            objects[i].length,
            ...objects[i].codeUnits,
          ],
        ];
      }
      throw ModbusError(1);
    } on ModbusError catch (e) {
      return [fc | 128, e.code];
    }
  }
}

class ModbusServer {
  ServerSocket? server;
  SerialChannel? serial;
  StreamSubscription<dynamic>? listener;
  final clients = <Socket, StreamSubscription<Uint8List>>{};
  Future<List<int>> Function(int, List<int>)? handler;
  void Function(bool)? onClient;
  Future<void> _tail = Future.value();
  bool get running => server != null || serial != null;
  Future<void> start(
    Json raw,
    Future<List<int>> Function(int, List<int>) handle,
  ) async {
    final p = connection(raw);
    if (p['transport'] == 'rtu_udp') {
      throw const FormatException('UDP is available for targets only');
    }
    await close();
    handler = handle;
    final tcp = p['transport'] == 'tcp';
    void attach(
      Stream<Uint8List> stream,
      Future<void> Function(List<int>) send,
      void Function() done,
    ) {
      final parser = FrameParser(tcp: tcp, request: true);
      final sub = stream.listen(
        (bytes) {
          for (final f in parser.feed(bytes)) {
            _tail = _tail
                .then((_) async {
                  if (!running) return;
                  final unit = f[tcp ? 6 : 0],
                      pdu = f.sublist(
                        tcp ? 7 : 1,
                        tcp ? f.length : f.length - 2,
                      );
                  final response = await handle(unit, pdu);
                  if (response.isNotEmpty && unit != 0) {
                    await send(
                      tcp
                          ? tcpFrame(u16(f, 0), unit, response)
                          : rtuFrame(unit, response),
                    );
                  }
                })
                .catchError((Object _) {});
          }
        },
        onError: (Object _) => done(),
        onDone: done,
      );
      if (stream is Socket) {
        clients[stream] = sub;
      } else {
        listener = sub;
      }
    }

    if (p['transport'] == 'rtu') {
      serial = SerialChannel(p);
      attach(serial!.stream, (b) => serial!.write(b), () {});
    } else {
      server = await ServerSocket.bind(
        InternetAddress.tryParse(p['host']) ?? p['host'],
        p['port'],
      );
      listener = server!.listen((s) {
        onClient?.call(true);
        attach(
          s,
          (b) async {
            s.add(b);
          },
          () {
            clients.remove(s);
            s.destroy();
            onClient?.call(false);
          },
        );
      });
    }
  }

  Future<void> close() async {
    final s = server;
    server = null;
    await s?.close();
    await listener?.cancel();
    listener = null;
    for (final e in clients.entries.toList()) {
      await e.value.cancel();
      e.key.destroy();
    }
    clients.clear();
    serial?.close();
    serial = null;
    await _tail;
  }
}

class NativeDevices {
  final store = DataStore();
  final server = ModbusServer();
  final target = ModbusClient();
  SerialChannel? sniffer;
  StreamSubscription<Uint8List>? sniffSubscription;
  final events = <Json>[];
  int dropped = 0;
  String mode = '';
  List<Json> rows = [];
  final ruleErrors = <String, Json>{};
  final rules = <int, Expression>{};
  final previous = <int, num>{};
  Timer? ticker;
  final started = Stopwatch();
  final recovered = <int, Map<String, Map<int, dynamic>>>{};
  final _pending = <String, (int, int)>{};
  bool get running => server.running || sniffer != null;
  void emit(String event, Json data) {
    if (events.length >= 2000) {
      events.removeAt(0);
      dropped++;
    }
    events.add({'mode': mode, 'event': event, ...data});
  }

  Future<void> close() async {
    ticker?.cancel();
    ticker = null;
    await target.close();
    await server.close();
    await sniffSubscription?.cancel();
    sniffSubscription = null;
    sniffer?.close();
    sniffer = null;
    started.stop();
  }

  void configure(Json d) {
    final list = (d['rows'] as List);
    if (list.length > 512) {
      throw const FormatException('At most 512 simulator rows');
    }
    final parsed = list.map((v) => row(v)).toList();
    for (final r in parsed) {
      if ((r['address'] as int) + (r['count'] as int) > 10000) {
        throw const FormatException('Simulator addresses must be below 10000');
      }
      if (r['values'] != null) validateRaw(r, r['values']);
    }
    rows = parsed;
    rules.clear();
    previous.clear();
    ruleErrors.clear();
    for (var i = 0; i < rows.length; i++) {
      final r = rows[i];
      if (r['values'] != null) store.set(r['kind'], r['address'], r['values']);
      final text = r['rule_text'] ?? '';
      if (text != '') {
        try {
          rules[i] = Expression(text, simulator: true);
        } catch (e) {
          ruleErrors['$i'] = {'code': 'invalid_rule', 'detail': '$e'};
        }
      }
    }
  }

  void tick() {
    final values = <String, num>{};
    for (final r in rows) {
      if (['hex', 'ascii', 'ascii1'].contains(r['format'])) continue;
      final raw = store.get(r['kind'], r['address'], r['count']);
      values[r['name']] = bitKind(r['kind'])
          ? (raw[0] == true ? 1 : 0)
          : decode(raw, r['format'], r['order'])[0];
    }
    for (final e in rules.entries) {
      final i = e.key, r = rows[i];
      try {
        final value = e.value.evaluate({
          ...values,
          't': started.elapsedMilliseconds / 1000,
          'prev': previous[i] ?? values[r['name']] ?? 0,
        });
        if (!value.isFinite) {
          ruleErrors['$i'] = {'code': 'nonfinite_rule', 'detail': ''};
          continue;
        }
        final raw = bitKind(r['kind'])
            ? [bankersRound(value) != 0]
            : encodeNumber(value, r['format'], r['order']);
        store.set(
          r['kind'],
          r['address'],
          List.generate(r['count'], (i) => raw[i % raw.length]),
        );
        previous[i] = value;
        ruleErrors.remove('$i');
      } catch (e) {
        ruleErrors['$i'] = {
          'code': e is StateError
              ? 'missing_reference'
              : 'rule_evaluation_failed',
          'detail': '$e',
        };
      }
    }
  }

  void feedSniffer(List<int> bytes, FrameParser parser) {
    for (final f in parser.feed(bytes)) {
      final unit = f[0], fc = f[1];
      emit('traffic', {
        'unit': unit,
        'line': 'RTU $unit FC${fc.toRadixString(16)} ${hexBytes(f)}',
      });
      if (fc & 128 != 0) {
        _pending.remove('$unit/${fc & 127}');
        continue;
      }
      String? kind;
      int? address;
      List<dynamic>? values;
      if (fc >= 1 && fc <= 4) {
        kind = kinds[fc - 1];
        final key = '$unit/$fc';
        if (f.length == 8 &&
            u16(f, 4) > 0 &&
            u16(f, 4) <= (fc <= 2 ? 2000 : 125)) {
          _pending[key] = (u16(f, 2), u16(f, 4));
          continue;
        }
        final pending = _pending.remove(key);
        if (pending != null &&
            f.length == 5 + f[2] &&
            f[2] == (fc <= 2 ? (pending.$2 + 7) ~/ 8 : pending.$2 * 2)) {
          address = pending.$1;
          values = fc <= 2
              ? List.generate(
                  pending.$2,
                  (i) => i ~/ 8 < f[2] && f[3 + i ~/ 8] & (1 << (i % 8)) != 0,
                )
              : [for (var i = 3; i < f.length - 2; i += 2) u16(f, i)];
        }
      } else if (fc == 5 || fc == 6) {
        kind = fc == 5 ? 'coils' : 'holding_registers';
        address = u16(f, 2);
        values = [fc == 5 ? u16(f, 4) == 65280 : u16(f, 4)];
      } else if ((fc == 15 || fc == 16) && f.length > 8) {
        kind = fc == 15 ? 'coils' : 'holding_registers';
        address = u16(f, 2);
        final n = u16(f, 4);
        if (n < 1 ||
            n > (fc == 15 ? 1968 : 123) ||
            f[6] != (fc == 15 ? (n + 7) ~/ 8 : n * 2) ||
            f.length != 9 + f[6]) {
          continue;
        }
        values = fc == 15
            ? List.generate(n, (i) => f[7 + i ~/ 8] & (1 << (i % 8)) != 0)
            : List.generate(n, (i) => u16(f, 7 + i * 2));
      }
      if (kind != null &&
          address != null &&
          values != null &&
          address + values.length <= 65536) {
        final area = recovered.putIfAbsent(
          unit,
          () => {for (final k in kinds) k: {}},
        )[kind]!;
        for (var i = 0; i < values.length; i++) {
          area[address + i] = values[i];
        }
        emit('values', {
          'unit': unit,
          'kind': kind,
          'address': address,
          'values': values,
        });
      }
    }
  }

  Future<Json> dispatch(Json d) async {
    final command = d['command'];
    if (command == 'sim_configure') {
      configure(d);
      return {'rule_errors': ruleErrors};
    }
    if (command == 'device_start') {
      final listen = connection(d['listen']), which = d['mode'];
      if (which == 'sniffer' && listen['transport'] != 'rtu') {
        throw const FormatException('Sniffer requires a serial RTU adapter');
      }
      final gatewayTarget = which == 'gateway' ? connection(d['target']) : null;
      final unit = d['unit'];
      if (unit != null) bounded(unit, 'unit', 1, 247);
      final interval = bounded(d['tick_ms'] ?? 1000, 'tick_ms', 100, 10000);
      final units = d['units'] as List?;
      if (units != null) {
        if (units.isEmpty) throw const FormatException('Select units');
        for (final u in units) {
          bounded(u, 'unit', 1, 247);
        }
      }
      if (!['simulator', 'gateway', 'sniffer'].contains(which)) {
        throw const FormatException('Unknown device mode');
      }
      await close();
      mode = which;
      try {
        if (which == 'sniffer') {
          recovered.clear();
          _pending.clear();
          sniffer = SerialChannel(listen, readOnly: true);
          final parser = FrameParser(tcp: false, sniff: true);
          sniffSubscription = sniffer!.stream.listen(
            (b) => feedSniffer(b, parser),
            onError: (Object e) {
              emit('error', {'line': '$e'});
              unawaited(close());
            },
          );
        } else {
          server.onClient = (b) => emit('client', {'connected': b});
          store.onWrite = (k, a, v) =>
              emit('values', {'kind': k, 'address': a, 'values': v});
          if (which == 'gateway') await target.connect(gatewayTarget!);
          await server.start(listen, (u, pdu) async {
            emit('traffic', {'line': 'Unit $u ${hexBytes(pdu)}'});
            if (which == 'simulator') {
              if (unit != null && u != unit && u != 0) return [];
              return store.handle(pdu);
            }
            if (u < 1 || u > 247 || (units != null && !units.contains(u))) {
              return [pdu[0] | 128, 11];
            }
            try {
              return await target.request(u, pdu);
            } on ModbusError catch (e) {
              return [pdu[0] | 128, e.code];
            } catch (e) {
              emit('error', {'line': '$e'});
              return [pdu[0] | 128, 11];
            }
          });
          if (which == 'simulator') {
            started
              ..reset()
              ..start();
            ticker = Timer.periodic(
              Duration(milliseconds: interval),
              (_) => tick(),
            );
          }
        }
      } catch (_) {
        await close();
        rethrow;
      }
      return {'running': true};
    }
    if (command == 'device_stop') {
      await close();
      return {'running': false};
    }
    if (command == 'sim_set') {
      final r = row(d['row']);
      validateRaw(r, d['values']);
      store.set(r['kind'], r['address'], d['values']);
      return {};
    }
    if (command == 'sniffer_snapshot') {
      final u = bounded(d['unit'] ?? 1, 'unit', 1, 247);
      return {
        'unit': u,
        'areas': {
          for (final e
              in (recovered[u] ?? {for (final k in kinds) k: <int, dynamic>{}})
                  .entries)
            e.key: {for (final v in e.value.entries) '${v.key}': v.value},
        },
      };
    }
    if (command == 'device_status') {
      final result = {
        'simulator': mode == 'simulator' && server.running,
        'gateway': mode == 'gateway' && server.running,
        'sniffer': sniffer != null,
        'events': List<Json>.from(events),
        'dropped': dropped,
        'rows': [
          for (final r in rows)
            render(r, store.get(r['kind'], r['address'], r['count'])),
        ],
        'rule_errors': Map<String, Json>.from(ruleErrors),
        'units': recovered.keys.toList()..sort(),
      };
      events.clear();
      dropped = 0;
      return result;
    }
    throw const FormatException('Unknown device command');
  }
}

void validateRaw(Json r, dynamic raw) {
  if (raw is! List || raw.length != r['count']) {
    throw const FormatException('Invalid raw sample');
  }
  for (final v in raw) {
    if (bitKind(r['kind'])) {
      if (v != true && v != false && v != 0 && v != 1) {
        throw const FormatException('Invalid bit');
      }
    } else {
      bounded(v, 'register', 0, 65535);
    }
  }
}
