import 'dart:async';

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

class ReadTimeout extends TimeoutException {
  ReadTimeout(this.context) : super('Modbus read timed out');
  final Json context;
}

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

class ReadCancelled implements Exception {
  @override
  String toString() => 'Read cancelled';
}

class ReadCancellation {
  final _signal = Completer<void>();
  bool get cancelled => _signal.isCompleted;
  void cancel() {
    if (!cancelled) _signal.complete();
  }

  void check() {
    if (cancelled) throw ReadCancelled();
  }

  Future<T> wait<T>(Future<T> future) => Future.any([
    future,
    _signal.future.then<T>((_) => throw ReadCancelled()),
  ]);
}

// A sliding CRC search recovers valid frames behind fragmented or noisy input.
class FrameParser {
  FrameParser({
    required this.tcp,
    this.request = false,
    this.sniff = false,
    this.onDiscard,
  });
  final void Function(List<int>)? onDiscard;
  final bool tcp, request, sniff;
  final buffer = <int>[];

  List<List<int>> feed(List<int> bytes) {
    buffer.addAll(bytes);
    if (buffer.length > 131072) _discard(buffer.length - 65536);
    final frames = <List<int>>[];
    if (tcp) {
      while (buffer.length >= 7) {
        final n = u16(buffer, 4);
        if (u16(buffer, 2) != 0 || n < 2 || n > 254) {
          _discard(1);
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
        if (offset > 0) onDiscard?.call(buffer.sublist(0, offset));
        frames.add(buffer.sublist(offset, end));
        buffer.removeRange(0, end);
        offset = -1;
        break;
      }
      offset++;
    }
    // No RTU ADU can exceed 256 bytes. Retain incomplete candidates only.
    if (buffer.length > 255) _discard(buffer.length - 255);
    return frames;
  }

  void _discard(int count) {
    onDiscard?.call(buffer.sublist(0, count));
    buffer.removeRange(0, count);
  }

  /// Preserve incomplete/invalid input in the traffic log at exchange boundaries.
  void flush() => _discard(buffer.length);

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
