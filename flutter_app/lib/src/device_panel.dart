import 'sniffer_views.dart';
import 'desktop_table.dart';
import 'serial_ports.dart';
import 'templates_dialog.dart';
import 'bridge_client.dart';
import 'file_paths.dart';
import 'translations.dart';

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'register_map.dart';
import 'graph_dialog.dart';
import 'session_controller.dart';
import 'tool_widgets.dart';

class ConnectionFields extends StatefulWidget {
  const ConnectionFields({
    super.key,
    required this.label,
    required this.session,
    required this.value,
    required this.onChanged,
    this.enabled = true,
    this.serialOnly = false,
    this.target = false,
  });
  final String label;
  final SessionController session;
  final Map<String, dynamic> value;
  final ValueChanged<Map<String, dynamic>> onChanged;
  final bool enabled;
  final bool serialOnly;
  final bool target;
  @override
  State<ConnectionFields> createState() => _ConnectionFieldsState();
}

class _ConnectionFieldsState extends State<ConnectionFields> {
  final fields = <String, TextEditingController>{};
  late String transport = widget.serialOnly
      ? 'rtu'
      : widget.value['transport'] as String? ?? 'tcp';
  late String parity = widget.value['parity'] as String? ?? 'N';
  @override
  void initState() {
    super.initState();
    for (final e in {
      'host': '127.0.0.1',
      'port': 1502,
      'serial': '',
      'baudrate': 9600,
      'bytesize': 8,
      'stopbits': 1,
      'timeout': 3,
    }.entries) {
      fields[e.key] = TextEditingController(
        text:
            '${e.key == 'serial' ? (widget.value['transport'] == 'rtu' ? widget.value['port'] ?? '' : '') : (e.key == 'port' && widget.value['transport'] == 'rtu' ? e.value : widget.value[e.key] ?? e.value)}',
      );
      fields[e.key]!.addListener(changed);
    }
  }

  void changed() {
    widget.onChanged({
      'transport': transport,
      'host': fields['host']!.text,
      'port': transport == 'rtu'
          ? fields['serial']!.text
          : int.tryParse(fields['port']!.text) ?? -1,
      for (final key in ['baudrate', 'bytesize', 'stopbits'])
        key: int.tryParse(fields[key]!.text) ?? -1,
      'parity': parity,
      'timeout': double.tryParse(fields['timeout']!.text) ?? -1,
    });
  }

  @override
  void dispose() {
    for (final c in fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LText(widget.label, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              if (!widget.serialOnly)
                toolChoice(
                  'Transport',
                  transport,
                  ['tcp', 'rtu_tcp', 'rtu', if (widget.target) 'rtu_udp'],
                  widget.enabled
                      ? (v) => setState(() {
                          transport = v;
                          changed();
                        })
                      : null,
                  width: 140,
                ),
              if (transport != 'rtu') ...[
                toolField(
                  'Host',
                  fields['host']!,
                  enabled: widget.enabled,
                  width: 175,
                ),
                toolField(
                  'Port',
                  fields['port']!,
                  enabled: widget.enabled,
                  width: 90,
                ),
              ] else ...[
                SerialPortPicker(
                  session: widget.session,
                  controller: fields['serial']!,
                  enabled: widget.enabled,
                ),
                BaudRatePicker(
                  controller: fields['baudrate']!,
                  enabled: widget.enabled,
                ),
                for (final key in ['bytesize', 'stopbits'])
                  toolField(
                    key,
                    fields[key]!,
                    enabled: widget.enabled,
                    width: 90,
                  ),
                toolChoice(
                  'Parity',
                  parity,
                  ['N', 'E', 'O'],
                  widget.enabled
                      ? (v) => setState(() {
                          parity = v;
                          changed();
                        })
                      : null,
                  width: 90,
                ),
              ],
              toolField(
                'Timeout, s',
                fields['timeout']!,
                enabled: widget.enabled,
                width: 100,
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class DevicePanel extends StatefulWidget {
  const DevicePanel({
    super.key,
    required this.session,
    this.utilityBridgeFactory,
  });
  final BridgeTransport Function()? utilityBridgeFactory;
  final SessionController session;
  @override
  State<DevicePanel> createState() => _DevicePanelState();
}

class _DevicePanelState extends State<DevicePanel> {
  SessionController get session => widget.session;
  late Map<String, dynamic> listen = Map<String, dynamic>.from(
    session.deviceConfig['listen'] as Map? ??
        {
          'transport': session.mode == 'sniffer' ? 'rtu' : 'tcp',
          'host': '127.0.0.1',
          'port': session.mode == 'sniffer' ? '' : 1502,
          'timeout': 3,
        },
  );
  late Map<String, dynamic> target = Map<String, dynamic>.from(
    session.deviceConfig['target'] as Map? ??
        {'transport': 'tcp', 'host': '127.0.0.1', 'port': 502, 'timeout': 3},
  );
  late final units = TextEditingController(
    text: session.deviceConfig['units_text'] as String? ?? '',
  );
  late final tick = TextEditingController(
    text: '${session.deviceConfig['tick_ms'] ?? 1000}',
  );
  final logs = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> results = [];
  Map<String, dynamic> ruleErrors = {};
  final sniffDisplays = <String, Map<String, dynamic>>{};
  late bool unitLog = session.draft['sniffer_unit_log'] != false;
  late int selectedUnit = session.draft['sniffer_selected_unit'] as int? ?? 1;
  late String sniffArea = session.draft['sniffer_area'] as String? ?? 'all';
  late bool sniffDescending = session.draft['sniffer_descending'] == true;
  late final sniffSearch = TextEditingController(
    text: session.draft['sniffer_search'] as String? ?? '',
  );
  List<Map<String, dynamic>> get visibleViews => visibleSnifferViews(
    session.sniffed[selectedUnit] ?? {},
    area: sniffArea,
    query: sniffSearch.text,
    descending: sniffDescending,
  );

  String? localError;
  Timer? timer;
  @override
  void initState() {
    super.initState();
    sniffSearch.addListener(
      () => setState(() {
        session.draft['sniffer_search'] = sniffSearch.text;
      }),
    );
    units.addListener(saveConfig);
    tick.addListener(saveConfig);
    timer = Timer.periodic(
      const Duration(milliseconds: 400),
      (_) => unawaited(refresh()),
    );
  }

  @override
  void dispose() {
    timer?.cancel();
    sniffSearch.dispose();
    units.dispose();
    tick.dispose();
    super.dispose();
  }

  void saveConfig() {
    session.deviceConfig
      ..clear()
      ..addAll({
        'listen': listen,
        'target': target,
        'units_text': units.text,
        'tick_ms': int.tryParse(tick.text) ?? 1000,
      });
  }

  Future<void> refresh() async {
    if (session.busy || session.disconnecting) return;
    final status = await session.command({'command': 'device_status'});
    if (!mounted || status == null) return;
    var receivedValues = false;
    setState(() {
      session.deviceRunning = status[session.mode] == true;
      results = (status['rows'] as List).cast<Map<String, dynamic>>();
      ruleErrors = Map<String, dynamic>.from(
        status['rule_errors'] as Map? ?? {},
      );
      for (final e in (status['events'] as List).cast<Map<String, dynamic>>()) {
        logs.add(e);
        final seenUnit = e['unit'];
        if (session.mode == 'sniffer' &&
            seenUnit is int &&
            seenUnit >= 1 &&
            seenUnit <= 247) {
          session.sniffed.putIfAbsent(seenUnit, () => {});
        }
        if (logs.length > 1000) logs.removeAt(0);
        if (e['mode'] == 'sniffer' && e['event'] == 'values') {
          receivedValues = true;
          final unit = e['unit'] as int;
          final map = session.sniffed.putIfAbsent(unit, () => {});
          final values = e['values'] as List;
          for (var i = 0; i < values.length; i++) {
            final address = (e['address'] as int) + i;
            final key = '${e['kind']}/$address';
            session.recordPoint(
              'sniff/$unit/$key',
              'unit $unit ${e['kind']} @$address',
              values[i] is bool
                  ? (values[i] == true ? 1 : 0)
                  : (values[i] as num).toDouble(),
            );
            final old = map[key];
            map[key] = {
              ...?old,
              'unit_id': unit,
              'kind': e['kind'],
              'address': address,
              'count': old?['count'] ?? 1,
              'format': old?['format'] ?? 'dec',
              'name': old?['name'] ?? '',
              'value': values[i],
            };
          }
          if (!session.sniffed.containsKey(selectedUnit)) {
            selectedUnit = unit;
            session.draft['sniffer_selected_unit'] = unit;
          }
        }
      }
      if (session.mode == 'sniffer' &&
          session.sniffed.isNotEmpty &&
          !session.sniffed.containsKey(selectedUnit)) {
        selectedUnit = (session.sniffed.keys.toList()..sort()).first;
        session.draft['sniffer_selected_unit'] = selectedUnit;
      }
      if ((status['dropped'] as int) > 0) {
        localError = trf(
          'Event buffer overflow ({count} events); use Refresh map.',
          {'count': status['dropped']},
        );
      }
    });
    if (session.mode == 'sniffer' &&
        (receivedValues || sniffDisplays.isEmpty)) {
      await renderSniffer(record: receivedValues);
    }
  }

  Future<void> renderSniffer({bool record = false}) async {
    final unit = selectedUnit;
    final views = snifferViews(session.sniffed[unit] ?? {});
    final complete = views.where((v) => v['values'] != null).toList();
    final displays = <String, Map<String, dynamic>>{};
    for (var offset = 0; offset < complete.length; offset += 512) {
      final batch = complete.skip(offset).take(512).toList();
      final reply = await session.command({
        'command': 'render_rows',
        'rows': batch,
      });
      if (reply == null || !mounted || unit != selectedUnit) return;
      final rendered = (reply['rows'] as List).cast<Map<String, dynamic>>();
      for (var i = 0; i < batch.length; i++) {
        final row = batch[i];
        final key = '${row['kind']}/${row['address']}';
        displays[key] = rendered[i];
        if (record && rendered[i]['numeric'] is num) {
          session.recordPoint(
            'sniff-view/$unit/$key',
            row['name'] as String? ?? key,
            (rendered[i]['numeric'] as num).toDouble(),
          );
        }
      }
    }
    if (mounted && unit == selectedUnit) {
      setState(() {
        sniffDisplays
          ..clear()
          ..addAll(displays);
      });
    }
  }

  Future<void> editSniffer(Map<String, dynamic> row) async {
    final editingUnit = selectedUnit;
    final editingKey = "${row['kind']}/${row['address']}";
    var format = row['format'] as String? ?? 'dec';
    var order = row['order'] as String? ?? 'ABCD';
    final name = TextEditingController(text: row['name'] as String? ?? '');
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const LText('Sniffer view'),
          content: SizedBox(
            width: 420,
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                toolField('Name', name, width: 390),
                toolChoice(
                  'Format',
                  format,
                  displayFormats,
                  (v) => update(() => format = v),
                ),
                toolChoice('Byte order', order, [
                  'ABCD',
                  'CDAB',
                  'BADC',
                  'DCBA',
                ], (v) => update(() => order = v)),
                const LText(
                  'Multiword views require consecutive recovered addresses.',
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const LText('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const LText('Apply'),
            ),
          ],
        ),
      ),
    );
    final current = session.sniffed[editingUnit]?[editingKey];
    if (accepted == true && mounted && current != null) {
      setState(() {
        current['name'] = name.text;
        current['format'] = format;
        current['order'] = order;
        current['count'] = ['u64', 's64', 'f64'].contains(format)
            ? 4
            : ['u32', 's32', 'f32'].contains(format)
            ? 2
            : 1;
      });
      await renderSniffer();
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
    name.dispose();
  }

  Future<void> templates() async {
    final service = SessionController(
      (widget.utilityBridgeFactory ?? ProcessBridge.new)(),
    );
    List<Map<String, dynamic>>? incoming;
    try {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => TemplatesDialog(
          session: session,
          service: service,
          onOpen: (state, _) {
            incoming =
                (state[state['mode'] == 'simulator' ? 'sim_rows' : 'registers']
                            as List? ??
                        [])
                    .whereType<Map<String, dynamic>>()
                    .map(Map<String, dynamic>.of)
                    .toList();
          },
          simulator: true,
        ),
      );
    } finally {
      await service.shutdown();
      service.dispose();
    }
    if (!mounted || incoming == null) return;
    final existing = {
      for (final row in session.simRows) '${row['kind']}/${row['address']}',
    };
    var skipped = 0;
    for (final row in incoming!) {
      final key = '${row['kind']}/${row['address']}';
      if (session.simRows.length >= 512 ||
          (row['address'] as int) + (row['count'] as int) > 10000 ||
          !existing.add(key)) {
        skipped++;
        continue;
      }
      session.simRows.add({...row, 'rule_text': row['rule_text'] ?? ''});
    }
    await configure();
    if (mounted) {
      setState(() => localError = '${tr('Template rows skipped')}: $skipped');
    }
  }

  Future<void> start() async {
    saveConfig();
    final ids = units.text.trim().isEmpty
        ? null
        : units.text
              .split(',')
              .map((v) => int.tryParse(v.trim()) ?? -1)
              .toList();
    if (session.mode == 'simulator' && ids != null && ids.length != 1) {
      setState(
        () => localError = 'Simulator unit: blank for any, or one unit 1–247',
      );
      return;
    }
    if (session.mode == 'simulator' && !await configure()) return;
    final reply = await session.command({
      'command': 'device_start',
      'mode': session.mode,
      'listen': listen,
      if (session.mode == 'gateway') 'target': target,
      if (session.mode == 'gateway') 'units': ids,
      if (session.mode == 'simulator') 'unit': ids?.first,
      'tick_ms': int.tryParse(tick.text) ?? -1,
    });
    if (reply != null && mounted) {
      setState(() {
        session.deviceRunning = true;
        if (session.mode == 'sniffer') session.sniffed.clear();
        localError = null;
      });
    }
  }

  Future<bool> configure() async {
    final reply = await session.command({
      'command': 'sim_configure',
      'rows': session.simRows,
    });
    if (reply != null) {
      ruleErrors = Map<String, dynamic>.from(
        reply['rule_errors'] as Map? ?? {},
      );
    }
    return reply != null;
  }

  Future<void> addRow([int? index]) async {
    final row = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) =>
          RegisterRowDialog(row: index == null ? null : session.simRows[index]),
    );
    if (row == null || !mounted) return;
    setState(() {
      if (index == null) {
        session.simRows.add(row);
      } else {
        session.simRows[index] = row;
      }
    });
    await configure();
  }

  Future<void> setValue(int i) async {
    final row = session.simRows[i];
    List<dynamic>? values;
    if (hasRawEditor(row)) {
      values = await rawValuePrompt(
        context,
        row,
        i < results.length ? results[i]['values'] as List? ?? [] : [],
      );
    } else {
      final content = await textPrompt(
        context,
        trf('Set {name} ({format})', {
          'name': row['name'],
          'format': row['format'],
        }),
      );
      if (content == null) return;
      final encoded = await session.command({
        'command': 'encode_values',
        'row': row,
        'text': content,
      });
      values = encoded?['values'] as List?;
    }
    if (values == null) return;
    await session.command({'command': 'sim_set', 'row': row, 'values': values});
    await refresh();
  }

  Future<void> editRule(int i) async {
    final rule = await expressionPrompt(
      context,
      value: session.simRows[i]['rule_text'] as String? ?? '',
      names: session.simRows
          .map((r) => r['name'] as String? ?? '')
          .where((n) => n.isNotEmpty),
    );
    if (rule == null || !mounted) return;
    final old = session.simRows[i]['rule_text'];
    session.simRows[i]['rule_text'] = rule;
    if (!await configure()) session.simRows[i]['rule_text'] = old;
    if (mounted) setState(() {});
  }

  Future<void> refreshSniffer() async {
    final unit = selectedUnit;
    final reply = await session.command({
      'command': 'sniffer_snapshot',
      'unit': unit,
    });
    if (reply == null || !mounted) return;
    setState(() {
      final map = session.sniffed.putIfAbsent(unit, () => {});
      for (final area in (reply['areas'] as Map).entries) {
        for (final cell in (area.value as Map).entries) {
          final address = int.parse('${cell.key}');
          final key = '${area.key}/$address';
          map[key] = {
            ...?map[key],
            'unit_id': unit,
            'kind': area.key,
            'address': address,
            'count': map[key]?['count'] ?? 1,
            'format': map[key]?['format'] ?? 'dec',
            'name': map[key]?['name'] ?? '',
            'value': cell.value,
          };
        }
      }
      localError = null;
    });
    await renderSniffer(record: true);
  }

  Future<void> manageSnifferViews() async {
    final unit = selectedUnit;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const LText('Manage views'),
          content: SizedBox(
            width: 500,
            height: 320,
            child: ListView(
              children: [
                const LText(
                  'Hidden views retain captured values and settings.',
                ),
                for (final row in snifferViews(session.sniffed[unit] ?? {}))
                  CheckboxListTile(
                    title: LText(
                      '${tr(row['kind'] as String)} @${row['address']} ${row['name']}',
                    ),
                    value: row['hidden'] != true,
                    onChanged: (v) => update(() {
                      session.sniffed[unit]!['${row['kind']}/${row['address']}']!['hidden'] =
                          !v!;
                    }),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const LText('Close'),
            ),
          ],
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Widget snifferTable() {
    final rows = visibleViews;
    return DesktopTable(
      key: ValueKey('sniffer-table-$selectedUnit'),
      columns: const [
        TableColumnSpec('address', 'Address', 95),
        TableColumnSpec('name', 'Name', 150),
        TableColumnSpec('kind', 'Area', 160),
        TableColumnSpec('format', 'Format', 85),
        TableColumnSpec('order', 'Byte order', 100),
        TableColumnSpec('value', 'Value', 190),
        TableColumnSpec('trend', 'Trend', 130),
      ],
      layout: desktopTableLayout(session.draft, 'sniffer_table_$selectedUnit'),
      rowCount: rows.length,
      onRowTap: (i) => editSniffer(rows[i]),
      cellBuilder: (context, i, key) {
        final row = rows[i];
        final id = '${row['kind']}/${row['address']}';
        if (key == 'trend') {
          return SizedBox(
            height: 26,
            child: CustomPaint(
              painter: MultiSeriesPainter(
                [
                  session.histories['sniff-view/$selectedUnit/$id']?.toList() ??
                      [],
                ],
                false,
                Theme.of(context).colorScheme,
                null,
              ),
            ),
          );
        }
        final text = key == 'value'
            ? (sniffDisplays[id]?['display'] ?? '—')
            : row[key] ?? (key == 'order' ? 'ABCD' : '');
        return Tooltip(
          message: tr('$text'),
          child: LText('$text', maxLines: 1, overflow: TextOverflow.ellipsis),
        );
      },
    );
  }

  Future<void> exportSniffer() async {
    final path = await chooseFilePath(
      context,
      save: true,
      title: 'Export selected unit CSV file path',
      extension: 'csv',
      suggestedName: 'unit-$selectedUnit.csv',
    );
    if (path == null || path.isEmpty) return;
    try {
      final rows = snifferViews(session.sniffed[selectedUnit] ?? {})
          .where((r) => r['values'] != null)
          .toList();
      final result = await session.command({
        'command': 'csv_export',
        'rows': rows,
        'include_values': true,
      });
      if (result != null) {
        await File(path).writeAsString(result['text'] as String, flush: true);
      }
    } catch (e) {
      if (mounted) setState(() => localError = userError(e));
    }
  }

  List<Map<String, dynamic>> get visibleLogs => logs
      .where(
        (e) =>
            session.mode != 'sniffer' ||
            !unitLog ||
            e['unit'] == null ||
            e['unit'] == selectedUnit,
      )
      .toList();

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) => Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: ListView(
          children: [
            Row(
              children: [
                LText(
                  trf('{mode} session', {'mode': tr(session.mode)}),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const Spacer(),
                IconButton(
                  tooltip: tr('Graph'),
                  icon: const Icon(Icons.multiline_chart),
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => GraphDialog(session: session),
                  ),
                ),
                LText(session.deviceRunning ? 'Running' : 'Stopped'),
                const SizedBox(width: 12),
                FilledButton.icon(
                  onPressed: session.busy
                      ? null
                      : session.deviceRunning
                      ? () async {
                          await session.command({'command': 'device_stop'});
                          if (mounted) {
                            setState(() => session.deviceRunning = false);
                          }
                        }
                      : start,
                  icon: Icon(
                    session.deviceRunning ? Icons.stop : Icons.play_arrow,
                  ),
                  label: LText(session.deviceRunning ? 'Stop' : 'Start'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ConnectionFields(
              session: session,
              key: ValueKey('${session.mode}-listen'),
              label: session.mode == 'sniffer'
                  ? 'Serial adapter (passive; never transmits)'
                  : 'Listen',
              value: listen,
              enabled: !session.deviceRunning,
              serialOnly: session.mode == 'sniffer',
              onChanged: (v) {
                listen = v;
                saveConfig();
              },
            ),
            if (session.mode == 'gateway') ...[
              const SizedBox(height: 12),
              ConnectionFields(
                session: session,
                label: 'Target',
                value: target,
                enabled: !session.deviceRunning,
                target: true,
                onChanged: (v) {
                  target = v;
                  saveConfig();
                },
              ),
            ],
            const SizedBox(height: 12),
            if (session.mode != 'sniffer')
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  toolField(
                    session.mode == 'gateway'
                        ? 'Allowed units: blank=all; 1,2,3'
                        : 'Unit: blank=any',
                    units,
                    width: 280,
                    enabled: !session.deviceRunning,
                  ),
                  if (session.mode == 'simulator')
                    toolField(
                      'Tick, ms',
                      tick,
                      enabled: !session.deviceRunning,
                    ),
                ],
              ),
            if (localError != null || session.error != null)
              Padding(
                padding: const EdgeInsets.all(8),
                child: LText(
                  localError ?? session.error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (session.mode == 'simulator') ...[
              Wrap(
                spacing: 12,
                children: [
                  TextButton.icon(
                    onPressed: session.busy ? null : addRow,
                    icon: const Icon(Icons.add),
                    label: const LText('Add row'),
                  ),
                  TextButton.icon(
                    onPressed: session.busy ? null : templates,
                    icon: const Icon(Icons.library_books),
                    label: const LText('Load template rows'),
                  ),
                  const Padding(
                    padding: EdgeInsets.all(10),
                    child: LText(
                      'Edit rows, set values, or assign expression rules. Map persists while stopped.',
                    ),
                  ),
                ],
              ),
              SizedBox(
                height: 260,
                child: Card(
                  child: ListView.builder(
                    itemCount: session.simRows.length,
                    itemBuilder: (context, i) {
                      final row = session.simRows[i];
                      return ListTile(
                        dense: true,
                        title: LText(
                          '${row['name']} · ${tr(row['kind'] as String)} @${row['address']} ×${row['count']}',
                        ),
                        subtitle: LText(
                          '${i < results.length ? results[i]['display'] : '—'} · ${row['rule_text'] ?? tr('manual')}${ruleErrors['$i'] == null ? '' : ' · ${tr(const {'invalid_rule': 'Invalid rule syntax', 'nonfinite_rule': 'Rule result is not finite', 'missing_reference': 'Rule reference is unavailable', 'rule_evaluation_failed': 'Rule evaluation or encoding failed'}[ruleErrors['$i']['code']] ?? 'Rule evaluation or encoding failed')}'}',
                          style: ruleErrors['$i'] == null
                              ? null
                              : TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                        ),
                        onTap: session.busy ? null : () => addRow(i),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (hasInlineEnum(row))
                              inlineEnumEditor(
                                row,
                                i < results.length
                                    ? results[i]['values'] as List? ?? []
                                    : [],
                                session.busy ||
                                        (row['rule_text'] as String? ?? '')
                                            .trim()
                                            .isNotEmpty
                                    ? null
                                    : (v) async {
                                        await session.command({
                                          'command': 'sim_set',
                                          'row': row,
                                          'values': [v],
                                        });
                                        await refresh();
                                      },
                              )
                            else
                              IconButton(
                                tooltip: tr('Set value'),
                                onPressed:
                                    session.busy ||
                                        (row['rule_text'] as String? ?? '')
                                            .trim()
                                            .isNotEmpty
                                    ? null
                                    : () => setValue(i),
                                icon: const Icon(Icons.edit_note),
                              ),
                            IconButton(
                              tooltip: tr('Expression rule'),
                              onPressed: session.busy
                                  ? null
                                  : () => editRule(i),
                              icon: const Icon(Icons.functions),
                            ),
                            IconButton(
                              tooltip: tr('Remove row'),
                              onPressed: session.busy
                                  ? null
                                  : () async {
                                      setState(
                                        () => session.simRows.removeAt(i),
                                      );
                                      await configure();
                                    },
                              icon: const Icon(Icons.close),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
            if (session.mode == 'sniffer') ...[
              Wrap(
                spacing: 10,
                children: [
                  for (final unit in session.sniffed.keys.toList()..sort())
                    ChoiceChip(
                      label: LText('Unit $unit'),
                      selected: selectedUnit == unit,
                      onSelected: (_) {
                        setState(() {
                          selectedUnit = unit;
                          session.draft['sniffer_selected_unit'] = unit;
                          sniffDisplays.clear();
                        });
                        unawaited(renderSniffer());
                      },
                    ),
                  TextButton(
                    onPressed: refreshSniffer,
                    child: const LText('Refresh map'),
                  ),
                  TextButton(
                    onPressed: exportSniffer,
                    child: const LText('Export CSV'),
                  ),
                ],
              ),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  toolField('Search name / address', sniffSearch, width: 210),
                  toolChoice(
                    'Area',
                    sniffArea,
                    ['all', ...areas.keys],
                    (v) => setState(() {
                      sniffArea = v;
                      session.draft['sniffer_area'] = v;
                    }),
                    width: 180,
                  ),
                  FilterChip(
                    label: const LText('Descending addresses'),
                    selected: sniffDescending,
                    onSelected: (v) => setState(() {
                      sniffDescending = v;
                      session.draft['sniffer_descending'] = v;
                    }),
                  ),
                  TextButton(
                    onPressed: manageSnifferViews,
                    child: const LText('Manage views'),
                  ),
                  TextButton(
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (_) => GraphDialog(
                        session: session,
                        historyPrefix: 'sniff-view/$selectedUnit/',
                      ),
                    ),
                    child: const LText('Graph selected unit'),
                  ),
                ],
              ),
              SizedBox(height: 280, child: Card(child: snifferTable())),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                const LText('Traffic / events'),
                if (session.mode == 'sniffer')
                  FilterChip(
                    label: const LText('Selected unit only'),
                    selected: unitLog,
                    onSelected: (v) => setState(() {
                      unitLog = v;
                      session.draft['sniffer_unit_log'] = v;
                    }),
                  ),
                const Spacer(),
                TextButton(
                  onPressed: () => setState(logs.clear),
                  child: const LText('Clear'),
                ),
              ],
            ),
            SizedBox(
              height: 170,
              child: Card(
                child: ListView.builder(
                  reverse: true,
                  itemCount: visibleLogs.length,
                  itemBuilder: (context, i) {
                    final e = visibleLogs[visibleLogs.length - 1 - i];
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 3,
                      ),
                      child: SelectableText(
                        e['line'] as String? ??
                            '${e['event']}: ${userError(e)}',
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          color: e['event'] == 'error'
                              ? Theme.of(context).colorScheme.error
                              : null,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
