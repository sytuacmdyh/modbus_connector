import 'package:flutter/material.dart';

import 'src/bridge_client.dart';
import 'src/session_controller.dart';
import 'src/workbench.dart';

void main() => runApp(const ModbusApp());

class ModbusApp extends StatefulWidget {
  const ModbusApp({super.key, this.controller});
  final SessionController? controller;

  @override
  State<ModbusApp> createState() => _ModbusAppState();
}

class _ModbusAppState extends State<ModbusApp> {
  ThemeMode _themeMode = ThemeMode.system;
  late final SessionController _controller =
      widget.controller ?? SessionController(ProcessBridge());

  ThemeData _theme(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xff326d76),
      brightness: brightness,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surfaceContainerLowest,
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
        isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerLow,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    );
  }

  @override
  void dispose() {
    if (widget.controller == null) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Modbus Connector',
    debugShowCheckedModeBanner: false,
    theme: _theme(Brightness.light),
    darkTheme: _theme(Brightness.dark),
    themeMode: _themeMode,
    home: Workbench(
      controller: _controller,
      themeMode: _themeMode,
      onThemeChanged: (mode) => setState(() => _themeMode = mode),
    ),
  );
}
