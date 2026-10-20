import 'package:evenda/app/providers.dart';
import 'package:evenda/core/connectivity.dart';
import 'package:evenda/data/backend.dart';
import 'package:evenda/data/demo/demo_backend.dart';
import 'package:evenda/design/ev.dart';
import 'package:evenda/domain/models.dart';
import 'package:evenda/features/admin/admin_dispute_case.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fonts.dart';

/// A dispute opens as a case file and is ruled with a decision, a booking
/// outcome and words both businesses read; nothing is pre-chosen.
void main() {
  setUpAll(loadAppFonts);

  testWidgets('open dispute: case file, take the case, ruling needs every part', (t) async {
    t.view.physicalSize = const Size(1080, 2400);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final admin = _FakeAdmin();
    final backend = (await t.runAsync(() async {
      final b = _Backend(admin);
      await b.auth.signIn('mutale@demo.evenda.zm', 'demo-vendor');
      final booking = (await b.bookings.bookings((await b.business.mine())!.id)).first;
      admin.dispute = Dispute(
        id: 'disp1',
        bookingId: booking.id,
        reason: 'Only 6 of the 10 table linens arrived and two were stained.',
        status: 'open',
        createdAt: DateTime.now().subtract(const Duration(days: 3)),
        bookingReference: booking.reference,
        openedBy: booking.requester.name,
        openedByBusinessId: booking.requester.id,
      );
      return b;
    }))!;
    addTearDown(backend.dispose);

    await t.pumpWidget(ProviderScope(
      overrides: [
        backendProvider.overrideWithValue(backend),
        onlineProvider.overrideWith((ref) => Stream.value(true)),
        adminSessionProvider.overrideWith((ref) async => const AdminSession(userId: 'a', role: AdminRole.superAdmin, displayName: 'Daniel')),
      ],
      child: MediaQuery(
        data: const MediaQueryData(size: Size(360, 800), textScaler: TextScaler.linear(1.3)),
        child: MaterialApp(theme: EvTheme.light(), home: const AdminDisputeCaseScreen(id: 'disp1')),
      ),
    ));
    for (var i = 0; i < 6; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await t.pump(const Duration(milliseconds: 400));
    }

    expect(find.text('Waiting for your ruling'), findsOneWidget);
    expect(find.textContaining('6 of the 10 table linens'), findsOneWidget);
    expect(find.textContaining('opened the dispute'), findsOneWidget);
    expect(find.text('Take the case'), findsOneWidget);

    await t.tap(find.text('Take the case'));
    await t.pump();
    expect(admin.taken, isTrue);

    await t.tap(find.text('Rule'));
    await t.pumpAndSettle();
    Finder issue() => find.widgetWithText(EvButton, 'Issue ruling');
    expect(t.widget<EvButton>(issue()).onPressed, isNull);
    await t.tap(find.text('Uphold the complaint'));
    await t.ensureVisible(find.text('Cancel the booking'));
    await t.tap(find.text('Cancel the booking'));
    await t.pump();
    expect(t.widget<EvButton>(issue()).onPressed, isNull); // still no ruling text
    await t.enterText(find.byType(TextFormField), 'Supplier delivered short and stained linen; booking cancelled, refund the deposit.');
    await t.pump();
    await t.ensureVisible(issue());
    expect(t.widget<EvButton>(issue()).onPressed, isNotNull);
    await t.tap(issue());
    await t.pump();
    expect(admin.ruled, ('resolved', 'cancel'));
    expect(t.takeException(), isNull);
    await t.pump(const Duration(seconds: 6)); // let the confirmation toast finish
    await t.pumpWidget(const SizedBox());
  });
}

class _Backend extends DemoBackend {
  _Backend(this._admin);
  final AdminApi _admin;
  @override
  AdminApi get admin => _admin;
}

class _FakeAdmin implements AdminApi {
  late Dispute dispute;
  bool taken = false;
  (String, String)? ruled;
  @override
  AdminSession? get current => const AdminSession(userId: 'a', role: AdminRole.superAdmin, displayName: 'Daniel');
  @override
  Future<List<Dispute>> disputes() async => [dispute];
  @override
  Future<List<AuditEntry>> auditLog() async => const [];
  @override
  Future<void> takeDispute(String disputeId, {String? note}) async => taken = true;
  @override
  Future<void> ruleDispute(String disputeId, {required String decision, required String ruling, required String bookingOutcome}) async =>
      ruled = (decision, bookingOutcome);
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}
