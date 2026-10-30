import 'dart:async';

import 'package:flutter/material.dart';

import 'session_controller.dart';
import 'backend/update.dart';
import 'tool_widgets.dart';
import 'translations.dart';

class CloudDialog extends StatefulWidget {
  const CloudDialog({super.key, required this.session});
  final SessionController session;
  @override
  State<CloudDialog> createState() => _CloudDialogState();
}

class _CloudDialogState extends State<CloudDialog> {
  final url = TextEditingController();
  final username = TextEditingController();
  final password = TextEditingController();
  final directory = TextEditingController(text: 'templates');
  final timeout = TextEditingController(text: '15');
  String mode = 'consumer';
  bool remember = false;
  bool busy = false;
  bool running = false;
  bool cancelling = false;
  String? selected;
  List<String> versions = [];
  String? message;
  Timer? timer;
  @override
  void initState() {
    super.initState();
    load();
    timer = Timer.periodic(
      const Duration(milliseconds: 350),
      (_) => unawaited(poll()),
    );
  }

  Map<String, dynamic> settings() => {
    'url': url.text.trim(),
    'username': username.text,
    'password': password.text,
    'templates_path': directory.text.trim(),
    'timeout': int.tryParse(timeout.text) ?? -1,
    'remember_password': remember,
    'mode': mode,
  };
  Future<void> load() async {
    setState(() => busy = true);
    final reply = await widget.session.command({
      'command': 'cloud_settings_load',
    });
    if (!mounted) return;
    setState(() {
      busy = false;
      if (reply != null) {
        final s = reply['settings'] as Map;
        url.text = s['url'] as String;
        username.text = s['username'] as String;
        password.text = s['password'] as String;
        directory.text = s['templates_path'] as String;
        timeout.text = '${s['timeout']}';
        remember = s['remember_password'] == true;
        mode = s['mode'] as String;
      }
    });
  }

  Future<void> poll() async {
    if (!running || busy || widget.session.busy) return;
    final status = await widget.session.command({'command': 'cloud_status'});
    if (!mounted || status == null) return;
    if (status['running'] == true) return;
    setState(() {
      running = false;
      cancelling = false;
      final result = status['result'] as Map?;
      message =
          status['error'] as String? ??
          (result == null ? 'Finished' : '${result['message'] ?? result}');
      if (result?['versions'] is List) {
        versions = (result!['versions'] as List).cast<String>();
        selected = null;
      }
    });
  }

  Future<bool> confirm(String title) => showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: LText(title),
      content: const LText(
        'Publish only the visible public template catalog; personal templates and sessions are excluded.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const LText('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const LText('Continue'),
        ),
      ],
    ),
  ).then((v) => v == true);
  Future<void> action(String action) async {
    if (action == 'publish' && !await confirm('Publish public templates?')) {
      return;
    }
    if (action == 'activate' &&
        !await confirm('Activate selected template version?')) {
      return;
    }
    if (!mounted) return;
    setState(() => busy = true);
    final reply = await widget.session.command({
      'command': 'cloud_start',
      'action': action,
      'settings': settings(),
      if (action == 'activate' || action == 'download' && selected != null)
        'version': selected,
    });
    if (mounted) {
      setState(() {
        busy = false;
        running = reply != null;
        message = reply == null ? widget.session.error : 'Working…';
      });
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    for (final c in [url, username, password, directory, timeout]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !running && !busy,
    child: AlertDialog(
      title: const LText('Cloud sync'),
      content: SizedBox(
        width: 760,
        height: 480,
        child: Column(
          children: [
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                toolField(
                  'WebDAV URL',
                  url,
                  width: 440,
                  enabled: !running && !busy,
                ),
                toolChoice(
                  'Mode',
                  mode,
                  ['consumer', 'publisher'],
                  running || busy ? null : (v) => setState(() => mode = v),
                  width: 200,
                ),
                toolField(
                  'Username',
                  username,
                  width: 210,
                  enabled: !running && !busy,
                ),
                toolField(
                  'Password',
                  password,
                  width: 210,
                  secret: true,
                  enabled: !running && !busy,
                ),
                toolField(
                  'Templates path',
                  directory,
                  width: 170,
                  enabled: !running && !busy,
                ),
                toolField(
                  'Timeout, s',
                  timeout,
                  width: 100,
                  enabled: !running && !busy,
                ),
              ],
            ),
            CheckboxListTile(
              dense: true,
              title: const LText('Save password as plaintext on this computer'),
              value: remember,
              onChanged: running || busy
                  ? null
                  : (v) => setState(() => remember = v!),
            ),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton(
                  onPressed: running || busy
                      ? null
                      : () async {
                          final result = await widget.session.command({
                            'command': 'cloud_settings_save',
                            'settings': settings(),
                          });
                          if (mounted) {
                            setState(
                              () => message = result == null
                                  ? widget.session.error
                                  : 'Connection settings saved',
                            );
                          }
                        },
                  child: const LText('Save connection settings'),
                ),
                OutlinedButton(
                  onPressed: running || busy ? null : () => action('test'),
                  child: const LText('Test connection'),
                ),
                OutlinedButton(
                  onPressed: running || busy ? null : () => action('download'),
                  child: LText(
                    selected == null
                        ? 'Download current templates'
                        : 'Download selected version',
                  ),
                ),
                OutlinedButton(
                  onPressed: running || busy ? null : () => action('versions'),
                  child: const LText('Template history'),
                ),
                if (mode == 'publisher') ...[
                  OutlinedButton(
                    onPressed: running || busy ? null : () => action('publish'),
                    child: const LText('Publish templates'),
                  ),
                  OutlinedButton(
                    onPressed: running || busy || selected == null
                        ? null
                        : () => action('activate'),
                    child: const LText('Activate version'),
                  ),
                ],
              ],
            ),
            if (running || busy) const LinearProgressIndicator(),
            if (message != null)
              Padding(padding: const EdgeInsets.all(8), child: LText(message!)),
            Expanded(
              child: ListView(
                children: [
                  for (final version in versions)
                    ListTile(
                      dense: true,
                      title: Text(version),
                      selected: selected == version,
                      leading: Icon(
                        selected == version
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off,
                      ),
                      onTap: running || busy
                          ? null
                          : () => setState(() => selected = version),
                    ),
                ],
              ),
            ),
            if (selected != null)
              TextButton(
                onPressed: running || busy
                    ? null
                    : () => setState(() => selected = null),
                child: const LText('Use current catalog'),
              ),
            const LText(
              'Only public templates are synced. Downloads replace the Flutter cache; sessions and custom templates stay separate.',
            ),
          ],
        ),
      ),
      actions: [
        if (running)
          FilledButton(
            onPressed: cancelling
                ? null
                : () async {
                    setState(() => cancelling = true);
                    await widget.session.command({'command': 'cloud_cancel'});
                  },
            child: LText(cancelling ? 'Cancelling…' : 'Cancel transfer'),
          ),
        TextButton(
          onPressed: running || busy ? null : () => Navigator.pop(context),
          child: const LText('Close'),
        ),
      ],
    ),
  );
}

class UpdateDialog extends StatefulWidget {
  const UpdateDialog({
    super.key,
    required this.session,
    this.initialResult,
    this.onInstall,
    this.installerFactory,
    this.onDownloadChanged,
  });
  final SessionController session;
  final Map<String, dynamic>? initialResult;
  final Future<void> Function(UpdateHandoff)? onInstall;
  final UpdateInstaller Function()? installerFactory;
  final void Function(Future<void> Function()? cancel)? onDownloadChanged;
  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  bool busy = false, downloading = false, closing = false, installing = false;
  double progress = 0;
  Map<String, dynamic>? result;
  String? error;
  UpdateInstaller? installer;
  Future<void>? operation;
  @override
  void initState() {
    super.initState();
    result = widget.initialResult;
    if (result == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(check());
      });
    }
  }

  @override
  void dispose() {
    installer?.cancel();
    super.dispose();
  }

  Future<void> check() async {
    if (busy || downloading) return;
    setState(() {
      busy = true;
      result = null;
      error = null;
    });
    final reply = await widget.session.command({'command': 'update_check'});
    if (mounted) {
      setState(() {
        busy = false;
        result = reply;
        error = reply == null
            ? widget.session.error
            : reply['error'] as String?;
      });
    }
  }

  Future<void> close() async {
    if (closing || installing) return;
    closing = true;
    installer?.cancel();
    await operation;
    if (mounted) Navigator.pop(context);
  }

  Future<void> install() async {
    if (busy || downloading || widget.onInstall == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const LText('Install update'),
        content: const LText(
          'Save the workspace, close connections, install this update and restart? Close other Modbus Connector windows first.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const LText('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const LText('Save, install and restart'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      downloading = true;
      error = null;
      progress = 0;
    });
    operation = runInstall();
    widget.onDownloadChanged?.call(() async {
      closing = true;
      installer?.cancel();
      await operation;
    });
    await operation;
  }

  Future<void> runInstall() async {
    final download = installer =
        widget.installerFactory?.call() ?? UpdateInstaller();
    UpdateHandoff? handoff;
    try {
      final asset = InstallerAsset.fromJson(
        Map<String, dynamic>.from(result!['release']['installer'] as Map),
      );
      handoff = await download.prepare(asset, (value) {
        if (mounted && !closing) setState(() => progress = value);
      });
      if (!mounted || closing) {
        await handoff.abort();
        return;
      }
      widget.onDownloadChanged?.call(null);
      setState(() => installing = true);
      await widget.onInstall!(handoff);
    } on UpdateCancelled {
      // Close waits until temporary files and an uncommitted helper are cleaned up.
    } catch (e) {
      await handoff?.abort();
      if (mounted && !closing) setState(() => error = userError(e));
    } finally {
      installer = null;
      widget.onDownloadChanged?.call(null);
      if (mounted) {
        setState(() {
          downloading = false;
          installing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy && !downloading,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop && downloading && !installing) unawaited(close());
    },
    child: AlertDialog(
      title: const LText('Check for updates'),
      content: SizedBox(
        width: 680,
        height: 390,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (busy) const LinearProgressIndicator(),
            if (downloading) ...[
              LinearProgressIndicator(value: progress),
              LText(
                closing
                    ? 'Cancelling download…'
                    : installing
                    ? 'Saving workspace and closing connections…'
                    : 'Downloading and verifying update…',
              ),
              Text('${(progress * 100).floor()}%'),
            ],
            if (error != null) LText(error!),
            if (result != null) ...[
              LText(
                'Current ${result!['current']} · ${result!['release'] == null
                    ? 'No public stable release'
                    : result!['newer'] == true
                    ? 'New version available'
                    : 'Up to date'}',
              ),
              if (result!['release'] != null)
                LText('Latest: ${result!['release']['tag']}'),
              const SizedBox(height: 12),
              Expanded(
                child: SingleChildScrollView(
                  child: SelectableText(
                    result!['release']?['notes'] as String? ??
                        tr('No release notes.'),
                  ),
                ),
              ),
              LText(result!['install_reason'] as String? ?? ''),
              const SizedBox(height: 8),
              SelectableText(result!['url'] as String),
            ] else
              const Expanded(
                child: Center(child: LText('Checking for updates…')),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy || closing || installing ? null : close,
          child: LText(downloading ? 'Cancel download' : 'Close'),
        ),
        OutlinedButton(
          onPressed: busy || downloading
              ? null
              : () => widget.session.command({'command': 'update_open_page'}),
          child: const LText('Open releases page'),
        ),
        OutlinedButton(
          onPressed:
              !busy &&
                  !downloading &&
                  result?['install_supported'] == true &&
                  widget.onInstall != null
              ? install
              : null,
          child: const LText('Install update'),
        ),
        FilledButton(
          onPressed: busy || downloading ? null : check,
          child: const LText('Check now'),
        ),
      ],
    ),
  );
}
