// Request a quotation lays out on a 360 dp phone at large text without
// squeezing item names, and shows what listed prices come to.
import 'package:evenda/app/providers.dart';
import 'package:evenda/core/connectivity.dart';
import 'package:evenda/data/demo/demo_backend.dart';
import 'package:evenda/design/ev.dart';
import 'package:evenda/domain/models.dart';
import 'package:evenda/features/find/quote_request_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../helpers/fonts.dart';

void main() {
  setUpAll(loadAppFonts);
  testWidgets('request a quotation: clean item rows and an estimate', (t) async {
    t.view.physicalSize = const Size(1080, 2400);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final (b, sup, lid) = (await t.runAsync(() async {
      final b = DemoBackend();
      await b.auth.signIn('mutale@demo.evenda.zm', 'demo-vendor');
      final me = (await b.business.mine())!;
      final results = await b.discovery.search(me.id, const SearchQuery());
      final l = results.firstWhere((x) => x.listing.businessId != me.id).listing;
      return (b, l.businessId, l.id);
    }))!;
    final router = GoRouter(initialLocation: '/s', routes: [GoRoute(path: '/', builder: (_, _) => const SizedBox(), routes: [GoRoute(path: 's', builder: (_, _) => QuoteRequestScreen(supplierId: sup, listingId: lid, quantity: 50))])]);
    await t.pumpWidget(ProviderScope(
      overrides: [backendProvider.overrideWithValue(b), onlineProvider.overrideWith((ref) => Stream.value(true)), bizIdProvider.overrideWithValue((await t.runAsync(() => b.business.mine()))!.id)],
      child: MediaQuery(
        data: const MediaQueryData(size: Size(360, 800), textScaler: TextScaler.linear(1.3)),
        child: MaterialApp.router(theme: EvTheme.light(), routerConfig: router),
      ),
    ));
    for (var i = 0; i < 8; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
      await t.pump(const Duration(milliseconds: 400));
    }
    expect(find.text('White plastic chairs'), findsOneWidget);
    expect(find.text('about K400'), findsOneWidget);
    expect(t.takeException(), isNull);
    b.dispose();
    await t.pumpWidget(const SizedBox());
  });
}
