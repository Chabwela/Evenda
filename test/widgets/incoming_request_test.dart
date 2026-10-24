import 'package:evenda/app/providers.dart';
import 'package:evenda/core/connectivity.dart';
import 'package:evenda/data/demo/demo_backend.dart';
import 'package:evenda/design/ev.dart';
import 'package:evenda/features/now/incoming_request.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../helpers/fonts.dart';

/// An incoming Evenda Now request rings like a call: who is asking, what they
/// need, the stock you have free, and "Make an offer" opens the offer form.
void main() {
  setUpAll(loadAppFonts);

  testWidgets('incoming request: call-style screen, Make an offer opens the form', (t) async {
    t.view.physicalSize = const Size(1080, 2400);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final (b, rid) = (await t.runAsync(() async {
      final b = DemoBackend();
      await b.auth.signIn('mutale@demo.evenda.zm', 'demo-vendor');
      final inbox = await b.now.inbox((await b.business.mine())!.id);
      return (b, inbox.first.request.id);
    }))!;
    addTearDown(b.dispose);
    final router = GoRouter(initialLocation: '/now/incoming/$rid', routes: [
      GoRoute(path: '/now/incoming/:id', builder: (_, s) => IncomingRequestScreen(id: s.pathParameters['id']!)),
      GoRoute(path: '/now/respond/:id', builder: (_, s) => Scaffold(body: Text('Offer form ${s.pathParameters['id']}'))),
      GoRoute(path: '/now', builder: (_, _) => const Scaffold(body: Text('Evenda Now'))),
    ]);
    await t.pumpWidget(ProviderScope(
      overrides: [
        backendProvider.overrideWithValue(b),
        onlineProvider.overrideWith((ref) => Stream.value(true)),
        // The screen reads the signed-in business id directly.
        bizIdProvider.overrideWithValue((await t.runAsync(() => b.business.mine()))!.id),
      ],
      child: MediaQuery(
        data: const MediaQueryData(size: Size(360, 800), textScaler: TextScaler.linear(1.3), disableAnimations: true),
        child: MaterialApp.router(theme: EvTheme.light(), routerConfig: router),
      ),
    ));
    for (var i = 0; i < 6; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
      await t.pump(const Duration(milliseconds: 300));
    }

    expect(find.text('EVENDA NOW'), findsOneWidget);
    expect(find.textContaining('Chair covers'), findsOneWidget);
    expect(find.textContaining('free that day'), findsOneWidget);
    expect(find.text('Not now'), findsOneWidget);
    expect(t.takeException(), isNull);

    await t.tap(find.text('Make an offer'));
    await t.pumpAndSettle();
    expect(find.text('Offer form $rid'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });
}
