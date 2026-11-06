import 'dart:ui';

import 'src/diagnostics.dart';
import 'src/workbench_theme.dart';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'src/translations.dart';

import 'src/session_controller.dart';
import 'src/workbench.dart';
import 'src/workspace.dart';
import 'src/graph_window.dart';

void main(List<String> args) {
  Diagnostics.initialize(
    role: args.contains('--graph-window') ? 'graph' : 'ui',
  );
  FlutterError.onError = (details) {
    Diagnostics.current?.write(
      'flutter-error',
      details.exceptionAsString(),
      details.stack,
    );
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    Diagnostics.current?.write('unhandled-error', '$error', stack);
    return false;
  };
  runApp(ModbusApp(graphWindow: args.contains('--graph-window')));
}

class ModbusApp extends StatefulWidget {
  const ModbusApp({super.key, this.controller, this.graphWindow = false});
  final SessionController? controller;
  final bool graphWindow;

  @override
  State<ModbusApp> createState() => _ModbusAppState();
}

class _ModbusAppState extends State<ModbusApp> {
  ThemeMode get _themeMode => appTheme.value;
  @override
  void initState() {
    super.initState();
    appLanguage.addListener(_languageChanged);
    appTheme.addListener(_languageChanged);
  }

  void _languageChanged() {
    setState(() {});
  }

  @override
  void dispose() {
    appLanguage.removeListener(_languageChanged);
    appTheme.removeListener(_languageChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Modbus Connector',
    locale: appLanguage.value == 'zh_CN'
        ? const Locale('zh', 'CN')
        : const Locale('en'),
    supportedLocales: const [Locale('en'), Locale('zh', 'CN')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    debugShowCheckedModeBanner: false,
    theme: workbenchTheme(Brightness.light),
    darkTheme: workbenchTheme(Brightness.dark),
    themeMode: _themeMode,
    home: widget.graphWindow
        ? const GraphWindow()
        : widget.controller == null
        ? SessionWorkspace(
            themeMode: _themeMode,
            onThemeChanged: (mode) => appTheme.value = mode,
          )
        : Workbench(
            controller: widget.controller!,
            themeMode: _themeMode,
            onThemeChanged: (mode) => appTheme.value = mode,
          ),
  );
}
