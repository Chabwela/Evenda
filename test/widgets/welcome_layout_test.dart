import 'package:evenda/design/ev.dart';
import 'package:evenda/features/auth/auth_screens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fonts.dart';

/// Returning vendors must see "I already have an account" without scrolling,
/// on a 360x800 phone at a large text size.
void main() {
  setUpAll(loadAppFonts);

  for (final scale in [1.0, 1.3]) {
    testWidgets('both ways in are fully on screen (text x$scale)', (t) async {
      t.view.physicalSize = const Size(1080, 2400);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(ProviderScope(
        child: MaterialApp(
          theme: EvTheme.light(),
          builder: (c, child) => MediaQuery(data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
          home: const WelcomeScreen(),
        ),
      ));
      await t.pump(const Duration(seconds: 2));
      for (final label in ['Create a vendor account', 'I already have an account']) {
        final r = t.getRect(find.text(label));
        expect(r.bottom, lessThanOrEqualTo(800), reason: '$label ends at ${r.bottom}');
      }
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    });
  }
}
