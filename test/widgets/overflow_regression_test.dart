import 'package:evenda/data/demo/demo_backend.dart';
import 'package:evenda/design/ev.dart';
import 'package:evenda/domain/models.dart';
import 'package:evenda/features/bookings/bookings_screen.dart';
import 'package:evenda/features/shared/feed_cards.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// Regression: the Find listing card and the incoming request row overflowed
/// on a 360 dp phone. Rendered here at 360 dp with 1.3× text (the app's cap).
void main() {
  Future<void> render(WidgetTester t, Widget child) async {
    t.view.physicalSize = const Size(1080, 2400);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, _) => Scaffold(body: ListView(children: [child]))),
    ]);
    await t.pumpWidget(MediaQuery(
      data: const MediaQueryData(size: Size(360, 800), textScaler: TextScaler.linear(1.3)),
      child: MaterialApp.router(theme: EvTheme.light(), routerConfig: router),
    ));
    await t.pump();
  }

  testWidgets('Find listing card fits with a long title and long business details', (t) async {
    final backend = DemoBackend();
    await backend.auth.signIn('mutale@demo.evenda.zm', 'demo-vendor');
    // The longest real title in the demo catalogue wraps to two lines.
    final listing = ((await backend.listings.mine('b-kabwata'))..sort((a, b) => b.title.length.compareTo(a.title.length))).first;
    backend.dispose();
    await render(t, ListingResultCard(result: SearchResult(listing: listing, available: 1240, distanceKm: 12.4)));
    expect(t.takeException(), isNull);
  });

  testWidgets('Incoming request row fits next to its status pill', (t) async {
    final backend = DemoBackend();
    await backend.auth.signIn('mutale@demo.evenda.zm', 'demo-vendor');
    final requests = await backend.bookings.requests('b-kabwata');
    backend.dispose();
    final incoming = requests.firstWhere((q) => q.supplier.id == 'b-kabwata' && q.status == QuoteRequestStatus.open,
        orElse: () => requests.first);
    await render(t, RequestRow(request: incoming, me: 'b-kabwata'));
    expect(t.takeException(), isNull);
  });
}
