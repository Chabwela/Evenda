// UI audit harness. Opens every route through the real router with the demo
// businesses, on a 360 dp phone at 1.3x text, in light and dark, and records
// a screenshot plus any Flutter error per screen.
//
// Not part of the normal suite. Run with:
//   flutter test test/_audit --dart-define=AUDIT=true --update-goldens
// Screenshots land in test/_audit/shots/, findings in test/_audit/shots/report.txt.
import 'dart:io';

import 'package:evenda/app/providers.dart';
import 'package:evenda/app/router.dart';
import 'package:evenda/core/connectivity.dart';
import 'package:evenda/data/demo/demo_backend.dart';
import 'package:evenda/design/ev.dart';
import 'package:evenda/domain/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fonts.dart';

const _run = bool.fromEnvironment('AUDIT');
final _report = StringBuffer();

void main() {
  setUpAll(loadAppFonts);
  tearDownAll(() {
    if (!_run) return;
    Directory('test/_audit/shots').createSync(recursive: true);
    File('test/_audit/shots/report.txt').writeAsStringSync(_report.toString());
  });

  Future<void> settle(WidgetTester t, [int n = 8]) async {
    for (var i = 0; i < n; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await t.pump(const Duration(milliseconds: 300));
    }
  }

  Future<void> sweep(WidgetTester t, {required bool dark, required bool vendor}) async {
    EvColors.apply(dark ? EvPalette.darkPalette : EvPalette.light);
    t.view.physicalSize = const Size(1080, 2400);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final b = (await t.runAsync(() async {
      final b = DemoBackend();
      if (vendor) await b.auth.signIn('mutale@demo.evenda.zm', 'demo-vendor');
      return b;
    }))!;

    // Real ids from the demo data.
    final ids = vendor
        ? (await t.runAsync(() async {
            final me = (await b.business.mine())!;
            final listings = await b.listings.mine(me.id);
            final results = await b.discovery.search(me.id, const SearchQuery());
            final other = results.firstWhere((r) => r.listing.businessId != me.id).listing;
            final requests = await b.bookings.requests(me.id);
            final bookings = await b.bookings.bookings(me.id);
            final events = await b.work.events(me.id);
            final tasks = await b.work.tasks(me.id);
            final inbox = await b.now.inbox(me.id);
            return <String, String?>{
              'listing': other.id,
              'supplier': other.businessId,
              'mylisting': listings.firstOrNull?.id,
              'request': requests.firstOrNull?.id,
              'booking': bookings.firstOrNull?.id,
              'event': events.firstOrNull?.id,
              'task': tasks.firstOrNull?.id,
              'nowin': inbox.firstOrNull?.request.id,
            };
          }))!
        : const <String, String?>{};

    final container = ProviderContainer(overrides: [backendProvider.overrideWithValue(b), onlineProvider.overrideWith((ref) => Stream.value(true))]);
    addTearDown(container.dispose);
    container.read(launchIntroDoneProvider.notifier).set(true);
    final router = container.read(routerProvider);
    await t.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MediaQuery(
        data: const MediaQueryData(size: Size(360, 800), textScaler: TextScaler.linear(1.3)),
        child: MaterialApp.router(theme: EvTheme.light(), debugShowCheckedModeBanner: false, routerConfig: router),
      ),
    ));
    await settle(t);

    String? id(String k) => ids[k];
    final routes = vendor
        ? <String>[
            '/home', '/find', '/bookings', '/bookings?tab=sent', '/bookings?tab=confirmed', '/work', '/work?tab=calendar', '/business', '/notifications',
            if (id('listing') != null) '/listing/${id('listing')}',
            if (id('supplier') != null) '/supplier/${id('supplier')}',
            if (id('listing') != null) '/quote/new?supplier=${id('supplier')}&listing=${id('listing')}&qty=50',
            if (id('request') != null) '/bookings/request/${id('request')}',
            if (id('request') != null) '/bookings/request/${id('request')}/quote',
            if (id('booking') != null) '/bookings/${id('booking')}',
            '/work/event/new',
            if (id('event') != null) '/work/event/${id('event')}',
            if (id('task') != null) '/work/task/${id('task')}',
            '/business/account', '/business/delete-account', '/business/profile', '/business/stock/new',
            if (id('mylisting') != null) '/business/stock/${id('mylisting')}',
            '/business/listings', '/business/listings/new', '/business/inventory', '/business/availability', '/business/team', '/business/notifications',
            '/now', '/now/new',
            if (id('nowin') != null) '/now/respond/${id('nowin')}',
            if (id('nowin') != null) '/now/incoming/${id('nowin')}',
          ]
        : <String>['/welcome', '/auth/email', '/auth/signup', '/auth/forgot', '/auth/code?purpose=signup&email=a%40b.zm', '/auth/phone', '/admin/login'];

    for (final r in routes) {
      final errors = <String>[];
      final old = FlutterError.onError;
      FlutterError.onError = (d) => errors.add(d.exceptionAsString().split('\n').first);
      router.go(r);
      await settle(t, 6);
      FlutterError.onError = old;
      final name = '${dark ? 'dark' : 'light'}_${r.replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'_[a-z0-9-]{20,}'), '_id')}';
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('shots/$name.png'));
      _report.writeln('$name\t${router.routerDelegate.currentConfiguration.uri}\t${errors.isEmpty ? 'ok' : errors.toSet().join(' | ')}');
      t.takeException();
    }
    b.dispose();
    await t.pumpWidget(const SizedBox());
    EvColors.apply(EvPalette.light);
  }

  testWidgets('vendor screens, light', (t) => sweep(t, dark: false, vendor: true), skip: !_run);
  testWidgets('vendor screens, dark', (t) => sweep(t, dark: true, vendor: true), skip: !_run);
  testWidgets('signed-out screens, light', (t) => sweep(t, dark: false, vendor: false), skip: !_run);
  testWidgets('signed-out screens, dark', (t) => sweep(t, dark: true, vendor: false), skip: !_run);
}
