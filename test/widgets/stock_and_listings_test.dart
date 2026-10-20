import 'package:evenda/app/providers.dart';
import 'package:evenda/core/connectivity.dart';
import 'package:evenda/data/demo/demo_backend.dart';
import 'package:evenda/design/ev.dart';
import 'package:evenda/features/business/inventory_screen.dart';
import 'package:evenda/features/business/listings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../helpers/fonts.dart';

/// My stock and On the marketplace render with a real vendor's catalogue on a
/// 360 dp phone at the app's largest text size, and say what each one is for.
void main() {
  setUpAll(loadAppFonts);

  Future<DemoBackend> open(WidgetTester t, Widget screen) async {
    t.view.physicalSize = const Size(1080, 2400);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final backend = (await t.runAsync(() async {
      final b = DemoBackend();
      await b.auth.signIn('mutale@demo.evenda.zm', 'demo-vendor');
      return b;
    }))!;
    final router = GoRouter(routes: [GoRoute(path: '/', builder: (_, _) => screen)]);
    await t.pumpWidget(ProviderScope(
      overrides: [backendProvider.overrideWithValue(backend), onlineProvider.overrideWith((ref) => Stream.value(true))],
      child: MediaQuery(
        data: const MediaQueryData(size: Size(360, 800), textScaler: TextScaler.linear(1.3)),
        child: MaterialApp.router(theme: EvTheme.light(), routerConfig: router),
      ),
    ));
    // Let the demo backend answer (real timers), then settle frames.
    for (var i = 0; i < 6; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 400)));
      await t.pump(const Duration(milliseconds: 100));
    }
    return backend;
  }

  testWidgets('My stock: what you own, quick actions, marketplace status', (t) async {
    final b = await open(t, const InventoryScreen());
    expect(find.text('My stock'), findsOneWidget);
    expect(find.text('WHAT YOU OWN'), findsOneWidget);
    expect(find.text('Add item'), findsOneWidget);
    expect(find.textContaining('marketplace'), findsWidgets);
    expect(t.takeException(), isNull);
    b.dispose();
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('On the marketplace: live count, switches, list from stock', (t) async {
    final b = await open(t, const ListingsScreen());
    expect(find.text('On the marketplace'), findsOneWidget);
    expect(find.text('VENDORS CAN SEE'), findsOneWidget);
    expect(find.byType(Switch), findsWidgets);
    expect(find.text('List something'), findsOneWidget);
    expect(t.takeException(), isNull);
    b.dispose();
    await t.pumpWidget(const SizedBox());
  });
}
