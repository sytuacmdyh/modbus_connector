import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_libserialport/flutter_libserialport.dart';

import 'registers.dart';
import 'wire_protocol.dart';

class SerialChannel {
  SerialChannel(
    Json p, {
    bool readOnly = false,
    SerialPort Function(String) createPort = SerialPort.new,
    SerialPortConfig Function() createConfig = SerialPortConfig.new,
  }) {
    port = createPort(p['port']);
    try {
      if (!(readOnly ? port.openRead() : port.openReadWrite())) {
        throw StateError('Could not open serial port: ${SerialPort.lastError}');
      }
      final config = createConfig();
      try {
        config
          ..baudRate = p['baudrate']
          ..bits = p['bytesize']
          ..parity = ({
            'N': SerialPortParity.none,
            'E': SerialPortParity.even,
            'O': SerialPortParity.odd,
          }[p['parity']]!)
          ..stopBits = p['stopbits']
          ..setFlowControl(SerialPortFlowControl.none);
      } catch (_) {
        config.dispose();
        rethrow;
      }
      // libserialport retains this object, even when the setter throws.
      // SerialPort.dispose owns its release; disposing here causes double-free.
      port.config = config;
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
  Future<void> write(List<int> b, {ReadCancellation? cancellation}) async {
    var i = 0;
    final watch = Stopwatch()..start();
    while (i < b.length) {
      cancellation?.check();
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
