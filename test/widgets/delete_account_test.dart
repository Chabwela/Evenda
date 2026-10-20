import 'package:evenda/app/providers.dart';
import 'package:evenda/data/demo/demo_backend.dart';
import 'package:evenda/design/ev.dart';
import 'package:evenda/features/business/delete_account_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../helpers/fonts.dart';

void main() {
  setUpAll(loadAppFonts);

  testWidgets('Delete account explains the outcome and stays locked until DELETE is typed', (t) async {
    t.view.physicalSize = const Size(1080, 2400);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final backend = DemoBackend();
    final router = GoRouter(routes: [GoRoute(path: '/', builder: (_, _) => const DeleteAccountScreen())]);
    await t.pumpWidget(ProviderScope(
      overrides: [backendProvider.overrideWithValue(backend)],
      child: MaterialApp.router(theme: EvTheme.light(), routerConfig: router),
    ));
    for (var i = 0; i < 5; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }

    expect(find.textContaining('permanently deletes'), findsOneWidget);
    expect(find.text('Deleted'), findsOneWidget); // section headers are sentence case
    expect(find.text('Kept, without your name'), findsOneWidget);

    final button = find.widgetWithText(EvButton, 'Delete my account permanently');
    await t.ensureVisible(button);
    expect(t.widget<EvButton>(button).onPressed, isNull, reason: 'locked before confirmation');

    await t.enterText(find.byType(TextFormField), 'delete');
    await t.pump();
    expect(t.widget<EvButton>(button).onPressed, isNull, reason: 'must be exactly DELETE');

    await t.enterText(find.byType(TextFormField), 'DELETE');
    await t.pump();
    expect(t.widget<EvButton>(button).onPressed, isNotNull, reason: 'unlocked after typing DELETE');

    expect(t.takeException(), isNull);
    backend.dispose();
  });
}
