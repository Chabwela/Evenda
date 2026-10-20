import 'package:evenda/app/providers.dart';
import 'package:evenda/core/connectivity.dart';
import 'package:evenda/data/demo/demo_backend.dart';
import 'package:evenda/design/ev.dart';
import 'package:evenda/features/business/account_screen.dart';
import 'package:evenda/features/business/business_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../helpers/fonts.dart';

/// Delete account must never sit next to Sign out.
void main() {
  setUpAll(loadAppFonts);

  Future<DemoBackend> open(WidgetTester t, Widget screen, {String? golden}) async {
    t.view.physicalSize = const Size(1080, 2400);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final (b, biz) = (await t.runAsync(() async {
      final b = DemoBackend();
      await b.auth.signIn('mutale@demo.evenda.zm', 'demo-vendor');
      return (b, (await b.business.mine())!);
    }))!;
    final router = GoRouter(routes: [GoRoute(path: '/', builder: (_, _) => screen)]);
    await t.pumpWidget(ProviderScope(
      overrides: [
        backendProvider.overrideWithValue(b),
        myBusinessProvider.overrideWith((ref) async => biz),
        onlineProvider.overrideWith((ref) => Stream.value(true)),
      ],
      child: MediaQuery(
        data: const MediaQueryData(size: Size(360, 800), textScaler: TextScaler.linear(1.3)),
        child: MaterialApp.router(theme: EvTheme.light(), routerConfig: router),
      ),
    ));
    for (var i = 0; i < 6; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await t.pump(const Duration(milliseconds: 100));
    }
    return b;
  }

  testWidgets('Business: no Delete account; Sign out stands alone', (t) async {
    final b = await open(t, const BusinessScreen());
    expect(find.text('This month'), findsOneWidget);
    expect(find.textContaining('Delete'), findsNothing);
    await t.scrollUntilVisible(find.text('Sign out'), 300, scrollable: find.byType(Scrollable).first);
    expect(find.text('Account & privacy'), findsOneWidget);
    expect(t.takeException(), isNull);
    b.dispose();
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('Account & privacy: deletion is last, in its own section', (t) async {
    final b = await open(t, const AccountScreen());
    await t.scrollUntilVisible(find.text('Delete account…'), 300, scrollable: find.byType(Scrollable).first);
    expect(find.text('Leaving Evenda'), findsOneWidget);
    expect(find.text('Sign out'), findsNothing);
    expect(t.takeException(), isNull);
    b.dispose();
    await t.pumpWidget(const SizedBox());
  });
}
