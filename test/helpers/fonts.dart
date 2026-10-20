import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Loads Evenda's real fonts. flutter_test otherwise renders every glyph as a
/// wide square (the Ahem test font), which roughly doubles text widths and
/// makes layout tests report overflows a phone never shows.
Future<void> loadAppFonts() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final (family, asset) in [('Figtree', 'assets/fonts/Figtree.ttf'), ('Fraunces', 'assets/fonts/Fraunces.ttf')]) {
    final loader = FontLoader(family)..addFont(rootBundle.load(asset));
    await loader.load();
  }
}
