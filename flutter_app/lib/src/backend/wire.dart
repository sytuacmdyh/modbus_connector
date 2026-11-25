import 'dart:async';

import 'registers.dart';
import 'wire_channel.dart';
import 'wire_channel_stub.dart'
    if (dart.library.io) 'wire_channel_native.dart'
    if (dart.library.js_interop) 'wire_channel_web.dart'
    as platform;
import 'wire_protocol.dart';

export 'wire_channel.dart';
export 'wire_protocol.dart';

class ModbusClient {
  ModbusClient({WireChannelFactory? openChannel})
    : _openChannel = openChannel ?? platform.openWireChannel;
  final WireChannelFactory _openChannel;
  WireChannel? _channel;
  StreamSubscription<dynamic>? subscription;
  Completer<List<int>>? pending;
  Json? params;
  int transaction = 0;
  int expectedId = 0, expectedUnit = 0;
  DateTime? drainUntil;
  FrameParser? activeParser;
  final _clock = Stopwatch()..start();
  int? _lastActivityUs;
  void _logRx(List<int> bytes) {
    if (bytes.isNotEmpty) traffic?.call('rx', bytes);
  }

  Future<void> _waitForSilence(Json p, ReadCancellation? cancellation) async {
    if (p['transport'] == 'tcp') return;
    // Apply to every request on this bus, including unit switches and writes.
    var gapUs = 50000;
    if (p['transport'] == 'rtu') {
      final bits =
          1 +
          (p['bytesize'] as int) +
          (p['stopbits'] as int) +
          (p['parity'] == 'N' ? 0 : 1);
      final frameGap = (3.5 * bits * 1000000 / (p['baudrate'] as int)).ceil();
      if (frameGap > gapUs) gapUs = frameGap;
    }
    while (_lastActivityUs != null) {
      cancellation?.check();
      if (!identical(params, p)) throw const WireDisconnected('Disconnected');
      final remaining = gapUs - (_clock.elapsedMicroseconds - _lastActivityUs!);
      if (remaining <= 0) break;
      final wait = Future<void>.delayed(Duration(microseconds: remaining));
      await (cancellation?.wait(wait) ?? wait);
    }
    cancellation?.check();
    if (!identical(params, p)) throw const WireDisconnected('Disconnected');
  }

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
    final parser = activeParser = FrameParser(tcp: tcp, onDiscard: _logRx);
    drainUntil = null;
    _lastActivityUs = null;
    void receive(List<int> b) {
      for (final f in parser.feed(b)) {
        _logRx(f);
        if (drainUntil != null) continue;
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
      parser.flush();
      params = null;
      final c = pending;
      if (c != null && !c.isCompleted) {
        c.completeError(error ?? const WireDisconnected('Connection closed'));
      }
    }

    try {
      _channel = await _openChannel(p);
      subscription = _channel!.stream.listen(
        (bytes) {
          if (bytes.isNotEmpty) _lastActivityUs = _clock.elapsedMicroseconds;
          receive(bytes);
        },
        onError: ended,
        onDone: ended,
      );
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
      c.completeError(const WireDisconnected('Disconnected'));
    }
    await subscription?.cancel();
    subscription = null;
    activeParser?.flush();
    await _channel?.close();
    _channel = null;
  }

  Future<List<int>> request(
    int unit,
    List<int> pdu, {
    ReadCancellation? cancellation,
  }) => serialized(() async {
    cancellation?.check();
    final p = params;
    if (p == null) throw const WireDisconnected('Not connected; connect again');
    if (drainUntil != null) {
      final delay = drainUntil!.difference(DateTime.now());
      if (!delay.isNegative) {
        final waiting = Future<void>.delayed(delay);
        await (cancellation?.wait(waiting) ?? waiting);
      }
      cancellation?.check();
      drainUntil = null;
      activeParser?.flush();
      if (!connected) throw const WireDisconnected('Disconnected');
    }
    await _waitForSilence(p, cancellation);
    activeParser?.flush();
    expectedUnit = unit;
    expectedId = transaction = (transaction + 1) & 65535;
    final tcp = p['transport'] == 'tcp';
    final packet = tcp ? tcpFrame(transaction, unit, pdu) : rtuFrame(unit, pdu);
    final responseDeadline = DateTime.now().add(
      Duration(milliseconds: ((p['timeout'] as num) * 1000).round()),
    );
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
      cancellation?.check();
      traffic?.call('tx', packet);
      await _channel!
          .write(packet, cancellation: cancellation)
          .timeout(
            Duration(milliseconds: ((p['timeout'] as num) * 1000).round()),
          );
      final response = await (cancellation?.wait(reply) ?? reply);
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
    } on ReadCancelled {
      if (!c.isCompleted) c.completeError(ReadCancelled());
      activeParser?.flush();
      // RTU has no transaction ID. Keep the abandoned reply out of the next
      // exchange, but release the caller immediately (also during draining).
      if (!tcp) drainUntil = responseDeadline;
      rethrow;
    } on TimeoutException {
      activeParser?.flush();
      // TCP IDs reject late replies. RTU has no IDs: drain a full timeout
      // before the next request, preserving polling on an open transport.
      if (!tcp) {
        drainUntil = DateTime.now().add(
          Duration(milliseconds: ((p['timeout'] as num) * 1000).round()),
        );
      }
      rethrow;
    } finally {
      _lastActivityUs = _clock.elapsedMicroseconds;
      if (identical(pending, c)) pending = null;
    }
  });
  Future<List<dynamic>> read(
    int unit,
    String kind,
    int address,
    int count, {
    ReadCancellation? cancellation,
  }) async {
    bounded(unit, 'unit', 1, 247);
    bounded(address, 'address', 0, 65535);
    bounded(count, 'count', 1, bitKind(kind) ? 2000 : 125);
    if (address + count > 65536 || !kinds.contains(kind)) {
      throw const FormatException('Invalid read range');
    }
    final fc = kinds.indexOf(kind) + 1;
    final p = params;
    late final List<int> r;
    try {
      r = await request(unit, [
        fc,
        ...word(address),
        ...word(count),
      ], cancellation: cancellation);
    } on TimeoutException {
      if (p == null) rethrow;
      throw ReadTimeout({
        'transport': p['transport'],
        'endpoint': p['transport'] == 'rtu'
            ? p['port']
            : '${p['host']}:${p['port']}',
        'unit': unit,
        'function': fc,
        'address': address,
        'count': count,
        'timeout_ms': ((p['timeout'] as num) * 1000).round(),
      });
    }
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
