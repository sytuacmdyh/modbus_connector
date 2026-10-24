import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import 'session_controller.dart';
import 'tool_widgets.dart';

class ScannerController extends ChangeNotifier {
  ScannerController(this.session);
  final SessionController session;
  bool running = false;
  bool stopped = false;
  bool _disposed = false;
  int done = 0;
  int total = 0;
  String? error;
  final List<Map<String, dynamic>> hits = [];
  void stop() {
    stopped = true;
    notifyListeners();
  }

  Future<void> scan({
    required bool addresses,
    required int start,
    required int end,
    required int unit,
    required String kind,
    required List<Map<String, dynamic>> probes,
  }) async {
    if (running || session.busy || !session.connected) return;
    if (start < (addresses ? 0 : 1) ||
        end < start ||
        end > (addresses ? 65535 : 247)) {
      error = 'Invalid scan range';
      notifyListeners();
      return;
    }
    running = true;
    stopped = false;
    error = null;
    done = 0;
    total = end - start + 1;
    hits.clear();
    session.beginTool();
    notifyListeners();
    try {
      for (var n = start; n <= end && !stopped && !_disposed; n++) {
        Map<String, dynamic>? reply;
        if (addresses) {
          reply = await session.command({
            'command': 'scan_address',
            'unit': unit,
            'kind': kind,
            'address': n,
          });
        } else {
          final matched = <int>[];
          for (var p = 0; p < probes.length && !stopped && !_disposed; p++) {
            final part = await session.command({
              'command': 'scan_unit',
              'unit': n,
              'probes': [probes[p]],
            });
            if (part == null) {
              error = session.error;
              break;
            }
            if ((part['hits'] as List).isNotEmpty) matched.add(p);
          }
          if (error == null) reply = {'unit': n, 'hits': matched};
        }
        if (stopped || _disposed) break;
        if (reply == null) {
          error = session.error;
          break;
        }
        if ((reply[addresses ? 'values' : 'hits'] as List).isNotEmpty) {
          hits.add(reply);
        }
        done++;
        notifyListeners();
      }
    } finally {
      running = false;
      session.endTool();
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    stopped = true;
    _disposed = true;
    super.dispose();
  }
}

class ScannerDialog extends StatefulWidget {
  const ScannerDialog({super.key, required this.session});
  final SessionController session;
  @override
  State<ScannerDialog> createState() => _ScannerDialogState();
}

class _ScannerDialogState extends State<ScannerDialog> {
  late final scanner = ScannerController(widget.session);
  final start = TextEditingController(text: '1');
  final end = TextEditingController(text: '247');
  final unit = TextEditingController(text: '1');
  final probes = <Map<String, dynamic>>[
    {'kind': 'holding_registers', 'address': 0, 'count': 1},
    {'kind': 'input_registers', 'address': 0, 'count': 1},
    {'kind': 'coils', 'address': 0, 'count': 1},
  ];
  bool addresses = false;
  String kind = 'holding_registers';
  final selected = <int>{};
  @override
  void initState() {
    super.initState();
    final state = widget.session.scannerState;
    addresses = state['addresses'] == true;
    start.text = '${state['start'] ?? (addresses ? 0 : 1)}';
    end.text = '${state['end'] ?? (addresses ? 99 : 247)}';
    unit.text = '${state['unit'] ?? widget.session.unit}';
    if (areas.containsKey(state['kind'])) kind = state['kind'] as String;
    if (state['probes'] is List && (state['probes'] as List).isNotEmpty) {
      probes
        ..clear()
        ..addAll((state['probes'] as List).whereType<Map<String, dynamic>>());
    }
  }

  @override
  void dispose() {
    widget.session.scannerState.addAll({
      'addresses': addresses,
      'start': int.tryParse(start.text),
      'end': int.tryParse(end.text),
      'unit': int.tryParse(unit.text),
      'kind': kind,
      'probes': probes,
    });
    scanner.dispose();
    start.dispose();
    end.dispose();
    unit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: scanner,
    builder: (context, _) => PopScope(
      canPop: !scanner.running,
      child: AlertDialog(
        title: const Text('Scanner'),
        content: SizedBox(
          width: 760,
          height: 470,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 10,
                runSpacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  toolChoice(
                    'Scan',
                    addresses ? 'Addresses' : 'Units',
                    ['Units', 'Addresses'],
                    scanner.running
                        ? null
                        : (v) => setState(() {
                            addresses = v == 'Addresses';
                            start.text = addresses ? '0' : '1';
                            end.text = addresses ? '99' : '247';
                            selected.clear();
                            scanner.hits.clear();
                          }),
                    width: 140,
                  ),
                  toolField(
                    'From',
                    start,
                    width: 80,
                    enabled: !scanner.running,
                  ),
                  toolField('To', end, width: 80, enabled: !scanner.running),
                  if (addresses) ...[
                    toolField(
                      'Unit',
                      unit,
                      width: 75,
                      enabled: !scanner.running,
                    ),
                    toolChoice(
                      'Area',
                      kind,
                      areas.keys,
                      scanner.running ? null : (v) => setState(() => kind = v),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 10),
              if (!addresses)
                SizedBox(
                  height: 110,
                  child: ListView(
                    children: [
                      for (final probe in probes)
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${probe['kind']} @${probe['address']} × ${probe['count']}',
                              ),
                            ),
                            IconButton(
                              tooltip: 'Edit probe',
                              onPressed: scanner.running
                                  ? null
                                  : () async {
                                      final value = await textPrompt(
                                        context,
                                        'Probe: area,address,count',
                                        value:
                                            '${probe['kind']},${probe['address']},${probe['count']}',
                                      );
                                      if (value == null || !mounted) return;
                                      final parts = value.split(',');
                                      if (parts.length == 3 &&
                                          areas.containsKey(parts[0]) &&
                                          int.tryParse(parts[1]) != null &&
                                          int.tryParse(parts[2]) != null) {
                                        setState(() {
                                          probe['kind'] = parts[0];
                                          probe['address'] = int.parse(
                                            parts[1],
                                          );
                                          probe['count'] = int.parse(parts[2]);
                                        });
                                      }
                                    },
                              icon: const Icon(Icons.edit, size: 18),
                            ),
                            IconButton(
                              tooltip: 'Remove probe',
                              onPressed: scanner.running || probes.length == 1
                                  ? null
                                  : () => setState(() => probes.remove(probe)),
                              icon: const Icon(Icons.close, size: 18),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              if (!addresses)
                TextButton(
                  onPressed: scanner.running || probes.length >= 32
                      ? null
                      : () => setState(
                          () => probes.add({
                            'kind': kind,
                            'address': 0,
                            'count': 1,
                          }),
                        ),
                  child: const Text('Add probe'),
                ),
              LinearProgressIndicator(
                value: scanner.total == 0 ? 0 : scanner.done / scanner.total,
              ),
              Text(
                '${scanner.done} / ${scanner.total} · ${scanner.hits.length} hits${scanner.stopped ? ' · stopped' : ''}',
              ),
              if (scanner.error != null)
                Text(
                  scanner.error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              Expanded(
                child: ListView.builder(
                  itemCount: scanner.hits.length,
                  itemBuilder: (context, i) {
                    final hit = scanner.hits[i];
                    final n = hit[addresses ? 'address' : 'unit'] as int;
                    return CheckboxListTile(
                      dense: true,
                      value: selected.contains(n),
                      onChanged: scanner.running
                          ? null
                          : (v) => setState(() {
                              if (v == true) {
                                selected.add(n);
                              } else {
                                selected.remove(n);
                              }
                            }),
                      title: Text(
                        addresses
                            ? '@$n · ${(hit['values'] as List).join(', ')}'
                            : 'Unit $n · probes ${hit['hits']}',
                      ),
                      secondary: addresses
                          ? null
                          : IconButton(
                              tooltip: 'Device identification',
                              onPressed: scanner.running
                                  ? null
                                  : () async {
                                      final result = await widget.session
                                          .command({
                                            'command': 'device_id',
                                            'unit': n,
                                          });
                                      if (context.mounted) {
                                        await showText(
                                          context,
                                          'Unit $n identification',
                                          const JsonEncoder.withIndent(
                                            '  ',
                                          ).convert(
                                            result ??
                                                {'error': widget.session.error},
                                          ),
                                        );
                                      }
                                    },
                              icon: const Icon(Icons.info_outline),
                            ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: scanner.running ? null : () => Navigator.pop(context),
            child: const Text('Close'),
          ),
          if (scanner.running)
            FilledButton(onPressed: scanner.stop, child: const Text('Stop'))
          else ...[
            TextButton(
              onPressed: selected.isEmpty
                  ? null
                  : () {
                      if (addresses) {
                        final list = selected.toList()..sort();
                        widget.session.unit = int.tryParse(unit.text) ?? 1;
                        widget.session.setQuery(
                          ReadQuery(
                            kind: kind,
                            address: list.first,
                            count: (list.last - list.first + 1).clamp(
                              1,
                              kind == 'coils' || kind == 'discrete_inputs'
                                  ? 2000
                                  : 125,
                            ),
                          ),
                        );
                      } else {
                        widget.session.unit = selected.first;
                      }
                      Navigator.pop(context, true);
                    },
              child: Text(
                addresses ? 'Open selected range' : 'Use selected unit',
              ),
            ),
            FilledButton(
              onPressed: !widget.session.connected
                  ? null
                  : () {
                      selected.clear();
                      unawaited(
                        scanner.scan(
                          addresses: addresses,
                          start: int.tryParse(start.text) ?? -1,
                          end: int.tryParse(end.text) ?? -1,
                          unit: int.tryParse(unit.text) ?? -1,
                          kind: kind,
                          probes: probes,
                        ),
                      );
                    },
              child: const Text('Start scan'),
            ),
          ],
        ],
      ),
    ),
  );
}
