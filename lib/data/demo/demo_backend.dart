import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:latlong2/latlong.dart';

import '../../core/errors.dart';
import '../../core/format.dart';
import '../../domain/models.dart';
import '../backend.dart';
import 'demo_db.dart';
import 'demo_seed.dart';

/// In-memory backend for demo mode. State resets on restart (or via
/// "Reset demo data"). Every rule mirrors the corresponding SQL function so
/// demo workflows behave like production; nothing here talks to a server.
class DemoBackend implements Backend {
  DemoBackend() {
    _seed();
    // Local stand-in for the pg_cron jobs: reminders and Now expiry.
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) => _tick());
  }

  late DemoDb db;
  late Timer _ticker;
  final _sessions = StreamController<Session?>.broadcast();
  final _changes = StreamController<Set<DataDomain>>.broadcast();
  StreamSubscription? _dbSub;

  void _seed() {
    _dbSub?.cancel();
    db = DemoDb();
    seedDemo(db);
    _dbSub = db.changes.listen(_changes.add);
  }

  void _tick() {
    final sent = db.processDueReminders();
    final expired = (now as _DemoNow).expireDue();
    if (sent > 0 || expired > 0) db.touch({DataDomain.notifications, DataDomain.now, DataDomain.work});
  }

  /// Simulated latency so loading states are visible and honest.
  static Future<void> latency([int ms = 260]) => Future.delayed(Duration(milliseconds: ms));

  // ------------------------------------------------------------ demo controls
  List<DemoPersona> get personas => kDemoPersonas;

  void enterAs(String userId) {
    db.sessionUserId = userId;
    _sessions.add(db.users[userId]);
    db.touch(DataDomain.values.toSet());
  }

  /// A fresh account with no business, to walk through onboarding.
  void enterAsNewVendor() {
    final id = newId();
    db.users[id] = Session(userId: id, phone: '+260970000000', fullName: '', isDemo: true);
    enterAs(id);
  }

  /// DEMO CONTROL: notified suppliers reply with offers from their real
  /// listings (price and free quantity), through the normal offer rules.
  Future<int> simulateSupplierReplies(String requestId) => (now as _DemoNow).simulateSupplierReplies(requestId);

  void reset() {
    final current = db.sessionUserId;
    _seed();
    if (current != null && db.users.containsKey(current)) {
      enterAs(current);
    } else {
      db.sessionUserId = null;
      _sessions.add(null);
    }
    db.touch(DataDomain.values.toSet());
  }

  @override
  bool get isDemo => true;

  @override
  Stream<Set<DataDomain>> get changes => _changes.stream;

  @override
  late final AuthApi auth = _DemoAuth(this);
  @override
  late final BusinessApi business = _DemoBusiness(this);
  @override
  late final ListingApi listings = _DemoListings(this);
  @override
  late final DiscoveryApi discovery = _DemoDiscovery(this);
  @override
  late final BookingApi bookings = _DemoBookings(this);
  @override
  late final WorkApi work = _DemoWork(this);
  @override
  late final NotificationApi notifications = _DemoNotifications(this);
  @override
  late final NowApi now = _DemoNow(this);
  @override
  late final AdminApi admin = _DemoAdmin(this);

  @override
  String photoUrl(String p) => p;

  @override
  Future<void> reconnect() async {}

  @override
  void dispose() {
    _ticker.cancel();
    _dbSub?.cancel();
    _sessions.close();
    _changes.close();
    db.dispose();
  }
}

// ============================================================================
class _DemoAuth implements AuthApi {
  _DemoAuth(this.b);
  final DemoBackend b;

  static const _vendorAccounts = <String, ({String userId, String password})>{
    'mutale@demo.evenda.zm': (userId: 'u-kabwata', password: 'demo-vendor'),
    'chipo@demo.evenda.zm': (userId: 'u-lilac', password: 'demo-vendor'),
    'bwalya@demo.evenda.zm': (userId: 'u-woodlands', password: 'demo-vendor'),
    'grace@demo.evenda.zm': (userId: 'u-roma', password: 'demo-vendor'),
    'thandiwe@demo.evenda.zm': (userId: 'u-ibex', password: 'demo-vendor'),
  };

  @override
  Session? get current => b.db.sessionUserId == null ? null : b.db.users[b.db.sessionUserId];

  @override
  Stream<Session?> get sessions => b._sessions.stream;

  @override
  Future<Session> signIn(String email, String password) async {
    final account = _vendorAccounts[email.trim().toLowerCase()];
    if (account == null || account.password != password) {
      throw const EvError('invalid_credentials', 'Email or password is incorrect.');
    }
    final s = b.db.users[account.userId];
    if (s == null) throw const EvError('not_authenticated', 'Vendor account not found.');
    b.db.sessionUserId = account.userId;
    b._sessions.add(s);
    b.db.touch(DataDomain.values.toSet());
    return s;
  }

  // Demo mode never creates accounts or sends email.
  static const _noAccounts = EvError('signup_disabled', 'Accounts need the live backend.');

  @override
  Future<bool> signUp(String email, String password, String fullName) async => throw _noAccounts;

  @override
  Future<void> verifyEmail(String email, String code) async => throw _noAccounts;

  @override
  Future<void> resendEmailCode(String email) async => throw _noAccounts;

  @override
  Future<void> sendPasswordReset(String email) async => throw _noAccounts;

  @override
  Future<void> verifyPasswordReset(String email, String code) async => throw _noAccounts;

  @override
  Future<void> updatePassword(String newPassword) async => throw _noAccounts;

  // Demo mode never pretends to send or verify an SMS code.
  @override
  Future<void> sendOtp(String e164Phone) async => throw const EvError('otp_not_configured',
      'Phone sign-in needs a configured backend. In demo mode, choose a demo vendor instead.');

  @override
  Future<void> verifyOtp(String e164Phone, String code) => sendOtp(e164Phone);

  @override
  Future<void> updateProfileName(String name) async {
    final s = b.db.requireSession();
    b.db.users[s.userId] = s.copyWith(fullName: name.trim());
    b._sessions.add(b.db.users[s.userId]);
  }

  @override
  Future<void> signOut() async {
    b.db.sessionUserId = null;
    b._sessions.add(null);
    b.db.touch(DataDomain.values.toSet());
  }
}

// ============================================================================
class _DemoBusiness implements BusinessApi {
  _DemoBusiness(this.b);
  final DemoBackend b;
  DemoDb get db => b.db;

  @override
  Future<Business?> mine() async {
    await DemoBackend.latency(120);
    final id = db.currentBusinessId();
    return id == null ? null : db.businesses[id];
  }

  @override
  Future<Business> get(String id) async {
    await DemoBackend.latency(150);
    return db.businesses[id] ?? (throw const EvError('not_found', 'Business not found.'));
  }

  @override
  Future<String> create(String name) async {
    final s = db.requireSession();
    final existing = db.userBusiness[s.userId];
    if (existing != null) return existing;
    final id = newId();
    db.businesses[id] = Business(id: id, ownerId: s.userId, name: name.trim(), createdAt: DateTime.now());
    db.userBusiness[s.userId] = id;
    db.team[id] = [TeamMember(id: newId(), displayName: s.fullName, role: MemberRole.owner, userId: s.userId, phone: s.phone)];
    db.prefs[id] = const NotificationPrefs();
    db.touch({DataDomain.business});
    return id;
  }

  @override
  Future<void> update(Business biz) async {
    db.requireMember(biz.id);
    final current = db.businesses[biz.id]!;
    // Protected fields stay as they are, like the guard trigger.
    db.businesses[biz.id] = biz.copyWith(
      verification: current.verification,
      status: current.status,
      onboardingCompleted: current.onboardingCompleted,
      location: current.location,
      locationPrecision: current.locationPrecision,
      neighbourhood: current.neighbourhood,
    );
    db.touch({DataDomain.business});
  }

  @override
  Future<void> setCategories(String businessId, List<String> categoryIds) async {
    db.requireMember(businessId);
    db.businesses[businessId] = db.businesses[businessId]!.copyWith(categories: categoryIds);
    db.touch({DataDomain.business});
  }

  @override
  Future<LatLng?> exactLocation(String businessId) async => db.businesses[businessId]?.location;

  @override
  Future<void> setLocation(String businessId, LatLng p, LocationPrecision precision, String neighbourhood) async {
    db.requireMember(businessId);
    if (p.latitude < -18.2 || p.latitude > -8.1 || p.longitude < 21.9 || p.longitude > 33.8) {
      throw const EvError('location_outside_zambia');
    }
    // Same rounding as derive_public_location().
    final public = precision == LocationPrecision.exact
        ? p
        : LatLng((p.latitude * 1000).round() / 1000 + 0.0005, (p.longitude * 1000).round() / 1000 + 0.0005);
    db.businesses[businessId] = db.businesses[businessId]!.copyWith(location: public, locationPrecision: precision, neighbourhood: neighbourhood);
    db.touch({DataDomain.business});
  }

  @override
  Future<void> completeOnboarding(String businessId) async {
    db.requireMember(businessId);
    await DemoBackend.latency(400);
    final biz = db.businesses[businessId]!;
    final missing = [
      if (biz.primaryCategory == null) 'primary category',
      if (biz.offeringTypes.isEmpty) 'what you offer',
      if (biz.phone == null) 'phone',
      if (biz.location == null) 'location',
    ];
    if (missing.isNotEmpty) throw EvError('onboarding_incomplete', 'Still needed: ${missing.join(', ')}.');
    db.businesses[businessId] = biz.copyWith(onboardingCompleted: true, onboardingStep: 6);
    final subs = {...biz.categories, if (biz.rents) ...kCategories.where((c) => c.kind == OfferingType.rental).map((c) => c.id)};
    db.prefs[businessId] = (db.prefs[businessId] ?? const NotificationPrefs()).copyWith(subscribedCategories: subs);
    db.touch({DataDomain.business, DataDomain.session});
  }

  @override
  Future<String> uploadLogo(String businessId, Uint8List bytes, String extension) async {
    throw const EvError('storage_not_configured', 'Photo upload needs a configured backend. Demo businesses use monogram logos.');
  }

  @override
  Future<void> uploadVerificationDocument(String businessId, String docType, Uint8List bytes, String extension) async {
    db.requireMember(businessId);
    await DemoBackend.latency(500);
    db.verificationDocs[businessId] = (db.verificationDocs[businessId] ?? 0) + 1;
  }

  @override
  Future<void> submitForVerification(String businessId) async {
    db.requireMember(businessId);
    if ((db.verificationDocs[businessId] ?? 0) == 0) throw const EvError('documents_required');
    final biz = db.businesses[businessId]!;
    if (biz.verification == VerificationStatus.unverified || biz.verification == VerificationStatus.rejected) {
      db.businesses[businessId] = biz.copyWith(verification: VerificationStatus.pending);
    }
    db.touch({DataDomain.business, DataDomain.admin});
  }

  @override
  Future<List<TeamMember>> team(String businessId) async {
    await DemoBackend.latency(150);
    return [...?db.team[businessId]];
  }

  @override
  Future<void> inviteMember(String businessId, String email, String name, MemberRole role) async {
    db.requireMember(businessId);
    if (role == MemberRole.owner) throw const EvError('forbidden', 'A business has one owner.');
    db.team[businessId]!.add(TeamMember(id: newId(), displayName: name, role: role, email: email.trim(), invited: true));
    db.touch({DataDomain.business});
  }

  @override
  Future<void> setMemberRole(String memberId, MemberRole role) async {
    for (final list in db.team.values) {
      final i = list.indexWhere((m) => m.id == memberId);
      if (i >= 0 && list[i].role != MemberRole.owner) {
        final m = list[i];
        list[i] = TeamMember(id: m.id, displayName: m.displayName, role: role, phone: m.phone, userId: m.userId, invited: m.invited);
      }
    }
    db.touch({DataDomain.business});
  }

  @override
  Future<void> removeMember(String memberId) async {
    for (final list in db.team.values) {
      list.removeWhere((m) => m.id == memberId && m.role != MemberRole.owner);
    }
    db.touch({DataDomain.business});
  }
}

// ============================================================================
class _DemoListings implements ListingApi {
  _DemoListings(this.b);
  final DemoBackend b;
  DemoDb get db => b.db;

  Listing _withBiz(Listing l) => l.copyWith(business: db.ref(l.businessId));

  @override
  Future<List<Listing>> mine(String businessId) async {
    await DemoBackend.latency(180);
    final list = db.listings.values.where((l) => l.businessId == businessId).map(_withBiz).toList()
      ..sort((a, b) => a.status.index.compareTo(b.status.index));
    return list;
  }

  @override
  Future<Listing> get(String id) async {
    await DemoBackend.latency(160);
    final l = db.listings[id];
    if (l == null) throw const EvError('not_found', 'This listing is no longer available.');
    final mine = db.currentBusinessId() == l.businessId;
    if (!mine && (l.status != ListingStatus.published || l.moderation != ModerationStatus.ok)) {
      throw const EvError('not_found', 'This listing is no longer available.');
    }
    return _withBiz(l);
  }

  @override
  Future<String> create(ListingDraft d) async {
    db.requireMember(d.businessId);
    await DemoBackend.latency(350);
    _validate(d);
    final id = newId();
    db.listings[id] = Listing(
      id: id,
      businessId: d.businessId,
      kind: d.kind,
      title: d.title.trim(),
      categoryId: d.categoryId!,
      description: d.description.trim(),
      status: ListingStatus.draft,
      priceAmount: d.priceUnit == PriceUnit.onQuote ? null : d.priceAmount,
      priceUnit: d.priceUnit,
      depositAmount: d.depositAmount,
      depositNote: d.depositNote,
      terms: d.terms,
      condition: d.condition,
      totalQuantity: d.totalQuantity,
      tracksStock: d.tracksStock,
      serviceAreaKm: d.serviceAreaKm,
      packageItems: d.packageItems,
      photos: d.photos,
      updatedAt: DateTime.now(),
    );
    if (d.totalQuantity > 0) db.stockLedger.add((id, d.totalQuantity, 'initial', DateTime.now()));
    if (d.status != ListingStatus.draft) await setStatus(id, d.status);
    db.touch({DataDomain.listings});
    return id;
  }

  void _validate(ListingDraft d) {
    if (d.title.trim().length < 2) throw const EvError('invalid', 'Give the listing a name.');
    if (d.categoryId == null) throw const EvError('invalid', 'Choose a category.');
    if (d.status == ListingStatus.published) {
      if (d.priceUnit != PriceUnit.onQuote && d.priceAmount == null) throw const EvError('invalid', 'Add a price or choose “Price on quotation”.');
      if (d.tracksStock && d.totalQuantity <= 0) throw const EvError('invalid', 'Add a quantity before publishing.');
    }
  }

  @override
  Future<void> update(String id, ListingDraft d) async {
    final old = db.listings[id]!;
    db.requireMember(old.businessId);
    await DemoBackend.latency(300);
    _validate(d);
    // Quantity changes go through the stock ledger, never a plain edit.
    if (d.totalQuantity != old.totalQuantity) {
      await adjustStock(id, d.totalQuantity - old.totalQuantity, 'correction', note: 'Edited on listing form');
    }
    final cur = db.listings[id]!;
    db.listings[id] = Listing(
      id: id,
      businessId: cur.businessId,
      kind: d.kind,
      title: d.title.trim(),
      categoryId: d.categoryId!,
      description: d.description.trim(),
      status: cur.status,
      priceAmount: d.priceUnit == PriceUnit.onQuote ? null : d.priceAmount,
      priceUnit: d.priceUnit,
      depositAmount: d.depositAmount,
      depositNote: d.depositNote,
      terms: d.terms,
      condition: d.condition,
      totalQuantity: cur.totalQuantity,
      damagedQuantity: cur.damagedQuantity,
      inspectionQuantity: cur.inspectionQuantity,
      tracksStock: d.tracksStock,
      serviceAreaKm: d.serviceAreaKm,
      packageItems: d.packageItems,
      photos: d.photos,
      moderation: cur.moderation,
      publishedAt: cur.publishedAt,
      updatedAt: DateTime.now(),
    );
    if (d.status != cur.status) await setStatus(id, d.status);
    db.touch({DataDomain.listings});
  }

  @override
  Future<void> setStatus(String id, ListingStatus status) async {
    final l = db.listings[id]!;
    db.requireMember(l.businessId);
    if (status == ListingStatus.published) {
      if (l.priceUnit != PriceUnit.onQuote && l.priceAmount == null) throw const EvError('invalid', 'Add a price before publishing.');
      if (l.tracksStock && l.totalQuantity <= 0) throw const EvError('invalid', 'Add a quantity before publishing.');
    }
    final prev = l.status;
    db.listings[id] = l.copyWith(status: status);
    final updated = db.listings[id]!;
    if (status == ListingStatus.published && prev != ListingStatus.published) {
      db.emitInventoryEvent(updated, prev == ListingStatus.paused ? 'stock_restored' : 'listing_published',
          high: true, payload: {'quantity': updated.totalQuantity});
    } else if (prev == ListingStatus.published && status == ListingStatus.paused) {
      db.emitInventoryEvent(updated, 'listing_paused');
    } else if (prev == ListingStatus.published && status == ListingStatus.archived) {
      db.emitInventoryEvent(updated, 'listing_removed');
    }
    db.touch({DataDomain.listings, DataDomain.discovery, DataDomain.notifications});
  }

  @override
  Future<List<String>> uploadPhotos(String businessId, List<(Uint8List, String)> files) async {
    throw const EvError('storage_not_configured', 'Photo upload needs a configured backend. Choose from the demo photo library instead.');
  }

  @override
  Future<void> adjustStock(String listingId, int delta, String reason, {String? note}) async {
    final l = db.listings[listingId]!;
    db.requireMember(l.businessId);
    if (delta == 0) return;
    if (l.totalQuantity + delta < l.damagedQuantity + l.inspectionQuantity) throw const EvError('stock_below_out_of_service');
    db.stockLedger.add((listingId, delta, reason, DateTime.now()));
    db.listings[listingId] = l.copyWith(totalQuantity: l.totalQuantity + delta);
    // Mirrors stock_inventory_events(): significant = 20+ units or +25%.
    if (delta > 0 && l.status == ListingStatus.published && (delta >= 20 || delta * 4 >= l.totalQuantity)) {
      db.emitInventoryEvent(db.listings[listingId]!, 'stock_added',
          high: delta >= 50, payload: {'delta': delta, 'total': l.totalQuantity + delta});
    }
    db.touch({DataDomain.listings, DataDomain.discovery, DataDomain.notifications});
  }

  @override
  Future<void> setDamaged(String listingId, int damaged) async {
    final l = db.listings[listingId]!;
    db.requireMember(l.businessId);
    if (damaged < 0 || damaged + l.inspectionQuantity > l.totalQuantity) throw const EvError('invalid', 'That count is more than you own.');
    final restored = l.damagedQuantity - damaged;
    db.listings[listingId] = l.copyWith(damagedQuantity: damaged);
    if (l.status == ListingStatus.published && restored >= math.max(10, l.totalQuantity ~/ 10)) {
      db.emitInventoryEvent(db.listings[listingId]!, 'stock_restored', payload: {'restored': restored});
    }
    db.touch({DataDomain.listings, DataDomain.discovery});
  }

  @override
  Future<void> completeInspection(String listingId, {required int good, required int damaged}) async {
    final l = db.listings[listingId]!;
    db.requireMember(l.businessId);
    if (good < 0 || damaged < 0 || good + damaged > l.inspectionQuantity) throw const EvError('invalid', 'Counts exceed items awaiting inspection.');
    db.listings[listingId] = l.copyWith(
      inspectionQuantity: l.inspectionQuantity - good - damaged,
      damagedQuantity: l.damagedQuantity + damaged,
    );
    db.touch({DataDomain.listings});
  }

  @override
  Future<int> availableQuantity(String listingId, DateTime from, DateTime to) async {
    await DemoBackend.latency(200);
    return db.available(listingId, from, to);
  }

  @override
  Future<List<AvailabilityDay>> calendar(String listingId, DateTime from, DateTime to) async {
    await DemoBackend.latency(200);
    final l = db.listings[listingId]!;
    return [
      for (var d = EvDates.dateOnly(from); !d.isAfter(to); d = d.add(const Duration(days: 1)))
        () {
          final blocked = db.isBlocked(l, d, d);
          final reserved = db.reservedOn(listingId, d);
          return AvailabilityDay(day: d, usable: l.usable, reserved: reserved, available: blocked ? 0 : math.max(l.usable - reserved, 0), blocked: blocked);
        }()
    ];
  }

  @override
  Future<List<Reservation>> reservations(String businessId, {String? listingId, bool upcomingOnly = true}) async {
    db.requireMember(businessId);
    await DemoBackend.latency(160);
    final today = EvDates.today();
    return db.reservations
        .where((r) =>
            db.listings[r.listingId]?.businessId == businessId &&
            (listingId == null || r.listingId == listingId) &&
            (!upcomingOnly || !r.endsOn.isBefore(today)) &&
            r.status != ReservationStatus.cancelled)
        .toList()
      ..sort((a, b) => a.startsOn.compareTo(b.startsOn));
  }

  @override
  Future<void> recordManualReservation(String listingId, int quantity, DateTime from, DateTime to, String clientLabel, {String? note}) async {
    db.requireMember(db.listings[listingId]!.businessId);
    await DemoBackend.latency(300);
    db.reserve(listingId, quantity, from, to, ReservationSource.manual, clientLabel: clientLabel, note: note);
    db.touch({DataDomain.listings, DataDomain.work});
  }

  @override
  Future<void> moveReservation(String reservationId, String action) async {
    final i = db.reservations.indexWhere((r) => r.id == reservationId);
    final r = db.reservations[i];
    final l = db.listings[r.listingId]!;
    db.requireMember(l.businessId);
    if (action == 'dispatch' && (r.status == ReservationStatus.confirmed || r.status == ReservationStatus.held)) {
      db.reservations[i] = r.withStatus(ReservationStatus.dispatched);
    } else if (action == 'return' && r.status == ReservationStatus.dispatched) {
      db.reservations[i] = r.withStatus(ReservationStatus.returned);
      db.listings[l.id] = l.copyWith(inspectionQuantity: l.inspectionQuantity + r.quantity);
    } else if (action == 'cancel' && r.source == ReservationSource.manual && r.status != ReservationStatus.dispatched) {
      db.reservations[i] = r.withStatus(ReservationStatus.cancelled);
    } else {
      throw EvError('invalid_transition', 'Cannot $action a reservation that is ${r.status.name}.');
    }
    db.touch({DataDomain.listings});
  }

  @override
  Future<List<AvailabilityBlock>> blocks(String businessId) async {
    await DemoBackend.latency(120);
    return db.blocks.where((b) => b.$1 == businessId).map((b) => b.$2).toList();
  }

  @override
  Future<void> addBlock(String businessId, DateTime from, DateTime to, {String? listingId, String? reason}) async {
    db.requireMember(businessId);
    db.blocks.add((businessId, AvailabilityBlock(id: newId(), startsOn: EvDates.dateOnly(from), endsOn: EvDates.dateOnly(to), listingId: listingId, reason: reason)));
    db.touch({DataDomain.listings, DataDomain.discovery});
  }

  @override
  Future<void> removeBlock(String blockId) async {
    final entry = db.blocks.firstWhere((b) => b.$2.id == blockId);
    db.requireMember(entry.$1);
    db.blocks.remove(entry);
    final blk = entry.$2;
    // Mirrors block_inventory_events(): reopening future dates is broadcast.
    if (!blk.endsOn.isBefore(EvDates.today())) {
      final listing = blk.listingId != null
          ? db.listings[blk.listingId]
          : db.listings.values.where((l) => l.businessId == entry.$1 && l.status == ListingStatus.published).firstOrNull;
      if (listing != null && listing.status == ListingStatus.published) {
        db.emitInventoryEvent(listing, 'availability_opened',
            high: blk.endsOn.difference(blk.startsOn).inDays >= 1,
            payload: {'from': EvDates.iso(blk.startsOn), 'to': EvDates.iso(blk.endsOn)},
            suffix: EvDates.iso(blk.startsOn));
      }
    }
    db.touch({DataDomain.listings, DataDomain.discovery, DataDomain.notifications});
  }

  @override
  Future<List<InventoryConflict>> conflicts(String businessId) async {
    await DemoBackend.latency(120);
    final out = <InventoryConflict>[];
    final today = EvDates.today();
    for (final l in db.listings.values.where((l) => l.businessId == businessId && l.tracksStock)) {
      for (var i = 0; i <= 60; i++) {
        final d = today.add(Duration(days: i));
        final committed = db.reservedOn(l.id, d);
        if (committed > l.usable) {
          out.add(InventoryConflict(listingId: l.id, title: l.title, day: d, usable: l.usable, committed: committed));
        }
      }
    }
    return out;
  }
}

// ============================================================================
class _DemoDiscovery implements DiscoveryApi {
  _DemoDiscovery(this.b);
  final DemoBackend b;
  DemoDb get db => b.db;

  @override
  Future<List<SearchResult>> search(String myBusinessId, SearchQuery q) async {
    await DemoBackend.latency(280);
    final me = db.businesses[myBusinessId];
    final followed = db.follows[myBusinessId]?.keys.toSet() ?? {};
    final text = q.text.trim().toLowerCase();
    final hood = q.neighbourhood == null ? null : kNeighbourhoods.where((n) => n.name == q.neighbourhood).firstOrNull;
    final results = <SearchResult>[];
    for (final l in db.listings.values) {
      final biz = db.businesses[l.businessId]!;
      if (l.status != ListingStatus.published || l.moderation != ModerationStatus.ok) continue;
      if (biz.status != BusinessStatus.active || !biz.onboardingCompleted || biz.id == myBusinessId) continue;
      if (q.categoryId != null && l.categoryId != q.categoryId) continue;
      if (q.kind != null && l.kind != q.kind) continue;
      if (q.savedOnly && !followed.contains(biz.id)) continue;
      if (q.maxPrice != null && (l.priceAmount == null || l.priceAmount! > q.maxPrice!)) continue;
      if (text.isNotEmpty &&
          !('${l.title} ${l.description} ${biz.name} ${categoryById(l.categoryId).name} ${biz.neighbourhood}'.toLowerCase().contains(text))) {
        continue;
      }
      int? avail;
      if (q.from != null) {
        avail = db.available(l.id, q.from!, q.to ?? q.from!);
        if (avail == 0) continue;
        if (q.quantity != null && l.tracksStock && avail < q.quantity!) continue;
      } else if (q.quantity != null && l.tracksStock && l.usable < q.quantity!) {
        continue;
      }
      final origin = hood?.point ?? me?.location;
      final dist = origin != null && biz.location != null ? DemoDb.distanceKm(origin, biz.location!) : null;
      if (hood != null && dist != null && dist > 12) continue;
      results.add(SearchResult(listing: l.copyWith(business: biz.ref), available: l.tracksStock ? avail : null, distanceKm: dist));
    }
    results.sort((a, b) => (a.distanceKm ?? 999).compareTo(b.distanceKm ?? 999));
    return results;
  }

  @override
  Future<Business> supplier(String businessId) async {
    await DemoBackend.latency(160);
    return db.businesses[businessId]!;
  }

  @override
  Future<List<Listing>> supplierListings(String businessId) async {
    await DemoBackend.latency(160);
    return db.listings.values
        .where((l) => l.businessId == businessId && l.status == ListingStatus.published && l.moderation == ModerationStatus.ok)
        .map((l) => l.copyWith(business: db.ref(businessId)))
        .toList();
  }

  @override
  Future<List<InventoryUpdate>> inventoryFeed(String myBusinessId, {int limit = 12}) async {
    await DemoBackend.latency(200);
    final p = db.prefs[myBusinessId] ?? const NotificationPrefs();
    final follows = db.follows[myBusinessId] ?? {};
    final list = db.inventoryEvents
        .where((e) =>
            e.$2 != myBusinessId &&
            e.$3.type != 'listing_paused' &&
            e.$3.type != 'listing_removed' &&
            follows[e.$2]?.muted != true &&
            (follows.containsKey(e.$2) || p.subscribedCategories.contains(e.$3.listing?.categoryId)))
        .map((e) => e.$3)
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list.take(limit).toList();
  }

  @override
  Future<List<SupplierFollow>> follows(String myBusinessId) async {
    await DemoBackend.latency(120);
    return [...?db.follows[myBusinessId]?.values];
  }

  @override
  Future<void> follow(String myBusinessId, String supplierId) async {
    db.requireMember(myBusinessId);
    db.follows.putIfAbsent(myBusinessId, () => {})[supplierId] = SupplierFollow(supplier: db.ref(supplierId));
    db.touch({DataDomain.discovery});
  }

  @override
  Future<void> unfollow(String myBusinessId, String supplierId) async {
    db.requireMember(myBusinessId);
    db.follows[myBusinessId]?.remove(supplierId);
    db.touch({DataDomain.discovery});
  }

  @override
  Future<void> setFollowMuted(String myBusinessId, String supplierId, bool muted) async {
    db.requireMember(myBusinessId);
    final f = db.follows.putIfAbsent(myBusinessId, () => {})[supplierId];
    db.follows[myBusinessId]![supplierId] = SupplierFollow(supplier: db.ref(supplierId), muted: muted, pushEnabled: f?.pushEnabled ?? true);
    db.touch({DataDomain.discovery});
  }
}

// ============================================================================
class _DemoBookings implements BookingApi {
  _DemoBookings(this.b);
  final DemoBackend b;
  DemoDb get db => b.db;

  QuoteRequest _copy(QuoteRequest q, {QuoteRequestStatus? status, List<Quotation>? quotations, List<QuoteMessage>? messages, String? bookingId}) =>
      QuoteRequest(
        id: q.id,
        requester: q.requester,
        supplier: q.supplier,
        status: status ?? q.status,
        neededFrom: q.neededFrom,
        neededTo: q.neededTo,
        items: q.items,
        createdAt: q.createdAt,
        eventId: q.eventId,
        fulfilment: q.fulfilment,
        venue: q.venue,
        deliveryNotes: q.deliveryNotes,
        message: q.message,
        quotations: quotations ?? q.quotations,
        messages: messages ?? q.messages,
        bookingId: bookingId ?? q.bookingId,
      );

  void _assertParty(QuoteRequest q, String businessId) {
    db.requireMember(businessId);
    if (q.requester.id != businessId && q.supplier.id != businessId) throw const EvError('forbidden');
  }

  @override
  Future<List<QuoteRequest>> requests(String businessId) async {
    await DemoBackend.latency(220);
    return db.requests.values.where((q) => q.requester.id == businessId || q.supplier.id == businessId).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  @override
  Future<QuoteRequest> request(String id) async {
    await DemoBackend.latency(160);
    final q = db.requests[id] ?? (throw const EvError('not_found', 'Request not found.'));
    _assertParty(q, db.currentBusinessId() ?? '');
    return q;
  }

  @override
  Future<String> createRequest(QuoteRequestDraft d) async {
    db.requireMember(d.requesterId);
    await DemoBackend.latency(400);
    final existing = db.requests.values.where((q) => q.id == d.idempotencyKey).firstOrNull;
    if (existing != null) return existing.id;
    if (d.items.isEmpty) throw const EvError('items_required');
    if (d.neededFrom.isBefore(EvDates.today())) throw const EvError('dates_in_past');
    final q = QuoteRequest(
      id: d.idempotencyKey,
      requester: db.ref(d.requesterId),
      supplier: db.ref(d.supplierId),
      status: QuoteRequestStatus.open,
      neededFrom: d.neededFrom,
      neededTo: d.neededTo,
      items: d.items,
      createdAt: DateTime.now(),
      eventId: d.eventId,
      fulfilment: d.fulfilment,
      venue: d.venue,
      deliveryNotes: d.deliveryNotes,
      message: d.message,
    );
    db.requests[q.id] = q;
    db.notify(d.supplierId, NotificationCategory.booking, 'New quote request from ${q.requester.name}',
        '${EvDates.day(d.neededFrom)} · ${d.items.length} item(s)', 'qr:${q.id}', route: '/bookings/request/${q.id}');
    db.touch({DataDomain.bookings, DataDomain.notifications});
    return q.id;
  }

  @override
  Future<void> postMessage(String requestId, String businessId, String body) async {
    final q = db.requests[requestId]!;
    _assertParty(q, businessId);
    final m = QuoteMessage(id: newId(), senderBusinessId: businessId, body: body.trim(), createdAt: DateTime.now());
    db.requests[requestId] = _copy(q, messages: [...q.messages, m]);
    final other = businessId == q.requester.id ? q.supplier.id : q.requester.id;
    db.notify(other, NotificationCategory.booking, '${db.ref(businessId).name} sent a message', body.length > 140 ? '${body.substring(0, 140)}…' : body,
        'qm:${m.id}', route: '/bookings/request/$requestId');
    db.touch({DataDomain.bookings, DataDomain.notifications});
  }

  @override
  Future<String> sendQuotation(QuotationDraft d) async {
    final q = db.requests[d.requestId]!;
    db.requireMember(q.supplier.id);
    await DemoBackend.latency(400);
    if (!q.status.isOpen) throw const EvError('request_closed');
    if (d.validUntil.isBefore(EvDates.today())) throw const EvError('invalid', 'Validity date is in the past.');
    if (d.items.isEmpty) throw const EvError('items_required');
    final version = q.quotations.fold(0, (m, x) => math.max(m, x.version)) + 1;
    final qt = Quotation(
      id: newId(),
      requestId: q.id,
      version: version,
      status: QuotationStatus.sent,
      items: d.items,
      charges: d.charges,
      depositAmount: d.depositAmount,
      depositTerms: d.depositTerms,
      paymentTerms: d.paymentTerms,
      validUntil: d.validUntil,
      conditions: d.conditions,
      createdAt: DateTime.now(),
    );
    db.requests[q.id] = _copy(q, status: QuoteRequestStatus.quoted, quotations: [
      for (final x in q.quotations) x.status == QuotationStatus.sent ? x.withStatus(QuotationStatus.superseded) : x,
      qt,
    ]);
    db.notify(q.requester.id, NotificationCategory.booking,
        version == 1 ? '${q.supplier.name} sent a quotation' : '${q.supplier.name} revised their quotation',
        '${Money.k(qt.total)} · valid until ${EvDates.dayShort(d.validUntil)}', 'qt:${qt.id}', route: '/bookings/request/${q.id}');
    db.touch({DataDomain.bookings, DataDomain.notifications});
    return qt.id;
  }

  @override
  Future<void> declineRequest(String requestId, String businessId, {String? reason}) async {
    final q = db.requests[requestId]!;
    _assertParty(q, businessId);
    if (!q.status.isOpen) throw const EvError('request_closed');
    final bySupplier = businessId == q.supplier.id;
    db.requests[requestId] = _copy(q,
        status: bySupplier ? QuoteRequestStatus.declined : QuoteRequestStatus.cancelled,
        quotations: [
          for (final x in q.quotations)
            x.status == QuotationStatus.sent ? x.withStatus(bySupplier ? QuotationStatus.withdrawn : QuotationStatus.declined) : x
        ]);
    final other = bySupplier ? q.requester.id : q.supplier.id;
    db.notify(other, NotificationCategory.booking, '${db.ref(businessId).name} declined the request', reason ?? '', 'qd:$requestId',
        route: '/bookings/request/$requestId');
    db.touch({DataDomain.bookings, DataDomain.notifications});
  }

  @override
  Future<String> acceptQuotation(String quotationId, String idempotencyKey) async {
    await DemoBackend.latency(500);
    // Idempotency first, exactly like accept_quotation().
    final prior = db.idempotency[idempotencyKey] ?? db.bookings.values.where((b) => b.quotationId == quotationId).firstOrNull?.id;
    if (prior != null) return prior;

    final q = db.requests.values.firstWhere((r) => r.quotations.any((x) => x.id == quotationId));
    final qt = q.quotations.firstWhere((x) => x.id == quotationId);
    db.requireMember(q.requester.id);
    if (qt.status != QuotationStatus.sent) throw EvError('quotation_not_open', null, {'status': qt.status.name});
    if (qt.validUntil.isBefore(EvDates.today())) throw const EvError('quotation_expired');

    // Recheck availability for every stocked line before writing anything.
    for (final it in qt.items.where((i) => i.listingId != null)) {
      final avail = db.available(it.listingId!, q.neededFrom, q.neededTo);
      if (avail < it.quantity) {
        throw EvError('insufficient_availability',
            'The supplier now has only $avail × ${it.description} free for those dates. Ask for a revised quotation.', {'available': avail});
      }
    }

    final id = newId();
    final booking = Booking(
      id: id,
      reference: db.nextReference(),
      source: BookingSource.quotation,
      requester: q.requester,
      supplier: q.supplier,
      startsOn: q.neededFrom,
      endsOn: q.neededTo,
      status: BookingStatus.confirmed,
      paymentStatus: PaymentStatus.unpaid,
      total: qt.total,
      depositAmount: qt.depositAmount,
      fulfilment: q.fulfilment,
      createdAt: DateTime.now(),
      quotationId: qt.id,
      requestId: q.id,
      eventId: q.eventId,
      deliveryNotes: q.deliveryNotes ?? q.venue,
      items: [
        for (final i in qt.items)
          BookingItem(listingId: i.listingId, description: i.description, quantity: i.quantity, unitPrice: i.unitPrice, lineTotal: i.lineTotal)
      ],
      history: [BookingEvent(to: BookingStatus.confirmed, at: DateTime.now(), note: 'Quotation v${qt.version} accepted')],
    );
    for (final it in qt.items.where((i) => i.listingId != null)) {
      db.reserve(it.listingId!, it.quantity, q.neededFrom, q.neededTo, ReservationSource.booking, bookingId: id, clientLabel: q.requester.name);
    }
    db.bookings[id] = booking;
    db.idempotency[idempotencyKey] = id;
    db.requests[q.id] = _copy(q, status: QuoteRequestStatus.accepted, bookingId: id, quotations: [
      for (final x in q.quotations) x.id == qt.id ? x.withStatus(QuotationStatus.accepted) : x
    ]);
    db.notify(q.supplier.id, NotificationCategory.booking, '${q.requester.name} accepted your quotation',
        'Booking confirmed for ${EvDates.day(q.neededFrom)}. Stock is now reserved.', 'bk:$id:supplier', route: '/bookings/$id');
    db.generateBookingTasks(booking);
    db.touch({DataDomain.bookings, DataDomain.listings, DataDomain.work, DataDomain.notifications});
    return id;
  }

  @override
  Future<List<Booking>> bookings(String businessId) async {
    await DemoBackend.latency(200);
    return db.bookings.values.where((x) => x.requester.id == businessId || x.supplier.id == businessId).toList()
      ..sort((a, b) => a.startsOn.compareTo(b.startsOn));
  }

  @override
  Future<Booking> booking(String id) async {
    await DemoBackend.latency(160);
    final bk = db.bookings[id] ?? (throw const EvError('not_found', 'Booking not found.'));
    final me = db.currentBusinessId();
    if (me != bk.requester.id && me != bk.supplier.id) throw const EvError('forbidden');
    return bk;
  }

  Booking _with(Booking x, {BookingStatus? status, PaymentStatus? pay, List<BookingEvent>? history, List<PaymentRecord>? payments}) => Booking(
        id: x.id,
        reference: x.reference,
        source: x.source,
        requester: x.requester,
        supplier: x.supplier,
        startsOn: x.startsOn,
        endsOn: x.endsOn,
        status: status ?? x.status,
        paymentStatus: pay ?? x.paymentStatus,
        total: x.total,
        depositAmount: x.depositAmount,
        fulfilment: x.fulfilment,
        createdAt: x.createdAt,
        quotationId: x.quotationId,
        requestId: x.requestId,
        nowOfferId: x.nowOfferId,
        eventId: x.eventId,
        deliveryNotes: x.deliveryNotes,
        items: x.items,
        history: history ?? x.history,
        payments: payments ?? x.payments,
      );

  @override
  Future<void> updateStatus(String bookingId, BookingStatus to, {String? note}) async {
    await DemoBackend.latency(300);
    final x = db.bookings[bookingId]!;
    final me = db.currentBusinessId();
    final isSupplier = me == x.supplier.id;
    if (!isSupplier && me != x.requester.id) throw const EvError('forbidden');
    final s = x.status;
    final ok = switch (to) {
      BookingStatus.cancelled => s == BookingStatus.confirmed || s == BookingStatus.preparing,
      BookingStatus.disputed => s != BookingStatus.cancelled && s != BookingStatus.disputed,
      _ when !isSupplier => false,
      BookingStatus.preparing => s == BookingStatus.confirmed,
      BookingStatus.dispatched => s == BookingStatus.confirmed || s == BookingStatus.preparing,
      BookingStatus.inProgress => s == BookingStatus.confirmed || s == BookingStatus.preparing || s == BookingStatus.dispatched,
      BookingStatus.returned => s == BookingStatus.dispatched || s == BookingStatus.inProgress,
      BookingStatus.completed => s == BookingStatus.inProgress || s == BookingStatus.returned || s == BookingStatus.dispatched,
      _ => false,
    };
    if (!ok) throw EvError('invalid_transition', 'A ${s.label.toLowerCase()} booking cannot move to ${to.label.toLowerCase()}.');

    for (var i = 0; i < db.reservations.length; i++) {
      final r = db.reservations[i];
      if (r.bookingId != bookingId) continue;
      if (to == BookingStatus.cancelled && r.status.holdsStock && r.status != ReservationStatus.dispatched) {
        db.reservations[i] = r.withStatus(ReservationStatus.cancelled);
      } else if (to == BookingStatus.dispatched && (r.status == ReservationStatus.confirmed || r.status == ReservationStatus.held)) {
        db.reservations[i] = r.withStatus(ReservationStatus.dispatched);
      } else if (to == BookingStatus.returned && r.status == ReservationStatus.dispatched) {
        db.reservations[i] = r.withStatus(ReservationStatus.returned);
        final l = db.listings[r.listingId]!;
        db.listings[l.id] = l.copyWith(inspectionQuantity: l.inspectionQuantity + r.quantity);
      }
    }
    if (to == BookingStatus.cancelled) {
      for (final t in db.tasks.values.where((t) => t.bookingId == bookingId && t.status.open).toList()) {
        db.tasks[t.id] = t.copyWith(status: TaskStatus.cancelled);
        db.scheduleReminders(db.tasks[t.id]!);
      }
    }
    db.bookings[bookingId] = _with(x, status: to, history: [...x.history, BookingEvent(from: s, to: to, at: DateTime.now(), note: note)]);
    final other = isSupplier ? x.requester.id : x.supplier.id;
    db.notify(other, NotificationCategory.booking, 'Booking ${x.reference} is now ${to.label.toLowerCase()}', note ?? '',
        'bs:$bookingId:${to.name}', route: '/bookings/$bookingId');
    db.touch({DataDomain.bookings, DataDomain.listings, DataDomain.work, DataDomain.notifications});
  }

  PaymentStatus _paymentStatus(Booking x, List<PaymentRecord> payments) {
    final confirmed = payments.where((p) => p.confirmedAt != null);
    final paid = confirmed.where((p) => p.kind != 'refund').fold(0.0, (s, p) => s + p.amount);
    final refunded = confirmed.where((p) => p.kind == 'refund').fold(0.0, (s, p) => s + p.amount);
    final net = paid - refunded;
    if (refunded > 0 && net <= 0) return PaymentStatus.refunded;
    if (net >= x.total) return PaymentStatus.paid;
    if (net > 0 && x.depositAmount > 0 && net == x.depositAmount) return PaymentStatus.depositRecorded;
    if (net > 0) return PaymentStatus.partiallyPaid;
    return PaymentStatus.unpaid;
  }

  @override
  Future<void> recordPayment(String bookingId, String businessId,
      {required double amount, required String method, required String kind, String? reference, String? note}) async {
    db.requireMember(businessId);
    await DemoBackend.latency(300);
    final x = db.bookings[bookingId]!;
    if (amount <= 0) throw const EvError('invalid', 'Enter an amount above zero.');
    final p = PaymentRecord(id: newId(), amount: amount, method: method, kind: kind, recordedByBusinessId: businessId, createdAt: DateTime.now(), reference: reference, note: note);
    final payments = [...x.payments, p];
    db.bookings[bookingId] = _with(x, payments: payments, pay: _paymentStatus(x, payments));
    final other = businessId == x.supplier.id ? x.requester.id : x.supplier.id;
    db.notify(other, NotificationCategory.booking, 'Payment recorded on ${x.reference}', '${Money.k(amount)} · ${p.methodLabel} · please confirm',
        'pay:${p.id}', route: '/bookings/$bookingId');
    db.touch({DataDomain.bookings, DataDomain.notifications});
  }

  @override
  Future<void> confirmPayment(String paymentId) async {
    final x = db.bookings.values.firstWhere((bk) => bk.payments.any((p) => p.id == paymentId));
    final p = x.payments.firstWhere((p) => p.id == paymentId);
    final confirmer = p.recordedByBusinessId == x.supplier.id ? x.requester.id : x.supplier.id;
    db.requireMember(confirmer);
    final payments = [
      for (final q in x.payments)
        q.id == paymentId
            ? PaymentRecord(id: q.id, amount: q.amount, method: q.method, kind: q.kind, recordedByBusinessId: q.recordedByBusinessId,
                createdAt: q.createdAt, reference: q.reference, note: q.note, confirmedAt: DateTime.now())
            : q
    ];
    db.bookings[x.id] = _with(x, payments: payments, pay: _paymentStatus(x, payments));
    db.touch({DataDomain.bookings});
  }

  @override
  Future<void> openDispute(String bookingId, String businessId, String reason) async {
    db.requireMember(businessId);
    if (reason.trim().length < 10) throw const EvError('invalid', 'Describe the problem in a sentence or two.');
    final x = db.bookings[bookingId]!;
    final id = newId();
    db.disputes[id] = Dispute(id: id, bookingId: bookingId, reason: reason.trim(), status: 'open', createdAt: DateTime.now(),
        bookingReference: x.reference, openedBy: db.ref(businessId).name);
    await updateStatus(bookingId, BookingStatus.disputed, note: 'Dispute opened');
    db.touch({DataDomain.admin});
  }
}

// ============================================================================
class _DemoWork implements WorkApi {
  _DemoWork(this.b);
  final DemoBackend b;
  DemoDb get db => b.db;

  @override
  Future<List<EventPlan>> events(String businessId) async {
    await DemoBackend.latency(180);
    return db.events.values.where((e) => e.businessId == businessId).toList()..sort((a, b) => a.startsAt.compareTo(b.startsAt));
  }

  @override
  Future<EventPlan> event(String id) async {
    await DemoBackend.latency(140);
    final e = db.events[id] ?? (throw const EvError('not_found', 'Event not found.'));
    db.requireMember(e.businessId);
    return e;
  }

  @override
  Future<String> createEvent(EventDraft d) async {
    db.requireMember(d.businessId);
    await DemoBackend.latency(380);
    if (d.name.trim().length < 2) throw const EvError('invalid', 'Give the event a name.');
    if (d.endsAt.isBefore(d.startsAt)) throw const EvError('invalid', 'The event must end after it starts.');
    final id = newId();
    db.events[id] = EventPlan(
      id: id,
      businessId: d.businessId,
      name: d.name.trim(),
      type: d.type,
      startsAt: d.startsAt,
      endsAt: d.endsAt,
      venueName: d.venueName,
      venueAddress: d.venueAddress,
      clientName: d.clientName,
      guestCount: d.guestCount,
      notes: d.notes,
      status: d.status,
      requirements: [for (final r in d.requirements) _withId(r)],
    );
    db.generateEventTasks(id);
    db.touch({DataDomain.work});
    return id;
  }

  Requirement _withId(Requirement r) => r.id.isNotEmpty
      ? r
      : Requirement(id: newId(), label: r.label, responsibility: r.responsibility, categoryId: r.categoryId, quantity: r.quantity,
          supplierName: r.supplierName, supplierBusinessId: r.supplierBusinessId, bookingId: r.bookingId, notes: r.notes);

  @override
  Future<void> updateEvent(String id, EventDraft d) async {
    final e = db.events[id]!;
    db.requireMember(e.businessId);
    await DemoBackend.latency(300);
    db.events[id] = EventPlan(
      id: id,
      businessId: e.businessId,
      name: d.name.trim(),
      type: d.type,
      startsAt: d.startsAt,
      endsAt: d.endsAt,
      venueName: d.venueName,
      venueAddress: d.venueAddress,
      clientName: d.clientName,
      guestCount: d.guestCount,
      notes: d.notes,
      status: d.status,
      sourceBookingId: e.sourceBookingId,
      requirements: [for (final r in d.requirements) _withId(r)],
    );
    // Mirrors events_after_change(): move relative tasks, cancel on cancellation.
    if (d.startsAt != e.startsAt || d.status == EventStatus.cancelled || d.name != e.name) {
      for (final t in db.tasks.values.where((t) => t.eventId == id && t.status.open).toList()) {
        var nt = t.copyWith(eventName: d.name.trim());
        if (d.status == EventStatus.cancelled) {
          nt = nt.copyWith(status: TaskStatus.cancelled);
        } else if (t.offsetMinutes != null && d.startsAt != e.startsAt) {
          nt = nt.copyWith(dueAt: d.startsAt.add(Duration(minutes: t.offsetMinutes!)));
        }
        db.tasks[t.id] = nt;
        db.scheduleReminders(nt);
      }
    }
    db.generateEventTasks(id);
    db.touch({DataDomain.work});
  }

  @override
  Future<int> generateTasks(String eventId) async {
    db.requireMember(db.events[eventId]!.businessId);
    await DemoBackend.latency(250);
    final n = db.generateEventTasks(eventId);
    db.touch({DataDomain.work});
    return n;
  }

  @override
  Future<String> createEventFromBooking(String bookingId, String businessId) async {
    db.requireMember(businessId);
    final existing = db.events.values.where((e) => e.businessId == businessId && e.sourceBookingId == bookingId).firstOrNull;
    if (existing != null) return existing.id;
    final x = db.bookings[bookingId]!;
    final other = x.counterparty(businessId);
    final id = newId();
    db.events[id] = EventPlan(
      id: id,
      businessId: businessId,
      name: 'Job ${x.reference} · ${other.name}',
      type: EventType.other,
      startsAt: DateTime(x.startsOn.year, x.startsOn.month, x.startsOn.day, 8),
      endsAt: DateTime(x.endsOn.year, x.endsOn.month, x.endsOn.day, 22),
      clientName: other.name,
      status: EventStatus.confirmed,
      sourceBookingId: bookingId,
      venueName: x.deliveryNotes,
    );
    for (final t in db.tasks.values.where((t) => t.businessId == businessId && t.bookingId == bookingId).toList()) {
      db.tasks[t.id] = WorkTask(id: t.id, businessId: t.businessId, title: t.title, dueAt: t.dueAt, priority: t.priority, status: t.status,
          notes: t.notes, eventId: id, eventName: db.events[id]!.name, bookingId: t.bookingId, generatedKey: t.generatedKey);
    }
    db.generateEventTasks(id);
    db.touch({DataDomain.work, DataDomain.bookings});
    return id;
  }

  @override
  Future<List<WorkTask>> tasks(String businessId, {String? eventId, bool includeDone = false}) async {
    await DemoBackend.latency(160);
    return db.tasks.values
        .where((t) => t.businessId == businessId && (eventId == null || t.eventId == eventId) && (includeDone || t.status.open))
        .toList()
      ..sort((a, b) => a.dueAt.compareTo(b.dueAt));
  }

  @override
  Future<WorkTask> task(String id) async {
    await DemoBackend.latency(100);
    final t = db.tasks[id] ?? (throw const EvError('not_found', 'Task not found.'));
    db.requireMember(t.businessId);
    return t;
  }

  @override
  Future<String> createTask(String businessId,
      {required String title, required DateTime dueAt, TaskPriority priority = TaskPriority.normal, String? eventId, String notes = ''}) async {
    db.requireMember(businessId);
    final ev = eventId == null ? null : db.events[eventId];
    final t = WorkTask(
      id: newId(),
      businessId: businessId,
      title: title.trim(),
      dueAt: dueAt,
      priority: priority,
      status: TaskStatus.todo,
      notes: notes,
      eventId: eventId,
      eventName: ev?.name,
      offsetMinutes: ev == null ? null : dueAt.difference(ev.startsAt).inMinutes,
    );
    db.putTask(t);
    db.touch({DataDomain.work});
    return t.id;
  }

  @override
  Future<void> updateTask(WorkTask t) async {
    final cur = db.tasks[t.id]!;
    db.requireMember(cur.businessId);
    final ev = cur.eventId == null ? null : db.events[cur.eventId];
    // Rescheduling a task re-anchors its offset so later event moves keep the new gap.
    db.tasks[t.id] = WorkTask(
      id: t.id,
      businessId: cur.businessId,
      title: t.title,
      dueAt: t.dueAt,
      priority: t.priority,
      status: t.status,
      notes: t.notes,
      eventId: cur.eventId,
      eventName: cur.eventName,
      bookingId: cur.bookingId,
      requirementId: cur.requirementId,
      generatedKey: cur.generatedKey,
      offsetMinutes: ev == null ? cur.offsetMinutes : t.dueAt.difference(ev.startsAt).inMinutes,
      completedAt: t.status == TaskStatus.done ? (cur.completedAt ?? DateTime.now()) : null,
    );
    db.scheduleReminders(db.tasks[t.id]!);
    db.touch({DataDomain.work});
  }

  @override
  Future<void> setTaskStatus(String taskId, TaskStatus status) async {
    final t = db.tasks[taskId]!;
    db.requireMember(t.businessId);
    db.tasks[taskId] = t.copyWith(status: status);
    db.scheduleReminders(db.tasks[taskId]!); // done/cancelled cancels pending reminders
    db.touch({DataDomain.work});
  }

  @override
  Future<void> snoozeTask(String taskId, DateTime until) async {
    final t = db.tasks[taskId]!;
    db.requireMember(t.businessId);
    if (!until.isAfter(DateTime.now())) throw const EvError('invalid', 'Choose a time in the future.');
    final list = db.reminders.putIfAbsent(taskId, () => []);
    for (var i = 0; i < list.length; i++) {
      if (list[i].status == 'pending') list[i] = TaskReminder(id: list[i].id, remindAt: list[i].remindAt, kind: list[i].kind, status: 'cancelled');
    }
    list.add(TaskReminder(id: newId(), remindAt: until, kind: 'snoozed', status: 'pending'));
    db.touch({DataDomain.work});
  }

  @override
  Future<List<TaskReminder>> reminders(String taskId) async => [...?db.reminders[taskId]]..sort((a, b) => a.remindAt.compareTo(b.remindAt));

  @override
  Future<List<WorkloadDay>> workload(String businessId, DateTime from, DateTime to) async {
    await DemoBackend.latency(150);
    final evs = db.events.values.where((e) => e.businessId == businessId && e.status != EventStatus.cancelled).toList();
    final open = db.tasks.values.where((t) => t.businessId == businessId && t.status.open).toList();
    final now = DateTime.now();
    return [
      for (var d = EvDates.dateOnly(from); !d.isAfter(to); d = d.add(const Duration(days: 1)))
        () {
          final dayEvents = evs.where((e) => !EvDates.dateOnly(e.startsAt).isAfter(d) && !EvDates.dateOnly(e.endsAt).isBefore(d)).toList();
          var overlap = false;
          for (var i = 0; i < dayEvents.length && !overlap; i++) {
            for (var j = i + 1; j < dayEvents.length; j++) {
              if (dayEvents[i].startsAt.isBefore(dayEvents[j].endsAt) && dayEvents[j].startsAt.isBefore(dayEvents[i].endsAt)) overlap = true;
            }
          }
          final due = open.where((t) => EvDates.sameDay(t.dueAt, d));
          return WorkloadDay(day: d, events: dayEvents.length, tasksDue: due.length, overdue: due.where((t) => t.dueAt.isBefore(now)).length, overlapping: overlap);
        }()
    ];
  }
}

// ============================================================================
class _DemoNotifications implements NotificationApi {
  _DemoNotifications(this.b);
  final DemoBackend b;
  DemoDb get db => b.db;

  @override
  Future<List<AppNotification>> list(String businessId) async {
    await DemoBackend.latency(160);
    return [...?db.notifications[businessId]]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  @override
  Future<int> unreadCount(String businessId) async => db.notifications[businessId]?.where((n) => n.unread).length ?? 0;

  @override
  Future<void> markRead(String id) async {
    for (final list in db.notifications.values) {
      final i = list.indexWhere((n) => n.id == id);
      if (i >= 0) list[i] = list[i].markRead();
    }
    db.touch({DataDomain.notifications});
  }

  @override
  Future<void> markAllRead(String businessId) async {
    final list = db.notifications[businessId];
    if (list == null) return;
    for (var i = 0; i < list.length; i++) {
      list[i] = list[i].markRead();
    }
    db.touch({DataDomain.notifications});
  }

  @override
  Stream<AppNotification> incoming(String businessId) => db.incoming.where((e) => e.$1 == businessId).map((e) => e.$2);

  @override
  Future<NotificationPrefs> prefs(String businessId) async {
    await DemoBackend.latency(120);
    return db.prefs[businessId] ?? const NotificationPrefs();
  }

  @override
  Future<void> savePrefs(String businessId, NotificationPrefs prefs) async {
    db.requireMember(businessId);
    await DemoBackend.latency(250);
    db.prefs[businessId] = prefs;
    db.touch({DataDomain.notifications, DataDomain.discovery});
  }

  @override
  Future<void> registerDevice(String token, String platform) async {}
}

// ============================================================================
class _DemoNow implements NowApi {
  _DemoNow(this.b);
  final DemoBackend b;
  DemoDb get db => b.db;

  NowRequest _req(String id) => db.nowRequests[id] ?? (throw const EvError('not_found', 'Request not found.'));

  void _status(String id, NowStatus s) => db.nowRequests[id] = _req(id).copyWith(status: s);

  @override
  Future<String> create(NowRequestDraft d) async {
    db.requireMember(d.requesterId);
    await DemoBackend.latency(300);
    if (db.nowRequests.containsKey(d.idempotencyKey)) return d.idempotencyKey;
    if (d.categoryId == null) throw const EvError('invalid', 'Choose what you need.');
    if (d.location == null) throw const EvError('invalid', 'Confirm the request location on the map.');
    if (EvDates.dateOnly(d.neededFrom).isBefore(EvDates.today())) throw const EvError('dates_in_past');
    final neededStart = DateTime(d.neededFrom.year, d.neededFrom.month, d.neededFrom.day,
        int.tryParse(d.neededByTime?.split(':').first ?? '') ?? 8);
    final sixHours = DateTime.now().add(const Duration(hours: 6));
    final oneHour = DateTime.now().add(const Duration(hours: 1));
    final expires = neededStart.isBefore(sixHours) ? (neededStart.isAfter(oneHour) ? neededStart : oneHour) : sixHours;
    db.nowRequests[d.idempotencyKey] = NowRequest(
      id: d.idempotencyKey,
      requester: db.ref(d.requesterId),
      status: NowStatus.draft,
      categoryId: d.categoryId!,
      itemDescription: d.itemDescription.trim(),
      quantity: d.quantity,
      neededFrom: EvDates.dateOnly(d.neededFrom),
      neededTo: EvDates.dateOnly(d.neededFrom),
      neededByTime: d.neededByTime,
      fulfilment: d.fulfilment,
      location: d.location!,
      locationLabel: d.locationLabel,
      radiusKm: d.radiusKm,
      maxBudget: d.maxBudget,
      notes: d.notes,
      expiresAt: expires,
      createdAt: DateTime.now(),
    );
    db.touch({DataDomain.now});
    return d.idempotencyKey;
  }

  /// Mirrors now_eligible_suppliers().
  List<(String businessId, String listingId, double km, int available)> _eligible(NowRequest r) {
    final out = <(String, String, double, int)>[];
    for (final biz in db.businesses.values) {
      if (biz.id == r.requester.id || biz.status != BusinessStatus.active || !biz.onboardingCompleted || biz.location == null) continue;
      if (!(db.prefs[biz.id]?.nowRequests ?? true)) continue;
      final km = DemoDb.distanceKm(r.location, biz.location!);
      if (km > math.min(r.radiusKm, biz.serviceRadiusKm)) continue;
      (String, int)? best;
      for (final l in db.listings.values.where((l) =>
          l.businessId == biz.id && l.categoryId == r.categoryId && l.status == ListingStatus.published && l.moderation == ModerationStatus.ok)) {
        final a = db.available(l.id, r.neededFrom, r.neededTo);
        if (a > 0 && (best == null || a > best.$2)) best = (l.id, a);
      }
      if (best != null) out.add((biz.id, best.$1, km, l2(best.$2)));
    }
    out.sort((a, b) => a.$3.compareTo(b.$3));
    return out.take(30).toList();
  }

  static int l2(int v) => v > 1 << 29 ? 999 : v;

  @override
  Future<int> broadcast(String requestId, {int? radiusKm}) async {
    var r = _req(requestId);
    db.requireMember(r.requester.id);
    await DemoBackend.latency(700);
    if (!(r.status == NowStatus.draft || r.status == NowStatus.broadcasting || r.status == NowStatus.receivingOffers)) {
      throw const EvError('request_closed');
    }
    if (radiusKm != null) {
      r = r.copyWith(radiusKm: radiusKm);
      db.nowRequests[requestId] = r;
    }
    final recipients = db.nowRecipients.putIfAbsent(requestId, () => {});
    var added = 0;
    for (final e in _eligible(r)) {
      if (recipients.containsKey(e.$1)) continue;
      recipients[e.$1] = (e.$3, e.$4, e.$2, false);
      added++;
      db.notify(e.$1, NotificationCategory.now, 'Evenda Now · ${r.quantity} × ${r.itemDescription}',
          '${r.requester.name} needs this ${EvDates.day(r.neededFrom)} · ${e.$3} km away', 'now:$requestId',
          route: '/now/respond/$requestId', data: {'request_id': requestId});
    }
    db.nowRequests[requestId] = r.copyWith(
      recipientsCount: recipients.length,
      broadcastAt: r.broadcastAt ?? DateTime.now(),
      status: recipients.isNotEmpty && r.status == NowStatus.draft ? NowStatus.broadcasting : r.status,
    );
    db.touch({DataDomain.now, DataDomain.notifications});
    return added;
  }

  @override
  Future<NowRequest> request(String id) async {
    await DemoBackend.latency(100);
    return _req(id);
  }

  @override
  Future<List<NowRequest>> mine(String businessId) async {
    await DemoBackend.latency(160);
    return db.nowRequests.values.where((r) => r.requester.id == businessId).toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  @override
  Future<List<NowMapVendor>> map(String requestId) async {
    final r = _req(requestId);
    db.requireMember(r.requester.id);
    await DemoBackend.latency(200);
    final rec = db.nowRecipients[requestId] ?? {};
    return [
      for (final e in rec.entries)
        NowMapVendor(
          businessId: e.key,
          name: db.businesses[e.key]!.name,
          location: db.businesses[e.key]!.location!,
          distanceKm: e.value.$1,
          available: e.value.$2,
          hasOffer: db.nowOffers.values.any((o) =>
              o.requestId == requestId && o.supplier.id == e.key && (o.status == NowOfferStatus.pending || o.status == NowOfferStatus.selected)),
          declined: e.value.$4,
          approximate: db.businesses[e.key]!.locationPrecision == LocationPrecision.approximate,
        )
    ]..sort((a, b) => a.distanceKm.compareTo(b.distanceKm));
  }

  @override
  Future<List<NowOffer>> offers(String requestId) async {
    await DemoBackend.latency(120);
    final rec = db.nowRecipients[requestId] ?? {};
    return db.nowOffers.values
        .where((o) => o.requestId == requestId && o.status != NowOfferStatus.withdrawn)
        .map((o) => NowOffer(
              id: o.id, requestId: o.requestId, supplier: o.supplier, listingId: o.listingId, listingTitle: o.listingTitle,
              quantity: o.quantity, unitPrice: o.unitPrice, status: o.status, createdAt: o.createdAt, canDeliver: o.canDeliver,
              note: o.note, bookingId: o.bookingId, distanceKm: rec[o.supplier.id]?.$1))
        .toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }

  @override
  Future<String> selectOffer(String offerId, String idempotencyKey) async {
    await DemoBackend.latency(500);
    final prior = db.idempotency[idempotencyKey] ?? db.bookings.values.where((x) => x.nowOfferId == offerId).firstOrNull?.id;
    if (prior != null) return prior;
    final o = db.nowOffers[offerId] ?? (throw const EvError('not_found'));
    final r = _req(o.requestId);
    db.requireMember(r.requester.id);
    if (o.status != NowOfferStatus.pending) throw const EvError('offer_not_open');
    if (!(r.status == NowStatus.receivingOffers || r.status == NowStatus.offerSelected)) throw const EvError('request_closed');

    final id = newId();
    final canDeliver = o.canDeliver && r.fulfilment != Fulfilment.pickup;
    // reserve() rechecks availability and throws before anything is written.
    db.reserve(o.listingId, o.quantity, r.neededFrom, r.neededTo, ReservationSource.now, bookingId: id, clientLabel: r.requester.name);
    final bk = Booking(
      id: id,
      reference: db.nextReference(),
      source: BookingSource.now,
      requester: r.requester,
      supplier: o.supplier,
      startsOn: r.neededFrom,
      endsOn: r.neededTo,
      status: BookingStatus.confirmed,
      paymentStatus: PaymentStatus.unpaid,
      total: o.total,
      fulfilment: canDeliver ? r.fulfilment : Fulfilment.pickup,
      createdAt: DateTime.now(),
      nowOfferId: o.id,
      deliveryNotes: r.locationLabel,
      items: [BookingItem(listingId: o.listingId, description: o.listingTitle, quantity: o.quantity, unitPrice: o.unitPrice, lineTotal: o.total)],
      history: [BookingEvent(to: BookingStatus.confirmed, at: DateTime.now(), note: 'Evenda Now offer selected')],
    );
    db.bookings[id] = bk;
    db.idempotency[idempotencyKey] = id;
    db.nowOffers[offerId] = o.withStatus(NowOfferStatus.selected, bookingId: id);

    final covered = db.nowOffers.values.where((x) => x.requestId == r.id && x.status == NowOfferStatus.selected).fold(0, (s, x) => s + x.quantity);
    if (covered >= r.quantity) {
      for (final x in db.nowOffers.values.where((x) => x.requestId == r.id && x.status == NowOfferStatus.pending).toList()) {
        db.nowOffers[x.id] = x.withStatus(NowOfferStatus.rejected);
      }
      _status(r.id, NowStatus.bookingConfirmed);
    } else {
      _status(r.id, NowStatus.offerSelected);
    }
    db.notify(o.supplier.id, NotificationCategory.now, '${r.requester.name} selected your offer',
        '${o.quantity} × ${o.listingTitle} · booking confirmed and stock reserved', 'now-sel:${o.id}', route: '/bookings/$id');
    db.generateBookingTasks(bk);
    db.touch({DataDomain.now, DataDomain.bookings, DataDomain.listings, DataDomain.work, DataDomain.notifications});
    return id;
  }

  @override
  Future<void> close(String requestId, NowStatus to) async {
    final r = _req(requestId);
    db.requireMember(r.requester.id);
    if (to != NowStatus.cancelled && to != NowStatus.completed) throw const EvError('invalid_transition');
    if (to == NowStatus.cancelled && (r.status == NowStatus.bookingConfirmed || r.status == NowStatus.completed)) {
      throw const EvError('invalid_transition', 'Cancel the linked bookings instead.');
    }
    for (final x in db.nowOffers.values.where((x) => x.requestId == requestId && x.status == NowOfferStatus.pending).toList()) {
      db.nowOffers[x.id] = x.withStatus(NowOfferStatus.expired);
    }
    _status(requestId, to);
    db.touch({DataDomain.now});
  }

  int expireDue() {
    var n = 0;
    for (final r in db.nowRequests.values.toList()) {
      if (!r.expiresAt.isBefore(DateTime.now())) continue;
      if (r.status == NowStatus.draft || r.status == NowStatus.broadcasting || r.status == NowStatus.receivingOffers) {
        _status(r.id, NowStatus.expired);
        n++;
      } else if (r.status == NowStatus.offerSelected) {
        _status(r.id, NowStatus.bookingConfirmed);
        n++;
      } else {
        continue;
      }
      for (final x in db.nowOffers.values.where((x) => x.requestId == r.id && x.status == NowOfferStatus.pending).toList()) {
        db.nowOffers[x.id] = x.withStatus(NowOfferStatus.expired);
      }
    }
    return n;
  }

  NowInboxItem _inbox(NowRequest r, String businessId) {
    final rec = db.nowRecipients[r.id]![businessId]!;
    final mine = db.nowOffers.values.where((o) => o.requestId == r.id && o.supplier.id == businessId && o.status != NowOfferStatus.withdrawn).firstOrNull;
    final listing = db.listings[rec.$3];
    return NowInboxItem(
      request: r,
      distanceKm: rec.$1,
      availableQuantity: listing == null ? 0 : l2(db.available(listing.id, r.neededFrom, r.neededTo)),
      matchedListing: listing?.copyWith(business: db.ref(businessId)),
      myOffer: mine,
      declined: rec.$4,
    );
  }

  @override
  Future<List<NowInboxItem>> inbox(String businessId) async {
    await DemoBackend.latency(160);
    return [
      for (final e in db.nowRecipients.entries)
        if (e.value.containsKey(businessId) && db.nowRequests[e.key] != null) _inbox(db.nowRequests[e.key]!, businessId)
    ]..sort((a, b) => b.request.createdAt.compareTo(a.request.createdAt));
  }

  @override
  Future<NowInboxItem> inboxItem(String requestId, String businessId) async {
    await DemoBackend.latency(140);
    if (db.nowRecipients[requestId]?.containsKey(businessId) != true) throw const EvError('not_a_recipient');
    return _inbox(_req(requestId), businessId);
  }

  @override
  Future<void> submitOffer(NowOfferDraft d) async {
    db.requireMember(d.supplierId);
    await DemoBackend.latency(400);
    _submit(d);
  }

  void _submit(NowOfferDraft d) {
    final r = _req(d.requestId);
    if (db.nowRecipients[r.id]?.containsKey(d.supplierId) != true) throw const EvError('not_a_recipient');
    if (!r.status.live || r.expiresAt.isBefore(DateTime.now())) throw const EvError('request_closed');
    final l = db.listings[d.listingId];
    if (l == null || l.businessId != d.supplierId || l.status != ListingStatus.published) throw const EvError('listing_not_from_supplier');
    final avail = db.available(d.listingId, r.neededFrom, r.neededTo);
    if (d.quantity > avail) throw EvError('insufficient_availability', 'You have $avail available for that date.');
    if (d.quantity <= 0) throw const EvError('invalid', 'Offer at least one.');

    final existing = db.nowOffers.values.where((o) => o.requestId == r.id && o.supplier.id == d.supplierId && o.status == NowOfferStatus.pending).firstOrNull;
    final offer = NowOffer(
      id: existing?.id ?? newId(),
      requestId: r.id,
      supplier: db.ref(d.supplierId),
      listingId: d.listingId,
      listingTitle: l.title,
      quantity: d.quantity,
      unitPrice: d.unitPrice,
      status: NowOfferStatus.pending,
      createdAt: existing?.createdAt ?? DateTime.now(),
      canDeliver: d.canDeliver,
      note: d.note,
    );
    db.nowOffers[offer.id] = offer;
    if (r.status == NowStatus.broadcasting) _status(r.id, NowStatus.receivingOffers);
    db.notify(r.requester.id, NotificationCategory.now, '${offer.supplier.name} can supply ${d.quantity} × ${r.itemDescription}',
        '${Money.k(offer.total)} total', 'now-offer:${offer.id}:${DateTime.now().millisecondsSinceEpoch}',
        route: '/now/${r.id}', data: {'request_id': r.id, 'offer_id': offer.id});
    db.touch({DataDomain.now, DataDomain.notifications});
  }

  @override
  Future<void> decline(String requestId, String businessId) async {
    db.requireMember(businessId);
    final rec = db.nowRecipients[requestId]?[businessId];
    if (rec == null) throw const EvError('not_a_recipient');
    db.nowRecipients[requestId]![businessId] = (rec.$1, rec.$2, rec.$3, true);
    for (final o in db.nowOffers.values.where((o) => o.requestId == requestId && o.supplier.id == businessId && o.status == NowOfferStatus.pending).toList()) {
      db.nowOffers[o.id] = o.withStatus(NowOfferStatus.withdrawn);
    }
    db.touch({DataDomain.now});
  }

  /// DEMO CONTROL. Plays the part of the notified suppliers so a single
  /// person can see offers arrive. Each reply goes through the same
  /// validation as a real offer, using the supplier's real listing price and
  /// available quantity. Only reachable from a control labelled as a demo.
  Future<int> simulateSupplierReplies(String requestId) async {
    final r = _req(requestId);
    final rec = db.nowRecipients[requestId] ?? {};
    var remaining = r.quantity;
    var n = 0;
    for (final e in rec.entries) {
      if (e.value.$4 || db.nowOffers.values.any((o) => o.requestId == requestId && o.supplier.id == e.key)) continue;
      await Future.delayed(Duration(milliseconds: 900 + 700 * n));
      final cur = _req(requestId);
      if (!cur.status.live) break;
      final l = db.listings[e.value.$3]!;
      final avail = db.available(l.id, r.neededFrom, r.neededTo);
      final qty = math.min(avail, math.max(remaining, (r.quantity / 2).ceil()));
      if (qty <= 0) continue;
      _submit(NowOfferDraft(
        requestId: requestId,
        supplierId: e.key,
        listingId: l.id,
        quantity: qty,
        unitPrice: l.priceAmount ?? 0,
        canDeliver: n.isEven,
        note: n.isEven ? 'Can deliver by ${r.neededByTime ?? '09:00'}.' : 'Collect from our yard.',
      ));
      remaining -= qty;
      n++;
    }
    return n;
  }
}

// ============================================================================
class _DemoAdmin implements AdminApi {
  _DemoAdmin(this.b);
  final DemoBackend b;
  DemoDb get db => b.db;
  AdminSession? _session;

  @override
  AdminSession? get current => _session;

  @override
  Future<AdminSession?> restore() async => _session;

  /// Demo admin sign-in: any of the demo admin accounts listed on the sign-in screen.
  static const accounts = {
    'super@demo.evenda.zm': (AdminRole.superAdmin, 'Demo super admin'),
    'moderator@demo.evenda.zm': (AdminRole.moderator, 'Demo moderator'),
    'support@demo.evenda.zm': (AdminRole.support, 'Demo support agent'),
    'finance@demo.evenda.zm': (AdminRole.finance, 'Demo finance officer'),
  };

  @override
  Future<AdminSession> signIn(String email, String password) async {
    await DemoBackend.latency(500);
    final a = accounts[email.trim().toLowerCase()];
    if (a == null || password != 'demo-admin') throw const EvError('invalid_credentials', 'Email or password is incorrect.');
    return _session = AdminSession(userId: 'admin-${a.$1.name}', role: a.$1, displayName: a.$2, isDemo: true);
  }

  @override
  Future<void> signOut() async => _session = null;

  AdminRole _require(String permission, {String? reason, bool reasonRequired = false}) {
    final s = _session;
    if (s == null || !s.role.can(permission)) throw EvError('admin_forbidden', null, {'permission': permission});
    if (reasonRequired && (reason == null || reason.trim().length < 5)) throw const EvError('reason_required');
    return s.role;
  }

  @override
  Future<Map<String, int>> stats() async {
    _require('activity.read');
    await DemoBackend.latency(250);
    return {
      'businesses': db.businesses.values.where((x) => x.onboardingCompleted).length,
      'pending_verification': db.businesses.values.where((x) => x.verification == VerificationStatus.pending).length,
      'published_listings': db.listings.values.where((l) => l.status == ListingStatus.published).length,
      'flagged_listings': db.listings.values.where((l) => l.moderation == ModerationStatus.flagged).length,
      'open_quote_requests': db.requests.values.where((q) => q.status.isOpen).length,
      'bookings_30d': db.bookings.length,
      'now_open': db.nowRequests.values.where((r) => r.status.live).length,
      'open_disputes': db.disputes.values.where((d) => d.status == 'open' || d.status == 'investigating').length,
      'push_failed_24h': 0,
    };
  }

  @override
  Future<List<AdminBusinessRow>> businesses({String? search, VerificationStatus? verification}) async {
    _require('business.read');
    await DemoBackend.latency(220);
    return db.businesses.values
        .where((x) =>
            (search == null || search.isEmpty || x.name.toLowerCase().contains(search.toLowerCase())) &&
            (verification == null || x.verification == verification))
        .map((x) => AdminBusinessRow(
              id: x.id,
              name: x.name,
              neighbourhood: x.neighbourhood,
              primaryCategory: x.primaryCategory,
              verification: x.verification,
              status: x.status,
              createdAt: x.createdAt ?? DateTime.now(),
              listings: db.listings.values.where((l) => l.businessId == x.id).length,
              documents: db.verificationDocs[x.id] ?? (x.verification == VerificationStatus.pending ? 2 : 0),
            ))
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
  }

  @override
  Future<void> setVerification(String businessId, VerificationStatus status, String reason) async {
    final role = _require('business.verify', reason: reason, reasonRequired: status == VerificationStatus.rejected);
    await DemoBackend.latency(300);
    final x = db.businesses[businessId]!;
    db.businesses[businessId] = x.copyWith(verification: status);
    db.writeAudit(role, 'business.verification', 'businesses', businessId, reason, {'verification_status': x.verification.wire}, {'verification_status': status.wire});
    db.notify(businessId, NotificationCategory.system,
        status == VerificationStatus.verified ? 'Your business is verified' : 'Verification updated', reason, 'verify:${status.name}:${DateTime.now().millisecondsSinceEpoch}',
        route: '/business/profile');
    db.touch({DataDomain.admin, DataDomain.business, DataDomain.discovery});
  }

  @override
  Future<void> setBusinessStatus(String businessId, BusinessStatus status, String reason) async {
    final role = _require('business.verify', reason: reason, reasonRequired: true);
    final x = db.businesses[businessId]!;
    db.businesses[businessId] = x.copyWith(status: status);
    db.writeAudit(role, 'business.status', 'businesses', businessId, reason, {'status': x.status.name}, {'status': status.name});
    db.touch({DataDomain.admin, DataDomain.discovery});
  }

  @override
  Future<List<Listing>> listingsForReview({ModerationStatus? status}) async {
    _require('listing.moderate');
    await DemoBackend.latency(200);
    return db.listings.values
        .where((l) => l.status == ListingStatus.published && (status == null || l.moderation == status))
        .map((l) => l.copyWith(business: db.ref(l.businessId)))
        .toList()
      ..sort((a, b) => (b.publishedAt ?? DateTime(0)).compareTo(a.publishedAt ?? DateTime(0)));
  }

  @override
  Future<void> moderateListing(String listingId, ModerationStatus status, String reason) async {
    final role = _require('listing.moderate', reason: reason, reasonRequired: status != ModerationStatus.ok);
    await DemoBackend.latency(300);
    final l = db.listings[listingId]!;
    db.listings[listingId] = l.copyWith(moderation: status, moderationReason: reason);
    db.writeAudit(role, 'listing.moderate', 'listings', listingId, reason, {'moderation_status': l.moderation.name}, {'moderation_status': status.name});
    if (status != ModerationStatus.ok) {
      db.notify(l.businessId, NotificationCategory.system, '“${l.title}” was ${status.name} by moderation', reason,
          'mod:$listingId:${status.name}', route: '/business/listings/$listingId');
    }
    db.touch({DataDomain.admin, DataDomain.listings, DataDomain.discovery});
  }

  @override
  Future<List<NowRequest>> nowRequests() async {
    _require('now.read');
    await DemoBackend.latency(200);
    return db.nowRequests.values.toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  @override
  Future<List<Booking>> recentBookings() async {
    _require('booking.read');
    await DemoBackend.latency(200);
    return db.bookings.values.toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  @override
  Future<List<Dispute>> disputes() async {
    _require('dispute.manage');
    await DemoBackend.latency(200);
    return db.disputes.values.toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  @override
  Future<void> resolveDispute(String disputeId, String status, String resolution) async {
    final role = _require('dispute.manage', reason: resolution, reasonRequired: true);
    final d = db.disputes[disputeId]!;
    db.disputes[disputeId] = Dispute(id: d.id, bookingId: d.bookingId, reason: d.reason, status: status, createdAt: d.createdAt,
        bookingReference: d.bookingReference, openedBy: d.openedBy, resolution: resolution);
    db.writeAudit(role, 'dispute.update', 'disputes', disputeId, resolution, {'status': d.status}, {'status': status});
    db.touch({DataDomain.admin});
  }

  @override
  Future<List<AuditEntry>> auditLog() async {
    _require('audit.read');
    await DemoBackend.latency(180);
    return [...db.audit];
  }

  @override
  Future<void> upsertCategory(Category category, bool active, String reason) async {
    final role = _require('category.manage');
    db.writeAudit(role, 'category.upsert', 'categories', category.id, reason, null, {'name': category.name, 'active': active});
    db.touch({DataDomain.admin});
  }
}
