import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../settings_store.dart';
import 'registers.dart';

String randomId() => List.generate(
  16,
  (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();
Future<dynamic> readJson(File f) async =>
    jsonDecode((await f.readAsString()).replaceFirst('\ufeff', ''));
Future<void> atomicJson(File f, dynamic data) async {
  await f.parent.create(recursive: true);
  final temp = File('${f.path}.${randomId()}.tmp');
  try {
    await temp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(data),
      flush: true,
    );
    await temp.rename(f.path);
  } finally {
    if (await temp.exists()) await temp.delete();
  }
}

Json map(dynamic d) => Map<String, dynamic>.from(d as Map? ?? {});
void validateTemplate(dynamic v) {
  if (v is! Map ||
      v['name'] is! String ||
      (v['name'] as String).isEmpty ||
      v['connection'] is! Map ||
      v['registers'] is! List) {
    throw const FormatException('Invalid template');
  }
}

void validateCatalog(dynamic catalog) {
  if (catalog is! Map || catalog.isEmpty || catalog.length > 1000) {
    throw const FormatException('Invalid cloud template catalog');
  }
  for (final e in catalog.entries) {
    final key = e.key;
    if (key is! String ||
        key.split('/').length != 2 ||
        !key.endsWith('.json') ||
        key.startsWith('.')) {
      throw const FormatException('Invalid template resource');
    }
    relativePath(key);
    validateTemplate(e.value);
  }
}

String relativePath(String value) {
  if (value.isEmpty ||
      value.split('/').any((p) => p.isEmpty || p == '.' || p == '..') ||
      RegExp(r'[\\\x00\r\n?#]').hasMatch(value)) {
    throw const FormatException("Enter a relative cloud path without '..'.");
  }
  return value;
}

Json flutterState(Json s) {
  var c = map(s['connection']);
  final options = map(s['registers_options']),
      extra = map(map(s['registers_options'])['flutter']);
  if (!c.containsKey('transport')) {
    final transport =
        {
          'TCP': 'tcp',
          'RTU over TCP': 'rtu_tcp',
          'RTU over UDP': 'rtu_udp',
        }[c['type']] ??
        'rtu';
    c = {
      'transport': transport,
      'host': c['tcp_host'] ?? '127.0.0.1',
      'port': transport == 'rtu'
          ? c['rtu_port'] ?? ''
          : int.parse('${c['tcp_port'] ?? 502}'),
      'baudrate': int.parse('${c['rtu_baud'] ?? 9600}'),
      'bytesize': int.parse('${c['rtu_bytesize'] ?? 8}'),
      'parity': c['rtu_parity'] ?? 'N',
      'stopbits': int.parse('${c['rtu_stopbits'] ?? 1}'),
      'timeout': c['timeout'] ?? 3,
    };
  }
  final mode =
      {'sim': 'simulator', 'slave': 'simulator'}[s['mode']] ??
      s['mode'] ??
      'master';
  var device = map(extra['device_config'] ?? s['device_config']);
  final sim = map(s['sim']);
  if (device.isEmpty && mode == 'simulator') {
    final server = map(sim['server']);
    device = {
      'listen': flutterState({
        'connection': {
          ...server,
          'tcp_host': server['host'] ?? '127.0.0.1',
          'tcp_port': server['port'] ?? 1502,
        },
      })['connection'],
      'tick_ms': sim['tick_ms'] ?? 1000,
      'units_text': server['unit'] == null || server['unit'] == 'any'
          ? ''
          : '${server['unit']}',
    };
  }
  if (device.isEmpty && mode == 'gateway') {
    final g = map(s['gateway']);
    device = {
      for (final k in ['listen', 'target'])
        k: flutterState({'connection': map(g[k])})['connection'],
      'units_text': g['units'] ?? '',
    };
  }
  if (device.isEmpty && mode == 'sniffer') {
    device = {
      'listen': {'transport': 'rtu', ...map(map(s['sniffer'])['params'])},
    };
  }
  List<Json> normalize(dynamic rows) => [
    for (final raw in rows as List? ?? [])
      {
        'name': '',
        'kind': 'holding_registers',
        'address': 0,
        'count': 1,
        'format': 'dec',
        'scale': 1,
        'offset': 0,
        'unit': '',
        ...map(raw),
        'order': raw['order'] ?? options['order'] ?? 'ABCD',
        for (final k in ['unit_id', 'poll_ms'])
          k: raw[k] == null || raw[k] == '' ? null : int.parse('${raw[k]}'),
      },
  ];
  final sniffed = <String, dynamic>{};
  for (final entry in map(s['sniffer'])['units'] as List? ?? []) {
    final recovered = <String, dynamic>{};
    for (final raw in entry['rows'] as List? ?? []) {
      final values = raw['value'] as List? ?? [];
      for (var i = 0; i < values.length; i++) {
        final a = (raw['address'] as int) + i;
        recovered['${raw['kind']}/$a'] = {
          ...map(raw),
          'address': a,
          'value': values[i],
          'count': 1,
        };
      }
    }
    sniffed['${entry['unit']}'] = recovered;
  }
  String column(dynamic k) =>
      {'type': 'kind', 'poll_enabled': 'poll'}[k] ?? '$k';
  return {
    ...s,
    ...extra,
    'connection': c,
    'mode': mode,
    'device_config': device,
    'unit': extra['unit'] ?? s['unit'] ?? map(s['connection'])['unit'] ?? 1,
    'registers': normalize(s['registers']),
    'sim_rows': normalize(extra['sim_rows'] ?? s['sim_rows'] ?? sim['rows']),
    'expressions': [
      for (final e in s['expressions'] as List? ?? [])
        if (e is Map) {...map(e), 'text': e['text'] ?? e['expr'] ?? ''},
    ],
    'map_grouped':
        extra['map_grouped'] ??
        s['map_grouped'] ??
        options['group_reads'] ??
        false,
    'sniffed': extra['sniffed'] ?? s['sniffed'] ?? sniffed,
    'draft': {
      'transport': c['transport'],
      'host': '${c['host'] ?? '127.0.0.1'}',
      'port': c['transport'] == 'rtu' ? '502' : '${c['port'] ?? 502}',
      'serial': c['transport'] == 'rtu' ? '${c['port'] ?? ''}' : '',
      'baud': '${c['baudrate'] ?? 9600}',
      'parity': c['parity'] ?? 'N',
      'bits': c['bytesize'] ?? 8,
      'stop': c['stopbits'] ?? 1,
      'timeout': '${c['timeout'] ?? 3}',
      'map_table': {
        'order': [
          for (final k in options['column_order'] as List? ?? []) column(k),
        ],
        'hidden': [
          for (final k in options['hidden_columns'] as List? ?? []) column(k),
        ],
      },
      ...map(s['draft']),
      ...map(extra['draft']),
    },
  };
}

class NativeCatalog {
  NativeCatalog({Directory? directory})
    : directory = directory ?? SettingsStore().directory;
  final Directory directory;
  File file(String name) => File('${directory.path}/$name');
  Future<Json> public() async {
    final result = <String, dynamic>{};
    for (final f in [
      File('${directory.parent.path}/cloud_templates.json'),
      file('cloud_templates.json'),
    ]) {
      try {
        final data = await readJson(f);
        validateCatalog(data);
        result.addAll(map(data));
      } on FileSystemException {
        continue;
      } on FormatException {
        continue;
      }
    }
    return result;
  }

  File custom(dynamic id) {
    if (id is! String || !RegExp(r'^[a-f0-9]{32}$').hasMatch(id)) {
      throw const FormatException('Invalid custom template ID.');
    }
    return file('custom_templates/$id.json');
  }

  Future<Json> customData(dynamic id) async {
    final d = map(await readJson(custom(id)));
    if (d['schema'] != 1 ||
        d['name'] is! String ||
        (d['versions'] as List? ?? []).isEmpty) {
      throw const FormatException('Invalid custom template file.');
    }
    final seen = <String>{};
    for (final v in d['versions']) {
      if (v['id'] is! String || !seen.add(v['id'])) {
        throw const FormatException('Invalid version');
      }
      DateTime.parse(v['saved_at']);
      validateTemplate(v['state']);
    }
    return d;
  }

  Future<Json> dispatch(Json d) async {
    final cmd = d['command'], id = d['template_id'];
    if (cmd == 'template_convert_workspace') {
      final w = map(d['workspace']), tabs = w['tabs'];
      if (tabs is! List ||
          tabs.isEmpty ||
          tabs.length > 64 ||
          tabs.any((t) => t is! Map)) {
        throw const FormatException(
          'Configuration requires 1..64 session objects',
        );
      }
      const keys = {
        'mode',
        'connection',
        'registers',
        'expressions',
        'draft',
        'unit',
        'device_config',
        'sim_rows',
        'map_grouped',
        'logging',
        'scanner',
        'sniffed',
      };
      return {
        'schema': 1,
        'active_tab': w['active_tab'] ?? 0,
        'tabs': [
          for (final t in tabs)
            Map.fromEntries(
              flutterState(map(t)).entries.where((e) => keys.contains(e.key)),
            ),
        ],
      };
    }
    if (cmd == 'template_list') {
      final catalog = await public();
      final pub = [
        for (final e in catalog.entries)
          {
            'resource': e.key,
            'manufacturer': e.key.split('/')[0],
            'name': e.value['name'],
            'description': e.value['description'] ?? '',
          },
      ];
      pub.sort(
        (a, b) => '${a['manufacturer']}/${a['name']}'.toLowerCase().compareTo(
          '${b['manufacturer']}/${b['name']}'.toLowerCase(),
        ),
      );
      final own = <Json>[];
      final dir = Directory('${directory.path}/custom_templates');
      if (await dir.exists()) {
        await for (final f in dir.list()) {
          if (f is! File || !f.path.endsWith('.json')) continue;
          final identity = f.uri.pathSegments.last.replaceAll('.json', '');
          try {
            final data = await customData(identity);
            own.add({'id': identity, 'name': data['name']});
          } catch (_) {
            continue;
          }
        }
      }
      own.sort(
        (a, b) => (a['name'] as String).toLowerCase().compareTo(
          (b['name'] as String).toLowerCase(),
        ),
      );
      return {'public': pub, 'custom': own};
    }
    if (cmd == 'template_load') {
      Json state;
      if (id != null) {
        final data = await customData(id),
            versions = (data['versions'] as List).reversed;
        final v = versions.firstWhere(
          (v) => d['version_id'] == null || v['id'] == d['version_id'],
          orElse: () =>
              throw const FormatException('Custom template version not found.'),
        );
        state = {...map(v['state']), 'name': data['name']};
      } else {
        final catalog = await public();
        if (!catalog.containsKey(d['resource'])) {
          throw const FormatException('Template not found');
        }
        state = map(catalog[d['resource']]);
      }
      return {'state': flutterState(state), 'template_id': id};
    }
    if (cmd == 'template_save') {
      final state = map(d['state']);
      final identity = id ?? randomId();
      final data = id != null
          ? await customData(id)
          : {
              'schema': 1,
              'name': '${d['name'] ?? ''}'.trim(),
              'versions': <dynamic>[],
            };
      if ((data['name'] as String).isEmpty) {
        throw const FormatException('Template name cannot be empty.');
      }
      final now = DateTime.now().toUtc().toIso8601String();
      final snapshot = {...state, 'name': data['name']};
      validateTemplate(snapshot);
      (data['versions'] as List).add({
        'id': '$now-${randomId().substring(0, 8)}',
        'saved_at': now,
        'state': snapshot,
      });
      await atomicJson(custom(identity), data);
      return {'id': identity, 'name': data['name']};
    }
    final data = await customData(id), versions = data['versions'] as List;
    if (cmd == 'template_versions') {
      return {
        'versions': [
          for (final v in versions.reversed)
            {'id': v['id'], 'saved_at': v['saved_at']},
        ],
      };
    }
    if (cmd == 'template_delete') {
      await custom(id).delete();
      return {};
    }
    if (cmd == 'template_rename') {
      final name = '${d['name'] ?? ''}'.trim();
      if (name.isEmpty) {
        throw const FormatException('Template name cannot be empty.');
      }
      data['name'] = name;
    } else if (cmd == 'template_delete_version') {
      final kept = versions.where((v) => v['id'] != d['version_id']).toList();
      if (kept.length == versions.length) {
        throw const FormatException('Custom template version not found.');
      }
      if (kept.isEmpty) {
        throw const FormatException(
          'Cannot delete the last version; delete the template instead.',
        );
      }
      data['versions'] = kept;
    } else {
      throw const FormatException('Unknown template command');
    }
    await atomicJson(custom(id), data);
    return {};
  }
}
