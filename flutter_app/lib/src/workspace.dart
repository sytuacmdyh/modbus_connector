import 'file_paths.dart';
import 'tool_widgets.dart';
import 'translations.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';

import 'bridge_client.dart';
import 'session_controller.dart';
import 'workbench.dart';
import 'settings_store.dart';
import 'templates_dialog.dart';
import 'help_dialog.dart';
import 'online_dialogs.dart';
import 'demo.dart';

class WorkspaceController extends ChangeNotifier {
  WorkspaceController({BridgeTransport Function()? bridgeFactory, this.store})
    : bridgeFactory = bridgeFactory ?? NativeBridge.new {
    add();
    if (store != null) {
      loading = true;
      unawaited(load());
      _autosave = Timer.periodic(const Duration(seconds: 3), (_) {
        if (!loading && _allowAutoSave && autoSave && !closing) {
          unawaited(save());
        }
      });
    }
  }
  final BridgeTransport Function() bridgeFactory;
  final List<SessionController> sessions = [];
  final List<SessionController> tools = [];
  final SettingsStore? store;
  Timer? _autosave;
  bool loading = false;
  bool _disposed = false;
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  bool _allowAutoSave = true;
  bool autoSave = true;
  String? stateError;
  Future<void>? _shutdown;
  Map<String, dynamic> exportState() => {
    'schema': 1,
    'autosave': autoSave,
    'tabs': sessions.map((s) => s.state()).toList(),
    'active_tab': selected,
    'language': appLanguage.value,
    'theme_mode': appTheme.value.name,
  };
  Future<void> save({String? path}) async {
    try {
      await store?.save(exportState(), path: path);
      stateError = null;
    } catch (e) {
      stateError = 'Could not save workspace: ${userError(e)}';
      notifyListeners();
    }
  }

  Future<void> load({String? path, Map<String, dynamic>? imported}) async {
    loading = true;
    notifyListeners();
    try {
      final data = imported ?? await store?.load(path: path);
      if (data != null && !closing) {
        final staged = <SessionController>[];
        try {
          for (final state in data['tabs'] as List) {
            final session = SessionController(bridgeFactory());
            staged.add(session);
            session.restore(state as Map<String, dynamic>);
          }
        } catch (_) {
          for (final s in staged) {
            s.dispose();
          }
          rethrow;
        }
        await Future.wait(sessions.map((s) => s.shutdown()));
        for (final s in sessions) {
          s.dispose();
        }
        sessions
          ..clear()
          ..addAll(staged);
        selected = (data['active_tab'] is int ? data['active_tab'] as int : 0)
            .clamp(0, sessions.length - 1);
      }
      if (data?['autosave'] is bool) autoSave = data!['autosave'] as bool;
      if (data?['language'] == 'en' || data?['language'] == 'zh_CN') {
        appLanguage.value = data!['language'] as String;
      }
      for (final theme in ThemeMode.values) {
        if (theme.name == data?['theme_mode']) appTheme.value = theme;
      }
      stateError = null;
      _allowAutoSave = true;
    } catch (e) {
      stateError = 'Could not restore workspace: ${userError(e)}';
      _allowAutoSave = false;
    }
    loading = false;
    notifyListeners();
  }

  void openState(Map<String, dynamic> state, {String? templateId}) {
    if (closing) throw const FormatException('Workspace is closing');
    if (sessions.length >= 64) {
      throw const FormatException(
        'Close a tab before opening another template (64 tabs maximum).',
      );
    }
    final session = SessionController(bridgeFactory());
    try {
      session.restore(state);
    } catch (_) {
      session.dispose();
      rethrow;
    }
    session.customTemplateId = templateId;
    sessions.add(session);
    selected = sessions.length - 1;
    notifyListeners();
  }

  int selected = 0;
  bool closing = false;
  Future<void> openDemo() async {
    openState(demoState());
    final session = sessions.last;
    await session.connect({'transport': 'demo', 'timeout': 1.0}, 1);
    if (!closing && sessions.contains(session) && session.connected) {
      session.registerMap.start(500);
    }
  }

  void add() {
    if (closing || sessions.length >= 64) return;
    sessions.add(SessionController(bridgeFactory()));
    selected = sessions.length - 1;
    notifyListeners();
  }

  void select(int index) {
    selected = index;
    notifyListeners();
  }

  Future<void> remove(SessionController session) async {
    if (closing || !sessions.contains(session)) return;
    await session.shutdown();
    if (closing || !sessions.contains(session)) return;
    final index = sessions.indexOf(session);
    sessions.removeAt(index);
    session.dispose();
    if (selected > index) selected--;
    if (selected >= sessions.length) selected = sessions.length - 1;
    if (sessions.isEmpty) add();
    notifyListeners();
  }

  Future<void> shutdown() => _shutdown ??= _shutdownOwned();
  Future<void> _shutdownOwned() async {
    closing = true;
    _autosave?.cancel();
    if (_allowAutoSave && autoSave) await save();
    await Future.wait([...sessions, ...tools].map((s) => s.shutdown()));
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(shutdown());
    for (final session in sessions) {
      session.dispose();
    }
    super.dispose();
  }
}

class SessionWorkspace extends StatefulWidget {
  const SessionWorkspace({
    super.key,
    required this.themeMode,
    required this.onThemeChanged,
    this.controller,
  });
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeChanged;
  final WorkspaceController? controller;
  @override
  State<SessionWorkspace> createState() => _SessionWorkspaceState();
}

class _SessionWorkspaceState extends State<SessionWorkspace> {
  Future<void> openDemo() async {
    try {
      await workspace.openDemo();
    } catch (e) {
      workspace.stateError = userError(e);
      workspace.notifyListeners();
    }
  }

  late final workspace =
      widget.controller ?? WorkspaceController(store: SettingsStore());
  late final AppLifecycleListener lifecycle;
  @override
  void initState() {
    super.initState();
    lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        await workspace.shutdown();
        return AppExitResponse.exit;
      },
    );
  }

  @override
  void dispose() {
    lifecycle.dispose();
    if (widget.controller == null) workspace.dispose();
    super.dispose();
  }

  Future<void> workspaceFile(String action) async {
    if (action == 'save') {
      await workspace.save();
      return;
    }
    final path = await chooseFilePath(
      context,
      save: action == 'export',
      extension: 'json',
      suggestedName: 'workspace.json',
      title: action == 'export'
          ? 'Export Flutter workspace file path'
          : action == 'import_qt'
          ? 'Import Qt configuration'
          : 'Import Flutter workspace file path',
    );
    if (path == null || path.isEmpty) return;
    if (action == 'export') {
      await workspace.save(path: path);
    } else if (action == 'import_qt') {
      final bridge = workspace.bridgeFactory();
      try {
        final source = File(path);
        if (await source.length() > 2000000) {
          throw const FormatException('Configuration file is too large');
        }
        final converted = await bridge.request({
          'command': 'template_convert_workspace',
          'workspace': jsonDecode(await source.readAsString()),
        });
        await workspace.load(imported: converted.result);
      } catch (e) {
        workspace.stateError = userError(e);
        workspace.notifyListeners();
      } finally {
        await bridge.close();
      }
    } else {
      await workspace.load(path: path);
    }
  }

  Future<void> settings() => showDialog<void>(
    context: context,
    builder: (context) => ListenableBuilder(
      listenable: Listenable.merge([appLanguage, appTheme, workspace]),
      builder: (context, _) => AlertDialog(
        title: const LText('Settings'),
        content: SizedBox(
          width: 540,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                toolChoice(
                  'Appearance',
                  appTheme.value.name,
                  ThemeMode.values.map((m) => m.name),
                  (v) => widget.onThemeChanged(
                    ThemeMode.values.firstWhere((m) => m.name == v),
                  ),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  initialValue: appLanguage.value,
                  decoration: InputDecoration(labelText: tr('Language')),
                  items: const [
                    DropdownMenuItem(value: 'en', child: Text('English')),
                    DropdownMenuItem(value: 'zh_CN', child: Text('简体中文')),
                  ],
                  onChanged: (v) {
                    if (v != null) appLanguage.value = v;
                  },
                ),
                const SizedBox(height: 16),
                const LText('Workspace'),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const LText('Automatically save workspace'),
                  subtitle: const LText(
                    'Restore tabs disconnected on next launch',
                  ),
                  value: workspace.autoSave,
                  onChanged: (v) {
                    workspace.autoSave = v;
                    workspace.notifyListeners();
                  },
                ),
                const LText(
                  'Use Save workspace to keep preferences when autosave is off.',
                ),
                if (workspace.store != null)
                  SelectableText(workspace.store!.file.path),
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed: () => workspaceFile('save'),
                      child: const LText('Save workspace'),
                    ),
                    TextButton(
                      onPressed: () => workspaceFile('export'),
                      child: const LText('Export workspace'),
                    ),
                    TextButton(
                      onPressed: () => workspaceFile('import'),
                      child: const LText('Import workspace'),
                    ),
                    TextButton(
                      onPressed: () => workspaceFile('import_qt'),
                      child: const LText('Import Qt configuration'),
                    ),
                  ],
                ),
                if (workspace.stateError != null) LText(workspace.stateError!),
              ],
            ),
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

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: workspace,
    builder: (context, _) => Scaffold(
      body: Column(
        children: [
          SizedBox(
            height: 42,
            child: Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (var i = 0; i < workspace.sessions.length; i++)
                          ListenableBuilder(
                            listenable: workspace.sessions[i],
                            builder: (context, _) => Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                              ),
                              child: InputChip(
                                selected: workspace.selected == i,
                                avatar: Icon(
                                  workspace.sessions[i].connected
                                      ? Icons.link
                                      : Icons.tab,
                                  size: 16,
                                ),
                                label: LText(
                                  '${tr(workspace.sessions[i].draft['transport'] == 'demo' ? 'Local demo' : workspace.sessions[i].mode)} ${i + 1}',
                                ),
                                onPressed: () => workspace.select(i),
                                onDeleted: () => unawaited(
                                  workspace.remove(workspace.sessions[i]),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  tooltip: tr('Help'),
                  onPressed: () => showFeatureHelp(context),
                  icon: const Icon(Icons.help_outline),
                ),
                IconButton(
                  tooltip: tr('Settings'),
                  onPressed: settings,
                  icon: const Icon(Icons.settings_outlined),
                ),
                PopupMenuButton<String>(
                  tooltip: tr('Workspace'),
                  icon: const Icon(Icons.folder_open),
                  onSelected: (v) async {
                    if (v == 'demo') {
                      await openDemo();
                      return;
                    }
                    final session = workspace.sessions[workspace.selected];
                    if (['templates', 'cloud', 'updates'].contains(v)) {
                      final tool = SessionController(workspace.bridgeFactory());
                      workspace.tools.add(tool);
                      try {
                        await showDialog<void>(
                          context: context,
                          builder: (_) => v == 'templates'
                              ? TemplatesDialog(
                                  session: session,
                                  service: tool,
                                  onOpen: (state, id) {
                                    workspace.openState(state, templateId: id);
                                  },
                                )
                              : v == 'cloud'
                              ? CloudDialog(session: tool)
                              : UpdateDialog(session: tool),
                        );
                      } finally {
                        await tool.shutdown();
                        tool.dispose();
                        workspace.tools.remove(tool);
                      }
                      return;
                    }
                    await workspaceFile(v);
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'demo', child: LText('Local demo')),
                    PopupMenuItem(
                      value: 'templates',
                      child: LText('Templates / history'),
                    ),
                    PopupMenuItem(value: 'cloud', child: LText('Cloud sync')),
                    PopupMenuItem(
                      value: 'updates',
                      child: LText('Check for updates'),
                    ),
                    PopupMenuItem(
                      value: 'save',
                      child: LText('Save workspace'),
                    ),
                    PopupMenuItem(
                      value: 'export',
                      child: LText('Export workspace'),
                    ),
                    PopupMenuItem(
                      value: 'import',
                      child: LText('Import workspace'),
                    ),
                    PopupMenuItem(
                      value: 'import_qt',
                      child: LText('Import Qt configuration'),
                    ),
                  ],
                ),
                PopupMenuButton<String>(
                  tooltip: tr('Session mode'),
                  icon: const Icon(Icons.swap_horiz),
                  onSelected: (v) => unawaited(
                    workspace.sessions[workspace.selected].changeMode(v),
                  ),
                  itemBuilder: (_) =>
                      ['master', 'simulator', 'sniffer', 'gateway']
                          .map((m) => PopupMenuItem(value: m, child: LText(m)))
                          .toList(),
                ),
                IconButton(
                  tooltip: tr('New session'),
                  onPressed: workspace.add,
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
          ),
          if (workspace.stateError != null)
            MaterialBanner(
              content: LText(workspace.stateError!),
              actions: [
                TextButton(
                  onPressed: () {
                    workspace.stateError = null;
                    setState(() {});
                  },
                  child: const LText('Dismiss'),
                ),
              ],
            ),
          Expanded(
            child: workspace.loading
                ? const Center(child: CircularProgressIndicator())
                : IndexedStack(
                    index: workspace.selected,
                    children: [
                      for (final session in workspace.sessions)
                        TickerMode(
                          key: ObjectKey(session),
                          enabled: identical(
                            session,
                            workspace.sessions[workspace.selected],
                          ),
                          child: Workbench(
                            controller: session,
                            manageLifecycle: false,
                            onOpenDemo: () => unawaited(openDemo()),
                            themeMode: widget.themeMode,
                            onThemeChanged: widget.onThemeChanged,
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    ),
  );
}
