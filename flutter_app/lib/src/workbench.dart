import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';

import 'live_chart.dart';
import 'session_controller.dart';
import 'write_dialog.dart';

class Workbench extends StatefulWidget {
  const Workbench({
    super.key,
    required this.controller,
    required this.themeMode,
    required this.onThemeChanged,
  });
  final SessionController controller;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeChanged;

  @override
  State<Workbench> createState() => _WorkbenchState();
}

class _WorkbenchState extends State<Workbench> {
  SessionController get session => widget.controller;
  final _connectionForm = GlobalKey<FormState>();
  final _host = TextEditingController(text: '127.0.0.1');
  final _port = TextEditingController(text: '502');
  final _serial = TextEditingController();
  final _baud = TextEditingController(text: '9600');
  final _unit = TextEditingController(text: '1');
  final _timeout = TextEditingController(text: '3');
  final _address = TextEditingController(text: '0');
  final _count = TextEditingController(text: '50');
  final _interval = TextEditingController(text: '500');
  String _transport = 'rtu';
  String _parity = 'N';
  int _bits = 8;
  int _stop = 1;
  String _kind = 'holding_registers';
  String? _queryError;
  bool get _queryMatches =>
      session.query.kind == _kind &&
      session.query.address == int.tryParse(_address.text) &&
      session.query.count == int.tryParse(_count.text);
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _address.addListener(_rangeEdited);
    _count.addListener(_rangeEdited);
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        await session.shutdown();
        return AppExitResponse.exit;
      },
    );
  }

  void _rangeEdited() => setState(() {});

  @override
  void dispose() {
    _lifecycle.dispose();
    for (final controller in [
      _host,
      _port,
      _serial,
      _baud,
      _unit,
      _timeout,
      _address,
      _count,
      _interval,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  String? _integer(String? value, int min, int max) {
    final parsed = int.tryParse(value ?? '');
    return parsed != null && parsed >= min && parsed <= max
        ? null
        : '$min–$max';
  }

  Widget _field(
    String label,
    TextEditingController controller,
    double width, {
    bool enabled = true,
    String? Function(String?)? validator,
    VoidCallback? onSubmit,
  }) => SizedBox(
    width: width,
    child: TextFormField(
      controller: controller,
      enabled: enabled,
      validator: validator,
      decoration: InputDecoration(labelText: label),
      onFieldSubmitted: (_) => onSubmit?.call(),
    ),
  );

  Widget _dropdown<T>(
    String label,
    T value,
    Map<T, String> items,
    ValueChanged<T>? onChanged,
    double width,
  ) => SizedBox(
    width: width,
    child: DropdownButtonFormField<T>(
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: items.entries
          .map(
            (e) => DropdownMenuItem(
              value: e.key,
              child: Text(e.value, overflow: TextOverflow.ellipsis),
            ),
          )
          .toList(),
      onChanged: onChanged == null
          ? null
          : (v) {
              if (v != null) onChanged(v);
            },
    ),
  );

  void _connect() {
    if (session.busy || session.connected || session.disconnecting) return;
    if (!_connectionForm.currentState!.validate()) return;
    unawaited(
      session.connect({
        'transport': _transport,
        'timeout': double.parse(_timeout.text),
        if (_transport == 'tcp') ...{
          'host': _host.text.trim(),
          'port': int.parse(_port.text),
        },
        if (_transport == 'rtu') ...{
          'port': _serial.text.trim(),
          'baudrate': int.parse(_baud.text),
          'bytesize': _bits,
          'parity': _parity,
          'stopbits': _stop,
        },
      }, int.parse(_unit.text)),
    );
  }

  bool _prepareQuery() {
    try {
      final address = int.tryParse(_address.text) ?? -1;
      final count = int.tryParse(_count.text) ?? -1;
      final interval = int.tryParse(_interval.text) ?? -1;
      final query = ReadQuery(kind: _kind, address: address, count: count);
      query.validate();
      if (interval < 100 || interval > 60000) {
        throw 'Poll interval must be 100–60000 ms';
      }
      if (session.query.kind != _kind ||
          session.query.address != address ||
          session.query.count != count) {
        session.setQuery(query);
      }
      session.intervalMs = interval;
      setState(() => _queryError = null);
      return true;
    } catch (error) {
      setState(() => _queryError = error.toString());
      return false;
    }
  }

  Future<void> _ports() async {
    final ports = await session.ports();
    if (!mounted || session.error != null) return;
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Serial ports'),
        children: ports.isEmpty
            ? [
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'No serial ports found. You can type a port manually.',
                  ),
                ),
              ]
            : ports
                  .map(
                    (p) => SimpleDialogOption(
                      onPressed: () =>
                          Navigator.pop(context, p['port'] as String),
                      child: Text('${p['port']} · ${p['description']}'),
                    ),
                  )
                  .toList(),
      ),
    );
    if (selected != null) _serial.text = selected;
  }

  Future<void> _edit(int index) async {
    if (!session.canRead || !session.query.writable || !_queryMatches) return;
    final address = session.query.address + index;
    final isBit = session.query.isBit;
    final current = index < session.values.length ? session.values[index] : 0;
    final wasPolling = session.polling;
    session.stopPolling();
    final value = await showDialog<int>(
      context: context,
      builder: (_) =>
          WriteDialog(address: address, isBit: isBit, current: current),
    );
    if (!mounted) return;
    if (value != null && session.canRead) await session.write(index, value);
    if (wasPolling && session.canRead && session.error == null) {
      session.startPolling();
    }
  }

  Widget _connection() {
    final locked = session.connected || session.busy || session.disconnecting;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Form(
          key: _connectionForm,
          child: Wrap(
            spacing: 12,
            runSpacing: 16,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _dropdown<String>(
                'Transport',
                _transport,
                const {'rtu': 'Serial RTU', 'tcp': 'TCP', 'demo': 'Local demo'},
                locked ? null : (v) => setState(() => _transport = v),
                150,
              ),
              if (_transport == 'tcp') ...[
                _field(
                  'Host',
                  _host,
                  175,
                  enabled: !locked,
                  validator: (v) => v!.trim().isEmpty ? 'Required' : null,
                  onSubmit: _connect,
                ),
                _field(
                  'Port',
                  _port,
                  90,
                  enabled: !locked,
                  validator: (v) => _integer(v, 1, 65535),
                  onSubmit: _connect,
                ),
              ],
              if (_transport == 'rtu') ...[
                _field(
                  'Serial port',
                  _serial,
                  160,
                  enabled: !locked,
                  validator: (v) =>
                      v!.trim().isEmpty ? 'Enter COM3 or /dev/ttyUSB0' : null,
                  onSubmit: _connect,
                ),
                IconButton(
                  tooltip: 'Find serial ports',
                  onPressed: locked ? null : _ports,
                  icon: const Icon(Icons.refresh),
                ),
                _field(
                  'Baud',
                  _baud,
                  95,
                  enabled: !locked,
                  validator: (v) => _integer(v, 50, 4000000),
                  onSubmit: _connect,
                ),
                _dropdown<int>(
                  'Bits',
                  _bits,
                  const {8: '8', 7: '7'},
                  locked ? null : (v) => setState(() => _bits = v),
                  75,
                ),
                _dropdown<String>(
                  'Parity',
                  _parity,
                  const {'N': 'None', 'E': 'Even', 'O': 'Odd'},
                  locked ? null : (v) => setState(() => _parity = v),
                  95,
                ),
                _dropdown<int>(
                  'Stop',
                  _stop,
                  const {1: '1', 2: '2'},
                  locked ? null : (v) => setState(() => _stop = v),
                  75,
                ),
              ],
              _field(
                'Unit',
                _unit,
                75,
                enabled: !locked,
                validator: (v) => _integer(v, 1, 247),
                onSubmit: _connect,
              ),
              _field(
                'Timeout, s',
                _timeout,
                105,
                enabled: !locked,
                validator: (v) {
                  final n = double.tryParse(v ?? '');
                  return n != null && n >= 0.1 && n <= 60 ? null : '0.1–60';
                },
                onSubmit: _connect,
              ),
              FilledButton.icon(
                onPressed: session.disconnecting
                    ? null
                    : (session.connected || session.busy)
                    ? () => unawaited(session.disconnect())
                    : _connect,
                icon:
                    session.disconnecting ||
                        (session.busy && !session.connected)
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(session.connected ? Icons.link_off : Icons.link),
                label: Text(
                  session.disconnecting
                      ? 'Disconnecting…'
                      : session.connected
                      ? 'Disconnect'
                      : session.busy
                      ? 'Cancel connection'
                      : 'Connect',
                ),
              ),
              if (_transport == 'demo')
                const Text('Real loopback TCP · input registers animate'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _controls() {
    final editable =
        !session.busy && !session.polling && !session.disconnecting;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _dropdown<String>(
              'Function area',
              _kind,
              areas,
              editable ? (v) => setState(() => _kind = v) : null,
              230,
            ),
            _field('Start · 0-based', _address, 125, enabled: editable),
            _field('Count', _count, 80, enabled: editable),
            _field('Interval, ms', _interval, 110, enabled: editable),
            OutlinedButton.icon(
              onPressed: session.canRead && !session.polling
                  ? () {
                      if (_prepareQuery()) unawaited(session.read());
                    }
                  : null,
              icon: const Icon(Icons.download, size: 18),
              label: const Text('Read'),
            ),
            FilledButton.tonalIcon(
              onPressed: session.polling
                  ? session.stopPolling
                  : session.canRead
                  ? () {
                      if (_prepareQuery()) session.startPolling();
                    }
                  : null,
              icon: Icon(
                session.polling ? Icons.stop : Icons.play_arrow,
                size: 18,
              ),
              label: Text(session.polling ? 'Stop polling' : 'Start polling'),
            ),
          ],
        ),
        if (_queryError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _queryError!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
      ],
    );
  }

  Widget _table() {
    final colors = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 8),
            child: Row(
              children: [
                Text(
                  areas[session.query.kind]!.split(' · ').first,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                Text(
                  !_queryMatches
                      ? 'Read to apply range'
                      : session.elapsedMs == null
                      ? 'Select a row to chart'
                      : '${session.elapsedMs!.toStringAsFixed(1)} ms',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ],
            ),
          ),
          Container(
            color: colors.surfaceContainerHighest,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            child: const Row(
              children: [
                SizedBox(width: 32),
                SizedBox(width: 80, child: Text('Address')),
                Expanded(child: Text('Value')),
                SizedBox(width: 100, child: Text('Hex')),
                SizedBox(width: 48),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: session.query.count,
              itemExtent: 44,
              itemBuilder: (context, index) {
                final raw = index < session.values.length
                    ? session.values[index]
                    : null;
                final value = raw is bool ? (raw ? 1 : 0) : raw as int?;
                return Material(
                  color: index == session.selected
                      ? colors.primaryContainer.withValues(alpha: 0.45)
                      : Colors.transparent,
                  child: InkWell(
                    onTap: () => session.select(index),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 32,
                            child: index == session.selected
                                ? Icon(
                                    Icons.show_chart,
                                    size: 17,
                                    color: colors.primary,
                                  )
                                : null,
                          ),
                          SizedBox(
                            width: 80,
                            child: Text('${session.query.address + index}'),
                          ),
                          Expanded(
                            child: Text(
                              value == null ? '—' : '$value',
                              style: const TextStyle(
                                fontFeatures: [FontFeature.tabularFigures()],
                              ),
                            ),
                          ),
                          SizedBox(
                            width: 100,
                            child: Text(
                              value == null
                                  ? '—'
                                  : '0x${value.toRadixString(16).padLeft(4, '0').toUpperCase()}',
                              style: TextStyle(
                                color: colors.onSurfaceVariant,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ),
                          SizedBox(
                            width: 48,
                            child: IconButton(
                              tooltip: session.query.writable
                                  ? 'Write address ${session.query.address + index}'
                                  : 'Read-only area',
                              onPressed:
                                  session.canRead &&
                                      session.query.writable &&
                                      _queryMatches
                                  ? () => _edit(index)
                                  : null,
                              icon: Icon(
                                session.query.writable
                                    ? Icons.edit_outlined
                                    : Icons.lock_outline,
                                size: 17,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          if (session.busy)
            const LinearProgressIndicator(minHeight: 2)
          else
            const SizedBox(height: 2),
        ],
      ),
    );
  }

  Widget _logs() {
    final logs = session.logs.toList(growable: false);
    final colors = Theme.of(context).colorScheme;
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 4, 8, 0),
            child: Row(
              children: [
                Text('Activity', style: Theme.of(context).textTheme.titleSmall),
                const Spacer(),
                IconButton(
                  tooltip: 'Clear log',
                  onPressed: session.clearLog,
                  icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                ),
              ],
            ),
          ),
          Expanded(
            child: logs.isEmpty
                ? const Center(
                    child: Text('Connection and error events appear here'),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
                    itemCount: logs.length,
                    itemBuilder: (context, i) {
                      final log = logs[i];
                      final time = log.time.toIso8601String().substring(11, 19);
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: SelectableText(
                          '$time  ${log.message}',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: log.isError
                                    ? colors.error
                                    : colors.onSurfaceVariant,
                              ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) {
      final colors = Theme.of(context).colorScheme;
      return Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                Row(
                  children: [
                    Icon(Icons.hub_outlined, color: colors.primary),
                    const SizedBox(width: 12),
                    Text(
                      'Modbus Connector',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(width: 20),
                    Icon(
                      Icons.circle,
                      size: 8,
                      color: session.connected
                          ? colors.primary
                          : colors.outline,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        session.description,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    PopupMenuButton<ThemeMode>(
                      tooltip: 'Appearance',
                      initialValue: widget.themeMode,
                      icon: const Icon(Icons.contrast),
                      onSelected: widget.onThemeChanged,
                      itemBuilder: (_) => ThemeMode.values
                          .map(
                            (mode) => PopupMenuItem(
                              value: mode,
                              child: Text(
                                '${mode.name[0].toUpperCase()}${mode.name.substring(1)}',
                              ),
                            ),
                          )
                          .toList(),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _connection(),
                if (session.error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Material(
                      color: colors.errorContainer,
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.only(left: 14),
                        child: Row(
                          children: [
                            Icon(
                              Icons.error_outline,
                              size: 18,
                              color: colors.onErrorContainer,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                session.error!,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: colors.onErrorContainer,
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Dismiss error',
                              onPressed: session.clearError,
                              icon: const Icon(Icons.close, size: 18),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 18),
                _controls(),
                const SizedBox(height: 16),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final chart = LiveChart(
                        samples: session.samples.toList(growable: false),
                        address: session.query.address + session.selected,
                      );
                      if (constraints.maxWidth >= 800) {
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(flex: 5, child: _table()),
                            const SizedBox(width: 16),
                            Expanded(
                              flex: 3,
                              child: Column(
                                children: [
                                  Expanded(child: chart),
                                  const SizedBox(height: 16),
                                  Expanded(child: _logs()),
                                ],
                              ),
                            ),
                          ],
                        );
                      }
                      return Column(
                        children: [
                          Expanded(child: _table()),
                          const SizedBox(height: 12),
                          SizedBox(
                            height: 170,
                            child: Row(
                              children: [
                                Expanded(child: chart),
                                const SizedBox(width: 12),
                                Expanded(child: _logs()),
                              ],
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
