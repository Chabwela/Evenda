import 'package:evenda/design/ev.dart';
import 'package:evenda/domain/models.dart';
import 'package:evenda/features/shared/feed_cards.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression: the Find listing card overflowed at the bottom (fixed 112 px
/// text column) with a two-line title on a 360 dp phone.
void main() {
  for (final scale in [1.0, 1.3]) {
    testWidgets('ListingResultCard fits a long listing at text scale $scale', (t) async {
      t.view.physicalSize = const Size(1080, 2400);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);

      final listing = Listing(
        id: 'l1',
        businessId: 'b1',
        kind: OfferingType.rental,
        title: 'Premium white satin table linens with gold embroidered runners',
        categoryId: 'linen',
        status: ListingStatus.published,
        priceAmount: 1250,
        priceUnit: PriceUnit.perItemPerEvent,
        totalQuantity: 400,
        business: const BizRef(id: 'b1', name: 'Feluna Events And Design Lusaka Limited', neighbourhood: 'Kabulonga', verified: true),
      );

      await t.pumpWidget(MaterialApp(
        theme: EvTheme.light(),
        home: MediaQuery(
          data: MediaQueryData(size: const Size(360, 800), textScaler: TextScaler.linear(scale)),
          child: Scaffold(
            body: ListView(children: [
              ListingResultCard(result: SearchResult(listing: listing, available: 400, distanceKm: 12.4)),
              ListingResultCard(result: SearchResult(listing: listing)),
            ]),
          ),
        ),
      ));
      await t.pump();
      expect(t.takeException(), isNull);
      expect(find.text('400 free'), findsOneWidget);
    });
  }
}
