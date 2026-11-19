class BridgeReply {
  const BridgeReply(this.result, this.connected);
  final Map<String, dynamic> result;
  final bool connected;
}

class BridgeException implements Exception {
  const BridgeException(this.message, {this.connected, this.readTimeout});
  final String message;
  final bool? connected;
  final Map<String, dynamic>? readTimeout;
  @override
  String toString() => message;
}

abstract class BridgeTransport {
  List<String> get transports => const [
    'rtu',
    'tcp',
    'rtu_tcp',
    'rtu_udp',
    'demo',
  ];
  bool get supportsDeviceModes => true;
  bool get browserSerial => false;
  bool get downloadableLogs => false;
  bool get bufferedLogging => false;
  Future<Map<String, dynamic>?> selectSerialPort() async =>
      throw UnsupportedError('Use native serial port discovery');
  void Function(List<Map<String, dynamic>>, Map<String, dynamic>)? onTraffic;
  void Function(String)? onDiagnostic;
  void Function()? onExit;
  Future<BridgeReply> request(
    Map<String, dynamic> command, {
    Duration? timeout,
  });
  void cancelPendingRead() {}
  Future<void> close();
}
