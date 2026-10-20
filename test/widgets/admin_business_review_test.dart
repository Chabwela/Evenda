import 'package:evenda/app/providers.dart';
import 'package:evenda/core/connectivity.dart';
import 'package:evenda/data/backend.dart';
import 'package:evenda/data/demo/demo_backend.dart';
import 'package:evenda/design/ev.dart';
import 'package:evenda/domain/models.dart';
import 'package:evenda/features/admin/admin_business_review.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fonts.dart';

/// The review says whose move it is, judges the newest document of each type
/// (replaced ones fold away), and keeps suspend out of the everyday decision.
void main() {
  setUpAll(loadAppFonts);

  Map<String, dynamic> doc(String id, String type, String status, int day, {String? note}) => {
        'id': id,
        'doc_type': type,
        'storage_path': 'b/$id.jpg',
        'status': status,
        'created_at': DateTime.utc(2026, 10, day).toIso8601String(),
        'review_note': note,
        if (status != 'submitted') 'reviewed_at': DateTime.utc(2026, 10, day, 12).toIso8601String(),
        if (status != 'submitted') 'reviewed_by': 'Daniel (Evenda admin)',
      };

  AdminBusinessDetail detail(String verification, List<Map<String, dynamic>> docs) => AdminBusinessDetail({
        'id': 'b1',
        'name': 'Kabwata Party',
        'description': '',
        'primary_category': 'chairs',
        'neighbourhood': 'Avondale',
        'phone': '+260973978668',
        'whatsapp': '+260973978668',
        'service_radius_km': 25,
        'verification_status': verification,
        'status': 'active',
        'created_at': DateTime.utc(2026, 10, 18).toIso8601String(),
        'onboarding_completed_at': DateTime.utc(2026, 10, 18).toIso8601String(),
        'owner': {'name': 'Chabwela', 'email': 'owner@example.com', 'email_confirmed': true},
        'counts': {'listings': 0, 'published_listings': 0, 'bookings_as_supplier': 0, 'bookings_as_requester': 2, 'disputes': 1, 'flagged_listings': 0},
        'documents': docs,
        'team': [],
        'history': [],
      });

  Future<void> open(WidgetTester t, AdminBusinessDetail d) async {
    t.view.physicalSize = const Size(1080, 2400);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final backend = (await t.runAsync(() async => _Backend(_FakeAdmin(d))))!;
    addTearDown(backend.dispose);
    await t.pumpWidget(ProviderScope(
      overrides: [
        backendProvider.overrideWithValue(backend),
        onlineProvider.overrideWith((ref) => Stream.value(true)),
        adminSessionProvider.overrideWith((ref) async => const AdminSession(userId: 'a', role: AdminRole.superAdmin, displayName: 'Daniel')),
      ],
      child: MediaQuery(
        data: const MediaQueryData(size: Size(360, 800), textScaler: TextScaler.linear(1.3)),
        child: MaterialApp(theme: EvTheme.light(), home: const AdminBusinessReviewScreen(id: 'b1')),
      ),
    ));
    for (var i = 0; i < 4; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await t.pump(const Duration(milliseconds: 300));
    }
  }

  testWidgets('only document turned down: waiting for the vendor, no "your decision"', (t) async {
    await open(t, detail('pending', [doc('d1', 'pacra_certificate', 'rejected', 18, note: 'wrong documents')]));
    expect(find.text('Waiting for the vendor'), findsOneWidget);
    expect(find.textContaining('upload a replacement'), findsOneWidget);
    expect(find.text('Rejected'), findsOneWidget);
    expect(find.text('Accept instead'), findsOneWidget);
    expect(find.text('Send back'), findsOneWidget);
    expect(t.widget<EvButton>(find.widgetWithText(EvButton, 'Verify')).onPressed, isNull);
    expect(find.text('Suspend account'), findsNothing); // in the ⋮ menu, not the bar
    expect(t.takeException(), isNull);
  });

  testWidgets('replacement arrives: it is the one to judge, the old one folds away', (t) async {
    await open(t, detail('pending', [
      doc('d1', 'pacra_certificate', 'rejected', 18, note: 'wrong documents'),
      doc('d2', 'pacra_certificate', 'submitted', 20),
    ]));
    expect(find.text('Documents to review'), findsOneWidget);
    expect(find.text('Replacement'), findsOneWidget);
    expect(find.text('Accept'), findsOneWidget);
    expect(find.text('Earlier uploads (1)'), findsOneWidget);
    expect(find.text('“wrong documents”'), findsNothing); // folded
    expect(t.takeException(), isNull);
  });

  testWidgets('accepted document: ready to verify, suspend lives in the menu', (t) async {
    await open(t, detail('pending', [doc('d2', 'pacra_certificate', 'accepted', 20)]));
    expect(find.text('Ready to verify'), findsOneWidget);
    expect(t.widget<EvButton>(find.widgetWithText(EvButton, 'Verify')).onPressed, isNotNull);
    await t.tap(find.byTooltip('More actions'));
    await t.pumpAndSettle();
    expect(find.text('Suspend account'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}

class _Backend extends DemoBackend {
  _Backend(this._admin);
  final AdminApi _admin;
  @override
  AdminApi get admin => _admin;
}

/// Only what the review screen calls; anything else fails loudly.
class _FakeAdmin implements AdminApi {
  _FakeAdmin(this.d);
  final AdminBusinessDetail d;
  @override
  AdminSession? get current => const AdminSession(userId: 'a', role: AdminRole.superAdmin, displayName: 'Daniel');
  @override
  Future<AdminBusinessDetail> businessDetail(String businessId) async => d;
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}
