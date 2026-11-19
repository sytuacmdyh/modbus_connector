import 'registers.dart';
import 'wire_protocol.dart';

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
