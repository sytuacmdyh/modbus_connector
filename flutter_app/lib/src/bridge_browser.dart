import 'backend/wire_channel_web.dart';
import 'backend/catalog_web.dart';
import 'backend/cloud_sync.dart';
import 'backend/logger_buffer.dart';
import 'bridge_local.dart';
import 'bridge_transport.dart';
import 'remote/bridge.dart';
import 'remote/configuration.dart';

BridgeTransport createBridge({ServiceConfiguration? configuration}) {
  if (configuration != null) return RemoteBridge(configuration);
  final catalog = BrowserCatalog();
  final cloud = CloudSync(
    loadSettings: catalog.loadCloudSettings,
    saveSettings: catalog.saveCloudSettings,
    replaceCatalog: catalog.replacePublic,
  );
  final logger = BufferedLogger();
  return LocalBridge(
    listPorts: () => BrowserSerialPorts.ports,
    authorizePort: BrowserSerialPorts.select,
    platformCommand: (command) {
      final name = command['command'] as String;
      if (name.startsWith('logger_')) return logger.dispatch(command);
      if (name.startsWith('cloud_')) return cloud.dispatch(command);
      return catalog.dispatch(command);
    },
    closePlatform: () async {
      await cloud.close();
      await logger.close();
    },
  );
}

/// Catalog and WebDAV operations always run in the browser, even when device
/// communication uses a remote Dart service.
BridgeTransport createUtilityBridge() => createBridge();
