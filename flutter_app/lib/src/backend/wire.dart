import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_libserialport/flutter_libserialport.dart';

import 'registers.dart';

int u16(List<int> b, int i) => (b[i] << 8) | b[i + 1];
List<int> word(int v) => [v >> 8 & 255, v & 255];
int crc16(List<int> b) {
  var c = 65535;
  for (final v in b) {
    c ^= v;
    for (var i = 0; i < 8; i++) {
      c = c & 1 != 0 ? (c >> 1) ^ 0xa001 : c >> 1;
    }
  }
  return c;
}

List<int> rtuFrame(int unit, List<int> pdu) {
  final b = [unit, ...pdu];
  final crc = crc16(b);
  return [...b, crc & 255, crc >> 8];
}

List<int> tcpFrame(int id, int unit, List<int> pdu) => [
  ...word(id),
  0,
  0,
  ...word(pdu.length + 1),
  unit,
  ...pdu,
];
String hexBytes(List<int> b) =>
    b.map((v) => v.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');

class ModbusError implements Exception {
  ModbusError(this.code);
  final int code;
  @override
  String toString() =>
      'Modbus exception $code: ${const {1: 'Illegal function', 2: 'Illegal data address', 3: 'Illegal data value', 4: 'Slave device failure', 5: 'Acknowledge', 6: 'Slave device busy', 10: 'Gateway path unavailable', 11: 'Gateway target failed to respond'}[code] ?? 'Unknown exception'}';
}

Json connection(dynamic raw) {
  if (raw is! Map) throw const FormatException('connection must be an object');
  final p = <String, dynamic>{
    'transport': 'rtu',
    'timeout': 3,
    ...Map<String, dynamic>.from(raw),
  };
  final t = finite(p['timeout'], 'timeout');
  if (t < 0.1 || t > 60) {
    throw const FormatException('timeout must be 0.1..60 seconds');
  }
  if (p['transport'] == 'rtu') {
    if (p['port'] is! String || (p['port'] as String).trim().isEmpty) {
      throw const FormatException('Enter a serial port');
    }
    p['baudrate'] = bounded(p['baudrate'] ?? 9600, 'baudrate', 50, 4000000);
    p['bytesize'] = bounded(p['bytesize'] ?? 8, 'bytesize', 7, 8);
    p['stopbits'] = bounded(p['stopbits'] ?? 1, 'stopbits', 1, 2);
    p['parity'] ??= 'N';
    if (!['N', 'E', 'O'].contains(p['parity'])) {
      throw const FormatException('parity must be N, E or O');
    }
  } else {
    if (!['tcp', 'rtu_tcp', 'rtu_udp'].contains(p['transport']) ||
        p['host'] is! String ||
        (p['host'] as String).trim().isEmpty) {
      throw const FormatException('Choose a transport and host');
    }
    p['port'] = bounded(p['port'] ?? 502, 'port', 1, 65535);
  }
  return p;
}

String describe(Json p) => p['transport'] == 'rtu'
    ? 'rtu ${p['port']} @ ${p['baudrate']}'
    : '${p['transport']} ${p['host']}:${p['port']}';

class SerialChannel {
  SerialChannel(Json p, {bool readOnly = false}) {
    port = SerialPort(p['port']);
    try {
      if (!(readOnly ? port.openRead() : port.openReadWrite())) {
        throw StateError('Could not open serial port: ${SerialPort.lastError}');
      }
      final config = SerialPortConfig()
        ..baudRate = p['baudrate']
        ..bits = p['bytesize']
        ..parity = ({
          'N': SerialPortParity.none,
          'E': SerialPortParity.even,
          'O': SerialPortParity.odd,
        }[p['parity']]!)
        ..stopBits = p['stopbits']
        ..setFlowControl(SerialPortFlowControl.none);
      try {
        port.config = config;
      } finally {
        config.dispose();
      }
      timer = Timer.periodic(const Duration(milliseconds: 2), (_) {
        try {
          final available = port.bytesAvailable;
          if (available < 0) throw StateError('Serial read failed');
          if (available > 0) {
            final bytes = port.read(available.clamp(1, 4096));
            if (bytes.isNotEmpty) incoming.add(bytes);
          }
        } catch (error, stack) {
          timer.cancel();
          incoming.addError(error, stack);
        }
      });
    } catch (_) {
      port.close();
      port.dispose();
      rethrow;
    }
  }
  late final SerialPort port;
  late final Timer timer;
  final incoming = StreamController<Uint8List>();
  bool closed = false;
  Stream<Uint8List> get stream => incoming.stream;
  Future<void> write(List<int> b) async {
    var i = 0;
    final watch = Stopwatch()..start();
    while (i < b.length) {
      if (watch.elapsedMilliseconds > 5000) {
        throw TimeoutException('Serial write timed out');
      }
      final n = port.write(Uint8List.fromList(b.sublist(i)));
      if (n < 0) throw StateError('Serial write failed');
      i += n;
      if (i < b.length) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
    }
  }

  void close() {
    if (closed) return;
    closed = true;
    timer.cancel();
    unawaited(incoming.close());
    port.close();
    port.dispose();
  }
}

// A sliding CRC search recovers valid frames behind fragmented or noisy input.
class FrameParser {
  FrameParser({required this.tcp, this.request = false, this.sniff = false});
  final bool tcp, request, sniff;
  final buffer = <int>[];

  List<List<int>> feed(List<int> bytes) {
    buffer.addAll(bytes);
    if (buffer.length > 131072) buffer.removeRange(0, buffer.length - 65536);
    final frames = <List<int>>[];
    if (tcp) {
      while (buffer.length >= 7) {
        final n = u16(buffer, 4);
        if (u16(buffer, 2) != 0 || n < 2 || n > 254) {
          buffer.removeAt(0);
          continue;
        }
        if (buffer.length < n + 6) break;
        frames.add(buffer.sublist(0, n + 6));
        buffer.removeRange(0, n + 6);
      }
      return frames;
    }
    var offset = 0;
    while (offset + 4 <= buffer.length) {
      if (buffer[offset] > 247) {
        offset++;
        continue;
      }
      for (final n in _lengths(offset)) {
        if (n < 5 || n > 256 || offset + n > buffer.length) continue;
        final end = offset + n;
        if (crc16(buffer.sublist(offset, end - 2)) !=
            (buffer[end - 2] | buffer[end - 1] << 8)) {
          continue;
        }
        frames.add(buffer.sublist(offset, end));
        buffer.removeRange(0, end);
        offset = -1;
        break;
      }
      offset++;
    }
    // No RTU ADU can exceed 256 bytes. Retain incomplete candidates only.
    if (buffer.length > 255) buffer.removeRange(0, buffer.length - 255);
    return frames;
  }

  List<int> _lengths(int start) {
    final left = buffer.length - start;
    int at(int i) => buffer[start + i];
    final fc = at(1), out = <int>[];
    if (fc & 128 != 0) return [5];
    if (sniff || request) {
      if ([1, 2, 3, 4, 5, 6, 8].contains(fc)) out.add(8);
      if ([15, 16].contains(fc) && left >= 7) out.add(9 + at(6));
      if (fc == 22) out.add(10);
      if (fc == 23 && left >= 11) out.add(13 + at(10));
      if (fc == 43) out.add(7);
    }
    if (sniff || !request) {
      if ([1, 2, 3, 4, 23].contains(fc)) out.add(5 + at(2));
      if ([5, 6, 8, 15, 16].contains(fc)) out.add(8);
      if (fc == 22) out.add(10);
      if (fc == 43 && left >= 8) {
        var pos = 8;
        for (var i = 0; i < at(7); i++) {
          if (pos + 2 > left) return out;
          pos += 2 + at(pos + 1);
        }
        out.add(pos + 2);
      }
    }
    return out;
  }
}

class ModbusClient {
  Socket? socket;
  RawDatagramSocket? udp;
  InternetAddress? udpHost;
  SerialChannel? serial;
  StreamSubscription<dynamic>? subscription;
  Completer<List<int>>? pending;
  Json? params;
  int transaction = 0;
  int expectedId = 0, expectedUnit = 0;
  DateTime? drainUntil;
  FrameParser? activeParser;
  bool get connected => params != null;
  void Function(String, List<int>)? traffic;
  Future<void> _tail = Future.value();
  Future<T> serialized<T>(Future<T> Function() work) {
    final next = _tail.then((_) => work());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<void> connect(Json raw) async {
    final p = connection(raw);
    await close();
    final tcp = p['transport'] == 'tcp';
    final parser = activeParser = FrameParser(tcp: tcp);
    drainUntil = null;
    void receive(List<int> b) {
      traffic?.call('rx', b);
      if (drainUntil != null) {
        if (DateTime.now().isBefore(drainUntil!)) return;
        drainUntil = null;
        parser.buffer.clear();
      }
      for (final f in parser.feed(b)) {
        if (tcp && u16(f, 0) != expectedId) continue;
        final unit = f[tcp ? 6 : 0];
        if (unit != expectedUnit) continue;
        final c = pending;
        if (c != null && !c.isCompleted) {
          c.complete(f.sublist(tcp ? 7 : 1, tcp ? f.length : f.length - 2));
        }
      }
    }

    void ended([Object? error]) {
      params = null;
      final c = pending;
      if (c != null && !c.isCompleted) {
        c.completeError(error ?? const SocketException('Connection closed'));
      }
    }

    try {
      final timeout = Duration(
        milliseconds: ((p['timeout'] as num) * 1000).round(),
      );
      if (p['transport'] == 'rtu') {
        serial = SerialChannel(p);
        subscription = serial!.stream.listen(
          receive,
          onError: ended,
          onDone: ended,
        );
      } else if (p['transport'] == 'rtu_udp') {
        udpHost =
            InternetAddress.tryParse(p['host']) ??
            (await InternetAddress.lookup(p['host'])).first;
        udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
        subscription = udp!.listen(
          (event) {
            if (event == RawSocketEvent.read) {
              Datagram? d;
              while ((d = udp!.receive()) != null) {
                if (d!.address.address == udpHost!.address &&
                    d.port == p['port']) {
                  receive(d.data);
                }
              }
            }
          },
          onError: ended,
          onDone: ended,
        );
      } else {
        socket = await Socket.connect(
          InternetAddress.tryParse(p['host']) ?? p['host'],
          p['port'],
          timeout: timeout,
        );
        socket!.setOption(SocketOption.tcpNoDelay, true);
        subscription = socket!.listen(receive, onError: ended, onDone: ended);
      }
      params = p;
    } catch (_) {
      await close();
      rethrow;
    }
  }

  Future<void> close() async {
    params = null;
    final c = pending;
    if (c != null && !c.isCompleted) {
      c.completeError(const SocketException('Disconnected'));
    }
    await subscription?.cancel();
    subscription = null;
    socket?.destroy();
    socket = null;
    udp?.close();
    udp = null;
    serial?.close();
    serial = null;
  }

  Future<List<int>> request(int unit, List<int> pdu) => serialized(() async {
    final p = params;
    if (p == null) throw const SocketException('Not connected; connect again');
    if (drainUntil != null) {
      final delay = drainUntil!.difference(DateTime.now());
      if (!delay.isNegative) await Future<void>.delayed(delay);
      drainUntil = null;
      activeParser?.buffer.clear();
      if (!connected) throw const SocketException('Disconnected');
    }
    expectedUnit = unit;
    expectedId = transaction = (transaction + 1) & 65535;
    final tcp = p['transport'] == 'tcp';
    final packet = tcp ? tcpFrame(transaction, unit, pdu) : rtuFrame(unit, pdu);
    final c = Completer<List<int>>();
    pending = c;
    // Attach the response listener before writing so disconnect errors are observed.
    Future<List<int>> exchange() async {
      final response = await c.future.timeout(
        Duration(milliseconds: ((p['timeout'] as num) * 1000).round()),
      );
      return response;
    }

    final reply = exchange();
    unawaited(reply.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
    try {
      traffic?.call('tx', packet);
      if (socket != null) {
        socket!.add(packet);
      } else if (udp != null) {
        udp!.send(packet, udpHost!, p['port']);
      } else {
        await serial!
            .write(packet)
            .timeout(
              Duration(milliseconds: ((p['timeout'] as num) * 1000).round()),
            );
      }
      final response = await reply;
      if (response.isEmpty) {
        throw const FormatException('Empty Modbus response');
      }
      if (response[0] & 128 != 0) {
        if (response.length != 2 || response[0] != (pdu[0] | 128)) {
          throw const FormatException('Invalid exception response');
        }
        throw ModbusError(response[1]);
      }
      if (response[0] != pdu[0]) {
        throw const FormatException('Unexpected function code');
      }
      return response;
    } on TimeoutException {
      activeParser?.buffer.clear();
      // TCP IDs reject late replies. RTU has no IDs: drain a full timeout
      // before the next request, preserving polling on an open transport.
      if (!tcp) {
        drainUntil = DateTime.now().add(
          Duration(milliseconds: ((p['timeout'] as num) * 1000).round()),
        );
      }
      rethrow;
    } finally {
      if (identical(pending, c)) pending = null;
    }
  });
  Future<List<dynamic>> read(
    int unit,
    String kind,
    int address,
    int count,
  ) async {
    bounded(unit, 'unit', 1, 247);
    bounded(address, 'address', 0, 65535);
    bounded(count, 'count', 1, bitKind(kind) ? 2000 : 125);
    if (address + count > 65536 || !kinds.contains(kind)) {
      throw const FormatException('Invalid read range');
    }
    final fc = kinds.indexOf(kind) + 1;
    final r = await request(unit, [fc, ...word(address), ...word(count)]);
    final n = bitKind(kind) ? (count + 7) ~/ 8 : count * 2;
    if (r.length != n + 2 || r[1] != n) {
      throw const FormatException('Invalid read response length');
    }
    return bitKind(kind)
        ? List.generate(count, (i) => r[2 + i ~/ 8] & (1 << (i % 8)) != 0)
        : List.generate(count, (i) => u16(r, 2 + i * 2));
  }

  Future<void> write(
    int unit,
    String kind,
    int address,
    List<dynamic> values,
  ) async {
    if (!['coils', 'holding_registers'].contains(kind)) {
      throw const FormatException('This register area is read-only');
    }
    bounded(address, 'address', 0, 65535);
    bounded(unit, 'unit', 1, 247);
    bounded(values.length, 'count', 1, kind == 'coils' ? 1968 : 123);
    if (address + values.length > 65536) {
      throw const FormatException('Address range exceeds 65535');
    }
    for (final v in values) {
      if (kind == 'coils') {
        if (v != true && v != false && v != 0 && v != 1) {
          throw const FormatException('Invalid coil value');
        }
      } else {
        bounded(v, 'value', 0, 65535);
      }
    }
    final bit = kind == 'coils', single = values.length == 1;
    late List<int> pdu;
    if (single) {
      pdu = [
        bit ? 5 : 6,
        ...word(address),
        ...word(
          bit ? (values[0] == true || values[0] == 1 ? 65280 : 0) : values[0],
        ),
      ];
    } else {
      final data = bit
          ? List.generate((values.length + 7) ~/ 8, (i) {
              var b = 0;
              for (var j = 0; j < 8 && i * 8 + j < values.length; j++) {
                if (values[i * 8 + j] == true || values[i * 8 + j] == 1) {
                  b |= 1 << j;
                }
              }
              return b;
            })
          : [for (final v in values) ...word(v)];
      pdu = [
        bit ? 15 : 16,
        ...word(address),
        ...word(values.length),
        data.length,
        ...data,
      ];
    }
    final r = await request(unit, pdu);
    if (r.length != 5 || r.take(5).join(',') != pdu.take(5).join(',')) {
      throw const FormatException('Invalid write acknowledgement');
    }
  }
}
