// The main screens render in dark mode without errors, and switching back
// restores the light palette.
import 'package:evenda/app/providers.dart';
import 'package:evenda/core/connectivity.dart';
import 'package:evenda/data/demo/demo_backend.dart';
import 'package:evenda/design/ev.dart';
import 'package:evenda/features/business/business_screen.dart';
import 'package:evenda/features/find/find_screen.dart';
import 'package:evenda/features/home/home_screen.dart';
import 'package:evenda/features/notifications/notifications_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../helpers/fonts.dart';

const _shots = bool.fromEnvironment('SHOTS');

void main() {
  setUpAll(loadAppFonts);
  tearDown(() => EvColors.apply(EvPalette.light));

  Future<void> render(WidgetTester t, String name, Widget screen) async {
    EvColors.apply(EvPalette.darkPalette);
    t.view.physicalSize = const Size(1080, 2400);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final b = (await t.runAsync(() async {
      final b = DemoBackend();
      await b.auth.signIn('mutale@demo.evenda.zm', 'demo-vendor');
      return b;
    }))!;
    final router = GoRouter(initialLocation: '/s', routes: [GoRoute(path: '/', builder: (_, _) => const SizedBox(), routes: [GoRoute(path: 's', builder: (_, _) => screen)])]);
    await t.pumpWidget(ProviderScope(
      overrides: [backendProvider.overrideWithValue(b), onlineProvider.overrideWith((ref) => Stream.value(true))],
      child: MediaQuery(
        data: const MediaQueryData(size: Size(360, 800), textScaler: TextScaler.linear(1.3)),
        child: MaterialApp.router(theme: EvTheme.light(), debugShowCheckedModeBanner: false, routerConfig: router),
      ),
    ));
    for (var i = 0; i < 8; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
      await t.pump(const Duration(milliseconds: 400));
    }
    expect(Theme.of(t.element(find.byType(Scaffold).first)).brightness, Brightness.dark);
    if (_shots) await expectLater(find.byType(MaterialApp), matchesGoldenFile('../_shots/dark_$name.png'));
    expect(t.takeException(), isNull);
    b.dispose();
    await t.pumpWidget(const SizedBox());
  }

  testWidgets('home in dark mode', (t) => render(t, 'home', const HomeScreen()));
  testWidgets('find in dark mode', (t) => render(t, 'find', const FindScreen()));
  testWidgets('business in dark mode', (t) => render(t, 'business', const BusinessScreen()));
  testWidgets('notifications in dark mode', (t) => render(t, 'notifications', const NotificationsScreen()));

  test('switching back restores the light palette', () {
    EvColors.apply(EvPalette.darkPalette);
    expect(EvType.body.color, EvPalette.darkPalette.ink);
    EvColors.apply(EvPalette.light);
    expect(EvType.body.color, EvPalette.light.ink);
    expect(Tone.positive.fg, EvPalette.light.success);
  });
}
