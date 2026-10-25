import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'motion.dart';
import 'tokens.dart';

/// Type system.
///
/// Figtree (UI): open apertures and a tall x-height read well on small,
/// bright-sunlight screens. Fraunces (display) is used only for a few
/// editorial moments: greetings, listing titles on detail pages, empty-state
/// headlines. Sizes are restrained so operational screens stay dense.
abstract final class EvType {
  static const _ui = 'Figtree';
  static const _display = 'Fraunces';

  static TextStyle _f(double size, double height, int weight, {Color? color, double tracking = 0}) =>
      TextStyle(
        fontFamily: _ui,
        fontSize: size,
        height: height / size,
        fontWeight: FontWeight.values[(weight ~/ 100) - 1],
        fontVariations: [FontVariation.weight(weight.toDouble())],
        color: color ?? EvColors.ink,
        letterSpacing: tracking,
      );

  static TextStyle _d(double size, double height, int weight) => TextStyle(
        fontFamily: _display,
        fontSize: size,
        height: height / size,
        fontWeight: FontWeight.values[(weight ~/ 100) - 1],
        fontVariations: [
          FontVariation.weight(weight.toDouble()),
          const FontVariation('opsz', 48),
          const FontVariation('SOFT', 50),
        ],
        color: EvColors.ink,
        letterSpacing: -0.3,
      );

  // Styles carry the palette's text colours: rebuilt when the palette changes.
  static final _cache = <String, TextStyle>{};
  static EvPalette? _cachedFor;
  static TextStyle _s(String k, TextStyle Function() make) {
    if (!identical(_cachedFor, EvColors.palette)) {
      _cache.clear();
      _cachedFor = EvColors.palette;
    }
    return _cache[k] ??= make();
  }

  static TextStyle get display => _s('display', () => _d(28, 34, 560));
  static TextStyle get displaySm => _s('displaySm', () => _d(22, 28, 560));
  static TextStyle get title => _s('title', () => _f(20, 26, 680, tracking: -0.2));
  static TextStyle get headline => _s('headline', () => _f(17, 22, 650, tracking: -0.1));
  static TextStyle get body => _s('body', () => _f(15, 21, 440));
  static TextStyle get bodyStrong => _s('bodyStrong', () => _f(15, 21, 620));
  static TextStyle get small => _s('small', () => _f(13, 18, 450, color: EvColors.ink2));
  static TextStyle get smallStrong => _s('smallStrong', () => _f(13, 18, 620));
  static TextStyle get caption => _s('caption', () => _f(12, 16, 500, color: EvColors.ink3));
  static TextStyle get overline => _s('overline', () => _f(11, 14, 700, color: EvColors.ink3, tracking: 0.8));
  static TextStyle get label => _s('label', () => _f(14, 18, 620));
  static TextStyle get number => _s('number', () => _f(22, 26, 700, tracking: -0.4)
      .copyWith(fontFeatures: const [FontFeature.tabularFigures()]));
  static TextStyle get money => _s('money', () => _f(15, 20, 680)
      .copyWith(fontFeatures: const [FontFeature.tabularFigures()]));
}

abstract final class EvTheme {
  /// Status-bar icons that read on the current canvas.
  static SystemUiOverlayStyle get statusBar =>
      (EvColors.isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark).copyWith(statusBarColor: Colors.transparent);

  static ThemeData light() {
    final scheme = ColorScheme(
      brightness: EvColors.isDark ? Brightness.dark : Brightness.light,
      primary: EvColors.forest,
      onPrimary: EvColors.inkOnDark,
      primaryContainer: EvColors.forestTint,
      onPrimaryContainer: EvColors.forest,
      secondary: EvColors.bronze,
      onSecondary: EvColors.inkOnDark,
      secondaryContainer: EvColors.bronzeTint,
      onSecondaryContainer: EvColors.bronzeDeep,
      tertiary: EvColors.info,
      onTertiary: EvColors.inkOnDark,
      error: EvColors.danger,
      onError: EvColors.inkOnDark,
      errorContainer: EvColors.dangerTint,
      onErrorContainer: EvColors.danger,
      surface: EvColors.cream,
      onSurface: EvColors.ink,
      onSurfaceVariant: EvColors.ink2,
      surfaceContainerLowest: EvColors.warmWhite,
      surfaceContainerLow: EvColors.warmWhite,
      surfaceContainer: EvColors.warmWhite,
      surfaceContainerHigh: EvColors.warmWhite,
      surfaceContainerHighest: EvColors.neutralTint,
      outline: EvColors.sandDeep,
      outlineVariant: EvColors.sand,
      shadow: EvColors.ink,
      scrim: EvColors.scrim,
      inverseSurface: EvColors.ink,
      onInverseSurface: EvColors.inkOnDark,
      inversePrimary: EvColors.forestTint,
    );

    final textTheme = TextTheme(
      displaySmall: EvType.display,
      headlineSmall: EvType.displaySm,
      titleLarge: EvType.title,
      titleMedium: EvType.headline,
      titleSmall: EvType.label,
      bodyLarge: EvType.body,
      bodyMedium: EvType.body,
      bodySmall: EvType.small,
      labelLarge: EvType.label,
      labelMedium: EvType.smallStrong,
      labelSmall: EvType.caption,
    );

    final inputBorder = OutlineInputBorder(
      borderRadius: EvRadius.smAll,
      borderSide: BorderSide(color: EvColors.sand),
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: EvColors.cream,
      fontFamily: 'Figtree',
      textTheme: textTheme,
      splashFactory: InkSparkle.splashFactory,
      visualDensity: VisualDensity.standard,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      pageTransitionsTheme: const PageTransitionsTheme(builders: {
        TargetPlatform.android: EvPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.linux: EvPageTransitionsBuilder(),
        TargetPlatform.macOS: EvPageTransitionsBuilder(),
        TargetPlatform.windows: EvPageTransitionsBuilder(),
      }),
      appBarTheme: AppBarTheme(
        backgroundColor: EvColors.cream,
        surfaceTintColor: Colors.transparent,
        foregroundColor: EvColors.ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleSpacing: EvSpace.gutter,
        toolbarHeight: 56,
        titleTextStyle: EvType.title,
        systemOverlayStyle: statusBar,
      ),
      dividerTheme: DividerThemeData(color: EvColors.hairline, thickness: 1, space: 1),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: EvColors.warmWhite,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        hintStyle: EvType.body.copyWith(color: EvColors.ink3),
        labelStyle: EvType.small,
        floatingLabelBehavior: FloatingLabelBehavior.never,
        border: inputBorder,
        enabledBorder: inputBorder,
        focusedBorder: inputBorder.copyWith(borderSide: BorderSide(color: EvColors.forest, width: 1.6)),
        errorBorder: inputBorder.copyWith(borderSide: BorderSide(color: EvColors.danger)),
        focusedErrorBorder: inputBorder.copyWith(borderSide: BorderSide(color: EvColors.danger, width: 1.6)),
        errorStyle: EvType.caption.copyWith(color: EvColors.danger),
        helperStyle: EvType.caption,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: EvColors.forest,
          foregroundColor: EvColors.inkOnDark,
          disabledBackgroundColor: EvColors.sand,
          disabledForegroundColor: EvColors.ink3,
          minimumSize: const Size(64, 50),
          padding: const EdgeInsets.symmetric(horizontal: 20),
          shape: RoundedRectangleBorder(borderRadius: EvRadius.smAll),
          textStyle: EvType.label,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: EvColors.forest,
          textStyle: EvType.label,
          shape: RoundedRectangleBorder(borderRadius: EvRadius.smAll),
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
        side: BorderSide(color: EvColors.sandDeep, width: 1.6),
        fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? EvColors.forest : null),
      ),
      switchTheme: SwitchThemeData(
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
        thumbColor: WidgetStatePropertyAll(EvColors.warmWhite),
        trackColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? EvColors.forest : EvColors.sandDeep),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: EvColors.forest,
        inactiveTrackColor: EvColors.sand,
        thumbColor: EvColors.forest,
        overlayColor: Color(0x221B3B22),
        trackHeight: 4,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: EvColors.warmWhite,
        surfaceTintColor: Colors.transparent,
        modalBarrierColor: EvColors.scrim,
        showDragHandle: true,
        dragHandleColor: EvColors.sandDeep,
        dragHandleSize: Size(36, 4),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(EvRadius.lg))),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: EvColors.warmWhite,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: EvRadius.mdAll),
        titleTextStyle: EvType.headline,
        contentTextStyle: EvType.body.copyWith(color: EvColors.ink2),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: EvColors.ink,
        contentTextStyle: EvType.body.copyWith(color: EvColors.inkOnDark),
        actionTextColor: EvColors.bronzeTint,
        shape: RoundedRectangleBorder(borderRadius: EvRadius.smAll),
      ),
      datePickerTheme: DatePickerThemeData(
        backgroundColor: EvColors.warmWhite,
        surfaceTintColor: Colors.transparent,
        headerBackgroundColor: EvColors.forest,
        headerForegroundColor: EvColors.inkOnDark,
        todayBorder: BorderSide(color: EvColors.bronze),
        shape: RoundedRectangleBorder(borderRadius: EvRadius.mdAll),
      ),
      timePickerTheme: TimePickerThemeData(
        backgroundColor: EvColors.warmWhite,
        shape: RoundedRectangleBorder(borderRadius: EvRadius.mdAll),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: EvColors.forest, linearTrackColor: EvColors.sand),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(color: EvColors.ink, borderRadius: EvRadius.smAll),
        textStyle: EvType.caption.copyWith(color: EvColors.inkOnDark),
      ),
    );
  }
}
