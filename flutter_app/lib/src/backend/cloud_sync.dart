import 'dart:async';
import 'dart:convert';

import 'package:xml/xml.dart';

import 'dav_http.dart';
import 'registers.dart';
import 'template_schema.dart';
export 'dav_http_contract.dart' show DavException;

Json cloudSettings(dynamic raw, {bool validate = true}) {
  final input = map(raw);
  // Legacy publisher settings migrate to this read-only schema. Unknown fields
  // (including mode and configuration_path) never enter the saved settings.
  final d = <String, dynamic>{
    'url': '',
    'username': '',
    'password': '',
    'templates_path': 'templates',
    'timeout': 15,
    'remember_password': false,
  };
  for (final key in d.keys.toList()) {
    if (input.containsKey(key)) d[key] = input[key];
  }
  if (!validate) {
    for (final key in ['url', 'username', 'password', 'templates_path']) {
      if (d[key] is! String) {
        d[key] = key == 'templates_path' ? 'templates' : '';
      }
    }
    if (d['timeout'] is! int || d['timeout'] < 1 || d['timeout'] > 120) {
      d['timeout'] = 15;
    }
    d['remember_password'] = d['remember_password'] == true;
    if (d['remember_password'] != true) d['password'] = '';
    return d;
  }
  for (final key in ['url', 'username', 'password', 'templates_path']) {
    if (d[key] is! String) {
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
  if (d['remember_password'] is! bool) {
    throw const FormatException('remember_password must be a boolean');
  }
  relativePath(d['templates_path']);
  bounded(d['timeout'], 'timeout', 1, 120);
  return d;
}

String cloudVersion(dynamic value) {
  if (value is! String ||
      !RegExp(r'^\d{8}T\d{12}Z-[a-f0-9]{8}$').hasMatch(value)) {
    throw const FormatException('Invalid cloud version.');
  }
  return value;
}

/// Shared read-only WebDAV consumer. Storage and HTTP belong to this client,
/// independently of the optional Modbus communication service.
class CloudSync {
  CloudSync({
    required this.loadSettings,
    required this.saveSettings,
    required this.replaceCatalog,
    this.clientFactory = openDavClient,
  });
  final Future<dynamic> Function() loadSettings;
  final Future<void> Function(Json) saveSettings;
  final Future<void> Function(Json, void Function()) replaceCatalog;
  final DavHttpClient Function() clientFactory;
  bool cancelled = false, running = false, closed = false;
  Json status = {};
  DavHttpClient? active;
  Future<void>? task;

  void checkCancel() {
    if (cancelled || closed) {
      throw const DavException('Cloud operation cancelled.');
    }
  }

  Future<void> close() async {
    closed = true;
    cancelled = true;
    active?.close();
    await task;
  }

  Future<List<int>> request(
    Json settings,
    String method,
    String path, {
    bool collection = false,
    List<int> allowed = const [200],
    String depth = '1',
  }) async {
    checkCancel();
    // This guard applies even to stale/malicious publisher settings.
    if (!['GET', 'PROPFIND'].contains(method)) {
      throw const DavException(
        'WebDAV sync is read-only. Uploads are managed by the template-upload skill.',
      );
    }
    if (path.isNotEmpty) relativePath(path);
    final base = Uri.parse(settings['url']);
    final prefix = base.path.replaceFirst(RegExp(r'/+$'), '');
    final uri = base.replace(
      path:
          '$prefix/${path.isEmpty ? '' : path}${collection && path.isNotEmpty ? '/' : ''}',
    );
    final headers = <String, String>{'Cache-Control': 'no-cache'};
    if (settings['username'] != '' || settings['password'] != '') {
      headers['Authorization'] =
          'Basic ${base64Encode(utf8.encode('${settings['username']}:${settings['password']}'))}';
    }
    List<int>? body;
    if (method == 'PROPFIND') {
      headers['Depth'] = depth;
      headers['Content-Type'] = 'application/xml; charset=utf-8';
      body = utf8.encode(
        '<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>',
      );
    }
    final response = await active!.request(
      uri,
      method: method,
      headers: headers,
      body: body,
      timeout: Duration(seconds: settings['timeout']),
    );
    checkCancel();
    if (!allowed.contains(response.status)) {
      throw DavException(
        'WebDAV $method failed: HTTP ${response.status}.',
        response.status,
      );
    }
    if (response.bytes.length > cloudByteLimit) {
      throw const DavException('Cloud response exceeds the 16 MiB limit.');
    }
    return response.bytes;
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

  Json decodeCatalog(List<int> bytes) {
    final data = map(jsonDecode(utf8.decode(bytes).replaceFirst('\ufeff', '')));
    if (data['schema'] != 1 || data['version'] is! String) {
      throw const FormatException('Invalid cloud template catalog.');
    }
    cloudVersion(data['version']);
    validateCatalog(data['templates']);
    return map(data['templates']);
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
        validateCatalog(downloaded);
        await replaceCatalog(downloaded, checkCancel);
        return {'downloaded': downloaded.length};
      default:
        throw const FormatException('Unknown cloud action');
    }
  }

  Future<Json> dispatch(Json d) async {
    final command = d['command'];
    if (command == 'cloud_settings_load') {
      return {'settings': cloudSettings(await loadSettings(), validate: false)};
    }
    if (command == 'cloud_settings_save') {
      final settings = cloudSettings(d['settings']);
      if (settings['remember_password'] != true) settings.remove('password');
      await saveSettings(settings);
      return {};
    }
    if (command == 'cloud_cancel') {
      cancelled = true;
      active?.close();
      return {};
    }
    if (command == 'cloud_status') return {...status, 'running': running};
    if (command == 'cloud_start') {
      if (running) {
        throw const FormatException('Cloud transfer already running');
      }
      // Validate both action and settings before creating a network client.
      if (!['test', 'download', 'versions'].contains(d['action'])) {
        throw const DavException(
          'WebDAV sync is read-only. Uploads are managed by the template-upload skill.',
        );
      }
      final settings = cloudSettings(d['settings']);
      if (d['version'] != null) cloudVersion(d['version']);
      closed = false;
      cancelled = false;
      active = clientFactory();
      running = true;
      status = {'action': d['action'], 'error': null, 'result': null};
      task = () async {
        try {
          status['result'] = await work(d, settings);
        } catch (error) {
          status['error'] = cancelled || closed
              ? 'Cloud operation cancelled.'
              : '$error';
        } finally {
          active?.close();
          active = null;
          running = false;
        }
      }();
      return {};
    }
    throw const FormatException('Unknown cloud command');
  }
}
