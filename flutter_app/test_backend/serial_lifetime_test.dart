import 'package:flutter_libserialport/flutter_libserialport.dart';
import 'package:test/test.dart';
import 'package:modbus_desktop/src/backend/wire.dart';

class Config implements SerialPortConfig {
  int frees = 0;
  bool fail = false;
  @override
  void dispose() {
    if (++frees != 1) throw StateError('double free');
  }

  @override
  set baudRate(int value) {
    if (fail) throw StateError('configuration failed');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class Port implements SerialPort {
  Config? owned;
  bool fail = false;
  int frees = 0;
  @override
  bool openReadWrite() => true;
  @override
  set config(SerialPortConfig config) {
    owned = config as Config; // Mirrors the pinned libserialport setter.
    if (fail) throw StateError('apply failed');
  }

  @override
  bool close() => true;
  @override
  void dispose() {
    frees++;
    owned?.dispose();
  }

  @override
  int get bytesAvailable => 0;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  const params = {
    'port': 'test',
    'baudrate': 9600,
    'bytesize': 8,
    'parity': 'N',
    'stopbits': 1,
  };
  test('assigned configuration survives until close and is freed once', () {
    final port = Port(), config = Config();
    final channel = SerialChannel(
      params,
      createPort: (_) => port,
      createConfig: () => config,
    );
    expect(config.frees, 0);
    channel.close();
    channel.close();
    expect(config.frees, 1);
    expect(port.frees, 1);
  });
  test('setter failure releases retained configuration once', () {
    final port = Port()..fail = true, config = Config();
    expect(
      () => SerialChannel(
        params,
        createPort: (_) => port,
        createConfig: () => config,
      ),
      throwsStateError,
    );
    expect(config.frees, 1);
    expect(port.frees, 1);
  });
  test('configuration failure before transfer releases unowned config', () {
    final port = Port(), config = Config()..fail = true;
    expect(
      () => SerialChannel(
        params,
        createPort: (_) => port,
        createConfig: () => config,
      ),
      throwsStateError,
    );
    expect(config.frees, 1);
    expect(port.frees, 1);
  });
}
