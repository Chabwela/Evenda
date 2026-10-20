import 'dart:typed_data';

import 'package:evenda/app/providers.dart';
import 'package:evenda/core/connectivity.dart';
import 'package:evenda/data/demo/demo_backend.dart';
import 'package:evenda/design/ev.dart';
import 'package:evenda/features/business/verification_docs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fonts.dart';

/// A document row says "Uploading" while the file travels, "Uploaded" only once
/// the server lists it, and "Didn't upload" with Retry when it fails.
void main() {
  setUpAll(loadAppFonts);

  Future<PickedDocument?> fakePick(BuildContext context, {String title = ''}) async =>
      (bytes: Uint8List.fromList(List.filled(2048, 1)), ext: 'pdf', name: 'pacra.pdf');

  Future<(DemoBackend, String)> open(WidgetTester t, {String? businessId}) async {
    t.view.physicalSize = const Size(1080, 2400);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final (backend, id) = (await t.runAsync(() async {
      final b = DemoBackend();
      await b.auth.signIn('mutale@demo.evenda.zm', 'demo-vendor');
      return (b, (await b.business.mine())!.id);
    }))!;
    final target = businessId ?? id;
    await t.pumpWidget(ProviderScope(
      overrides: [backendProvider.overrideWithValue(backend), onlineProvider.overrideWith((ref) => Stream.value(true))],
      child: MaterialApp(
        theme: EvTheme.light(),
        home: MediaQuery(
          data: const MediaQueryData(size: Size(360, 800), textScaler: TextScaler.linear(1.3)),
          child: Scaffold(body: ListView(children: [VerificationDocsSection(businessId: target, picker: fakePick)])),
        ),
      ),
    ));
    await settle(t);
    return (backend, target);
  }

  testWidgets('upload: Uploading… then Uploaded once the server has it', (t) async {
    final (b, _) = await open(t);
    expect(find.text('Upload'), findsNWidgets(3));

    await t.tap(find.text('Upload').first);
    await t.pump();
    await t.pump();
    expect(find.textContaining('Uploading pacra.pdf'), findsOneWidget);
    expect(find.text('Uploaded · waiting for review'), findsNothing);

    await settle(t);
    expect(find.textContaining('Uploading'), findsNothing);
    expect(find.text('Uploaded · waiting for review'), findsOneWidget);
    expect(find.text('Add'), findsOneWidget);
    expect(find.text('Upload'), findsNWidgets(2));
    expect(t.takeException(), isNull);
    b.dispose();
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('failure: never says uploaded, offers Retry', (t) async {
    // A business this vendor doesn't manage: the server refuses the upload.
    final (b, _) = await open(t, businessId: 'not-my-business');
    await t.tap(find.text('Upload').first);
    await t.pump();
    await settle(t);
    expect(find.textContaining('Didn’t upload'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Uploaded · waiting for review'), findsNothing);
    expect(t.takeException(), isNull);
    b.dispose();
    await t.pumpWidget(const SizedBox());
  });
}

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 6; i++) {
    // Demo latency runs on real timers when started inside runAsync and on the
    // fake clock when started by a tap: advance both.
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await t.pump(const Duration(milliseconds: 400));
  }
}
