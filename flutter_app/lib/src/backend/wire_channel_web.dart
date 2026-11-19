import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'registers.dart';
import 'wire_channel.dart';
import 'wire_protocol.dart';

@JS('navigator.serial')
external _Serial? get _serial;
@JS('isSecureContext')
external bool get _secureContext;

extension type _Serial(JSObject _) implements JSObject {
  external JSPromise<_Port> requestPort();
}

extension type _Port(JSObject _) implements JSObject {
  external JSPromise<JSAny?> open(JSObject options);
  external _Readable? get readable;
  external _Writable? get writable;
  external JSPromise<JSAny?> close();
}

extension type _Readable(JSObject _) implements JSObject {
  external _Reader getReader();
}

extension type _Reader(JSObject _) implements JSObject {
  external JSPromise<_ReadResult> read();
  external JSPromise<JSAny?> cancel();
  external void releaseLock();
}

extension type _ReadResult(JSObject _) implements JSObject {
  external bool get done;
  external JSUint8Array? get value;
}

extension type _Writable(JSObject _) implements JSObject {
  external _Writer getWriter();
}

extension type _Writer(JSObject _) implements JSObject {
  external JSPromise<JSAny?> write(JSUint8Array bytes);
  external void releaseLock();
}

/// Browser port handles are memory-only and must never be restored from paths.
class BrowserSerialPorts {
  static final _ports = <String, _Port>{};
  static bool get supported => _secureContext && _serial != null;

  /// Call directly from a user action, before unrelated asynchronous work.
  static Future<Json?> select() async {
    if (!supported) {
      throw UnsupportedError(
        'Browser serial requires a supported browser and HTTPS or localhost',
      );
    }
    final port = await _serial!.requestPort().toDart;
    for (final entry in _ports.entries) {
      if (entry.value == port) {
        return {'port': entry.key, 'description': 'Browser serial port'};
      }
    }
    final id = 'browser-serial-${_ports.length + 1}';
    _ports[id] = port;
    return {'port': id, 'description': 'Browser serial port'};
  }

  static List<Json> get ports => [
    for (final id in _ports.keys)
      {'port': id, 'description': 'Browser serial port'},
  ];
}

Future<WireChannel> openWireChannel(Json raw) async {
  final p = connection(raw);
  if (p['transport'] != 'rtu') {
    throw UnsupportedError('TCP and UDP require the optional Dart service');
  }
  final port = BrowserSerialPorts._ports[p['port']];
  if (port == null) {
    throw StateError('Select and authorize a browser serial port');
  }
  await port
      .open(
        {
              'baudRate': p['baudrate'],
              'dataBits': p['bytesize'],
              'stopBits': p['stopbits'],
              'parity': {'N': 'none', 'E': 'even', 'O': 'odd'}[p['parity']],
              'flowControl': 'none',
            }.jsify()
            as JSObject,
      )
      .toDart;
  try {
    return _BrowserSerialChannel(port);
  } catch (_) {
    await port.close().toDart;
    rethrow;
  }
}

class _BrowserSerialChannel implements WireChannel {
  _BrowserSerialChannel(this.port) {
    final readable = port.readable, writable = port.writable;
    if (readable == null || writable == null) {
      throw StateError('Serial port has no readable or writable stream');
    }
    reader = readable.getReader();
    try {
      writer = writable.getWriter();
    } catch (_) {
      reader.releaseLock();
      rethrow;
    }
    incoming = StreamController<Uint8List>(
      onListen: () {
        _reading = _read();
      },
    );
  }
  final _Port port;
  late final _Reader reader;
  late final _Writer writer;
  late final StreamController<Uint8List> incoming;
  Future<void>? _reading, _closing;
  bool closed = false;
  @override
  Stream<Uint8List> get stream => incoming.stream;

  Future<void> _read() async {
    try {
      while (!closed) {
        final result = await reader.read().toDart;
        if (result.done) break;
        final bytes = result.value;
        if (!closed && bytes != null) incoming.add(bytes.toDart);
      }
    } catch (error, stack) {
      if (!closed) incoming.addError(error, stack);
    } finally {
      unawaited(incoming.close());
    }
  }

  @override
  Future<void> write(List<int> bytes, {ReadCancellation? cancellation}) async {
    cancellation?.check();
    if (closed) throw const WireDisconnected('Serial port is closed');
    final writing = writer.write(Uint8List.fromList(bytes).toJS).toDart;
    await (cancellation?.wait(writing) ?? writing);
  }

  @override
  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    closed = true;
    try {
      await reader.cancel().toDart;
      await _reading;
    } finally {
      reader.releaseLock();
      writer.releaseLock();
      unawaited(incoming.close());
      await port.close().toDart;
    }
  }
}
