import 'package:flutter/material.dart';

import 'session_controller.dart';
import 'tool_widgets.dart';

class LoggingDialog extends StatefulWidget {
  const LoggingDialog({super.key, required this.session});
  final SessionController session;
  @override
  State<LoggingDialog> createState() => _LoggingDialogState();
}

class _LoggingDialogState extends State<LoggingDialog> {
  late final path = TextEditingController(
    text: widget.session.loggingSettings['path'] as String? ?? 'modbus-log.csv',
  );
  final interval = TextEditingController(text: '1000');
  String format = 'csv';
  bool append = true;
  final fields = <String>{'timestamp', 'name', 'address', 'kind'};
  final selected = <int>{};
  String? error;
  @override
  void initState() {
    super.initState();
    selected.addAll(List.generate(widget.session.registers.length, (i) => i));
  }

  @override
  void dispose() {
    path.dispose();
    interval.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.session,
    builder: (context, _) => AlertDialog(
      title: const Text('Data logger'),
      content: SizedBox(
        width: 600,
        height: 400,
        child: Column(
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                toolField(
                  'Output file path',
                  path,
                  width: 550,
                  enabled: !widget.session.logging,
                ),
                toolChoice(
                  'Format',
                  format,
                  ['csv', 'jsonl'],
                  widget.session.logging
                      ? null
                      : (v) => setState(() => format = v),
                ),
                toolField(
                  'Interval, ms',
                  interval,
                  enabled: !widget.session.logging,
                ),
              ],
            ),
            CheckboxListTile(
              title: const Text('Append to existing file'),
              value: append,
              onChanged: widget.session.logging
                  ? null
                  : (v) => setState(() => append = v!),
            ),
            if (format == 'jsonl')
              Wrap(
                children: [
                  for (final f in ['timestamp', 'name', 'address', 'kind'])
                    FilterChip(
                      label: Text(f),
                      selected: fields.contains(f),
                      onSelected: widget.session.logging
                          ? null
                          : (v) => setState(() {
                              if (v) {
                                fields.add(f);
                              } else {
                                fields.remove(f);
                              }
                            }),
                    ),
                ],
              ),
            const Text(
              'CSV: timestamp + one column per selected row. Logging reads at this interval; busy ticks are skipped.',
            ),
            if (widget.session.registers.isEmpty)
              const Text('Add rows in Register map before starting.'),
            Expanded(
              child: ListView(
                children: [
                  for (var i = 0; i < widget.session.registers.length; i++)
                    CheckboxListTile(
                      dense: true,
                      title: Text(
                        '${widget.session.registers[i]['name']} @${widget.session.registers[i]['address']}',
                      ),
                      value: selected.contains(i),
                      onChanged: widget.session.logging
                          ? null
                          : (v) => setState(() {
                              if (v!) {
                                selected.add(i);
                              } else {
                                selected.remove(i);
                              }
                            }),
                    ),
                ],
              ),
            ),
            Text(
              widget.session.logging
                  ? 'Logging · ${widget.session.loggedSamples} samples written'
                  : 'Stopped',
            ),
            if (error != null || widget.session.error != null)
              Text(error ?? widget.session.error!),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        if (widget.session.logging)
          FilledButton(
            onPressed: widget.session.stopLogging,
            child: const Text('Stop logging'),
          )
        else
          FilledButton(
            onPressed:
                widget.session.busy ||
                    !widget.session.connected ||
                    selected.isEmpty
                ? null
                : () async {
                    final ms = int.tryParse(interval.text);
                    if (ms == null ||
                        ms < 100 ||
                        ms > 86400000 ||
                        path.text.trim().isEmpty) {
                      setState(
                        () => error =
                            'Choose a path and interval 100–86400000 ms',
                      );
                      return;
                    }
                    if (!append) {
                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('Replace existing log file?'),
                          content: Text(path.text),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: const Text('Cancel'),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: const Text('Replace'),
                            ),
                          ],
                        ),
                      );
                      if (confirmed != true) return;
                    }
                    await widget.session.startLogging(
                      {
                        'path': path.text.trim(),
                        'format': format,
                        'interval_ms': ms,
                        'append': append,
                        'fields': fields.toList(),
                      },
                      selected.map((i) => widget.session.registers[i]).toList(),
                    );
                  },
            child: const Text('Start logging'),
          ),
      ],
    ),
  );
}

class AlarmRulesDialog extends StatefulWidget {
  const AlarmRulesDialog({super.key, required this.rules});
  final List<Map<String, dynamic>> rules;
  @override
  State<AlarmRulesDialog> createState() => _AlarmRulesDialogState();
}

class _AlarmRulesDialogState extends State<AlarmRulesDialog> {
  late final rules = widget.rules
      .map((r) => Map<String, dynamic>.of(r))
      .toList();
  String condition = 'gt';
  String color = 'red';
  bool log = true;
  bool sound = false;
  final value = TextEditingController(text: '100');
  final value2 = TextEditingController(text: '200');
  String? error;
  @override
  void dispose() {
    value.dispose();
    value2.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Alarm rules · first match wins'),
    content: SizedBox(
      width: 650,
      height: 400,
      child: Column(
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              toolChoice('Condition', condition, [
                'gt',
                'ge',
                'lt',
                'le',
                'eq',
                'ne',
                'in_range',
                'outside_range',
              ], (v) => setState(() => condition = v)),
              toolField('Threshold / lower', value),
              if (condition.endsWith('range')) toolField('Upper', value2),
              toolChoice(
                'Color',
                color,
                ['red', 'yellow'],
                (v) => setState(() => color = v),
                width: 120,
              ),
            ],
          ),
          Row(
            children: [
              Checkbox(value: log, onChanged: (v) => setState(() => log = v!)),
              const Text('Log on entry'),
              Checkbox(
                value: sound,
                onChanged: (v) => setState(() => sound = v!),
              ),
              const Text('Sound on entry'),
              TextButton(
                onPressed: () {
                  final a = double.tryParse(value.text);
                  final b = condition.endsWith('range')
                      ? double.tryParse(value2.text)
                      : null;
                  if (a == null ||
                      !a.isFinite ||
                      (condition.endsWith('range') &&
                          (b == null || !b.isFinite))) {
                    setState(() => error = 'Enter finite thresholds');
                    return;
                  }
                  setState(
                    () => rules.add({
                      'condition': condition,
                      'value': a,
                      'value2': ?b,
                      'color': color,
                      'log': log,
                      'sound': sound,
                    }),
                  );
                },
                child: const Text('Add rule'),
              ),
            ],
          ),
          if (error != null) Text(error!),
          Expanded(
            child: ListView(
              children: [
                for (var i = 0; i < rules.length; i++)
                  ListTile(
                    dense: true,
                    title: Text(
                      '${i + 1}. ${rules[i]['condition']} ${rules[i]['value']} ${rules[i]['value2'] ?? ''} · ${rules[i]['color']}',
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: 'Higher priority',
                          onPressed: i == 0
                              ? null
                              : () => setState(() {
                                  final r = rules.removeAt(i);
                                  rules.insert(i - 1, r);
                                }),
                          icon: const Icon(Icons.arrow_upward),
                        ),
                        IconButton(
                          tooltip: 'Remove rule',
                          onPressed: () => setState(() => rules.removeAt(i)),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, rules),
        child: const Text('Apply'),
      ),
    ],
  );
}
