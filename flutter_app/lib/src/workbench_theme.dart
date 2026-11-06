import 'package:flutter/material.dart';

/// Shared by the workbench, owned graph windows and native acceptance tests.
ThemeData workbenchTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme =
      ColorScheme.fromSeed(
        seedColor: const Color(0xff087f83),
        brightness: brightness,
      ).copyWith(
        primary: dark ? const Color(0xff60c6c8) : const Color(0xff087f83),
        onPrimary: dark ? const Color(0xff15252b) : Colors.white,
        primaryContainer: dark
            ? const Color(0xff203a41)
            : const Color(0xffeaf5f5),
        onPrimaryContainer: dark
            ? const Color(0xff9adfe0)
            : const Color(0xff17676b),
        surface: dark ? const Color(0xff151b22) : Colors.white,
        surfaceContainerLowest: dark ? const Color(0xff151b22) : Colors.white,
        surfaceContainerLow: dark
            ? const Color(0xff1a222c)
            : const Color(0xfff4f6f8),
        surfaceContainer: dark
            ? const Color(0xff202a35)
            : const Color(0xffedf1f4),
        surfaceContainerHigh: dark
            ? const Color(0xff26323e)
            : const Color(0xffe7ecf0),
        surfaceContainerHighest: dark
            ? const Color(0xff303e4c)
            : const Color(0xffe0e6eb),
        onSurface: dark ? const Color(0xffd5dee8) : const Color(0xff263441),
        onSurfaceVariant: dark
            ? const Color(0xffa3b1c0)
            : const Color(0xff596a79),
        outline: dark ? const Color(0xff607184) : const Color(0xff80909f),
        outlineVariant: dark
            ? const Color(0xff303b47)
            : const Color(0xffdce1e7),
        surfaceTint: Colors.transparent,
      );
  const controlShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(3)),
  );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme);
  final controlStyle = ButtonStyle(
    minimumSize: const WidgetStatePropertyAll(Size(0, 32)),
    padding: const WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    ),
    shape: const WidgetStatePropertyAll(controlShape),
    textStyle: WidgetStatePropertyAll(
      base.textTheme.labelLarge?.copyWith(fontSize: 12),
    ),
    iconSize: const WidgetStatePropertyAll(16),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  );
  return base.copyWith(
    scaffoldBackgroundColor: scheme.surface,
    visualDensity: VisualDensity.compact,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    textTheme: base.textTheme.copyWith(
      bodyLarge: base.textTheme.bodyLarge?.copyWith(fontSize: 14),
      bodyMedium: base.textTheme.bodyMedium?.copyWith(fontSize: 13),
      bodySmall: base.textTheme.bodySmall?.copyWith(fontSize: 12),
      titleLarge: base.textTheme.titleLarge?.copyWith(fontSize: 18),
      titleMedium: base.textTheme.titleMedium?.copyWith(
        fontSize: 14,
        fontWeight: FontWeight.w600,
      ),
      titleSmall: base.textTheme.titleSmall?.copyWith(
        fontSize: 13,
        fontWeight: FontWeight.w600,
      ),
      labelLarge: base.textTheme.labelLarge?.copyWith(fontSize: 12),
    ),
    iconTheme: IconThemeData(size: 18, color: scheme.onSurfaceVariant),
    filledButtonTheme: FilledButtonThemeData(style: controlStyle),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: controlStyle.copyWith(
        side: WidgetStateProperty.resolveWith(
          (states) => BorderSide(
            color: states.contains(WidgetState.disabled)
                ? scheme.outlineVariant.withValues(alpha: .5)
                : scheme.outlineVariant,
          ),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(style: controlStyle),
    elevatedButtonTheme: ElevatedButtonThemeData(style: controlStyle),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(30, 30)),
        padding: const WidgetStatePropertyAll(EdgeInsets.all(5)),
        iconSize: const WidgetStatePropertyAll(18),
        shape: const WidgetStatePropertyAll(controlShape),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: scheme.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      border: const OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(3)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: const BorderRadius.all(Radius.circular(3)),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: const BorderRadius.all(Radius.circular(3)),
        borderSide: BorderSide(color: scheme.primary, width: 1.5),
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surface,
      surfaceTintColor: Colors.transparent,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(4),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant,
      thickness: 1,
      space: 1,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: scheme.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(4),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      textStyle: base.textTheme.bodyMedium?.copyWith(
        fontSize: 13,
        color: scheme.onSurface,
      ),
    ),
    tooltipTheme: const TooltipThemeData(
      waitDuration: Duration(milliseconds: 500),
    ),
  );
}
