import 'dart:ui' show Brightness;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/tokens.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Light, dark, or follow the phone. Saved on this device.
enum Appearance {
  system('Same as phone'),
  light('Light'),
  dark('Dark');

  const Appearance(this.label);
  final String label;

  static Appearance parse(String? w) => values.where((a) => a.name == w).firstOrNull ?? system;
}

class AppearanceNotifier extends Notifier<Appearance> {
  static const _key = 'appearance';

  /// Read in main() before the first frame, so the app never flashes the wrong mode.
  static Appearance initial = Appearance.system;

  static Future<void> load() async {
    try {
      initial = Appearance.parse((await SharedPreferences.getInstance()).getString(_key));
    } catch (_) {}
  }

  @override
  Appearance build() => initial;

  Future<void> set(Appearance a) async {
    state = a;
    try {
      await (await SharedPreferences.getInstance()).setString(_key, a.name);
    } catch (_) {}
  }
}

final appearanceProvider = NotifierProvider<AppearanceNotifier, Appearance>(AppearanceNotifier.new);

EvPalette paletteFor(Appearance a, Brightness platform) => switch (a) {
      Appearance.light => EvPalette.light,
      Appearance.dark => EvPalette.darkPalette,
      Appearance.system => platform == Brightness.dark ? EvPalette.darkPalette : EvPalette.light,
    };
