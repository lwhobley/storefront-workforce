import 'package:flutter/material.dart';

/// Paper-and-ink palette shared with Premium Command, with one accent that each venue can
/// replace through its branding. Status colors are fixed so green, amber, and red mean
/// the same thing at every venue.
abstract final class AppColors {
  static const background = Color(0xFFF3F2F2);
  static const surface = Color(0xFFEAE9E9);
  static const raised = Color(0xFFFBFAFA);
  static const text = Color(0xFF201E1D);
  static const muted = Color(0xFF605D5D);
  static const divider = Color(0x29201E1D);

  static const accent = Color(0xFF0088B0);

  // Status, used on the arena map, tags, and KPI tiles. Each is paired with an icon or
  // word, never color alone.
  static const good = Color(0xFF1E7B45);
  static const goodSoft = Color(0xFFDDF1E4);
  static const warn = Color(0xFFB86B00);
  static const warnSoft = Color(0xFFFCEBD0);
  static const bad = Color(0xFFC0263A);
  static const badSoft = Color(0xFFFBE1E4);
  static const idle = Color(0xFF8A8686);
  static const idleSoft = Color(0xFFE3E0E0);

  static Color ink(double opacity) => text.withValues(alpha: opacity);
}

abstract final class AppSpace {
  static const xs = 4.0;
  static const s = 8.0;
  static const m = 12.0;
  static const l = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;
  static const screen = 20.0;
  static const minTap = 48.0;
}

abstract final class AppText {
  static const sans = 'NotoSans';
  static const serif = 'SourceSerif4';

  static const screenTitle = TextStyle(
    fontFamily: serif,
    fontSize: 30,
    height: 1.1,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.5,
    color: AppColors.text,
  );
  static const sectionHeading = TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.text);
  static const kicker = TextStyle(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1.0, color: AppColors.muted);
  static const body = TextStyle(fontSize: 15, height: 1.45, color: AppColors.text);
  static const meta = TextStyle(fontSize: 13, height: 1.35, color: AppColors.muted);
  static const numeral = TextStyle(fontSize: 34, height: 1.0, fontWeight: FontWeight.w700, color: AppColors.text);
}

/// Parses '#RRGGBB' from venue branding. Falls back to the default accent.
Color brandColor(Object? hex) {
  if (hex is String && RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(hex)) {
    return Color(int.parse('FF${hex.substring(1)}', radix: 16));
  }
  return AppColors.accent;
}

abstract final class AppTheme {
  static ThemeData light({Color accent = AppColors.accent}) {
    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      primary: accent,
      surface: AppColors.background,
      onSurface: AppColors.text,
      error: AppColors.bad,
    ).copyWith(
      surfaceContainerLowest: AppColors.raised,
      surfaceContainerLow: AppColors.surface,
      surfaceContainer: AppColors.surface,
      surfaceContainerHigh: AppColors.surface,
      surfaceContainerHighest: AppColors.surface,
      outline: AppColors.divider,
      outlineVariant: AppColors.divider,
      onSurfaceVariant: AppColors.muted,
      surfaceTint: Colors.transparent,
    );
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(6));
    const divider = BorderSide(color: AppColors.divider);

    final base = ThemeData(useMaterial3: true, colorScheme: scheme, fontFamily: AppText.sans);
    return base.copyWith(
      scaffoldBackgroundColor: AppColors.background,
      dividerTheme: const DividerThemeData(color: AppColors.divider, thickness: 1, space: 1),
      materialTapTargetSize: MaterialTapTargetSize.padded,
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.background,
        foregroundColor: AppColors.text,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(fontFamily: AppText.sans, fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.text),
      ),
      cardTheme: CardThemeData(
        color: AppColors.raised,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: shape.copyWith(side: divider),
      ),
      listTileTheme: const ListTileThemeData(
        minVerticalPadding: 10,
        titleTextStyle: TextStyle(fontFamily: AppText.sans, fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.text),
        subtitleTextStyle: TextStyle(fontFamily: AppText.sans, fontSize: 13, color: AppColors.muted),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, AppSpace.minTap),
          shape: shape,
          textStyle: const TextStyle(fontFamily: AppText.sans, fontSize: 15, fontWeight: FontWeight.w700),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, AppSpace.minTap),
          shape: shape,
          side: divider,
          foregroundColor: AppColors.text,
          textStyle: const TextStyle(fontFamily: AppText.sans, fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 44),
          textStyle: const TextStyle(fontFamily: AppText.sans, fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.raised,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: divider),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: divider),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: accent, width: 2)),
      ),
      chipTheme: ChipThemeData(shape: shape, side: divider, backgroundColor: AppColors.raised),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: AppColors.raised,
        indicatorColor: accent.withValues(alpha: 0.14),
        height: 68,
        labelTextStyle: WidgetStateTextStyle.resolveWith(
          (s) => TextStyle(
            fontFamily: AppText.sans,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: s.contains(WidgetState.selected) ? AppColors.text : AppColors.muted,
          ),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: AppColors.raised,
        indicatorColor: accent.withValues(alpha: 0.14),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: AppColors.background,
        showDragHandle: true,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
      ),
      dialogTheme: DialogThemeData(backgroundColor: AppColors.background, shape: shape),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColors.text,
        behavior: SnackBarBehavior.floating,
        shape: shape,
        contentTextStyle: const TextStyle(fontFamily: AppText.sans, fontSize: 15, color: AppColors.background),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          minimumSize: const Size(0, 44),
          shape: shape,
          side: divider,
          selectedBackgroundColor: accent,
          selectedForegroundColor: Colors.white,
        ),
      ),
    );
  }
}
