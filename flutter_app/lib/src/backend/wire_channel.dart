import 'dart:typed_data';

import 'registers.dart';
import 'wire_protocol.dart';

typedef WireChannelFactory = Future<WireChannel> Function(Json parameters);

/// Owns only the byte transport. Modbus framing and transactions live in the client.
abstract class WireChannel {
  Stream<Uint8List> get stream;
  Future<void> write(List<int> bytes, {ReadCancellation? cancellation});
  Future<void> close();
}

class WireDisconnected implements Exception {
  const WireDisconnected(this.message);
  final String message;
  @override
  String toString() => message;
}
