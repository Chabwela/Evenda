import 'package:evenda/app/providers.dart';
import 'package:evenda/core/connectivity.dart';
import 'package:evenda/data/demo/demo_backend.dart';
import 'package:evenda/design/ev.dart';
import 'package:evenda/features/business/listing_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../helpers/fonts.dart';

/// Photos and item details live with the stock item; the marketplace listing
/// only handles price, how many are offered, terms and visibility.
void main() {
  setUpAll(loadAppFonts);

  Future<DemoBackend> open(WidgetTester t, ListingEditorMode mode) async {
    t.view.physicalSize = const Size(1080, 2400);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final (backend, biz) = (await t.runAsync(() async {
      final b = DemoBackend();
      await b.auth.signIn('mutale@demo.evenda.zm', 'demo-vendor');
      return (b, (await b.business.mine())!);
    }))!;
    final router = GoRouter(routes: [GoRoute(path: '/', builder: (_, _) => ListingEditorScreen(id: 'l-folding', mode: mode))]);
    await t.pumpWidget(ProviderScope(
      overrides: [
        backendProvider.overrideWithValue(backend),
        myBusinessProvider.overrideWith((ref) async => biz),
        onlineProvider.overrideWith((ref) => Stream.value(true)),
      ],
      child: MaterialApp.router(theme: EvTheme.light(), routerConfig: router),
    ));
    for (var i = 0; i < 6; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await t.pump(const Duration(milliseconds: 100));
    }
    return backend;
  }

  Future<bool> has(WidgetTester t, Finder f) async {
    await t.scrollUntilVisible(f, 300, scrollable: find.byType(Scrollable).first, maxScrolls: 30).catchError((_) {});
    return f.evaluate().isNotEmpty;
  }

  testWidgets('Stock item: photos, name and quantity; no pricing', (t) async {
    final b = await open(t, ListingEditorMode.item);
    expect(find.text('Stock item'), findsOneWidget);
    expect(find.text('PHOTOS'), findsOneWidget);
    expect(find.text('Save item'), findsOneWidget);
    expect(await has(t, find.text('Total you own')), isTrue);
    expect(find.text('PRICING'), findsNothing);
    expect(find.text('OFFERED TO OTHER VENDORS'), findsNothing);
    expect(t.takeException(), isNull);
    b.dispose();
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('Marketplace listing: price, offer quantity, terms; photos stay in My stock', (t) async {
    final b = await open(t, ListingEditorMode.offer);
    expect(find.text('FROM MY STOCK'), findsOneWidget);
    expect(find.text('PHOTOS'), findsNothing);
    expect(find.text('PRICING'), findsOneWidget);
    expect(await has(t, find.text('Offer everything in service')), isTrue);
    expect(find.text('Total you own'), findsNothing);
    expect(t.takeException(), isNull);
    b.dispose();
    await t.pumpWidget(const SizedBox());
  });
}
