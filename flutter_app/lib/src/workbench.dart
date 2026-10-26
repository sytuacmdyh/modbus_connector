import 'translations.dart';

import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'file_paths.dart';

import 'scanner.dart';
import 'register_map.dart';
import 'logging_dialog.dart';
import 'device_panel.dart';
import 'advanced_dialog.dart';
import 'session_controller.dart';
import 'traffic_dialog.dart';
import 'serial_ports.dart';

class Workbench extends StatefulWidget {
  const Workbench({
    super.key,
    required this.controller,
    required this.themeMode,
    required this.onThemeChanged,
    this.manageLifecycle = true,
    this.onOpenDemo,
  });
  final bool manageLifecycle;
  final VoidCallback? onOpenDemo;
  final SessionController controller;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeChanged;

  @override
  State<Workbench> createState() => _WorkbenchState();
}

class _WorkbenchState extends State<Workbench> {
  SessionController get session => widget.controller;
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  bool _showActivity = true;
  bool _editingConnection = false;
  StateSetter? _dialogSetState;
  final _logScroll = ScrollController();
  bool _refreshingPorts = false;
  String _logFilter = '';
  bool _errorsOnly = false;
  bool _showLogFilter = false;
  final _connectionForm = GlobalKey<FormState>();
  final _transportField = GlobalKey<FormFieldState<String>>();
  final _host = TextEditingController(text: '127.0.0.1');
  final _port = TextEditingController(text: '502');
  final _serial = TextEditingController();
  final _baud = TextEditingController(text: '9600');
  final _unit = TextEditingController(text: '1');
  final _timeout = TextEditingController(text: '3');
  String _transport = 'rtu';
  String _parity = 'N';
  int _bits = 8;
  int _stop = 1;
  AppLifecycleListener? _lifecycle;

  @override
  void initState() {
    super.initState();
    final saved = session.draft;
    for (final e in {
      'host': _host,
      'port': _port,
      'serial': _serial,
      'baud': _baud,
      'unit': _unit,
      'timeout': _timeout,
    }.entries) {
      if (saved[e.key] is String) e.value.text = saved[e.key] as String;
    }
    _transport =
        saved['transport'] as String? ??
        session.connectionConfig['transport'] as String? ??
        'rtu';
    if (!['tcp', 'rtu', 'rtu_tcp', 'rtu_udp', 'demo'].contains(_transport)) {
      _transport = 'rtu';
    }
    _parity = ['N', 'E', 'O'].contains(saved['parity'])
        ? saved['parity'] as String
        : 'N';
    _bits = saved['bits'] == 7 ? 7 : 8;
    _stop = saved['stop'] == 2 ? 2 : 1;
    if (!saved.containsKey('unit')) _unit.text = '${session.unit}';
    // Restore every field before edits can save the partially initialized form.
    for (final controller in [_host, _port, _serial, _baud, _unit, _timeout]) {
      controller.addListener(_saveDraft);
    }
    if (widget.manageLifecycle) {
      _lifecycle = AppLifecycleListener(
        onExitRequested: () async {
          await session.shutdown();
          return AppExitResponse.exit;
        },
      );
    }
  }

  void _saveDraft() {
    if (_editingConnection) return;
    session.draft.addAll({
      'transport': _transport,
      'parity': _parity,
      'bits': _bits,
      'stop': _stop,
      for (final e in {
        'host': _host,
        'port': _port,
        'serial': _serial,
        'baud': _baud,
        'unit': _unit,
        'timeout': _timeout,
      }.entries)
        e.key: e.value.text,
    });
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    _logScroll.dispose();
    for (final controller in [_host, _port, _serial, _baud, _unit, _timeout]) {
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
    FocusNode? focusNode,
  }) => SizedBox(
    width: width,
    child: TextFormField(
      controller: controller,
      focusNode: focusNode,
      enabled: enabled,
      validator: validator,
      decoration: InputDecoration(labelText: tr(label)),
      onFieldSubmitted: (_) => onSubmit?.call(),
    ),
  );

  Widget _dropdown<T>(
    String label,
    T value,
    Map<T, String> items,
    ValueChanged<T>? onChanged,
    double width, {
    Key? fieldKey,
  }) => SizedBox(
    width: width,
    child: DropdownButtonFormField<T>(
      key: fieldKey,
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: tr(label)),
      items: items.entries
          .map(
            (e) => DropdownMenuItem(
              value: e.key,
              child: LText(e.value, overflow: TextOverflow.ellipsis),
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

  void _changeConnection(VoidCallback change) {
    setState(change);
    _dialogSetState?.call(() {});
  }

  bool get _validConnection {
    bool integer(TextEditingController field, int min, int max) =>
        _integer(field.text, min, max) == null;
    final timeout = double.tryParse(_timeout.text);
    return integer(_unit, 1, 247) &&
        timeout != null &&
        timeout >= 0.1 &&
        timeout <= 60 &&
        (_transport != 'rtu' ||
            (_serial.text.trim().isNotEmpty && integer(_baud, 50, 4000000))) &&
        (!['tcp', 'rtu_tcp', 'rtu_udp'].contains(_transport) ||
            (_host.text.trim().isNotEmpty && integer(_port, 1, 65535)));
  }

  void _applyConnection() {
    if (!_refreshingPorts && _connectionForm.currentState!.validate()) {
      Navigator.of(context, rootNavigator: true).pop(true);
    }
  }

  Future<void> _configure({bool connectAfterSave = false}) async {
    if (session.connected || session.busy || session.disconnecting) return;
    final controllers = [_host, _port, _serial, _baud, _unit, _timeout];
    final previous = controllers.map((c) => c.text).toList();
    final transport = _transport;
    final parity = _parity;
    final bits = _bits;
    final stop = _stop;
    _editingConnection = true;
    final applied = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) {
          _dialogSetState = update;
          return ListenableBuilder(
            listenable: session,
            builder: (context, _) => AlertDialog(
              title: const LText('Connection settings'),
              content: SizedBox(
                width: 610,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _connectionFields(),
                      if (session.error != null) LText(session.error!),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const LText('Cancel'),
                ),
                FilledButton(
                  onPressed: session.busy || _refreshingPorts
                      ? null
                      : _applyConnection,
                  child: LText(connectAfterSave ? 'Save and connect' : 'Apply'),
                ),
              ],
            ),
          );
        },
      ),
    );
    _dialogSetState = null;
    if (!mounted) return;
    if (applied != true) {
      for (var i = 0; i < controllers.length; i++) {
        controllers[i].text = previous[i];
      }
      _transport = transport;
      _parity = parity;
      _bits = bits;
      _stop = stop;
    }
    _editingConnection = false;
    _refreshingPorts = false;
    setState(_saveDraft);
    if (applied == true && connectAfterSave) _connect();
  }

  void _connect() {
    if (session.busy || session.connected || session.disconnecting) return;
    if (!_validConnection) {
      unawaited(_configure(connectAfterSave: true));
      return;
    }
    unawaited(
      session.connect({
        'transport': _transport,
        'timeout': double.parse(_timeout.text),
        if (['tcp', 'rtu_tcp', 'rtu_udp'].contains(_transport)) ...{
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

  Widget _connectionFields() {
    final locked = session.connected || session.busy || session.disconnecting;
    return Form(
      key: _connectionForm,
      child: Wrap(
        spacing: 12,
        runSpacing: 16,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _dropdown<String>(
            'Transport',
            _transport,
            const {
              'rtu': 'Serial RTU',
              'tcp': 'TCP',
              'rtu_tcp': 'RTU over TCP',
              'rtu_udp': 'RTU over UDP',
              'demo': 'Local demo',
            },
            locked
                ? null
                : (v) {
                    if (v == 'demo' &&
                        _transport != 'demo' &&
                        widget.onOpenDemo != null) {
                      _transportField.currentState?.didChange(_transport);
                      Navigator.of(context, rootNavigator: true).pop();
                      widget.onOpenDemo!();
                      return;
                    }
                    _changeConnection(() {
                      _transport = v;
                      _saveDraft();
                    });
                  },
            150,
            fieldKey: _transportField,
          ),
          if (['tcp', 'rtu_tcp', 'rtu_udp'].contains(_transport)) ...[
            _field(
              'Host',
              _host,
              175,
              enabled: !locked,
              validator: (v) => v!.trim().isEmpty ? tr('Required') : null,
              onSubmit: _applyConnection,
            ),
            _field(
              'Port',
              _port,
              90,
              enabled: !locked,
              validator: (v) => _integer(v, 1, 65535),
              onSubmit: _applyConnection,
            ),
          ],
          if (_transport == 'rtu') ...[
            SerialPortPicker(
              session: session,
              controller: _serial,
              width: 180,
              enabled: !locked,
              validator: (v) =>
                  v!.trim().isEmpty ? tr('Enter COM3 or /dev/ttyUSB0') : null,
              onSubmit: _applyConnection,
              onRefreshingChanged: (value) =>
                  _changeConnection(() => _refreshingPorts = value),
            ),
            BaudRatePicker(
              controller: _baud,
              enabled: !locked,
              validator: (v) => _integer(v, 50, 4000000),
              onSubmit: _applyConnection,
            ),
            _dropdown<int>(
              'Bits',
              _bits,
              const {8: '8', 7: '7'},
              locked
                  ? null
                  : (v) => _changeConnection(() {
                      _bits = v;
                      _saveDraft();
                    }),
              75,
            ),
            _dropdown<String>(
              'Parity',
              _parity,
              const {'N': 'None', 'E': 'Even', 'O': 'Odd'},
              locked
                  ? null
                  : (v) => _changeConnection(() {
                      _parity = v;
                      _saveDraft();
                    }),
              95,
            ),
            _dropdown<int>(
              'Stop',
              _stop,
              const {1: '1', 2: '2'},
              locked
                  ? null
                  : (v) => _changeConnection(() {
                      _stop = v;
                      _saveDraft();
                    }),
              75,
            ),
          ],
          _field(
            'Unit',
            _unit,
            75,
            enabled: !locked,
            validator: (v) => _integer(v, 1, 247),
            onSubmit: _applyConnection,
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
            onSubmit: _applyConnection,
          ),
          if (_transport == 'demo')
            const LText(
              'Local simulator · poll the map to view signals; reconnect resets values.',
            ),
        ],
      ),
    );
  }

  String get _connectionSummary {
    final endpoint = _transport == 'rtu'
        ? '${_serial.text.isEmpty ? tr('Serial RTU') : _serial.text} · ${_baud.text} $_bits$_parity$_stop'
        : _transport == 'demo'
        ? tr('Local demo')
        : '${tr({'tcp': 'TCP', 'rtu_tcp': 'RTU over TCP', 'rtu_udp': 'RTU over UDP'}[_transport]!)} · ${_host.text}:${_port.text}';
    return '$endpoint · ${tr('Unit')} ${_unit.text} · ${_timeout.text} s';
  }

  Widget _tools() => PopupMenuButton<String>(
    tooltip: tr('Session tools'),
    icon: Icon(session.logging ? Icons.fiber_manual_record : Icons.more_horiz),
    onSelected: (action) async {
      if (action == 'scanner') {
        session.registerMap.stop();
        final applied = await showDialog<bool>(
          context: context,
          builder: (_) => ScannerDialog(session: session),
        );
        if (applied == true && mounted) {
          setState(() => _unit.text = '${session.unit}');
        }
        return;
      }
      if (action.startsWith('theme:')) {
        widget.onThemeChanged(ThemeMode.values.byName(action.substring(6)));
        return;
      }
      await showDialog<void>(
        context: context,
        builder: (_) => switch (action) {
          'advanced' => AdvancedDialog(session: session),
          'traffic' => TrafficDialog(session: session),
          _ => LoggingDialog(session: session),
        },
      );
    },
    itemBuilder: (_) => [
      PopupMenuItem(value: 'traffic', child: const LText('Bus traffic')),
      PopupMenuItem(
        value: 'logger',
        child: LText(
          session.logging ? 'Data logger · recording' : 'Data logger',
        ),
      ),
      PopupMenuItem(
        value: 'scanner',
        enabled: session.connected && !session.busy,
        child: const LText('Scanner'),
      ),
      PopupMenuItem(
        value: 'advanced',
        enabled: session.connected && !session.busy,
        child: const LText('Advanced Modbus'),
      ),
      const PopupMenuDivider(),
      for (final mode in ThemeMode.values)
        CheckedPopupMenuItem(
          value: 'theme:${mode.name}',
          checked: widget.themeMode == mode,
          child: LText(
            '${tr('Appearance')} · ${tr('${mode.name[0].toUpperCase()}${mode.name.substring(1)}')}',
          ),
        ),
    ],
  );

  Widget _connectionBar(bool wide) {
    final connecting = session.busy && !session.connected && !_refreshingPorts;
    final locked = session.connected || session.busy || session.disconnecting;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          children: [
            OutlinedButton.icon(
              onPressed: locked ? null : _configure,
              icon: const Icon(Icons.settings_outlined, size: 18),
              label: const LText('Connection settings'),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Tooltip(
                message: session.connected
                    ? session.description
                    : _connectionSummary,
                child: Text(
                  session.connected
                      ? tr(session.description)
                      : _connectionSummary,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: session.disconnecting || _refreshingPorts
                  ? null
                  : session.connected || connecting
                  ? () => unawaited(session.disconnect())
                  : _connect,
              icon: session.disconnecting || connecting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      session.connected ? Icons.link_off : Icons.link,
                      size: 18,
                    ),
              label: LText(
                session.disconnecting
                    ? 'Disconnecting…'
                    : session.connected
                    ? 'Disconnect'
                    : connecting
                    ? 'Cancel connection'
                    : 'Connect',
              ),
            ),
            _tools(),
            IconButton(
              tooltip: tr(
                wide && _showActivity ? 'Hide activity' : 'Show activity',
              ),
              isSelected: wide && _showActivity,
              icon: const Icon(Icons.view_sidebar_outlined),
              onPressed: () {
                if (wide) {
                  setState(() => _showActivity = !_showActivity);
                } else {
                  _scaffoldKey.currentState!.openEndDrawer();
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _logs() {
    final logs = session.logs
        .where(
          (l) =>
              (!_errorsOnly || l.isError) &&
              tr(l.message).toLowerCase().contains(_logFilter.toLowerCase()),
        )
        .toList(growable: false);
    String logText() => logs
        .map((l) => '${l.time.toIso8601String()}  ${tr(l.message)}')
        .join('\n');
    final colors = Theme.of(context).colorScheme;
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 4, 8, 0),
            child: Row(
              children: [
                Expanded(
                  child: LText(
                    'Activity',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                IconButton(
                  tooltip: tr('Filter activity'),
                  icon: Icon(
                    _showLogFilter
                        ? Icons.filter_alt
                        : Icons.filter_alt_outlined,
                    size: 18,
                  ),
                  onPressed: () => setState(() {
                    _showLogFilter = !_showLogFilter;
                    if (!_showLogFilter) {
                      _logFilter = '';
                      _errorsOnly = false;
                    }
                  }),
                ),
                PopupMenuButton<String>(
                  tooltip: tr('Export log'),
                  icon: const Icon(Icons.more_horiz, size: 18),
                  onSelected: (action) async {
                    final text = logText();
                    if (action == 'copy') {
                      await Clipboard.setData(ClipboardData(text: text));
                    } else {
                      final path = await chooseFilePath(
                        context,
                        save: true,
                        title: 'Export activity log',
                        extension: 'txt',
                        suggestedName: 'activity.txt',
                      );
                      if (path == null) return;
                      try {
                        await File(path).writeAsString(text, flush: true);
                      } catch (e) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: LText(userError(e))),
                          );
                        }
                      }
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'copy', child: LText('Copy log')),
                    PopupMenuItem(value: 'export', child: LText('Export log')),
                  ],
                ),
                IconButton(
                  tooltip: tr('Clear log'),
                  onPressed: session.clearLog,
                  icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                ),
              ],
            ),
          ),
          if (_showLogFilter)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      decoration: InputDecoration(
                        labelText: tr('Filter activity'),
                      ),
                      onChanged: (value) => setState(() => _logFilter = value),
                    ),
                  ),
                  IconButton(
                    tooltip: tr('Errors only'),
                    isSelected: _errorsOnly,
                    icon: const Icon(Icons.error_outline),
                    onPressed: () => setState(() => _errorsOnly = !_errorsOnly),
                  ),
                ],
              ),
            ),
          Expanded(
            child: logs.isEmpty
                ? const Center(
                    child: LText('Connection and error events appear here'),
                  )
                : Scrollbar(
                    controller: _logScroll,
                    thumbVisibility: true,
                    child: ListView.builder(
                      key: const ValueKey('activity-list'),
                      controller: _logScroll,
                      primary: false,
                      padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
                      itemCount: logs.length,
                      itemBuilder: (context, i) {
                        final log = logs[i];
                        final time = log.time.toIso8601String().substring(
                          11,
                          19,
                        );
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: SelectableText(
                            '$time  ${tr(log.message)}',
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
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) {
      if (session.mode != 'master') {
        return DevicePanel(key: ValueKey(session.mode), session: session);
      }
      final colors = Theme.of(context).colorScheme;
      final wide = MediaQuery.sizeOf(context).width >= 1100;
      return Scaffold(
        key: _scaffoldKey,
        endDrawer: wide
            ? null
            : Drawer(width: 320, child: SafeArea(child: _logs())),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              children: [
                _connectionBar(wide),
                if (session.error != null)
                  Material(
                    color: colors.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                    child: Row(
                      children: [
                        const SizedBox(width: 12),
                        Icon(
                          Icons.error_outline,
                          size: 18,
                          color: colors.onErrorContainer,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: LText(
                            session.error!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        IconButton(
                          tooltip: tr('Dismiss error'),
                          onPressed: session.clearError,
                          icon: const Icon(Icons.close, size: 18),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 8),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: Card(
                          child: Padding(
                            padding: const EdgeInsets.all(10),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                LText(
                                  'Register map',
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleMedium,
                                ),
                                const SizedBox(height: 6),
                                Expanded(
                                  child: RegisterMapPanel(session: session),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      if (wide && _showActivity) ...[
                        const SizedBox(width: 8),
                        SizedBox(width: 280, child: _logs()),
                      ],
                    ],
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
