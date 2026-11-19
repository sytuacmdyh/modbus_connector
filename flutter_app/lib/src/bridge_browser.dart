import 'backend/wire_channel_web.dart';
import 'backend/catalog_web.dart';
import 'backend/logger_buffer.dart';
import 'bridge_local.dart';
import 'bridge_transport.dart';
import 'remote/bridge.dart';
import 'remote/configuration.dart';

BridgeTransport createBridge({ServiceConfiguration? configuration}) {
  if (configuration != null) return RemoteBridge(configuration);
  final catalog = BrowserCatalog();
  final logger = BufferedLogger();
  return LocalBridge(
    listPorts: () => BrowserSerialPorts.ports,
    authorizePort: BrowserSerialPorts.select,
    platformCommand: (command) =>
        (command['command'] as String).startsWith('logger_')
        ? logger.dispatch(command)
        : catalog.dispatch(command),
    closePlatform: logger.close,
  );
}
