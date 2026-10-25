import 'package:flutter/material.dart';

/// Evenda design tokens. Every colour, space, radius and duration in the app
/// comes from here; widgets never hard-code values.
///
/// Palette rationale: forest green carries action and selection, cream is the
/// canvas, warm white lifts content, charcoal carries text and bronze is a
/// sparing accent (highlights, the logo's tail, money emphasis).
/// Fixed brand colours that never change with the theme: the logo, the
/// call-style Evenda Now screen, printed material.
abstract final class EvBrand {
  static const forest = Color(0xFF1B3B22);
  static const cream = Color(0xFFFDFCF7);
  static const bronze = Color(0xFF996633);
  static const bronzeLight = Color(0xFFC9A27A);
}

/// One full set of colours. [EvPalette.light] is the original Evenda look;
/// [EvPalette.dark] keeps the same meanings on a deep green-black canvas.
class EvPalette {
  const EvPalette({
    required this.dark,
    required this.forest,
    required this.forestHover,
    required this.forestSoft,
    required this.forestTint,
    required this.forestWash,
    required this.cream,
    required this.warmWhite,
    required this.hairline,
    required this.sand,
    required this.sandDeep,
    required this.bronze,
    required this.bronzeDeep,
    required this.bronzeTint,
    required this.ink,
    required this.ink2,
    required this.ink3,
    required this.inkOnDark,
    required this.success,
    required this.successTint,
    required this.warning,
    required this.warningTint,
    required this.danger,
    required this.dangerTint,
    required this.info,
    required this.infoTint,
    required this.neutralTint,
    required this.scrim,
  });

  final bool dark;
  final Color forest, forestHover, forestSoft, forestTint, forestWash;
  final Color cream, warmWhite, hairline, sand, sandDeep;
  final Color bronze, bronzeDeep, bronzeTint;
  final Color ink, ink2, ink3, inkOnDark;
  final Color success, successTint, warning, warningTint, danger, dangerTint, info, infoTint, neutralTint, scrim;

  static const light = EvPalette(
    dark: false,
    forest: Color(0xFF1B3B22),
    forestHover: Color(0xFF24502E),
    forestSoft: Color(0xFF3D6B47),
    forestTint: Color(0xFFE2EADF),
    forestWash: Color(0xFFEFF3EC),
    cream: Color(0xFFFDFCF7),
    warmWhite: Color(0xFFFFFFFF),
    hairline: Color(0xFFEEE8DB),
    sand: Color(0xFFE8DFCC),
    sandDeep: Color(0xFFD9CDB4),
    bronze: Color(0xFF996633),
    bronzeDeep: Color(0xFF7A5228),
    bronzeTint: Color(0xFFF1E6D6),
    ink: Color(0xFF171A18),
    ink2: Color(0xFF4A4F4B),
    ink3: Color(0xFF767B76),
    inkOnDark: Color(0xFFFCFBF7),
    success: Color(0xFF2F6B3F),
    successTint: Color(0xFFDDEBDD),
    warning: Color(0xFFA86A12),
    warningTint: Color(0xFFF6E7CC),
    danger: Color(0xFFA23B2A),
    dangerTint: Color(0xFFF5DDD7),
    info: Color(0xFF2E5C6E),
    infoTint: Color(0xFFDCE8EC),
    neutralTint: Color(0xFFECE7DC),
    scrim: Color(0x66171A18),
  );

  /// "forest" is the action colour: a light sage on dark so buttons, links and
  /// selection stay readable; "inkOnDark" is the text on it, so it turns dark.
  static const darkPalette = EvPalette(
    dark: true,
    forest: Color(0xFF94C9A0),
    forestHover: Color(0xFFA9D6B3),
    forestSoft: Color(0xFF6E9E79),
    forestTint: Color(0xFF213628),
    forestWash: Color(0xFF19251C),
    cream: Color(0xFF111512),
    warmWhite: Color(0xFF1A1F1B),
    hairline: Color(0xFF29302A),
    sand: Color(0xFF2E3530),
    sandDeep: Color(0xFF414A43),
    bronze: Color(0xFFD3A26F),
    bronzeDeep: Color(0xFFE2B98C),
    bronzeTint: Color(0xFF382C20),
    ink: Color(0xFFEDEBE4),
    ink2: Color(0xFFB8BDB7),
    ink3: Color(0xFF8D938D),
    inkOnDark: Color(0xFF0F1410),
    success: Color(0xFF86C595),
    successTint: Color(0xFF1D3123),
    warning: Color(0xFFE6AD55),
    warningTint: Color(0xFF3A2D18),
    danger: Color(0xFFEA8A78),
    dangerTint: Color(0xFF3E2420),
    info: Color(0xFF86BACD),
    infoTint: Color(0xFF1B2D34),
    neutralTint: Color(0xFF262C27),
    scrim: Color(0x99000000),
  );
}

/// Evenda colour tokens. They read the active palette, so every widget that
/// uses them follows light or dark mode (see EvendaApp and EvColors.apply).
///
/// Palette rationale: forest green carries action and selection, cream is the
/// canvas, warm white lifts content, charcoal carries text and bronze is a
/// sparing accent (highlights, the logo's tail, money emphasis).
abstract final class EvColors {
  static EvPalette _p = EvPalette.light;
  static final _listeners = <VoidCallback>[];

  static EvPalette get palette => _p;
  static bool get isDark => _p.dark;

  /// Switch the palette. Returns true when it changed.
  static bool apply(EvPalette p) {
    if (identical(p, _p)) return false;
    _p = p;
    for (final l in _listeners) {
      l();
    }
    return true;
  }

  static void addListener(VoidCallback l) => _listeners.add(l);

  // Brand
  static Color get forest => _p.forest;
  static Color get forestHover => _p.forestHover;
  static Color get forestSoft => _p.forestSoft;
  static Color get forestTint => _p.forestTint; // selected rows, primary containers
  static Color get forestWash => _p.forestWash;

  static Color get cream => _p.cream; // app canvas
  static Color get warmWhite => _p.warmWhite; // content surfaces
  static Color get hairline => _p.hairline; // card borders and row dividers
  static Color get sand => _p.sand; // dividers, skeletons, quiet fills
  static Color get sandDeep => _p.sandDeep;

  static Color get bronze => _p.bronze;
  static Color get bronzeDeep => _p.bronzeDeep;
  static Color get bronzeTint => _p.bronzeTint;

  // Text
  static Color get ink => _p.ink;
  static Color get ink2 => _p.ink2;
  static Color get ink3 => _p.ink3;
  static Color get inkOnDark => _p.inkOnDark; // text on forest fills

  // Semantic. One hue per meaning, used identically everywhere.
  static Color get success => _p.success;
  static Color get successTint => _p.successTint;
  static Color get warning => _p.warning;
  static Color get warningTint => _p.warningTint;
  static Color get danger => _p.danger;
  static Color get dangerTint => _p.dangerTint;
  static Color get info => _p.info;
  static Color get infoTint => _p.infoTint;
  static Color get neutralTint => _p.neutralTint;

  static Color get scrim => _p.scrim;
}

/// 4-pt spacing scale.
abstract final class EvSpace {
  static const x1 = 4.0;
  static const x2 = 8.0;
  static const x3 = 12.0;
  static const x4 = 16.0;
  static const x5 = 20.0;
  static const x6 = 24.0;
  static const x8 = 32.0;
  static const x10 = 40.0;
  static const x12 = 48.0;

  /// Horizontal page gutter on phones.
  static const gutter = 20.0;
}

abstract final class EvRadius {
  static const xs = 4.0;
  static const sm = 8.0; // inputs, chips, small media
  static const md = 12.0; // cards, list media
  static const lg = 18.0; // sheets, hero media
  static const pill = 999.0;

  static final smAll = BorderRadius.circular(sm);
  static final mdAll = BorderRadius.circular(md);
  static final lgAll = BorderRadius.circular(lg);
}

/// Elevation is used sparingly: canvas (0), raised surface (1), floating (2).
abstract final class EvShadow {
  static const raised = [
    BoxShadow(color: Color(0x0F171A18), blurRadius: 2, offset: Offset(0, 1)),
    BoxShadow(color: Color(0x0A171A18), blurRadius: 12, offset: Offset(0, 4)),
  ];
  static const floating = [
    BoxShadow(color: Color(0x14171A18), blurRadius: 4, offset: Offset(0, 2)),
    BoxShadow(color: Color(0x1F171A18), blurRadius: 28, offset: Offset(0, 12)),
  ];
}

abstract final class EvBreakpoints {
  static const tablet = 720.0;
  static const desktop = 1100.0;
  static const contentMax = 640.0;
}
