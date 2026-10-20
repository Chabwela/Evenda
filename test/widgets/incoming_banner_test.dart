import 'package:evenda/app/incoming_banner.dart';
import 'package:evenda/app/providers.dart';
import 'package:evenda/core/connectivity.dart';
import 'package:evenda/data/demo/demo_backend.dart';
import 'package:evenda/design/ev.dart';
import 'package:evenda/domain/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fonts.dart';

/// An Evenda Now offer shows a banner even over a full-screen page (where the
/// old in-shell banner was hidden), with a View button, and stays ~10 s.
void main() {
  setUpAll(loadAppFonts);

  testWidgets('Evenda Now offer banner shows above a pushed full-screen page', (t) async {
    t.view.physicalSize = const Size(1080, 2400);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final (b, id) = (await t.runAsync(() async {
      final b = DemoBackend();
      await b.auth.signIn('mutale@demo.evenda.zm', 'demo-vendor');
      return (b, (await b.business.mine())!.id);
    }))!;
    addTearDown(b.dispose);
    final nav = GlobalKey<NavigatorState>();

    await t.pumpWidget(ProviderScope(
      overrides: [backendProvider.overrideWithValue(b), onlineProvider.overrideWith((ref) => Stream.value(true))],
      child: MaterialApp(
        navigatorKey: nav,
        theme: EvTheme.light(),
        builder: (c, child) => IncomingBanner(child: child!),
        home: const Scaffold(body: Text('Home')),
      ),
    ));
    for (var i = 0; i < 4; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await t.pump(const Duration(milliseconds: 200));
    }
    // A full-screen page on top, like an open Evenda Now request.
    nav.currentState!.push(MaterialPageRoute(fullscreenDialog: true, builder: (_) => const Scaffold(body: Center(child: Text('Your request')))));
    await t.pumpAndSettle();

    b.db.notify(id, NotificationCategory.now, 'Feluna can supply 80 × chairs', 'ZMW 960.00 total', 'offer-1', route: '/now/r1');
    await t.pump();
    await t.pump(const Duration(milliseconds: 600));
    expect(find.text('EVENDA NOW'), findsOneWidget);
    expect(find.text('Feluna can supply 80 × chairs'), findsOneWidget);
    expect(find.text('View'), findsOneWidget);
    expect(find.text('Your request'), findsOneWidget);

    await t.pump(const Duration(seconds: 6));
    expect(find.text('View'), findsOneWidget); // still up: urgent banners stay ~10 s
    await t.pump(const Duration(seconds: 5));
    await t.pumpAndSettle();
    expect(find.text('EVENDA NOW'), findsNothing);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
}
