// Play Store screenshots: renders the real app UI with the rich demo data at
// phone resolution. Not part of the normal suite.
//   flutter test test/_store --dart-define=STORE=true --update-goldens
import 'package:evenda/app/providers.dart';
import 'package:evenda/core/connectivity.dart';
import 'package:evenda/data/demo/demo_backend.dart';
import 'package:evenda/design/ev.dart';
import 'package:evenda/domain/models.dart';
import 'package:evenda/features/bookings/request_detail.dart';
import 'package:evenda/features/business/inventory_screen.dart';
import 'package:evenda/features/now/incoming_request.dart';
import 'package:evenda/features/find/find_screen.dart';
import 'package:evenda/features/find/listing_detail.dart';
import 'package:evenda/features/home/home_screen.dart';
import 'package:flutter/material.dart';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../helpers/fonts.dart';

const _run = bool.fromEnvironment('STORE');

void main() {
  setUpAll(() async {
    await loadAppFonts();
    // Lucide icons, so the UI renders its real icons rather than empty squares.
    await (FontLoader('packages/lucide_icons_flutter/Lucide')
          ..addFont(rootBundle.load('packages/lucide_icons_flutter/assets/lucide.ttf')))
        .load();
    // MaterialIcons (nav back arrow etc.) from the Flutter SDK.
    final mat = File('/home/daniel/snap/flutter/common/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
    if (mat.existsSync()) {
      await (FontLoader('MaterialIcons')..addFont(Future.value(mat.readAsBytesSync().buffer.asByteData()))).load();
    }
  });
  tearDown(() => EvColors.apply(EvPalette.light));

  Future<void> shot(WidgetTester t, String name, Future<Widget> Function(DemoBackend b, String bizId) build) async {
    EvColors.apply(EvPalette.light);
    t.view.physicalSize = const Size(1080, 2340);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final (b, id, screen) = (await t.runAsync(() async {
      final b = DemoBackend();
      await b.auth.signIn('mutale@demo.evenda.zm', 'demo-vendor');
      final me = (await b.business.mine())!;
      final screen = await build(b, me.id);
      return (b, me.id, screen);
    }))!;
    final router = GoRouter(initialLocation: '/s', routes: [GoRoute(path: '/', builder: (_, _) => const SizedBox(), routes: [GoRoute(path: 's', builder: (_, _) => screen)])]);
    final container = ProviderContainer(overrides: [backendProvider.overrideWithValue(b), onlineProvider.overrideWith((ref) => Stream.value(true)), bizIdProvider.overrideWithValue(id)]);
    addTearDown(container.dispose);
    await t.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MediaQuery(
        data: const MediaQueryData(size: Size(360, 780), devicePixelRatio: 3),
        child: MaterialApp.router(theme: EvTheme.light(), debugShowCheckedModeBanner: false, routerConfig: router),
      ),
    ));
    for (var i = 0; i < 10; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
      await t.pump(const Duration(milliseconds: 400));
    }
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/$name.png'));
    b.dispose();
    await t.pumpWidget(const SizedBox());
  }

  testWidgets('home', (t) => shot(t, 'home', (b, id) async => const HomeScreen()), skip: !_run);
  testWidgets('find', (t) => shot(t, 'find', (b, id) async => const FindScreen(initialCategory: 'chairs')), skip: !_run);
  testWidgets('listing', (t) => shot(t, 'listing', (b, id) async {
        final res = await b.discovery.search(id, const SearchQuery(categoryId: 'chairs'));
        final l = res.firstWhere((r) => r.listing.photos.isNotEmpty, orElse: () => res.first).listing;
        return ListingDetailScreen(id: l.id);
      }), skip: !_run);
  testWidgets('now', (t) => shot(t, 'now', (b, id) async {
        // An urgent request that reached this vendor: the call-style alert.
        final inbox = await b.now.inbox(id);
        return IncomingRequestScreen(id: inbox.first.request.id);
      }), skip: !_run);
  testWidgets('quote', (t) => shot(t, 'quote', (b, id) async {
        final reqs = await b.bookings.requests(id);
        final r = reqs.firstWhere((q) => q.status == QuoteRequestStatus.open, orElse: () => reqs.first);
        return RequestDetailScreen(id: r.id);
      }), skip: !_run);
  testWidgets('inventory', (t) => shot(t, 'inventory', (b, id) async => const InventoryScreen()), skip: !_run);
}
