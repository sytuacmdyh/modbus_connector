import 'translations.dart';

import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';

import 'bridge_client.dart';
import 'session_controller.dart';
import 'workbench.dart';
import 'settings_store.dart';
import 'templates_dialog.dart';
import 'tool_widgets.dart';
import 'help_dialog.dart';

class WorkspaceController extends ChangeNotifier {
  WorkspaceController({BridgeTransport Function()? bridgeFactory, this.store})
    : bridgeFactory = bridgeFactory ?? ProcessBridge.new {
    add();
    if (store != null) {
      loading = true;
      unawaited(load());
      _autosave = Timer.periodic(const Duration(seconds: 3), (_) {
        if (!loading && _allowAutoSave && !closing) unawaited(save());
      });
    }
  }
  final BridgeTransport Function() bridgeFactory;
  final List<SessionController> sessions = [];
  final SettingsStore? store;
  Timer? _autosave;
  bool loading = false;
  bool _disposed = false;
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  bool _allowAutoSave = true;
  String? stateError;
  Future<void>? _shutdown;
  Map<String, dynamic> exportState() => {
    'schema': 1,
    'tabs': sessions.map((s) => s.state()).toList(),
    'active_tab': selected,
    'language': appLanguage.value,
  };
  Future<void> save({String? path}) async {
    try {
      await store?.save(exportState(), path: path);
      stateError = null;
    } catch (e) {
      stateError = 'Could not save workspace: $e';
      notifyListeners();
    }
  }

  Future<void> load({String? path}) async {
    loading = true;
    notifyListeners();
    try {
      final data = await store?.load(path: path);
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
      if (data?['language'] == 'en' || data?['language'] == 'zh_CN') {
        appLanguage.value = data!['language'] as String;
      }
      stateError = null;
      _allowAutoSave = true;
    } catch (e) {
      stateError = 'Could not restore workspace: $e';
      _allowAutoSave = false;
    }
    loading = false;
    notifyListeners();
  }

  void openState(Map<String, dynamic> state, {String? templateId}) {
    final session = SessionController(bridgeFactory());
    session.restore(state);
    session.customTemplateId = templateId;
    sessions.add(session);
    selected = sessions.length - 1;
    notifyListeners();
  }

  int selected = 0;
  bool closing = false;
  void add() {
    if (closing) return;
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
    if (_allowAutoSave) await save();
    await Future.wait(sessions.map((s) => s.shutdown()));
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
                                  '${workspace.sessions[i].mode} ${i + 1}',
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
                PopupMenuButton<String>(
                  tooltip: tr('Language'),
                  icon: const Icon(Icons.translate),
                  onSelected: (v) {
                    appLanguage.value = v;
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'en', child: Text('English')),
                    PopupMenuItem(value: 'zh_CN', child: Text('简体中文')),
                  ],
                ),
                PopupMenuButton<String>(
                  tooltip: tr('Workspace'),
                  icon: const Icon(Icons.folder_open),
                  onSelected: (v) async {
                    final session = workspace.sessions[workspace.selected];
                    if (v == 'templates') {
                      await showDialog<void>(
                        context: context,
                        builder: (_) => TemplatesDialog(
                          session: session,
                          onOpen: (state, id) {
                            workspace.openState(state, templateId: id);
                          },
                        ),
                      );
                      return;
                    }
                    if (v == 'save') {
                      await workspace.save();
                      return;
                    }
                    final path = await textPrompt(
                      context,
                      v == 'export'
                          ? 'Export Flutter workspace file path'
                          : 'Import Flutter workspace file path',
                    );
                    if (path == null || path.isEmpty) return;
                    if (v == 'export') {
                      await workspace.save(path: path);
                    } else {
                      await workspace.load(path: path);
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'templates',
                      child: LText('Templates / history'),
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
                        Workbench(
                          key: ObjectKey(session),
                          controller: session,
                          manageLifecycle: false,
                          themeMode: widget.themeMode,
                          onThemeChanged: widget.onThemeChanged,
                        ),
                    ],
                  ),
          ),
        ],
      ),
    ),
  );
}
