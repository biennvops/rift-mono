import 'package:flutter/material.dart';

abstract final class RiftDesign {
  static const compactBreakpoint = 1024.0;
  static const contentMaxWidth = 1280.0;
  static const sidebarWidth = 280.0;

  static const space2Xs = 2.0;
  static const spaceXs = 4.0;
  static const spaceSm = 8.0;
  static const spaceMd = 16.0;
  static const spaceLg = 24.0;
  static const spaceXl = 32.0;
  static const space2Xl = 48.0;

  static const padScreenMobile =
      EdgeInsets.symmetric(horizontal: 16, vertical: 16);
  static const padScreenDesktop =
      EdgeInsets.symmetric(horizontal: 24, vertical: 24);
  static const padCard = EdgeInsets.all(16);

  static const radiusSm = 2.0;
  static const radius = 4.0;
  static const radiusMd = 6.0;
  static const radiusLg = 8.0;
  static const radiusXl = 12.0;

  static const sidebar = Color(0xFF213145);
  static const success = Color(0xFF059669);
  static const warning = Color(0xFFD97706);
  static const pending = Color(0xFF6366F1);
}

ThemeData buildRiftTheme() {
  const colorScheme = ColorScheme(
    brightness: Brightness.light,
    primary: Color(0xFF00327d),
    onPrimary: Color(0xFFffffff),
    primaryContainer: Color(0xFF0047ab),
    onPrimaryContainer: Color(0xFFa5bdff),
    secondary: Color(0xFF545f73),
    onSecondary: Color(0xFFffffff),
    secondaryContainer: Color(0xFFd5e0f8),
    onSecondaryContainer: Color(0xFF586377),
    tertiary: Color(0xFF1a12af),
    onTertiary: Color(0xFFffffff),
    tertiaryContainer: Color(0xFF3636c5),
    onTertiaryContainer: Color(0xFFb7b8ff),
    error: Color(0xFFba1a1a),
    onError: Color(0xFFffffff),
    errorContainer: Color(0xFFffdad6),
    onErrorContainer: Color(0xFF93000a),
    surface: Color(0xFFf8f9ff),
    onSurface: Color(0xFF0b1c30),
    surfaceContainerHighest: Color(0xFFd3e4fe),
    onSurfaceVariant: Color(0xFF434653),
    outline: Color(0xFF737784),
    outlineVariant: Color(0xFFc3c6d5),
  );

  final inter = Typography.material2021().black.apply(fontFamily: 'Inter');

  return ThemeData(
    useMaterial3: true,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: colorScheme.surface,
    textTheme: inter.copyWith(
      displaySmall: inter.displaySmall?.copyWith(
          fontSize: 40,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.8,
          height: 48 / 40),
      headlineLarge: inter.headlineLarge?.copyWith(
          fontSize: 32,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.32,
          height: 40 / 32),
      headlineMedium: inter.headlineMedium?.copyWith(
          fontSize: 24,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.24,
          height: 32 / 24),
      bodyLarge: inter.bodyLarge?.copyWith(
          fontSize: 18, fontWeight: FontWeight.w400, height: 28 / 18),
      bodyMedium: inter.bodyMedium?.copyWith(
          fontSize: 16, fontWeight: FontWeight.w400, height: 24 / 16),
      bodySmall: inter.bodySmall?.copyWith(
          fontSize: 14, fontWeight: FontWeight.w400, height: 20 / 14),
      labelMedium: inter.labelMedium?.copyWith(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.7,
          height: 16 / 14),
      labelSmall: inter.labelSmall?.copyWith(
          fontSize: 12, fontWeight: FontWeight.w500, height: 16 / 12),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
      ),
      titleTextStyle: inter.headlineMedium?.copyWith(
        fontSize: 20,
        fontWeight: FontWeight.w700,
        color: colorScheme.onSurface,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(4),
        borderSide: BorderSide(color: colorScheme.outlineVariant),
      ),
      filled: true,
      fillColor: colorScheme.surface,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(4),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(4),
        ),
        side: BorderSide(color: colorScheme.primary, width: 1),
      ),
    ),
    cardTheme: CardThemeData(
      color: const Color(0xFFFFFFFF),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(RiftDesign.radiusLg),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: colorScheme.outlineVariant,
      thickness: 1,
      space: 1,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: colorScheme.surface,
      indicatorColor: colorScheme.primaryContainer,
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return inter.labelSmall!.copyWith(
              color: colorScheme.onSurface, fontWeight: FontWeight.w600);
        }
        return inter.labelSmall!.copyWith(color: colorScheme.onSurfaceVariant);
      }),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return IconThemeData(color: colorScheme.onPrimaryContainer);
        }
        return IconThemeData(color: colorScheme.onSurfaceVariant);
      }),
    ),
  );
}
