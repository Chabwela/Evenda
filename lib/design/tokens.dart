import 'package:flutter/material.dart';

/// Evenda design tokens. Every colour, space, radius and duration in the app
/// comes from here; widgets never hard-code values.
///
/// Palette rationale: forest green carries action and selection, cream is the
/// canvas, warm white lifts content, charcoal carries text and bronze is a
/// sparing accent (highlights, the logo's tail, money emphasis).
abstract final class EvColors {
  // Brand
  static const forest = Color(0xFF1B3B22);
  static const forestHover = Color(0xFF24502E);
  static const forestSoft = Color(0xFF3D6B47);
  static const forestTint = Color(0xFFE2EADF); // selected rows, primary containers
  static const forestWash = Color(0xFFEFF3EC);

  static const cream = Color(0xFFFDFCF7); // app canvas: warm off-white, never a coloured block
  static const warmWhite = Color(0xFFFFFFFF); // content surfaces
  static const hairline = Color(0xFFEEE8DB); // card borders and row dividers (lighter than sand)
  static const sand = Color(0xFFE8DFCC); // dividers, skeletons, quiet fills
  static const sandDeep = Color(0xFFD9CDB4);

  static const bronze = Color(0xFF996633);
  static const bronzeDeep = Color(0xFF7A5228);
  static const bronzeTint = Color(0xFFF1E6D6);

  // Text
  static const ink = Color(0xFF171A18);
  static const ink2 = Color(0xFF4A4F4B);
  static const ink3 = Color(0xFF767B76);
  static const inkOnDark = Color(0xFFFCFBF7);

  // Semantic. One hue per meaning, used identically everywhere.
  static const success = Color(0xFF2F6B3F);
  static const successTint = Color(0xFFDDEBDD);
  static const warning = Color(0xFFA86A12);
  static const warningTint = Color(0xFFF6E7CC);
  static const danger = Color(0xFFA23B2A);
  static const dangerTint = Color(0xFFF5DDD7);
  static const info = Color(0xFF2E5C6E);
  static const infoTint = Color(0xFFDCE8EC);
  static const neutralTint = Color(0xFFECE7DC);

  static const scrim = Color(0x66171A18);
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
