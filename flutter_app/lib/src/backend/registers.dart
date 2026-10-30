import 'dart:math' as math;
import 'dart:typed_data';

import 'expression.dart';

typedef Json = Map<String, dynamic>;
const kinds = [
  'coils',
  'discrete_inputs',
  'holding_registers',
  'input_registers',
];
const formats = [
  'u16',
  'hex',
  's16',
  'u32',
  's32',
  'f32',
  'u64',
  's64',
  'f64',
  'ascii',
  'ascii1',
];
String canonicalFormat(dynamic value) {
  final text = value == null ? 'u16' : '$value'.toLowerCase();
  return text == 'dec' ? 'u16' : text;
}
const orders = ['ABCD', 'BADC', 'CDAB', 'DCBA'];
bool bitKind(dynamic kind) => kind == 'coils' || kind == 'discrete_inputs';
int bounded(dynamic value, String name, int low, int high) {
  if (value is! int || value < low || value > high) {
    throw FormatException('$name must be an integer in $low..$high');
  }
  return value;
}

num finite(dynamic value, String name) {
  if (value is! num || !value.isFinite) {
    throw FormatException('$name must be finite');
  }
  return value;
}

int width(String fmt) => ['u32', 's32', 'f32'].contains(fmt)
    ? 2
    : ['u64', 's64', 'f64'].contains(fmt)
    ? 4
    : 1;
Json row(dynamic data, [int unit = 1]) {
  if (data is! Map) throw const FormatException('row must be an object');
  final r = <String, dynamic>{
    'name': '',
    'kind': 'holding_registers',
    'address': 0,
    'count': 1,
    'format': 'u16',
    'order': 'ABCD',
    'scale': 1,
    'offset': 0,
    'unit': '',
    ...Map<String, dynamic>.from(data),
  };
  r['format'] = canonicalFormat(r['format']);
  // Per-row polling intervals are no longer supported. Keep accepting the
  // legacy field while ensuring all callers use the global map interval.
  r['poll_ms'] = null;
  r['order'] ??= 'ABCD';
  if (!kinds.contains(r['kind']) ||
      !formats.contains(r['format']) ||
      !orders.contains(r['order'])) {
    throw const FormatException('Unknown register area, format or byte order');
  }
  final a = bounded(r['address'], 'address', 0, 65535),
      c = bounded(r['count'], 'count', 1, bitKind(r['kind']) ? 2000 : 125);
  if (a + c > 65536 || (!bitKind(r['kind']) && c < width(r['format']))) {
    throw const FormatException('Invalid row range or display width');
  }
  r['unit_id'] = bounded(r['unit_id'] ?? unit, 'unit_id', 1, 247);
  finite(r['scale'], 'scale');
  finite(r['offset'], 'offset');
  return r;
}

List<int> permutation(String order, int n) => switch (order) {
  'BADC' => List.generate(n, (i) => i ^ 1),
  'CDAB' => [
    for (var w = n ~/ 2 - 1; w >= 0; w--) ...[w * 2, w * 2 + 1],
  ],
  'DCBA' => List.generate(n, (i) => n - i - 1),
  _ => List.generate(n, (i) => i),
};
List<num> decode(List<dynamic> raw, String fmt, [String order = 'ABCD']) {
  final values = raw.map((v) => v is bool ? (v ? 1 : 0) : v as int).toList();
  fmt = canonicalFormat(fmt);
  if (fmt == 'u16') return values;
  if (fmt == 's16') {
    return values.map((v) => v >= 32768 ? v - 65536 : v).toList();
  }
  final size = width(fmt);
  final out = <num>[];
  for (var i = 0; i < values.length; i += size) {
    if (i + size > values.length) {
      out.addAll(values.sublist(i));
      break;
    }
    final bytes = [
      for (final v in values.sublist(i, i + size)) ...[v >> 8, v & 255],
    ];
    final b = ByteData.sublistView(
      Uint8List.fromList([
        for (final j in permutation(order, bytes.length)) bytes[j],
      ]),
    );
    out.add(switch (fmt) {
      'u32' => b.getUint32(0),
      's32' => b.getInt32(0),
      'u64' => bytesToUnsigned(b.buffer.asUint8List()),
      's64' => b.getInt64(0),
      'f32' => b.getFloat32(0),
      'f64' => b.getFloat64(0),
      _ => throw const FormatException('Not a numeric format'),
    });
  }
  return out;
}

List<int> encodeNumber(num value, String fmt, [String order = 'ABCD']) {
  finite(value, 'value');
  fmt = canonicalFormat(fmt);
  if (fmt == 'u16') return [bankersRound(value.clamp(0, 65535))];
  if (fmt == 's16') return [bankersRound(value.clamp(-32768, 32767)) & 65535];
  final n = width(fmt) * 2;
  final b = ByteData(n);
  if (fmt == 'f32') {
    b.setFloat32(0, value.toDouble());
    if (!b.getFloat32(0).isFinite) {
      throw const FormatException('Float32 overflow');
    }
  } else if (fmt == 'f64') {
    b.setFloat64(0, value.toDouble());
  } else {
    final signed = fmt.startsWith('s');
    final bits = n * 8;
    final big = value.abs() < 9007199254740992
        ? BigInt.from(bankersRound(value))
        : BigInt.from(value.roundToDouble());
    final lo = signed ? -(BigInt.one << (bits - 1)) : BigInt.zero;
    final hi = (BigInt.one << (signed ? bits - 1 : bits)) - BigInt.one;
    var x = big < lo
        ? lo
        : big > hi
        ? hi
        : big;
    if (x.isNegative) x += BigInt.one << bits;
    for (var i = n - 1; i >= 0; i--) {
      b.setUint8(i, (x & BigInt.from(255)).toInt());
      x >>= 8;
    }
  }
  final bytes = b.buffer.asUint8List();
  final raw = [for (final i in permutation(order, n)) bytes[i]];
  return [for (var i = 0; i < n; i += 2) (raw[i] << 8) | raw[i + 1]];
}

num bytesToUnsigned(Uint8List bytes) {
  var n = BigInt.zero;
  for (final b in bytes) {
    n = (n << 8) | BigInt.from(b);
  }
  return n <= BigInt.from(0x7fffffffffffffff) ? n.toInt() : n.toDouble();
}

String numberText(num value, [int precision = 6]) {
  if (!value.isFinite) {
    return value.isNaN
        ? 'nan'
        : value.isNegative
        ? '-inf'
        : 'inf';
  }
  if (value == 0) return value.isNegative ? '-0' : '0';
  var exponent = (math.log(value.abs()) / math.ln10).floor();
  var scale = math.pow(10, precision - 1 - exponent).toDouble();
  var rounded = value.toDouble();
  if (scale.isFinite && scale != 0 && (rounded * scale).abs() < 9e15) {
    rounded = bankersRound(rounded * scale) / scale;
  }
  if (rounded != 0) exponent = (math.log(rounded.abs()) / math.ln10).floor();
  String trim(String s) =>
      s.contains('.') ? s.replaceFirst(RegExp(r'\.?0+$'), '') : s;
  if (exponent < -4 || exponent >= precision) {
    final parts = rounded.toStringAsExponential(precision - 1).split('e');
    final e = int.parse(parts[1]);
    return '${trim(parts[0])}e${e < 0 ? '-' : '+'}${e.abs().toString().padLeft(2, '0')}';
  }
  return trim(rounded.toStringAsFixed(math.max(0, precision - 1 - exponent)));
}

Json? alarm(num? value, dynamic alarms) {
  if (value == null || !value.isFinite || alarms is! List) return null;
  for (final raw in alarms) {
    if (raw is! Map || raw['value'] is! num) continue;
    final r = Map<String, dynamic>.from(raw);
    var x = r['value'] as num;
    if (r['value2'] != null && r['value2'] is! num) continue;
    var y = r['value2'] as num?;
    final range = ['in_range', 'outside_range'].contains(r['condition']);
    if (!x.isFinite ||
        (y != null && !y.isFinite) ||
        (range && y == null) ||
        (!range && y != null) ||
        !['red', 'yellow'].contains(r['color'] ?? 'red')) {
      continue;
    }
    if (range && y! < x) {
      final previous = x;
      x = y;
      y = previous;
      r['value'] = x;
      r['value2'] = y;
    }
    final inside =
        y != null && value >= math.min(x, y) && value <= math.max(x, y);
    final match = switch (r['condition']) {
      'gt' => value > x,
      'ge' => value >= x,
      'lt' => value < x,
      'le' => value <= x,
      'eq' => value == x,
      'ne' => value != x,
      'in_range' => inside,
      'outside_range' => y != null && !inside,
      _ => false,
    };
    if (match) return {'color': 'red', 'log': true, 'sound': false, ...r};
  }
  return null;
}

Json render(Json r, List<dynamic> raw) {
  // Render callers may pass a legacy workspace row directly rather than the
  // normalized result of row(); canonicalize here as a final compatibility
  // guard so old `dec` rows use the same u16 behavior and labels.
  final fmt = canonicalFormat(r['format']);
  final bit = bitKind(r['kind']);
  final values = raw.map((v) => v is bool ? (v ? 1 : 0) : v as int).toList();
  num? primary;
  String display;
  if (bit) {
    primary = values.first * (r['scale'] as num) + (r['offset'] as num);
    display = values.join(', ');
  } else if (fmt == 'hex') {
    display = values
        .map((v) => '0x${v.toRadixString(16).padLeft(4, '0').toUpperCase()}')
        .join(', ');
  } else if (fmt == 'ascii' || fmt == 'ascii1') {
    final bytes = [
      for (final v in values) ...fmt == 'ascii' ? [v >> 8, v & 255] : [v & 255],
    ];
    display = String.fromCharCodes(
      bytes.takeWhile((b) => b != 0).map((b) => b >= 32 && b <= 126 ? b : 46),
    );
  } else {
    final nums = decode(raw, fmt, r['order']);
    final scaled = nums
        .map((v) => v * (r['scale'] as num) + (r['offset'] as num))
        .toList();
    primary = scaled.first;
    display = scaled.map((v) => numberText(v, 4)).join(', ');
    if (r['unit'] != '') display += ' ${r['unit']}';
  }
  final names = Map<String, dynamic>.from(r['value_names'] as Map? ?? {});
  if (values.length == 1 && (bit || ['u16', 's16', 'hex'].contains(fmt))) {
    if (!bit && r['bitmask'] == true) {
      final v = values[0];
      final binary = v.toRadixString(2).padLeft(16, '0');
      final grouped = [
        for (var i = 0; i < 16; i += 4) binary.substring(i, i + 4),
      ].join(' ');
      final labels = [
        for (var i = 0; i < 16; i++)
          if (v & (1 << i) != 0) names['$i'] ?? 'b$i',
      ];
      display = labels.isEmpty ? grouped : '${labels.join(', ')} ($grouped)';
    } else if (names.containsKey('${values[0]}')) {
      display = '${names['${values[0]}']} (${values[0]})';
    }
  }
  return {
    'values': raw,
    'display': display,
    'numeric': primary?.isFinite == true ? primary : null,
    'alarm': alarm(primary, r['alarms']),
  };
}

List<dynamic> encodeValues(Json data) {
  final r = row(data['row']);
  final text = data['text'] as String;
  final count = r['count'] as int, fmt = r['format'] as String;
  final tokens = text
      .trim()
      .split(RegExp(r'[,\s]+'))
      .where((v) => v.isNotEmpty)
      .toList();
  if (bitKind(r['kind'])) {
    if (tokens.length != count ||
        tokens.any(
          (t) => !['0', '1', 'true', 'false'].contains(t.toLowerCase()),
        )) {
      throw const FormatException('Enter exactly count boolean values (0/1)');
    }
    return tokens.map((t) => ['1', 'true'].contains(t.toLowerCase())).toList();
  }
  if (fmt == 'ascii' || fmt == 'ascii1') {
    final bytes = text.runes
        .map((v) => (fmt == 'ascii1' ? v < 128 : v >= 32 && v <= 126) ? v : 63)
        .toList();
    return List.generate(
      count,
      (i) => fmt == 'ascii1'
          ? (i < bytes.length ? bytes[i] : 0)
          : ((2 * i < bytes.length ? bytes[2 * i] : 0) << 8) |
                (2 * i + 1 < bytes.length ? bytes[2 * i + 1] : 0),
    );
  }
  if (fmt == 'hex') {
    final result = tokens.map((t) => int.parse(t)).toList();
    if (result.length != count || result.any((v) => v < 0 || v > 65535)) {
      throw const FormatException('Invalid hexadecimal values');
    }
    return result;
  }
  if (r['scale'] == 0) throw const FormatException('Cannot invert zero scale');
  final result = [
    for (final t in tokens)
      ...encodeNumber(
        (num.parse(t) - (r['offset'] as num)) / (r['scale'] as num),
        fmt,
        r['order'],
      ),
  ];
  if (result.length != count) {
    throw FormatException('Enter ${count ~/ width(fmt)} values');
  }
  return result;
}

List<List<int>> plan(List<Json> rows) {
  final byKey = <String, List<int>>{};
  for (var i = 0; i < rows.length; i++) {
    final r = rows[i];
    byKey.putIfAbsent('${r['unit_id']}/${r['kind']}', () => []).add(i);
  }
  final out = <List<int>>[];
  for (final indices in byKey.values) {
    indices.sort(
      (a, b) =>
          (rows[a]['address'] as int).compareTo(rows[b]['address'] as int),
    );
    var start = -1, end = -1;
    var group = <int>[];
    for (final i in indices) {
      final r = rows[i],
          a = r['address'] as int,
          e = (r['address'] as int) + (r['count'] as int);
      if (group.isNotEmpty &&
          a <= end &&
          math.max(end, e) - start <= (bitKind(r['kind']) ? 2000 : 125)) {
        group.add(i);
        end = math.max(end, e);
      } else {
        if (group.isNotEmpty) out.add(group);
        group = [i];
        start = a;
        end = e;
      }
    }
    if (group.isNotEmpty) out.add(group);
  }
  return out;
}

Json evaluateExpressions(Json d) {
  final rows = d['expressions'] as List;
  if (rows.length > 512) throw const FormatException('At most 512 expressions');
  final values = <String, num>{
    for (final e in (d['values'] as Map).entries)
      if (e.value is num && (e.value as num).isFinite)
        e.key as String: e.value as num,
  };
  return {
    'rows': [
      for (final raw in rows) _evaluate(Map<String, dynamic>.from(raw), values),
    ],
  };
}

Json _evaluate(Json r, Map<String, num> values) {
  try {
    final n = Expression(r['text']).evaluate(values);
    if (!n.isFinite) {
      throw const FormatException('Expression result is not finite');
    }
    return {
      'numeric': n,
      'display': numberText(n),
      'error': null,
      'alarm': alarm(n, r['alarms']),
    };
  } catch (e) {
    return {'numeric': null, 'display': '—', 'error': '$e', 'alarm': null};
  }
}
