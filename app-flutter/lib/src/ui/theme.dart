import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

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

  final inter = GoogleFonts.interTextTheme();

  return ThemeData(
    useMaterial3: true,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: colorScheme.surface,
    textTheme: inter.copyWith(
      headlineLarge: inter.headlineLarge?.copyWith(
          fontSize: 32,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.01,
          height: 40 / 32),
      headlineMedium: inter.headlineMedium?.copyWith(
          fontSize: 24, fontWeight: FontWeight.w600, height: 32 / 24),
      bodyLarge: inter.bodyLarge?.copyWith(
          fontSize: 18, fontWeight: FontWeight.w400, height: 28 / 18),
      bodyMedium: inter.bodyMedium?.copyWith(
          fontSize: 16, fontWeight: FontWeight.w400, height: 24 / 16),
      bodySmall: inter.bodySmall?.copyWith(
          fontSize: 14, fontWeight: FontWeight.w400, height: 20 / 14),
      labelMedium: inter.labelMedium?.copyWith(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.05,
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
