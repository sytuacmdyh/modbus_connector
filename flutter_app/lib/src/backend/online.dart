import 'dart:convert';
import 'dart:io';

import 'catalog.dart';
import 'cloud_sync.dart';
import 'registers.dart';
import 'update.dart';
export 'cloud_sync.dart' show cloudSettings, cloudVersion, DavException;

const releasesUrl = 'https://github.com/sytuacmdyh/modbus_connector/releases';
const applicationVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: String.fromEnvironment(
    'FLUTTER_BUILD_NAME',
    defaultValue: '0.16.3',
  ),
);

class NativeOnline {
  NativeOnline(this.catalog)
    : cloud = CloudSync(
        loadSettings: () async {
          try {
            return await readJson(catalog.file('cloud.json'));
          } on FileSystemException {
            return {};
          }
        },
        saveSettings: (settings) =>
            atomicJson(catalog.file('cloud.json'), settings),
        replaceCatalog: (data, check) => atomicJson(
          catalog.file('cloud_templates.json'),
          data,
          beforeCommit: check,
        ),
      );
  final NativeCatalog catalog;
  final CloudSync cloud;
  String releasePage = releasesUrl;
  Future<void> close() => cloud.close();

  Future<Json> dispatch(Json d) async {
    final cmd = d['command'];
    if (cmd is String && cmd.startsWith('cloud_')) return cloud.dispatch(d);
    if (cmd == 'update_check') {
      releasePage = releasesUrl;
      final client = HttpClient();
      try {
        final req = await client
            .getUrl(
              Uri.parse(
                'https://api.github.com/repos/sytuacmdyh/modbus_connector/releases/latest',
              ),
            )
            .timeout(const Duration(seconds: 10));
        req.followRedirects = false;
        req.headers.set('User-Agent', 'ModbusConnector/$applicationVersion');
        req.headers.set('Accept', 'application/vnd.github+json');
        final r = await req.close().timeout(const Duration(seconds: 10));
        if (r.statusCode == 404) {
          return {
            'current': applicationVersion,
            'release': null,
            'url': releasePage,
            'newer': false,
            'install_supported': false,
            'install_reason': 'No public stable release is available.',
          };
        }
        if (r.statusCode != 200) {
          throw HttpException('GitHub request failed: HTTP ${r.statusCode}');
        }
        final bytes = <int>[];
        await for (final c in r.timeout(const Duration(seconds: 10))) {
          bytes.addAll(c);
          if (bytes.length > 1024 * 1024) {
            throw const FormatException('Invalid GitHub release response.');
          }
        }
        final result = releaseResult(
          map(jsonDecode(utf8.decode(bytes))),
          applicationVersion,
          executable: await installedFlutterExecutable(),
          platform: Platform.isMacOS ? 'macos' : 'windows',
        );
        releasePage = result['url'] as String;
        return result;
      } catch (e) {
        return {
          'current': applicationVersion,
          'release': null,
          'url': releasePage,
          'newer': false,
          'install_supported': false,
          'error': '$e',
          'install_reason': '$e',
        };
      } finally {
        client.close(force: true);
      }
    }
    if (cmd == 'update_install') {
      throw const FormatException(
        'Use the desktop update dialog to download and install updates.',
      );
    }
    if (cmd == 'update_open_page') {
      if (Platform.isWindows) {
        await Process.start('rundll32', [
          'url.dll,FileProtocolHandler',
          releasePage,
        ]);
      } else {
        await Process.start(Platform.isMacOS ? 'open' : 'xdg-open', [
          releasePage,
        ]);
      }
      return {'url': releasePage};
    }
    throw const FormatException('Unknown cloud/update command');
  }
}
