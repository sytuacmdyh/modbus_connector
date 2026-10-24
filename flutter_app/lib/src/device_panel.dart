import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'register_map.dart';
import 'session_controller.dart';
import 'tool_widgets.dart';

class ConnectionFields extends StatefulWidget {
  const ConnectionFields({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.enabled = true,
    this.serialOnly = false,
    this.target = false,
  });
  final String label;
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
            '${e.key == 'serial' ? (widget.value['transport'] == 'rtu' ? widget.value['port'] ?? '' : '') : widget.value[e.key] ?? e.value}',
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
          Text(widget.label, style: Theme.of(context).textTheme.titleMedium),
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
                toolField(
                  'Serial port',
                  fields['serial']!,
                  enabled: widget.enabled,
                  width: 180,
                ),
                for (final key in ['baudrate', 'bytesize', 'stopbits'])
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
  const DevicePanel({super.key, required this.session});
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
  int selectedUnit = 1;
  String? localError;
  Timer? timer;
  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(
      const Duration(milliseconds: 400),
      (_) => unawaited(refresh()),
    );
  }

  @override
  void dispose() {
    timer?.cancel();
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
    setState(() {
      session.deviceRunning = status[session.mode] == true;
      results = (status['rows'] as List).cast<Map<String, dynamic>>();
      for (final e in (status['events'] as List).cast<Map<String, dynamic>>()) {
        logs.add(e);
        if (logs.length > 1000) logs.removeAt(0);
        if (e['mode'] == 'sniffer' && e['event'] == 'values') {
          final unit = e['unit'] as int;
          final map = session.sniffed.putIfAbsent(unit, () => {});
          final values = e['values'] as List;
          for (var i = 0; i < values.length; i++) {
            final address = (e['address'] as int) + i;
            final key = '${e['kind']}/$address';
            final old = map[key];
            map[key] = {
              ...?old,
              'unit_id': unit,
              'kind': e['kind'],
              'address': address,
              'count': 1,
              'format': old?['format'] ?? 'dec',
              'name': old?['name'] ?? '',
              'value': values[i],
            };
          }
          if (!session.sniffed.containsKey(selectedUnit)) selectedUnit = unit;
        }
      }
      if ((status['dropped'] as int) > 0) {
        localError =
            'Event buffer overflow (${status['dropped']} events); use Refresh map.';
      }
    });
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
        localError = null;
      });
    }
  }

  Future<bool> configure() async {
    final reply = await session.command({
      'command': 'sim_configure',
      'rows': session.simRows,
    });
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
    final content = await textPrompt(
      context,
      'Set ${row['name']} (${row['format']})',
    );
    if (content == null) return;
    final encoded = await session.command({
      'command': 'encode_values',
      'row': row,
      'text': content,
    });
    if (encoded == null) return;
    await session.command({
      'command': 'sim_set',
      'row': row,
      'values': encoded['values'],
    });
    await refresh();
  }

  Future<void> editRule(int i) async {
    final rule = await textPrompt(
      context,
      'Rule: t, prev, [name], sin(), rand(), randint(a,b); blank = manual',
      value: session.simRows[i]['rule_text'] as String? ?? '',
    );
    if (rule == null || !mounted) return;
    final old = session.simRows[i]['rule_text'];
    session.simRows[i]['rule_text'] = rule;
    if (!await configure()) session.simRows[i]['rule_text'] = old;
    if (mounted) setState(() {});
  }

  Future<void> refreshSniffer() async {
    final reply = await session.command({
      'command': 'sniffer_snapshot',
      'unit': selectedUnit,
    });
    if (reply == null || !mounted) return;
    setState(() {
      final map = session.sniffed.putIfAbsent(selectedUnit, () => {});
      for (final area in (reply['areas'] as Map).entries) {
        for (final cell in (area.value as Map).entries) {
          final address = int.parse('${cell.key}');
          final key = '${area.key}/$address';
          map[key] = {
            ...?map[key],
            'unit_id': selectedUnit,
            'kind': area.key,
            'address': address,
            'count': 1,
            'format': map[key]?['format'] ?? 'dec',
            'name': map[key]?['name'] ?? '',
            'value': cell.value,
          };
        }
      }
      localError = null;
    });
  }

  Future<void> exportSniffer() async {
    final path = await textPrompt(
      context,
      'Export selected unit CSV file path',
    );
    if (path == null || path.isEmpty) return;
    try {
      final rows = (session.sniffed[selectedUnit] ?? {}).values
          .map((r) => Map<String, dynamic>.of(r))
          .toList();
      final result = await session.command({
        'command': 'csv_export',
        'rows': rows,
      });
      if (result != null) {
        await File(path).writeAsString(result['text'] as String, flush: true);
      }
    } catch (e) {
      if (mounted) setState(() => localError = '$e');
    }
  }

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
                Text(
                  '${session.mode[0].toUpperCase()}${session.mode.substring(1)} session',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const Spacer(),
                Text(session.deviceRunning ? 'Running' : 'Stopped'),
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
                  label: Text(session.deviceRunning ? 'Stop' : 'Start'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ConnectionFields(
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
                child: Text(
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
                    label: const Text('Add row'),
                  ),
                  const Padding(
                    padding: EdgeInsets.all(10),
                    child: Text(
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
                        title: Text(
                          '${row['name']} · ${row['kind']} @${row['address']} ×${row['count']}',
                        ),
                        subtitle: Text(
                          '${i < results.length ? results[i]['display'] : '—'} · ${row['rule_text'] ?? 'manual'}',
                        ),
                        onTap: session.busy ? null : () => addRow(i),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'Set value',
                              onPressed: session.busy
                                  ? null
                                  : () => setValue(i),
                              icon: const Icon(Icons.edit_note),
                            ),
                            IconButton(
                              tooltip: 'Expression rule',
                              onPressed: session.busy
                                  ? null
                                  : () => editRule(i),
                              icon: const Icon(Icons.functions),
                            ),
                            IconButton(
                              tooltip: 'Remove row',
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
                  for (final unit in session.sniffed.keys)
                    ChoiceChip(
                      label: Text('Unit $unit'),
                      selected: selectedUnit == unit,
                      onSelected: (_) => setState(() => selectedUnit = unit),
                    ),
                  TextButton(
                    onPressed: refreshSniffer,
                    child: const Text('Refresh map'),
                  ),
                  TextButton(
                    onPressed: exportSniffer,
                    child: const Text('Export CSV'),
                  ),
                ],
              ),
              SizedBox(
                height: 260,
                child: Card(
                  child: ListView(
                    children: [
                      for (final row
                          in (session.sniffed[selectedUnit] ?? {}).values)
                        ListTile(
                          dense: true,
                          title: Text(
                            '${row['kind']} @${row['address']} ${row['name']}',
                          ),
                          subtitle: Text('Value: ${row['value']}'),
                          onTap: () async {
                            final name = await textPrompt(
                              context,
                              'Register name',
                              value: row['name'] as String,
                            );
                            if (name != null && mounted) {
                              setState(() => row['name'] = name);
                            }
                          },
                        ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                const Text('Traffic / events'),
                const Spacer(),
                TextButton(
                  onPressed: () => setState(logs.clear),
                  child: const Text('Clear'),
                ),
              ],
            ),
            SizedBox(
              height: 170,
              child: Card(
                child: ListView.builder(
                  reverse: true,
                  itemCount: logs.length,
                  itemBuilder: (context, i) {
                    final e = logs[logs.length - 1 - i];
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 3,
                      ),
                      child: SelectableText(
                        e['line'] as String? ?? '${e['event']}: $e',
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
