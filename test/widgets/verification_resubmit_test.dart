import 'dart:typed_data';

import 'package:evenda/app/providers.dart';
import 'package:evenda/core/connectivity.dart';
import 'package:evenda/data/demo/demo_backend.dart';
import 'package:evenda/design/ev.dart';
import 'package:evenda/domain/models.dart';
import 'package:evenda/features/business/profile_screen.dart';
import 'package:evenda/features/business/verification_docs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../helpers/fonts.dart';

/// After Evenda turns verification down, the vendor sees why, can replace what
/// was rejected, and can send it again only once something new has arrived.
void main() {
  setUpAll(loadAppFonts);

  VerificationDocument rejectedPacra(String biz) => VerificationDocument({
        'id': 'doc-old',
        'doc_type': 'pacra_certificate',
        'storage_path': '$biz/old.jpg',
        'status': 'rejected',
        'review_note': 'Photo is blurry, the registration number can’t be read',
        'created_at': DateTime.utc(2026, 10, 18).toIso8601String(),
      });

  Future<(DemoBackend, String)> signedIn(WidgetTester t) async => (await t.runAsync(() async {
        final b = DemoBackend();
        await b.auth.signIn('mutale@demo.evenda.zm', 'demo-vendor');
        return (b, (await b.business.mine())!.id);
      }))!;

  Future<void> pump(WidgetTester t, DemoBackend backend, Widget screen) async {
    t.view.physicalSize = const Size(1080, 2400);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final router = GoRouter(routes: [GoRoute(path: '/', builder: (_, _) => screen)]);
    await t.pumpWidget(ProviderScope(
      overrides: [backendProvider.overrideWithValue(backend), onlineProvider.overrideWith((ref) => Stream.value(true))],
      child: MediaQuery(
        data: const MediaQueryData(size: Size(360, 800), textScaler: TextScaler.linear(1.3)),
        child: MaterialApp.router(theme: EvTheme.light(), routerConfig: router),
      ),
    ));
    for (var i = 0; i < 8; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await t.pump(const Duration(milliseconds: 400));
    }
  }

  testWidgets('rejected business: reason, what to fix, resubmit waits for a new document', (t) async {
    final (b, id) = await signedIn(t);
    b.db.businesses[id] = b.db.businesses[id]!.copyWith(verification: VerificationStatus.rejected);
    b.db.verificationNotes[id] = 'The certificate name doesn’t match the business name';
    b.db.verificationDocs[id] = [rejectedPacra(id)];
    await pump(t, b, const BusinessProfileScreen());

    expect(find.text('What to fix'), findsOneWidget);
    expect(find.textContaining('name doesn’t match'), findsOneWidget);
    expect(find.textContaining('registration number can’t be read'), findsWidgets);
    await t.scrollUntilVisible(find.text('Send for review again'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('Replace'), findsOneWidget);
    expect(find.text('Upload a new document first.'), findsOneWidget);
    final send = t.widget<EvButton>(find.widgetWithText(EvButton, 'Send for review again'));
    expect(send.onPressed, isNull);

    // A new PACRA arrives on the server: sending again becomes possible.
    await t.runAsync(() => b.business.uploadVerificationDocument(id, 'pacra_certificate', Uint8List(10), 'pdf'));
    for (var i = 0; i < 4; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await t.pump(const Duration(milliseconds: 400));
    }
    await t.scrollUntilVisible(find.text('Send for review again'), -200, scrollable: find.byType(Scrollable).first);
    expect(t.widget<EvButton>(find.widgetWithText(EvButton, 'Send for review again')).onPressed, isNotNull);
    expect(t.takeException(), isNull);
    b.dispose();
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('in review: a turned-down document can still be replaced', (t) async {
    final (b, id) = await signedIn(t);
    b.db.verificationDocs[id] = [rejectedPacra(id)];
    Future<PickedDocument?> pick(BuildContext c, {String title = ''}) async => (bytes: Uint8List(10), ext: 'pdf', name: 'new.pdf');
    await pump(
        t,
        b,
        Scaffold(
          body: ListView(children: [VerificationDocsSection(businessId: id, locked: true, allowReplacingRejected: true, picker: pick)]),
        ));
    expect(find.text('Replace'), findsOneWidget);
    expect(find.text('Upload'), findsNothing); // other types stay locked while in review
    await t.tap(find.text('Replace'));
    for (var i = 0; i < 6; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await t.pump(const Duration(milliseconds: 400));
    }
    expect(find.text('Uploaded · waiting for review'), findsOneWidget);
    expect(t.takeException(), isNull);
    b.dispose();
    await t.pumpWidget(const SizedBox());
  });
}
