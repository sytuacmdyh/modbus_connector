import 'file_paths.dart';
import 'translations.dart';

import 'package:flutter/material.dart';

import 'session_controller.dart';
import 'tool_widgets.dart';

/// The wire format keeps short condition identifiers so that alarms can be
/// shared with the native backend.  Do not expose those identifiers directly
/// in the editor: operators are much easier to scan when they look like the
/// condition they express.
const alarmConditionChoices = [
  'gt',
  'ge',
  'lt',
  'le',
  'eq',
  'ne',
  'in_range',
  'outside_range',
];

String alarmConditionLabel(String condition) => switch (condition) {
  'gt' => '>',
  'ge' => '>=',
  'lt' => '<',
  'le' => '<=',
  'eq' => '=',
  'ne' => '!=',
  'in_range' => 'in range',
  'outside_range' => 'outside range',
  _ => condition,
};

String _alarmValue(dynamic value) => value is num ? '$value' : '${value ?? ''}';

String alarmRuleSummary(Map<String, dynamic> rule) {
  final condition = rule['condition'] as String? ?? '';
  final value = _alarmValue(rule['value']);
  final upper = _alarmValue(rule['value2']);
  final expression = switch (condition) {
    'gt' => 'x > $value',
    'ge' => 'x >= $value',
    'lt' => 'x < $value',
    'le' => 'x <= $value',
    'eq' => 'x = $value',
    'ne' => 'x != $value',
    'in_range' => '$value <= x <= $upper',
    'outside_range' => 'x < $value or x > $upper',
    _ => '${alarmConditionLabel(condition)} $value',
  };
  final color = tr('${rule['color'] ?? 'red'}');
  return '$expression · $color';
}

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
  final selectedExpressions = <int>{};
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
      title: const LText('Data logger'),
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
                  width: 410,
                  enabled: !widget.session.logging,
                ),
                IconButton(
                  tooltip: tr('Browse'),
                  icon: const Icon(Icons.folder_open),
                  onPressed: widget.session.logging
                      ? null
                      : () async {
                          final chosen = await chooseFilePath(
                            context,
                            save: true,
                            title: 'Output file path',
                            extension: format,
                            suggestedName: path.text,
                          );
                          if (chosen != null && mounted) {
                            setState(() => path.text = chosen);
                          }
                        },
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
              title: const LText('Append to existing file'),
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
                      label: LText(f),
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
            const LText(
              'CSV: timestamp + one column per selected row. Logging reads at this interval; busy ticks are skipped.',
            ),
            if (widget.session.expressions.isNotEmpty)
              const LText(
                'Expressions read fresh map dependencies at each logging tick.',
              ),
            if (widget.session.registers.isEmpty &&
                widget.session.expressions.isEmpty)
              const LText('Add rows in Register map before starting.'),
            Expanded(
              child: ListView(
                children: [
                  for (var i = 0; i < widget.session.expressions.length; i++)
                    CheckboxListTile(
                      dense: true,
                      title: Text(
                        'fx ${widget.session.expressions[i]['name']}',
                      ),
                      subtitle: Text(
                        widget.session.expressions[i]['text'] as String,
                      ),
                      value: selectedExpressions.contains(i),
                      onChanged: widget.session.logging
                          ? null
                          : (v) => setState(() {
                              if (v!) {
                                selectedExpressions.add(i);
                              } else {
                                selectedExpressions.remove(i);
                              }
                            }),
                    ),
                  for (var i = 0; i < widget.session.registers.length; i++)
                    CheckboxListTile(
                      dense: true,
                      title: LText(
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
            LText(
              widget.session.logging
                  ? 'Logging · ${widget.session.loggedSamples} samples written'
                  : !widget.session.connected
                  ? 'Connect to a device before starting logging.'
                  : widget.session.busy
                  ? 'Wait for the current operation to finish.'
                  : 'Stopped',
            ),
            if (error != null || widget.session.error != null)
              LText(error ?? widget.session.error!),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const LText('Close'),
        ),
        if (widget.session.logging)
          FilledButton(
            onPressed: widget.session.stopLogging,
            child: const LText('Stop logging'),
          )
        else
          FilledButton(
            onPressed:
                widget.session.busy ||
                    !widget.session.connected ||
                    (selected.isEmpty && selectedExpressions.isEmpty)
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
                          title: const LText('Replace existing log file?'),
                          content: LText(path.text),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: const LText('Cancel'),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: const LText('Replace'),
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
                      expressionRows: selectedExpressions
                          .map((i) => widget.session.expressions[i])
                          .toList(),
                    );
                  },
            child: const LText('Start logging'),
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

  Widget _conditionChoice() => SizedBox(
    width: 180,
    child: DropdownButtonFormField<String>(
      initialValue: condition,
      isExpanded: true,
      decoration: InputDecoration(labelText: tr('Condition')),
      items: alarmConditionChoices
          .map(
            (value) => DropdownMenuItem(
              value: value,
              child: LText(alarmConditionLabel(value)),
            ),
          )
          .toList(),
      onChanged: (value) {
        if (value != null) setState(() => condition = value);
      },
    ),
  );

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const LText('Alarm rules · first match wins'),
    content: SizedBox(
      width: 650,
      height: 400,
      child: Column(
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _conditionChoice(),
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
              const LText('Log on entry'),
              Checkbox(
                value: sound,
                onChanged: (v) => setState(() => sound = v!),
              ),
              const LText('Sound on entry'),
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
                child: const LText('Add rule'),
              ),
            ],
          ),
          if (error != null) LText(error!),
          Expanded(
            child: ListView(
              children: [
                for (var i = 0; i < rules.length; i++)
                  ListTile(
                    dense: true,
                    title: Text('${i + 1}. ${alarmRuleSummary(rules[i])}'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: tr('Higher priority'),
                          onPressed: i == 0
                              ? null
                              : () => setState(() {
                                  final r = rules.removeAt(i);
                                  rules.insert(i - 1, r);
                                }),
                          icon: const Icon(Icons.arrow_upward),
                        ),
                        IconButton(
                          tooltip: tr('Remove rule'),
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
        child: const LText('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, rules),
        child: const LText('Apply'),
      ),
    ],
  );
}
