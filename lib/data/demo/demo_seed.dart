import 'package:latlong2/latlong.dart';

import '../../core/format.dart';
import '../../domain/models.dart';
import 'demo_db.dart';

/// Demo personas: fictional Lusaka event businesses. Neighbourhoods and their
/// coordinates are real; the businesses, people and prices are illustrative.
class DemoPersona {
  const DemoPersona(this.userId, this.businessId, this.person, this.role);
  final String userId;
  final String businessId;
  final String person;
  final String role;
}

const kDemoPersonas = [
  DemoPersona('u-kabwata', 'b-kabwata', 'Mutale Banda', 'Tent, chair & table hire'),
  DemoPersona('u-lilac', 'b-lilac', 'Chipo Mwale', 'Décor & event styling'),
  DemoPersona('u-woodlands', 'b-woodlands', 'Bwalya Zulu', 'Sound, lighting & DJ'),
  DemoPersona('u-roma', 'b-roma', 'Grace Mulenga', 'Chairs, tables & linen'),
  DemoPersona('u-ibex', 'b-ibex', 'Thandiwe Ngoma', 'Planning & coordination'),
];

String _img(String name) => 'asset:assets/images/$name.jpg';

void seedDemo(DemoDb db) {
  final today = EvDates.today();
  DateTime d(int days) => today.add(Duration(days: days));
  DateTime at(int days, int hour, [int minute = 0]) => DateTime(today.year, today.month, today.day + days, hour, minute);
  final daysToSat = (DateTime.saturday - today.weekday) % 7;
  final sat = d(daysToSat == 0 ? 7 : daysToSat);
  final satOffset = sat.difference(today).inDays;

  // ---------------------------------------------------------------- businesses
  void biz(String id, String owner, String person, String name, String hood, String primary, List<String> cats,
      Set<OfferingType> offers, String phone, String desc,
      {VerificationStatus v = VerificationStatus.verified, double dLat = 0, double dLng = 0, int radius = 30, LocationPrecision precision = LocationPrecision.approximate}) {
    final n = kNeighbourhoods.firstWhere((x) => x.name == hood);
    db.users[owner] = Session(userId: owner, phone: phone, fullName: person, isDemo: true);
    db.userBusiness[owner] = id;
    db.businesses[id] = Business(
      id: id,
      ownerId: owner,
      name: name,
      description: desc,
      primaryCategory: primary,
      categories: cats,
      offeringTypes: offers,
      phone: phone,
      whatsapp: phone,
      neighbourhood: hood,
      location: LatLng(n.lat + dLat, n.lng + dLng),
      locationPrecision: precision,
      serviceRadiusKm: radius,
      operatingHours: const {'mon': '08:00-17:30', 'tue': '08:00-17:30', 'wed': '08:00-17:30', 'thu': '08:00-17:30', 'fri': '08:00-17:30', 'sat': '07:00-14:00', 'sun': 'closed'},
      onboardingStep: 6,
      onboardingCompleted: true,
      verification: v,
      createdAt: today.subtract(const Duration(days: 120)),
    );
    db.team[id] = [TeamMember(id: 'm-$id', displayName: person, role: MemberRole.owner, userId: owner, phone: phone)];
    db.prefs[id] = NotificationPrefs(subscribedCategories: cats.toSet());
  }

  biz('b-kabwata', 'u-kabwata', 'Mutale Banda', 'Kabwata Party Hire', 'Kabwata', 'chairs', ['chairs', 'tents', 'tables', 'linen'],
      {OfferingType.rental}, '+260971234501',
      'Tents, chairs, tables and linen for weddings, kitchen parties and funerals across Lusaka since 2014. Yard open six days a week.',
      dLat: 0.002, dLng: -0.003, radius: 40);
  biz('b-lilac', 'u-lilac', 'Chipo Mwale', 'Lilac & Linen Décor', 'Kabulonga', 'styling', ['styling', 'decor', 'centrepieces'],
      {OfferingType.service, OfferingType.rental}, '+260966234502',
      'Wedding and corporate styling: backdrops, centrepieces and full venue transformations. We work with your venue’s furniture.',
      dLat: -0.003, dLng: 0.002);
  biz('b-woodlands', 'u-woodlands', 'Bwalya Zulu', 'Woodlands Sound & Light', 'Woodlands', 'sound', ['sound', 'lighting', 'dj_mc'],
      {OfferingType.rental, OfferingType.service}, '+260977234503',
      'PA systems, stage lighting and DJs for receptions up to 600 guests. Technician included on every hire.',
      dLat: 0.004, dLng: 0.001);
  biz('b-chilenje', 'u-chilenje', 'Joseph Tembo', 'Chilenje Chairs & Canopies', 'Chilenje', 'chairs', ['chairs', 'tents'],
      {OfferingType.rental}, '+260955234504', 'Affordable plastic chairs and gazebo canopies. Same-day collection from our Chilenje yard.',
      v: VerificationStatus.pending, dLat: -0.002, dLng: 0.003, radius: 20);
  biz('b-roma', 'u-roma', 'Grace Mulenga', 'Roma Event Rentals', 'Roma', 'chairs', ['chairs', 'tables', 'linen'],
      {OfferingType.rental}, '+260976234505', 'Chiavari chairs, trestle tables and premium linen for elegant receptions.',
      dLat: 0.001, dLng: 0.004);
  biz('b-makeni', 'u-makeni', 'Peter Daka', 'Makeni Marquee Masters', 'Makeni', 'tents', ['tents', 'staging'],
      {OfferingType.rental}, '+260965234506', 'Stretch tents and frame marquees from 50 to 800 guests, installed by our own crew.',
      radius: 60);
  biz('b-chanda', 'u-chanda', 'Mary Chanda', 'Mama Chanda’s Kitchen', 'Chelston', 'catering', ['catering', 'catering_equip'],
      {OfferingType.service, OfferingType.rental}, '+260975234507', 'Zambian and continental buffets for 50–500 guests. Chafing dishes available for hire.',
      dLat: 0.003, dLng: -0.002);
  biz('b-petals', 'u-petals', 'Natasha Lungu', 'Petals by Natasha', 'Rhodes Park', 'florist', ['florist', 'centrepieces'],
      {OfferingType.service, OfferingType.rental}, '+260967234508', 'Fresh bridal flowers and table arrangements, sourced locally each week.',
      dLat: -0.001, dLng: -0.002);
  biz('b-lens', 'u-lens', 'Kelvin Sakala', 'Northmead Lens Studio', 'Northmead', 'photo_video', ['photo_video'],
      {OfferingType.service}, '+260978234509', 'Wedding photography and highlight films. Two shooters on full-day packages.');
  biz('b-ibex', 'u-ibex', 'Thandiwe Ngoma', 'Ibex Hill Events Co.', 'Ibex Hill', 'planning', ['planning'],
      {OfferingType.service}, '+260969234510', 'Full planning and day-of coordination. We source from trusted Lusaka suppliers.',
      dLat: 0.002, dLng: 0.002);
  biz('b-matero', 'u-matero', 'Moses Banda', 'Matero Hire Centre', 'Matero', 'chairs', ['chairs', 'tables'],
      {OfferingType.rental}, '+260954234511', 'Bulk chairs and tables at community prices. Funeral packages available.',
      v: VerificationStatus.unverified, radius: 25);
  biz('b-avondale', 'u-avondale', 'Ruth Kunda', 'Avondale Stage & Truss', 'Avondale', 'staging', ['staging', 'lighting'],
      {OfferingType.rental}, '+260974234512', 'Stage platforms, truss and lighting rigs for concerts, launches and church events.',
      dLat: -0.002, dLng: -0.001);

  // ------------------------------------------------------------------ listings
  Listing l(String id, String biz, OfferingType kind, String title, String cat, double? price, PriceUnit unit, int qty, List<String> photos,
      {String desc = '', double? deposit, String terms = '', String? condition = 'excellent', bool tracks = true, ListingStatus status = ListingStatus.published, int damaged = 0, int inspection = 0}) {
    final listing = Listing(
      id: id,
      businessId: biz,
      kind: kind,
      title: title,
      categoryId: cat,
      description: desc,
      status: status,
      priceAmount: price,
      priceUnit: unit,
      depositAmount: deposit,
      terms: terms,
      condition: kind == OfferingType.service ? null : condition,
      totalQuantity: qty,
      damagedQuantity: damaged,
      inspectionQuantity: inspection,
      tracksStock: tracks,
      photos: photos.map(_img).toList(),
      publishedAt: status == ListingStatus.published ? today.subtract(const Duration(days: 30)) : null,
      updatedAt: today.subtract(const Duration(days: 2)),
    );
    db.listings[id] = listing;
    db.stockLedger.add((id, qty, 'initial', today.subtract(const Duration(days: 60))));
    return listing;
  }

  const hireTerms = 'Collection from our yard unless delivery is agreed in the quotation. Items are counted out and back in; '
      'missing or damaged items are charged at replacement cost.';

  l('l-folding', 'b-kabwata', OfferingType.rental, 'Folding banquet chairs', 'chairs', 12, PriceUnit.perItemPerDay, 320,
      ['folding_chairs', 'marquee_chairs'],
      desc: 'Steel-frame folding chairs with padded seats. Stack of 10 per bundle, easy to load.', deposit: 500, terms: hireTerms);
  l('l-chiavari-gold', 'b-kabwata', OfferingType.rental, 'Gold Chiavari chairs', 'chairs', 35, PriceUnit.perItemPerEvent, 180,
      ['chiavari_chair', 'marquee_chairs'],
      desc: 'Resin Chiavari chairs in gold with ivory seat pads. Ideal for wedding receptions and head tables.',
      deposit: 1000, terms: hireTerms, damaged: 12);
  l('l-marquee', 'b-kabwata', OfferingType.rental, 'Pole marquee 10 × 20 m', 'tents', 5500, PriceUnit.perItemPerEvent, 3,
      ['pole_tent', 'marquee_chairs'],
      desc: 'Seats up to 200 guests at round tables. Price includes erection and take-down by our crew within Lusaka.',
      deposit: 2000, terms: hireTerms, condition: 'good');
  l('l-round-tables', 'b-kabwata', OfferingType.rental, 'Round banquet tables, 10-seater', 'tables', 85, PriceUnit.perItemPerDay, 40,
      ['tent_round_table', 'table_setting'], desc: '1.8 m round tables. Linen hired separately.', terms: hireTerms);
  l('l-covers', 'b-kabwata', OfferingType.rental, 'Chair covers with satin sash', 'linen', 10, PriceUnit.perItemPerEvent, 300,
      ['chair_sashes'], desc: 'White spandex covers with your choice of sash colour: gold, blush, emerald or navy.', terms: hireTerms);

  l('l-styling', 'b-lilac', OfferingType.service, 'Full wedding styling', 'styling', 18000, PriceUnit.perEvent, 1,
      ['backdrop_lights', 'table_setting', 'centrepiece'],
      desc: 'Concept, backdrop, head table, centrepieces and ceiling décor for receptions up to 250 guests. We style around the venue’s furniture.',
      tracks: true, terms: '50% deposit secures the date. Balance due 7 days before the event.');
  l('l-backdrop', 'b-lilac', OfferingType.rental, 'Fairy-light backdrop wall, 6 m', 'decor', 2800, PriceUnit.perItemPerEvent, 4,
      ['backdrop_lights'], desc: 'Draped frame with warm-white fairy lights. Setup included within 20 km.', deposit: 1000);
  l('l-centrepieces', 'b-lilac', OfferingType.rental, 'Floral glass centrepieces', 'centrepieces', 180, PriceUnit.perItemPerEvent, 60,
      ['centrepiece', 'table_setting'], desc: 'Tall glass vases with silk florals and floating candles.');
  l('l-pompom', 'b-lilac', OfferingType.rental, 'Paper pom-pom ceiling set', 'decor', 650, PriceUnit.perItemPerEvent, 10,
      ['pompom_decor'], desc: 'Set of 30 honeycomb balls and pom-poms in your palette.', condition: 'good');

  l('l-pa', 'b-woodlands', OfferingType.rental, 'PA system, 2 tops + sub', 'sound', 2500, PriceUnit.perItemPerEvent, 6,
      ['pa_speakers', 'sound_mixer'], desc: 'Covers up to 300 guests. Includes 2 wireless mics, mixer and a technician for setup.', deposit: 1500);
  l('l-lighting', 'b-woodlands', OfferingType.rental, 'Stage wash lighting kit', 'lighting', 1800, PriceUnit.perEvent, 5,
      ['stage_lights'], desc: '8 LED par cans on two stands with DMX controller.');
  l('l-dj', 'b-woodlands', OfferingType.service, 'DJ for receptions (with sound)', 'dj_mc', 4500, PriceUnit.perEvent, 2,
      ['sound_mixer', 'pa_speakers'], desc: 'Up to 6 hours. MC services available on request.');

  l('l-plastic-chilenje', 'b-chilenje', OfferingType.rental, 'White plastic chairs', 'chairs', 8, PriceUnit.perItemPerDay, 500,
      ['folding_chairs'], desc: 'Stackable white chairs. Bundles of 20.', condition: 'good');
  l('l-gazebo', 'b-chilenje', OfferingType.rental, 'Gazebo canopy 3 × 3 m', 'tents', 450, PriceUnit.perItemPerDay, 12, ['pole_tent']);

  l('l-chiavari-white', 'b-roma', OfferingType.rental, 'White Chiavari chairs', 'chairs', 40, PriceUnit.perItemPerEvent, 150,
      ['marquee_chairs', 'chiavari_chair'], desc: 'White resin Chiavari chairs with cushions.', deposit: 800);
  l('l-trestle', 'b-roma', OfferingType.rental, 'Trestle tables with linen', 'tables', 70, PriceUnit.perItemPerDay, 60, ['table_setting']);
  l('l-cloths', 'b-roma', OfferingType.rental, 'Ivory round tablecloths', 'linen', 25, PriceUnit.perItemPerEvent, 120, ['table_setting']);

  l('l-stretch', 'b-makeni', OfferingType.rental, 'Stretch tent 15 × 10 m', 'tents', 6800, PriceUnit.perItemPerEvent, 2,
      ['pole_tent'], desc: 'Seats 150. Installed by our crew.', deposit: 3000);
  l('l-frame', 'b-makeni', OfferingType.rental, 'Frame marquee 20 × 30 m', 'tents', 14000, PriceUnit.perItemPerEvent, 1,
      ['marquee_chairs', 'pole_tent'], desc: 'Clear-span marquee for up to 600 guests with lining and side walls.', deposit: 5000);

  l('l-buffet', 'b-chanda', OfferingType.service, 'Wedding buffet catering (per guest)', 'catering', 220, PriceUnit.perItemPerEvent, 2,
      ['catering'], desc: 'Two starches, three proteins, relish, salads and a dessert. Service staff included.');
  l('l-chafing', 'b-chanda', OfferingType.rental, 'Stainless chafing dishes', 'catering_equip', 75, PriceUnit.perItemPerDay, 40, ['catering']);

  l('l-bouquet', 'b-petals', OfferingType.service, 'Bridal bouquet & party flowers', 'florist', 1200, PriceUnit.perPackage, 3, ['florals']);
  l('l-fresh-centre', 'b-petals', OfferingType.rental, 'Fresh flower centrepieces', 'centrepieces', 250, PriceUnit.perItemPerEvent, 40,
      ['centrepiece', 'florals']);

  l('l-photo', 'b-lens', OfferingType.service, 'Wedding photography, full day', 'photo_video', 9500, PriceUnit.perEvent, 1,
      ['backdrop_lights', 'table_setting'], desc: 'Two photographers, 400+ edited photos delivered within three weeks.');
  l('l-coord', 'b-ibex', OfferingType.service, 'Day-of coordination', 'planning', 6000, PriceUnit.perEvent, 2, ['marquee_chairs']);

  l('l-plastic-matero', 'b-matero', OfferingType.rental, 'Plastic chairs (bulk)', 'chairs', 7, PriceUnit.perItemPerDay, 600, ['folding_chairs'], condition: 'fair');
  l('l-rect-matero', 'b-matero', OfferingType.rental, 'Rectangular tables', 'tables', 50, PriceUnit.perItemPerDay, 80, ['tent_round_table'], condition: 'good');

  l('l-stage', 'b-avondale', OfferingType.rental, 'Stage platform 6 × 4 m', 'staging', 4200, PriceUnit.perItemPerEvent, 2, ['stage_lights']);
  l('l-truss', 'b-avondale', OfferingType.rental, 'Truss with par-can lighting', 'lighting', 2200, PriceUnit.perItemPerEvent, 4, ['stage_lights']);

  // A draft and a paused listing for Kabwata so lifecycle states are visible.
  l('l-drape', 'b-kabwata', OfferingType.rental, 'Ceiling drapes for marquees', 'decor', null, PriceUnit.onQuote, 0, ['marquee_chairs'],
      status: ListingStatus.draft, tracks: true);
  l('l-heaters', 'b-kabwata', OfferingType.rental, 'Patio gas heaters', 'tents', 350, PriceUnit.perItemPerDay, 6, [],
      status: ListingStatus.paused, condition: 'good');

  // -------------------------------------------------------------- follows
  db.follows['b-kabwata'] = {
    'b-roma': SupplierFollow(supplier: db.ref('b-roma')),
    'b-makeni': SupplierFollow(supplier: db.ref('b-makeni')),
    'b-matero': SupplierFollow(supplier: db.ref('b-matero'), muted: true),
  };
  db.follows['b-lilac'] = {
    'b-kabwata': SupplierFollow(supplier: db.ref('b-kabwata')),
    'b-petals': SupplierFollow(supplier: db.ref('b-petals')),
  };

  // ----------------------------------------------------------- reservations
  // Kabwata already has 100 folding chairs out on Saturday, so a 300-chair
  // request leaves a shortfall of 80: the scenario Evenda Now exists for.
  db.reservations.add(Reservation(
    id: 'r-1', listingId: 'l-folding', quantity: 100, startsOn: sat, endsOn: sat, source: ReservationSource.manual,
    status: ReservationStatus.confirmed, clientLabel: 'Kabwata UCZ fundraiser', note: 'Collected Friday afternoon', listingTitle: 'Folding banquet chairs'));
  db.reservations.add(Reservation(
    id: 'r-2', listingId: 'l-marquee', quantity: 1, startsOn: sat, endsOn: sat, source: ReservationSource.manual,
    status: ReservationStatus.confirmed, clientLabel: 'Mwansa & Bwalya wedding', listingTitle: 'Pole marquee 10 × 20 m'));
  // Chiavari: 175 committed against 168 usable (12 damaged) in 9 days -> conflict.
  db.reservations.add(Reservation(
    id: 'r-3', listingId: 'l-chiavari-gold', quantity: 175, startsOn: d(9), endsOn: d(9), source: ReservationSource.manual,
    status: ReservationStatus.confirmed, clientLabel: 'Longacres Lodge corporate dinner', listingTitle: 'Gold Chiavari chairs'));
  db.reservations.add(Reservation(
    id: 'r-4', listingId: 'l-folding', quantity: 80, startsOn: d(3), endsOn: d(3), source: ReservationSource.manual,
    status: ReservationStatus.confirmed, clientLabel: 'Chikondi kitchen party', listingTitle: 'Folding banquet chairs'));
  db.reservations.add(Reservation(
    id: 'r-5', listingId: 'l-pa', quantity: 4, startsOn: sat, endsOn: sat, source: ReservationSource.manual,
    status: ReservationStatus.confirmed, clientLabel: 'Two weddings', listingTitle: 'PA system, 2 tops + sub'));

  // -------------------------------------------------------------- bookings
  Booking booking(String id, String ref, String requester, String supplier, DateTime from, DateTime to, BookingStatus status,
      List<BookingItem> items, {PaymentStatus pay = PaymentStatus.unpaid, double deposit = 0, Fulfilment f = Fulfilment.pickup, String? requestId}) {
    final b = Booking(
      id: id,
      reference: ref,
      source: BookingSource.quotation,
      requester: db.ref(requester),
      supplier: db.ref(supplier),
      startsOn: from,
      endsOn: to,
      status: status,
      paymentStatus: pay,
      total: items.fold(0, (s, i) => s + i.lineTotal),
      depositAmount: deposit,
      fulfilment: f,
      createdAt: today.subtract(const Duration(days: 6)),
      requestId: requestId,
      items: items,
      history: [
        BookingEvent(to: BookingStatus.confirmed, at: today.subtract(const Duration(days: 6)), note: 'Quotation v1 accepted'),
        if (status != BookingStatus.confirmed) BookingEvent(from: BookingStatus.confirmed, to: status, at: today.subtract(const Duration(days: 1))),
      ],
    );
    db.bookings[id] = b;
    for (final i in items) {
      if (i.listingId != null && status.isActive && !to.isBefore(today)) {
        db.reservations.add(Reservation(
          id: newId(), listingId: i.listingId!, quantity: i.quantity, startsOn: from, endsOn: to, source: ReservationSource.booking,
          status: status == BookingStatus.dispatched ? ReservationStatus.dispatched : ReservationStatus.confirmed,
          bookingId: id, clientLabel: db.businesses[requester]!.name, listingTitle: db.listings[i.listingId!]!.title));
      }
    }
    return b;
  }

  booking('bk-1', 'EV-3A1F2', 'b-lilac', 'b-kabwata', sat, sat, BookingStatus.preparing, const [
    BookingItem(listingId: 'l-round-tables', description: 'Round banquet tables, 10-seater', quantity: 12, unitPrice: 85, lineTotal: 1020),
    BookingItem(listingId: 'l-covers', description: 'Chair covers with satin sash', quantity: 120, unitPrice: 10, lineTotal: 1200),
  ], pay: PaymentStatus.depositRecorded, deposit: 1000, f: Fulfilment.supplierDelivers);
  db.bookings['bk-1'] = Booking(
    id: 'bk-1', reference: 'EV-3A1F2', source: BookingSource.quotation, requester: db.ref('b-lilac'), supplier: db.ref('b-kabwata'),
    startsOn: sat, endsOn: sat, status: BookingStatus.preparing, paymentStatus: PaymentStatus.depositRecorded, total: 2470,
    depositAmount: 1000, fulfilment: Fulfilment.supplierDelivers, createdAt: today.subtract(const Duration(days: 6)),
    deliveryNotes: 'Deliver to garden venue, Leopards Hill Road, by 09:00. Delivery K250 agreed.',
    items: db.bookings['bk-1']!.items, history: db.bookings['bk-1']!.history,
    payments: [
      PaymentRecord(id: 'p-1', amount: 1000, method: 'mobile_money', kind: 'deposit', recordedByBusinessId: 'b-lilac',
          createdAt: today.subtract(const Duration(days: 5)), reference: 'MP241015.1432.A12345', confirmedAt: today.subtract(const Duration(days: 5))),
    ],
  );
  booking('bk-2', 'EV-3A1E7', 'b-ibex', 'b-kabwata', d(satOffset + 7), d(satOffset + 7), BookingStatus.confirmed, const [
    BookingItem(listingId: 'l-chiavari-gold', description: 'Gold Chiavari chairs', quantity: 120, unitPrice: 35, lineTotal: 4200),
  ]);
  booking('bk-3', 'EV-3A1C0', 'b-kabwata', 'b-woodlands', d(-5), d(-5), BookingStatus.completed, const [
    BookingItem(listingId: 'l-pa', description: 'PA system, 2 tops + sub', quantity: 1, unitPrice: 2500, lineTotal: 2500),
  ], pay: PaymentStatus.paid);
  booking('bk-4', 'EV-3A1D4', 'b-chanda', 'b-kabwata', d(1), d(1), BookingStatus.dispatched, const [
    BookingItem(listingId: 'l-round-tables', description: 'Round banquet tables, 10-seater', quantity: 8, unitPrice: 85, lineTotal: 680),
  ], pay: PaymentStatus.paid);

  // -------------------------------------------------------- quote requests
  QuoteRequest request(String id, String requester, String supplier, DateTime from, DateTime to, List<QuoteRequestItem> items,
      {QuoteRequestStatus status = QuoteRequestStatus.open, String message = '', List<Quotation> quotations = const [],
      List<QuoteMessage> messages = const [], Fulfilment f = Fulfilment.pickup, String? venue, int ageHours = 3}) {
    final q = QuoteRequest(
      id: id, requester: db.ref(requester), supplier: db.ref(supplier), status: status, neededFrom: from, neededTo: to,
      items: items, createdAt: DateTime.now().subtract(Duration(hours: ageHours)), message: message, quotations: quotations,
      messages: messages, fulfilment: f, venue: venue);
    db.requests[id] = q;
    return q;
  }

  request('qr-1', 'b-ibex', 'b-kabwata', sat, sat, const [
    QuoteRequestItem(listingId: 'l-folding', description: 'Folding banquet chairs', quantity: 300),
    QuoteRequestItem(listingId: 'l-round-tables', description: 'Round banquet tables, 10-seater', quantity: 30),
  ], message: 'Church anniversary lunch at Kabulonga. Can you do the full 300 chairs? Delivery by 08:00 if possible.',
      f: Fulfilment.supplierDelivers, venue: 'Kabulonga, near the Baptist church', ageHours: 2);

  request('qr-2', 'b-roma', 'b-kabwata', d(satOffset + 14), d(satOffset + 14), const [
    QuoteRequestItem(listingId: 'l-covers', description: 'Chair covers with satin sash', quantity: 150),
  ], status: QuoteRequestStatus.quoted, message: 'Need emerald sashes if you have them.', quotations: [
    Quotation(id: 'qt-2', requestId: 'qr-2', version: 1, status: QuotationStatus.sent,
        items: const [QuotationItem(listingId: 'l-covers', description: 'Chair covers with emerald satin sash', quantity: 150, unitPrice: 10)],
        validUntil: d(5), createdAt: DateTime.now().subtract(const Duration(hours: 20)),
        paymentTerms: 'Full payment on collection.', conditions: 'Covers returned unwashed within 2 days.'),
  ], ageHours: 30);

  request('qr-3', 'b-kabwata', 'b-woodlands', sat, sat, const [
    QuoteRequestItem(listingId: 'l-pa', description: 'PA system, 2 tops + sub', quantity: 1),
    QuoteRequestItem(listingId: 'l-lighting', description: 'Stage wash lighting kit', quantity: 1),
  ], status: QuoteRequestStatus.quoted, message: 'For the Mwansa & Bwalya wedding. Garden venue, power available.',
      f: Fulfilment.supplierSetsUp, venue: 'Garden venue, Leopards Hill Road', quotations: [
    Quotation(id: 'qt-3a', requestId: 'qr-3', version: 1, status: QuotationStatus.superseded,
        items: const [
          QuotationItem(listingId: 'l-pa', description: 'PA system, 2 tops + sub', quantity: 1, unitPrice: 2500),
          QuotationItem(listingId: 'l-lighting', description: 'Stage wash lighting kit', quantity: 1, unitPrice: 1800),
        ],
        charges: const [Charge('Transport & setup', 600)], validUntil: d(4), createdAt: DateTime.now().subtract(const Duration(hours: 26)),
        depositAmount: 1500, paymentTerms: 'Deposit to confirm, balance on the day.'),
    Quotation(id: 'qt-3b', requestId: 'qr-3', version: 2, status: QuotationStatus.sent,
        items: const [
          QuotationItem(listingId: 'l-pa', description: 'PA system, 2 tops + sub', quantity: 1, unitPrice: 2500),
          QuotationItem(listingId: 'l-lighting', description: 'Stage wash lighting kit', quantity: 1, unitPrice: 1500),
        ],
        charges: const [Charge('Transport & setup', 400)], validUntil: d(4), createdAt: DateTime.now().subtract(const Duration(hours: 5)),
        depositAmount: 1500, depositTerms: 'Mobile money to 0977 234 503', paymentTerms: 'Deposit to confirm, balance on the day.',
        conditions: 'Technician on site 15:00–23:00. Overtime K250/hour.'),
  ], messages: [
    QuoteMessage(id: 'qm-1', senderBusinessId: 'b-kabwata', body: 'Can you sharpen the lighting price? Repeat customer.',
        createdAt: DateTime.now().subtract(const Duration(hours: 8))),
    QuoteMessage(id: 'qm-2', senderBusinessId: 'b-woodlands', body: 'Done — revised quote sent with a lower lighting rate and transport.',
        createdAt: DateTime.now().subtract(const Duration(hours: 5))),
  ], ageHours: 28);

  request('qr-4', 'b-kabwata', 'b-makeni', d(satOffset + 7), d(satOffset + 7), const [
    QuoteRequestItem(listingId: 'l-stretch', description: 'Stretch tent 15 × 10 m', quantity: 1),
  ], message: 'Overflow tent for a 350-guest wedding.', ageHours: 6);

  // --------------------------------------------------------------- events
  EventPlan event(String id, String biz, String name, EventType type, DateTime start, DateTime end, List<Requirement> reqs,
      {String? venue, String? client, int? guests, EventStatus status = EventStatus.confirmed, String notes = ''}) {
    final e = EventPlan(id: id, businessId: biz, name: name, type: type, startsAt: start, endsAt: end, venueName: venue,
        clientName: client, guestCount: guests, status: status, requirements: reqs, notes: notes);
    db.events[id] = e;
    db.generateEventTasks(id);
    return e;
  }

  event('e-wedding', 'b-kabwata', 'Mwansa & Bwalya wedding', EventType.wedding, at(satOffset, 14), at(satOffset, 23), const [
    Requirement(id: 'rq-1', label: 'Folding banquet chairs', categoryId: 'chairs', quantity: 220, responsibility: Responsibility.self),
    Requirement(id: 'rq-2', label: 'Pole marquee', categoryId: 'tents', quantity: 1, responsibility: Responsibility.self, bookingId: 'manual'),
    Requirement(id: 'rq-3', label: 'Sound system', categoryId: 'sound', quantity: 1, responsibility: Responsibility.otherVendor, supplierName: 'Woodlands Sound & Light'),
    Requirement(id: 'rq-4', label: 'Décor and backdrop', categoryId: 'decor', responsibility: Responsibility.otherVendor, supplierName: 'Lilac & Linen Décor'),
    Requirement(id: 'rq-5', label: 'Catering', categoryId: 'catering', responsibility: Responsibility.client),
    Requirement(id: 'rq-6', label: 'Generator', responsibility: Responsibility.unassigned),
  ], venue: 'Garden venue, Leopards Hill Road', client: 'Mwansa family', guests: 220);

  event('e-kitchen', 'b-kabwata', 'Chikondi kitchen party', EventType.kitchenParty, at(3, 11), at(3, 17), const [
    Requirement(id: 'rq-7', label: 'Folding banquet chairs', categoryId: 'chairs', quantity: 80, responsibility: Responsibility.self, bookingId: 'manual'),
    Requirement(id: 'rq-8', label: 'Gazebo canopies', categoryId: 'tents', quantity: 2, responsibility: Responsibility.self),
    Requirement(id: 'rq-9', label: 'Décor', responsibility: Responsibility.venue),
  ], venue: 'Private home, Chilenje South', client: 'Chikondi Phiri', guests: 80);

  event('e-corporate', 'b-kabwata', 'Longacres Lodge corporate dinner', EventType.corporate, at(9, 18), at(9, 23), const [
    Requirement(id: 'rq-10', label: 'Gold Chiavari chairs', categoryId: 'chairs', quantity: 175, responsibility: Responsibility.self, bookingId: 'manual'),
  ], venue: 'Longacres Lodge', client: 'Zambia Bankers Association', guests: 175);

  // The decorator's view of the same wedding: the venue supplies chairs, so
  // no chair tasks are generated for Lilac & Linen.
  event('e-lilac-wedding', 'b-lilac', 'Mwansa & Bwalya wedding — styling', EventType.wedding, at(satOffset, 14), at(satOffset, 23), const [
    Requirement(id: 'rq-11', label: 'Chairs', categoryId: 'chairs', quantity: 220, responsibility: Responsibility.venue),
    Requirement(id: 'rq-12', label: 'Backdrop wall', categoryId: 'decor', quantity: 1, responsibility: Responsibility.self),
    Requirement(id: 'rq-13', label: 'Centrepieces', categoryId: 'centrepieces', quantity: 22, responsibility: Responsibility.self),
    Requirement(id: 'rq-14', label: 'Round tables and chair covers', categoryId: 'tables', responsibility: Responsibility.otherVendor, supplierName: 'Kabwata Party Hire', bookingId: 'bk-1'),
  ], venue: 'Garden venue, Leopards Hill Road', client: 'Mwansa family', guests: 220);

  // Manual tasks, including one overdue.
  void task(String id, String biz, String title, DateTime due, TaskPriority p, {String? eventId, TaskStatus status = TaskStatus.todo, String? bookingId}) {
    db.putTask(WorkTask(id: id, businessId: biz, title: title, dueAt: due, priority: p, status: status, eventId: eventId,
        eventName: eventId == null ? null : db.events[eventId]?.name, bookingId: bookingId));
  }

  task('t-1', 'b-kabwata', 'Collect balance from Mwansa family', at(-1, 16), TaskPriority.high, eventId: 'e-wedding');
  task('t-2', 'b-kabwata', 'Wash and count chair covers from last weekend', at(0, 15), TaskPriority.normal);
  task('t-3', 'b-kabwata', 'Agree delivery time with Lilac & Linen', at(0, 17, 30), TaskPriority.normal, bookingId: 'bk-1');
  task('t-4', 'b-kabwata', 'Repair 12 damaged Chiavari chairs', at(5, 12), TaskPriority.high);
  task('t-5', 'b-kabwata', 'Send invoice to Mama Chanda’s Kitchen', at(-2, 10), TaskPriority.low, status: TaskStatus.done);
  db.generateBookingTasks(db.bookings['bk-1']!);
  db.generateBookingTasks(db.bookings['bk-2']!);
  db.generateBookingTasks(db.bookings['bk-4']!);

  // ----------------------------------------------------------- Evenda Now
  // Lilac urgently needs chair covers; Kabwata and Roma are eligible recipients.
  final nowLoc = db.businesses['b-lilac']!.location!;
  db.nowRequests['now-1'] = NowRequest(
    id: 'now-1', requester: db.ref('b-lilac'), status: NowStatus.broadcasting, categoryId: 'linen',
    itemDescription: 'Chair covers with sashes', quantity: 60, neededFrom: d(1), neededTo: d(1), neededByTime: '10:00',
    fulfilment: Fulfilment.pickup, location: nowLoc, locationLabel: 'Kabulonga, near Lilac & Linen studio', radiusKm: 15,
    maxBudget: 900, notes: 'Ivory or white covers. Sash colour flexible.', expiresAt: DateTime.now().add(const Duration(hours: 4)),
    broadcastAt: DateTime.now().subtract(const Duration(minutes: 18)), recipientsCount: 2, createdAt: DateTime.now().subtract(const Duration(minutes: 20)));
  db.nowRecipients['now-1'] = {
    'b-kabwata': (DemoDb.distanceKm(nowLoc, db.businesses['b-kabwata']!.location!), db.available('l-covers', d(1), d(1)), 'l-covers', false),
    'b-roma': (DemoDb.distanceKm(nowLoc, db.businesses['b-roma']!.location!), db.available('l-cloths', d(1), d(1)), 'l-cloths', false),
  };

  // ---------------------------------------------------------- notifications
  DateTime ago(int minutes) => DateTime.now().subtract(Duration(minutes: minutes));
  final roma = db.listings['l-chiavari-white']!;
  db.inventoryEvents.add(('stock_added:l-chiavari-white:seed', 'b-roma',
      InventoryUpdate(id: 'ie-1', type: 'stock_added', supplier: db.ref('b-roma'), listing: roma.copyWith(business: db.ref('b-roma')),
          payload: const {'delta': 50, 'total': 150}, createdAt: ago(95))));
  final frame = db.listings['l-frame']!;
  db.inventoryEvents.add(('availability_opened:l-frame:seed', 'b-makeni',
      InventoryUpdate(id: 'ie-2', type: 'availability_opened', supplier: db.ref('b-makeni'), listing: frame.copyWith(business: db.ref('b-makeni')),
          payload: {'from': EvDates.iso(sat), 'to': EvDates.iso(sat.add(const Duration(days: 1)))}, createdAt: ago(240))));
  final plastic = db.listings['l-plastic-chilenje']!;
  db.inventoryEvents.add(('listing_published:l-plastic-chilenje:seed', 'b-chilenje',
      InventoryUpdate(id: 'ie-3', type: 'listing_published', supplier: db.ref('b-chilenje'), listing: plastic.copyWith(business: db.ref('b-chilenje')),
          payload: const {'quantity': 500}, createdAt: ago(60 * 26))));
  final backdrop = db.listings['l-backdrop']!;
  db.inventoryEvents.add(('listing_published:l-backdrop:seed', 'b-lilac',
      InventoryUpdate(id: 'ie-4', type: 'listing_published', supplier: db.ref('b-lilac'), listing: backdrop.copyWith(business: db.ref('b-lilac')),
          payload: const {'quantity': 4}, createdAt: ago(60 * 30))));

  void n(String biz, NotificationCategory c, String title, String body, int minutesAgo, {String? route, String? image, bool digest = false, bool read = false}) {
    db.notify(biz, c, title, body, 'seed:$title', route: route, image: image, digest: digest, at: ago(minutesAgo));
    if (read) {
      final list = db.notifications[biz]!;
      list[0] = list[0].markRead();
    }
  }

  n('b-kabwata', NotificationCategory.task, 'Overdue: Collect balance from Mwansa family', 'Was due yesterday, 16:00', 60 * 15, route: '/work/task/t-1');
  n('b-kabwata', NotificationCategory.inventory, 'Makeni Marquee Masters opened dates for Frame marquee 20 × 30 m',
      'Tents & marquees · Makeni · Availability is confirmed only by quotation', 240, route: '/listing/l-frame', image: _img('marquee_chairs'));
  n('b-kabwata', NotificationCategory.inventory, 'Roma Event Rentals added 50 × White Chiavari chairs',
      'Chairs · Roma · Availability is confirmed only by quotation', 95, route: '/listing/l-chiavari-white', image: _img('marquee_chairs'));
  n('b-kabwata', NotificationCategory.booking, 'Woodlands Sound & Light revised their quotation', 'K4,400 · valid until ${EvDates.dayShort(d(4))}', 300,
      route: '/bookings/request/qr-3');
  n('b-kabwata', NotificationCategory.now, 'Evenda Now · 60 × Chair covers with sashes',
      'Lilac & Linen Décor needs this ${EvDates.day(d(1))} · ${db.nowRecipients['now-1']!['b-kabwata']!.$1} km away', 18, route: '/now/respond/now-1');
  n('b-kabwata', NotificationCategory.booking, 'New quote request from Ibex Hill Events Co.', '${EvDates.day(sat)} · 2 item(s)', 120,
      route: '/bookings/request/qr-1');
  n('b-kabwata', NotificationCategory.inventory, 'Chilenje Chairs & Canopies listed White plastic chairs', 'Chairs · Chilenje · Availability is confirmed only by quotation',
      60 * 26, route: '/listing/l-plastic-chilenje', image: _img('folding_chairs'), digest: true, read: true);
  n('b-lilac', NotificationCategory.booking, 'Kabwata Party Hire marked EV-3A1F2 as preparing', 'Delivery Saturday 09:00', 60 * 20, route: '/bookings/bk-1');
}
