import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:xml/xml.dart';

import 'catalog.dart';
import 'registers.dart';

const releasesUrl = 'https://github.com/sytuacmdyh/modbus_connector/releases';
const applicationVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: String.fromEnvironment(
    'FLUTTER_BUILD_NAME',
    defaultValue: '0.16.3',
  ),
);

class DavException implements Exception {
  const DavException(this.message, [this.status]);
  final String message;
  final int? status;
  @override
  String toString() => message;
}

Json cloudSettings(dynamic raw, {bool validate = true}) {
  final d = <String, dynamic>{
    'url': '',
    'username': '',
    'password': '',
    'templates_path': 'templates',
    'timeout': 15,
    'remember_password': false,
    'mode': 'consumer',
    ...map(raw),
  };
  d.remove('configuration_path');
  if (!validate) {
    if (d['remember_password'] != true) d['password'] = '';
    return d;
  }
  for (final k in ['url', 'username', 'password', 'templates_path']) {
    if (d[k] is! String) {
      throw const FormatException('Cloud connection fields must be strings');
    }
  }
  final uri = Uri.tryParse(d['url']);
  if (uri == null ||
      !['http', 'https'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      uri.port == 0 ||
      RegExp(r'[\x00-\x20]').hasMatch(d['url']) ||
      uri.pathSegments.any((p) => p == '.' || p == '..') ||
      RegExp(
        r'(^|/)(\.|%2e){1,2}(/|$)',
        caseSensitive: false,
      ).hasMatch(d['url'])) {
    throw const FormatException('Enter a valid HTTP or HTTPS WebDAV URL.');
  }
  if (RegExp(r'[:\r\n]').hasMatch(d['username'])) {
    throw const FormatException('Invalid WebDAV username.');
  }
  relativePath(d['templates_path']);
  bounded(d['timeout'], 'timeout', 1, 120);
  if (!['consumer', 'publisher'].contains(d['mode'])) {
    throw const FormatException('Invalid cloud mode.');
  }
  return d;
}

String cloudVersion([String? value]) {
  if (value != null) {
    if (!RegExp(r'^\d{8}T\d{12}Z-[a-f0-9]{8}$').hasMatch(value)) {
      throw const FormatException('Invalid cloud version.');
    }
    return value;
  }
  final now = DateTime.now().toUtc();
  String p(int n, int width) => '$n'.padLeft(width, '0');
  return '${p(now.year, 4)}${p(now.month, 2)}${p(now.day, 2)}T${p(now.hour, 2)}${p(now.minute, 2)}${p(now.second, 2)}${p(now.millisecond * 1000 + now.microsecond, 6)}Z-${randomId().substring(0, 8)}';
}

class NativeOnline {
  NativeOnline(this.catalog);
  final NativeCatalog catalog;
  bool cancelled = false, running = false, closed = false;
  Json status = {};
  HttpClient? active;
  Future<void>? task;
  String releasePage = releasesUrl;
  void checkCancel() {
    if (cancelled || closed) {
      throw const DavException('Cloud operation cancelled.');
    }
  }

  Future<void> close() async {
    closed = true;
    cancelled = true;
    active?.close(force: true);
    await task;
  }

  Future<List<int>> request(
    Json settings,
    String method,
    String path, {
    bool collection = false,
    List<int>? body,
    List<int> allowed = const [200],
    String depth = '1',
  }) async {
    checkCancel();
    if (!['GET', 'PROPFIND'].contains(method) &&
        settings['mode'] != 'publisher') {
      throw const DavException('Consumer mode cannot publish templates.');
    }
    if (path.isNotEmpty) relativePath(path);
    final base = Uri.parse(settings['url']);
    final prefix = base.path.replaceFirst(RegExp(r'/+$'), '');
    final url = base.replace(
      path:
          '$prefix/${path.isEmpty ? '' : path}${collection && path.isNotEmpty ? '/' : ''}',
    );
    final client = active!;
    final timeout = Duration(seconds: settings['timeout']);
    final req = await client.openUrl(method, url).timeout(timeout);
    req.followRedirects = false;
    req.headers.set('Cache-Control', 'no-cache');
    req.headers.set('User-Agent', 'ModbusConnector');
    if (settings['username'] != '' || settings['password'] != '') {
      req.headers.set(
        'Authorization',
        'Basic ${base64Encode(utf8.encode('${settings['username']}:${settings['password']}'))}',
      );
    }
    if (method == 'PROPFIND') {
      req.headers.set('Depth', depth);
      req.headers.set('Content-Type', 'application/xml; charset=utf-8');
      req.add(
        utf8.encode(
          '<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>',
        ),
      );
    }
    if (body != null) {
      req.headers.set('Content-Type', 'application/json; charset=utf-8');
      req.add(body);
    }
    final response = await req.close().timeout(timeout);
    if (!allowed.contains(response.statusCode)) {
      await response.take(1).drain<void>().timeout(timeout);
      throw DavException(
        'WebDAV $method failed: HTTP ${response.statusCode}.',
        response.statusCode,
      );
    }
    final bytes = <int>[];
    await for (final chunk in response.timeout(timeout)) {
      checkCancel();
      bytes.addAll(chunk);
      if (bytes.length > 16 * 1024 * 1024) {
        throw const DavException('Cloud response exceeds the 16 MiB limit.');
      }
    }
    return bytes;
  }

  Future<List<(String, bool)>> listing(
    Json s,
    String path, {
    String depth = '1',
  }) async {
    final bytes = await request(
      s,
      'PROPFIND',
      path,
      collection: true,
      allowed: [207],
      depth: depth,
    );
    final doc = XmlDocument.parse(utf8.decode(bytes));
    if (doc.rootElement.name.local != 'multistatus' ||
        doc.rootElement.namespaceUri != 'DAV:') {
      throw const FormatException('Invalid WebDAV directory response.');
    }
    final base = Uri.parse(s['url']);
    final target = base.replace(
      path:
          '${base.path.replaceFirst(RegExp(r'/+$'), '')}/${path.isEmpty ? '' : '$path/'}',
    );
    final root = Uri.decodeComponent(target.path)
        .replaceFirst(RegExp(r'/+$'), '');
    final result = <(String, bool)>[];
    var self = false;
    for (final r in doc.rootElement.findElements(
      'response',
      namespaceUri: 'DAV:',
    )) {
      final href = r.getElement('href', namespaceUri: 'DAV:')?.innerText;
      if (href == null) {
        throw const FormatException('Invalid WebDAV directory response.');
      }
      final resolved = target.resolve(href);
      if (resolved.scheme != target.scheme ||
          resolved.authority != target.authority) {
        throw const FormatException('Invalid WebDAV directory response.');
      }
      final path = Uri.decodeComponent(resolved.path)
          .replaceFirst(RegExp(r'/+$'), '');
      if (path != root && !path.startsWith('$root/')) {
        throw const FormatException('Invalid WebDAV directory response.');
      }
      final name = path.substring(root.length).replaceFirst(RegExp(r'^/'), '');
      if (name.contains('/') ||
          name.contains('\\') ||
          name == '.' ||
          name == '..') {
        throw const FormatException('Invalid WebDAV directory response.');
      }
      XmlElement? type;
      for (final p in r.findElements('propstat', namespaceUri: 'DAV:')) {
        if ((p.getElement('status', namespaceUri: 'DAV:')?.innerText ?? '')
            .split(' ')
            .contains('200')) {
          type = p
              .getElement('prop', namespaceUri: 'DAV:')
              ?.getElement('resourcetype', namespaceUri: 'DAV:');
        }
      }
      if (type == null) {
        throw const FormatException('Invalid WebDAV directory response.');
      }
      final collection =
          type.getElement('collection', namespaceUri: 'DAV:') != null;
      if (name.isEmpty) {
        self = collection;
      } else {
        result.add((name, collection));
      }
    }
    if (!self) {
      throw const FormatException('Invalid WebDAV directory response.');
    }
    return result;
  }

  Future<void> put(Json s, String path, List<int> bytes) async {
    final parts = path.split('/');
    for (var i = 1; i < parts.length; i++) {
      await request(
        s,
        'MKCOL',
        parts.take(i).join('/'),
        collection: true,
        allowed: [201, 405],
      );
    }
    await request(s, 'PUT', path, body: bytes, allowed: [200, 201, 204]);
  }

  Json decodeCatalog(List<int> bytes) {
    final data = map(jsonDecode(utf8.decode(bytes).replaceFirst('\ufeff', '')));
    if (data['schema'] != 1 || data['version'] is! String) {
      throw const FormatException('Invalid cloud template catalog.');
    }
    cloudVersion(data['version']);
    validateCatalog(data['templates']);
    return map(data['templates']);
  }

  Future<String> publish(Json s, Json templates) async {
    if (s['mode'] != 'publisher') {
      throw const DavException('Consumer mode cannot publish templates.');
    }
    validateCatalog(templates);
    final version = cloudVersion();
    final bytes = utf8.encode(
      const JsonEncoder.withIndent('  ')
          .convert({'schema': 1, 'version': version, 'templates': templates}),
    );
    if (bytes.length > 16 * 1024 * 1024) {
      throw const DavException('Cloud response exceeds the 16 MiB limit.');
    }
    await put(s, '${s['templates_path']}/.versions/$version.json', bytes);
    checkCancel();
    await put(s, '${s['templates_path']}/.catalog.json', bytes);
    return version;
  }

  Future<Json> work(Json d, Json s) async {
    final base = s['templates_path'];
    switch (d['action']) {
      case 'test':
        await listing(s, '', depth: '0');
        return {'message': 'Connection successful'};
      case 'versions':
        try {
          final entries = await listing(s, '$base/.versions');
          final versions = <String>[];
          for (final e in entries) {
            if (e.$2 || !e.$1.endsWith('.json')) continue;
            try {
              versions.add(cloudVersion(e.$1.substring(0, e.$1.length - 5)));
            } on FormatException {
              continue;
            }
          }
          versions.sort((a, b) => b.compareTo(a));
          return {'versions': versions};
        } on DavException catch (e) {
          if (e.status == 404) return {'versions': <String>[]};
          rethrow;
        }
      case 'publish':
        return {'version': await publish(s, await catalog.public())};
      case 'activate':
        final version = cloudVersion(d['version']);
        return {
          'version': await publish(
            s,
            decodeCatalog(
              await request(s, 'GET', '$base/.versions/$version.json'),
            ),
          ),
        };
      case 'download':
        Json downloaded;
        try {
          final v = d['version'];
          downloaded = decodeCatalog(
            await request(
              s,
              'GET',
              v == null
                  ? '$base/.catalog.json'
                  : '$base/.versions/${cloudVersion(v)}.json',
            ),
          );
        } on DavException catch (e) {
          if (e.status != 404 || d['version'] != null) rethrow;
          downloaded = {};
          var total = 0;
          for (final manufacturer in await listing(s, base)) {
            checkCancel();
            if (!manufacturer.$2 || manufacturer.$1.startsWith('.')) continue;
            for (final entry in await listing(s, '$base/${manufacturer.$1}')) {
              if (entry.$2 || !entry.$1.endsWith('.json')) continue;
              if (downloaded.length >= 1000) {
                throw const FormatException(
                  'Cloud template catalog is too large.',
                );
              }
              final resource = '${manufacturer.$1}/${entry.$1}';
              relativePath(resource);
              final bytes = await request(s, 'GET', '$base/$resource');
              total += bytes.length;
              if (total > 16 * 1024 * 1024) {
                throw const FormatException(
                  'Cloud template catalog is too large.',
                );
              }
              final data = jsonDecode(
                utf8.decode(bytes).replaceFirst('\ufeff', ''),
              );
              validateTemplate(data);
              downloaded[resource] = data;
            }
          }
        }
        checkCancel();
        await atomicJson(catalog.file('cloud_templates.json'), downloaded);
        return {'downloaded': downloaded.length};
      default:
        throw const FormatException('Unknown cloud action');
    }
  }

  Future<Json> dispatch(Json d) async {
    final cmd = d['command'];
    if (cmd == 'cloud_settings_load') {
      try {
        return {
          'settings': cloudSettings(
            await readJson(catalog.file('cloud.json')),
            validate: false,
          ),
        };
      } on FileSystemException {
        return {'settings': cloudSettings({}, validate: false)};
      }
    }
    if (cmd == 'cloud_settings_save') {
      final s = cloudSettings(d['settings']);
      if (s['remember_password'] != true) s.remove('password');
      await atomicJson(catalog.file('cloud.json'), s);
      return {};
    }
    if (cmd == 'cloud_cancel') {
      cancelled = true;
      active?.close(force: true);
      return {};
    }
    if (cmd == 'cloud_status') return {...status, 'running': running};
    if (cmd == 'cloud_start') {
      if (running) {
        throw const FormatException('Cloud transfer already running');
      }
      final s = cloudSettings(d['settings']);
      if (![
        'test',
        'download',
        'versions',
        'publish',
        'activate',
      ].contains(d['action'])) {
        throw const FormatException('Unknown cloud action');
      }
      if (['publish', 'activate'].contains(d['action']) &&
          s['mode'] != 'publisher') {
        throw const DavException('Publishing is disabled in consumer mode.');
      }
      if (d['action'] == 'activate') cloudVersion(d['version']);
      closed = false;
      cancelled = false;
      running = true;
      active = HttpClient();
      status = {'action': d['action'], 'error': null, 'result': null};
      task = () async {
        try {
          status['result'] = await work(d, s);
        } catch (e) {
          status['error'] = cancelled ? 'Cloud operation cancelled.' : '$e';
        } finally {
          running = false;
          active?.close(force: true);
          active = null;
        }
      }();
      return {};
    }
    if (cmd == 'update_check') {
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
        final release = map(jsonDecode(utf8.decode(bytes))),
            tag = release['tag_name'];
        if (release['draft'] != false ||
            release['prerelease'] != false ||
            tag is! String ||
            !RegExp(r'^v\d+\.\d+\.\d+$').hasMatch(tag)) {
          throw const FormatException('Invalid GitHub release response.');
        }
        releasePage = '$releasesUrl/tag/$tag';
        final parts = tag.substring(1).split('.').map(int.parse).toList(),
            current = applicationVersion
                .split('-')[0]
                .split('+')[0]
                .split('.')
                .map(int.parse)
                .toList();
        var newer = false;
        for (var i = 0; i < 3; i++) {
          if (parts[i] != current[i]) {
            newer = parts[i] > current[i];
            break;
          }
        }
        return {
          'current': applicationVersion,
          'release': {
            'tag': tag,
            'notes': release['body'] ?? '',
            'installer': null,
          },
          'url': releasePage,
          'newer': newer,
          'install_supported': false,
          'install_reason': 'Automatic installation is not supported by this Flutter client. Use the releases page for manual installation.',
        };
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
        'Automatic installation is not supported; use manual installation.',
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
