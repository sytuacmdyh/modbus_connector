import 'dart:async';
import 'dart:typed_data';

import 'datastore.dart';
import 'wire_channel.dart';
import 'wire_protocol.dart';

/// Runs the shared simulator protocol in memory, with no listening socket.
class MemoryModbusChannel implements WireChannel {
  MemoryModbusChannel(this.store);
  final DataStore store;
  final _incoming = StreamController<Uint8List>();
  bool _closed = false;
  @override
  Stream<Uint8List> get stream => _incoming.stream;
  @override
  Future<void> write(List<int> bytes, {ReadCancellation? cancellation}) async {
    cancellation?.check();
    if (_closed) throw const WireDisconnected('Demo is closed');
    if (bytes.length < 4 ||
        crc16(bytes.sublist(0, bytes.length - 2)) !=
            (bytes[bytes.length - 2] | bytes.last << 8)) {
      throw const FormatException('Invalid demo RTU request');
    }
    final reply = store.handle(bytes.sublist(1, bytes.length - 2));
    _incoming.add(Uint8List.fromList(rtuFrame(bytes.first, reply)));
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _incoming.close();
  }
}
