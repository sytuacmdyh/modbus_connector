import 'dart:convert';

import 'package:flutter/material.dart';

import 'session_controller.dart';
import 'tool_widgets.dart';
import 'translations.dart';

class AdvancedDialog extends StatefulWidget {
  const AdvancedDialog({super.key, required this.session});
  final SessionController session;
  @override
  State<AdvancedDialog> createState() => _AdvancedDialogState();
}

class _AdvancedDialogState extends State<AdvancedDialog> {
  final address = TextEditingController(text: '0');
  final andMask = TextEditingController(text: '0xFFFF');
  final orMask = TextEditingController(text: '0');
  final readAddress = TextEditingController(text: '0');
  final readCount = TextEditingController(text: '1');
  final values = TextEditingController(text: '0');
  String output = '';
  @override
  void initState() {
    super.initState();
    widget.session.beginTool();
  }

  @override
  void dispose() {
    widget.session.endTool();
    for (final c in [
      address,
      andMask,
      orMask,
      readAddress,
      readCount,
      values,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> call(
    String command, [
    Map<String, dynamic> args = const {},
  ]) async {
    final result = await widget.session.command({
      'command': command,
      'unit': widget.session.unit,
      ...args,
    });
    if (mounted) {
      setState(
        () => output = result == null
            ? widget.session.error ?? 'Busy'
            : const JsonEncoder.withIndent('  ').convert(result),
      );
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.session,
    builder: (context, _) => DefaultTabController(
      length: 3,
      child: AlertDialog(
        title: LText('Advanced Modbus · unit ${widget.session.unit}'),
        content: SizedBox(
          width: 700,
          height: 420,
          child: Column(
            children: [
              const TabBar(
                tabs: [
                  Tab(text: 'Device / diagnostics'),
                  Tab(text: 'Mask write · 0x16'),
                  Tab(text: 'Read/write · 0x17'),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 180,
                child: TabBarView(
                  children: [
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        OutlinedButton(
                          onPressed: widget.session.busy
                              ? null
                              : () => call('device_id'),
                          child: const LText('Device identification'),
                        ),
                        OutlinedButton(
                          onPressed: widget.session.busy
                              ? null
                              : () =>
                                    call('diagnostics', {'action': 'loopback'}),
                          child: const LText('Loopback'),
                        ),
                        OutlinedButton(
                          onPressed: widget.session.busy
                              ? null
                              : () =>
                                    call('diagnostics', {'action': 'counters'}),
                          child: const LText('Diagnostic counters'),
                        ),
                        OutlinedButton(
                          onPressed: widget.session.busy
                              ? null
                              : () => call('diagnostics', {'action': 'clear'}),
                          child: const LText('Clear counters'),
                        ),
                      ],
                    ),
                    SingleChildScrollView(
                      child: Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          toolField('Write address', address),
                          toolField('AND mask', andMask),
                          toolField('OR mask', orMask),
                          FilledButton(
                            onPressed: widget.session.busy
                                ? null
                                : () => call('mask_write', {
                                    'address': int.tryParse(address.text) ?? -1,
                                    'and_mask':
                                        int.tryParse(andMask.text) ?? -1,
                                    'or_mask': int.tryParse(orMask.text) ?? -1,
                                  }),
                            child: const LText('Mask write'),
                          ),
                        ],
                      ),
                    ),
                    SingleChildScrollView(
                      child: Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          toolField('Read address', readAddress),
                          toolField('Read count', readCount),
                          toolField('Write address', address),
                          toolField(
                            'Raw write values (comma-separated)',
                            values,
                            width: 440,
                          ),
                          FilledButton(
                            onPressed: widget.session.busy
                                ? null
                                : () => call('read_write', {
                                    'read_address':
                                        int.tryParse(readAddress.text) ?? -1,
                                    'read_count':
                                        int.tryParse(readCount.text) ?? -1,
                                    'write_address':
                                        int.tryParse(address.text) ?? -1,
                                    'values': values.text
                                        .split(',')
                                        .map(
                                          (v) => int.tryParse(v.trim()) ?? -1,
                                        )
                                        .toList(),
                                  }),
                            child: const LText('Read / write'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (widget.session.busy) const LinearProgressIndicator(),
              Expanded(
                child: SingleChildScrollView(child: SelectableText(output)),
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
}
