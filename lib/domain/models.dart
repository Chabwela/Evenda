import 'package:latlong2/latlong.dart';

import 'enums.dart';

export 'enums.dart';

DateTime? _dt(dynamic v) => v == null ? null : DateTime.parse(v as String).toLocal();
DateTime _d(dynamic v) => DateTime.parse(v as String);
double? _num(dynamic v) => v == null ? null : (v as num).toDouble();

// ---------------------------------------------------------------------------
// Reference data
// ---------------------------------------------------------------------------

class Category {
  const Category(this.id, this.name, this.kind, this.icon, {this.active = true, this.sort = 100});
  final String id;
  final String name;
  final OfferingType kind;
  final String icon;
  final bool active;
  final int sort;

  factory Category.fromRow(Map<String, dynamic> r) => Category(r['id'], r['name'], OfferingType.parse(r['kind']), r['icon'] ?? 'package',
      active: r['active'] as bool? ?? true, sort: (r['sort'] as num?)?.toInt() ?? 100);
}

/// Seeded categories (first migration), used until the live list loads and
/// when offline. The database is the authority: [CategoryCatalog.apply]
/// replaces this at start-up and after an admin edits categories.
const _seedCategories = <Category>[
  Category('tents', 'Tents & marquees', OfferingType.rental, 'tent', sort: 10),
  Category('chairs', 'Chairs', OfferingType.rental, 'armchair', sort: 20),
  Category('tables', 'Tables', OfferingType.rental, 'table', sort: 30),
  Category('linen', 'Linen & chair covers', OfferingType.rental, 'shirt', sort: 40),
  Category('decor', 'Décor & backdrops', OfferingType.rental, 'sparkles', sort: 50),
  Category('centrepieces', 'Centrepieces', OfferingType.rental, 'flower', sort: 60),
  Category('sound', 'Sound & PA', OfferingType.rental, 'speaker', sort: 70),
  Category('lighting', 'Lighting', OfferingType.rental, 'lightbulb', sort: 80),
  Category('staging', 'Staging & flooring', OfferingType.rental, 'layers', sort: 90),
  Category('catering_equip', 'Catering equipment', OfferingType.rental, 'cooking_pot', sort: 100),
  Category('styling', 'Event styling', OfferingType.service, 'palette', sort: 110),
  Category('catering', 'Catering', OfferingType.service, 'utensils', sort: 120),
  Category('florist', 'Floristry', OfferingType.service, 'flower_2', sort: 130),
  Category('photo_video', 'Photography & video', OfferingType.service, 'camera', sort: 140),
  Category('dj_mc', 'DJ & MC', OfferingType.service, 'music', sort: 150),
  Category('planning', 'Planning & coordination', OfferingType.service, 'clipboard_list', sort: 160),
];

/// Categories vendors can choose from (active only, in admin order).
/// Mutable on purpose: screens read it when they build, so a refreshed
/// catalogue shows up on the next build without threading a provider through
/// every picker.
final List<Category> kCategories = [..._seedCategories];
final Map<String, Category> _allCategories = {for (final c in _seedCategories) c.id: c};

abstract final class CategoryCatalog {
  /// Replace the catalogue with rows from the database (active and hidden).
  static void apply(List<Category> all) {
    if (all.isEmpty) return;
    _allCategories
      ..clear()
      ..addEntries(all.map((c) => MapEntry(c.id, c)));
    final active = all.where((c) => c.active).toList()..sort((a, b) => a.sort.compareTo(b.sort));
    kCategories
      ..clear()
      ..addAll(active);
  }

  /// Every category, including hidden ones, for the admin console.
  static List<Category> get all => _allCategories.values.toList()..sort((a, b) => a.sort.compareTo(b.sort));
}

/// Looks up hidden categories too, so existing listings keep their name.
Category categoryById(String? id) => _allCategories[id] ?? const Category('other', 'Other', OfferingType.service, 'package');

/// Lusaka neighbourhoods with representative coordinates (approximate
/// neighbourhood centres) used for search and location suggestions.
class Neighbourhood {
  const Neighbourhood(this.name, this.lat, this.lng);
  final String name;
  final double lat;
  final double lng;
  LatLng get point => LatLng(lat, lng);
}

const kLusakaCentre = LatLng(-15.4167, 28.2833);

const kNeighbourhoods = <Neighbourhood>[
  Neighbourhood('Avondale', -15.3880, 28.3500),
  Neighbourhood('Cathedral Hill', -15.4230, 28.2920),
  Neighbourhood('Chelston', -15.3880, 28.3750),
  Neighbourhood('Chilenje', -15.4500, 28.3100),
  Neighbourhood('Emmasdale', -15.3900, 28.2650),
  Neighbourhood('Ibex Hill', -15.4320, 28.3580),
  Neighbourhood('Kabulonga', -15.4050, 28.3330),
  Neighbourhood('Kabwata', -15.4380, 28.2980),
  Neighbourhood('Lusaka CBD', -15.4167, 28.2833),
  Neighbourhood('Longacres', -15.4180, 28.3130),
  Neighbourhood('Makeni', -15.4650, 28.2550),
  Neighbourhood('Matero', -15.3700, 28.2500),
  Neighbourhood('Northmead', -15.4020, 28.3010),
  Neighbourhood('Olympia', -15.3950, 28.3180),
  Neighbourhood('Rhodes Park', -15.4120, 28.3080),
  Neighbourhood('Roma', -15.3750, 28.3150),
  Neighbourhood('Woodlands', -15.4300, 28.3250),
];

// ---------------------------------------------------------------------------
// Accounts & businesses
// ---------------------------------------------------------------------------

class Session {
  const Session({required this.userId, this.phone, this.fullName = '', this.isDemo = false});
  final String userId;
  final String? phone;
  final String fullName;
  final bool isDemo;

  Session copyWith({String? fullName}) =>
      Session(userId: userId, phone: phone, fullName: fullName ?? this.fullName, isDemo: isDemo);
}

/// Compact reference to another business, embedded in bookings, offers, etc.
class BizRef {
  const BizRef({required this.id, required this.name, this.logoUrl, this.neighbourhood, this.verified = false, this.whatsapp, this.phone});
  final String id;
  final String name;
  final String? logoUrl;
  final String? neighbourhood;
  final bool verified;
  final String? whatsapp;
  final String? phone;

  factory BizRef.fromRow(Map<String, dynamic> r) => BizRef(
        id: r['id'],
        name: r['name'],
        logoUrl: r['logo_path'],
        neighbourhood: r['neighbourhood'],
        verified: r['verification_status'] == 'verified',
        whatsapp: r['whatsapp'],
        phone: r['phone'],
      );
}

class Business {
  const Business({
    required this.id,
    required this.ownerId,
    required this.name,
    this.description = '',
    this.logoUrl,
    this.primaryCategory,
    this.categories = const [],
    this.offeringTypes = const {},
    this.phone,
    this.whatsapp,
    this.email,
    this.neighbourhood,
    this.addressLine,
    this.location,
    this.locationPrecision = LocationPrecision.approximate,
    this.serviceRadiusKm = 25,
    this.operatingHours = const {},
    this.onboardingStep = 0,
    this.onboardingCompleted = false,
    this.verification = VerificationStatus.unverified,
    this.status = BusinessStatus.active,
    this.createdAt,
  });

  final String id;
  final String ownerId;
  final String name;
  final String description;
  final String? logoUrl;
  final String? primaryCategory;
  final List<String> categories;
  final Set<OfferingType> offeringTypes;
  final String? phone;
  final String? whatsapp;
  final String? email;
  final String? neighbourhood;
  final String? addressLine;

  /// Public location (exact or rounded, per [locationPrecision]).
  final LatLng? location;
  final LocationPrecision locationPrecision;
  final int serviceRadiusKm;

  /// Day key (mon..sun) -> "08:00-17:00" or "closed".
  final Map<String, String> operatingHours;
  final int onboardingStep;
  final bool onboardingCompleted;
  final VerificationStatus verification;
  final BusinessStatus status;
  final DateTime? createdAt;

  bool get rents => offeringTypes.contains(OfferingType.rental);
  bool get servicesOnly => !rents && offeringTypes.isNotEmpty;
  bool get verified => verification == VerificationStatus.verified;

  BizRef get ref =>
      BizRef(id: id, name: name, logoUrl: logoUrl, neighbourhood: neighbourhood, verified: verified, whatsapp: whatsapp, phone: phone);

  /// Explicit column list: the exact `location` column is not readable by clients.
  static const columns =
      'id, owner_id, name, description, logo_path, primary_category, offering_types, phone, whatsapp, email, '
      'neighbourhood, address_line, location_precision, public_location, service_radius_km, operating_hours, '
      'onboarding_step, onboarding_completed_at, verification_status, status, created_at, business_categories(category_id)';

  factory Business.fromRow(Map<String, dynamic> r) {
    LatLng? loc;
    final p = r['public_location'];
    if (p is Map && p['coordinates'] is List) {
      final c = p['coordinates'] as List;
      loc = LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble());
    } else if (p is String && p.startsWith('POINT')) {
      final m = RegExp(r'POINT\(([-\d.]+) ([-\d.]+)\)').firstMatch(p);
      if (m != null) loc = LatLng(double.parse(m[2]!), double.parse(m[1]!));
    }
    return Business(
      id: r['id'],
      ownerId: r['owner_id'],
      name: r['name'],
      description: r['description'] ?? '',
      logoUrl: r['logo_path'],
      primaryCategory: r['primary_category'],
      categories: [for (final c in (r['business_categories'] as List? ?? const [])) c['category_id'] as String],
      offeringTypes: {for (final o in (r['offering_types'] as List? ?? const [])) OfferingType.parse(o)},
      phone: r['phone'],
      whatsapp: r['whatsapp'],
      email: r['email'],
      neighbourhood: r['neighbourhood'],
      addressLine: r['address_line'],
      location: loc,
      locationPrecision: LocationPrecision.parse(r['location_precision']),
      serviceRadiusKm: r['service_radius_km'] ?? 25,
      operatingHours: Map<String, String>.from(r['operating_hours'] ?? const {}),
      onboardingStep: r['onboarding_step'] ?? 0,
      onboardingCompleted: r['onboarding_completed_at'] != null,
      verification: VerificationStatus.parse(r['verification_status']),
      status: BusinessStatus.parse(r['status']),
      createdAt: _dt(r['created_at']),
    );
  }

  Business copyWith({
    String? name,
    String? description,
    String? logoUrl,
    String? primaryCategory,
    List<String>? categories,
    Set<OfferingType>? offeringTypes,
    String? phone,
    String? whatsapp,
    String? email,
    String? neighbourhood,
    String? addressLine,
    LatLng? location,
    LocationPrecision? locationPrecision,
    int? serviceRadiusKm,
    Map<String, String>? operatingHours,
    int? onboardingStep,
    bool? onboardingCompleted,
    VerificationStatus? verification,
    BusinessStatus? status,
  }) =>
      Business(
        id: id,
        ownerId: ownerId,
        name: name ?? this.name,
        description: description ?? this.description,
        logoUrl: logoUrl ?? this.logoUrl,
        primaryCategory: primaryCategory ?? this.primaryCategory,
        categories: categories ?? this.categories,
        offeringTypes: offeringTypes ?? this.offeringTypes,
        phone: phone ?? this.phone,
        whatsapp: whatsapp ?? this.whatsapp,
        email: email ?? this.email,
        neighbourhood: neighbourhood ?? this.neighbourhood,
        addressLine: addressLine ?? this.addressLine,
        location: location ?? this.location,
        locationPrecision: locationPrecision ?? this.locationPrecision,
        serviceRadiusKm: serviceRadiusKm ?? this.serviceRadiusKm,
        operatingHours: operatingHours ?? this.operatingHours,
        onboardingStep: onboardingStep ?? this.onboardingStep,
        onboardingCompleted: onboardingCompleted ?? this.onboardingCompleted,
        verification: verification ?? this.verification,
        status: status ?? this.status,
        createdAt: createdAt,
      );
}

class TeamMember {
  const TeamMember({required this.id, required this.displayName, required this.role, this.phone, this.email, this.userId, this.invited = false});
  final String id;
  final String displayName;
  final MemberRole role;
  final String? phone;
  final String? email;
  final String? userId;
  final bool invited;

  factory TeamMember.fromRow(Map<String, dynamic> r) => TeamMember(
        id: r['id'],
        displayName: (r['display_name'] as String?)?.isNotEmpty == true ? r['display_name'] : ((r['invited_email'] ?? r['email'] ?? r['invited_phone']) ?? 'Member'),
        role: MemberRole.parse(r['role']),
        phone: r['invited_phone'],
        email: r['invited_email'] ?? r['email'],
        userId: r['user_id'],
        invited: r['status'] == 'invited',
      );
}

// ---------------------------------------------------------------------------
// Listings & inventory
// ---------------------------------------------------------------------------

class Listing {
  const Listing({
    required this.id,
    required this.businessId,
    required this.kind,
    required this.title,
    required this.categoryId,
    this.description = '',
    this.status = ListingStatus.draft,
    this.priceAmount,
    this.priceUnit = PriceUnit.onQuote,
    this.depositAmount,
    this.depositNote,
    this.terms = '',
    this.condition,
    this.totalQuantity = 0,
    this.damagedQuantity = 0,
    this.inspectionQuantity = 0,
    this.tracksStock = true,
    this.serviceAreaKm,
    this.packageItems = const [],
    this.photos = const [],
    this.moderation = ModerationStatus.ok,
    this.moderationReason,
    this.publishedAt,
    this.updatedAt,
    this.business,
  });

  final String id;
  final String businessId;
  final OfferingType kind;
  final String title;
  final String categoryId;
  final String description;
  final ListingStatus status;
  final double? priceAmount;
  final PriceUnit priceUnit;
  final double? depositAmount;
  final String? depositNote;
  final String terms;
  final String? condition;

  /// For services, total_quantity is jobs per day (capacity).
  final int totalQuantity;
  final int damagedQuantity;
  final int inspectionQuantity;
  final bool tracksStock;
  final int? serviceAreaKm;
  final List<String> packageItems;

  /// Photo references: `asset:` paths (demo) or public URLs.
  final List<String> photos;
  final ModerationStatus moderation;
  final String? moderationReason;
  final DateTime? publishedAt;
  final DateTime? updatedAt;

  /// Owning business, populated for discovery results.
  final BizRef? business;

  int get usable => totalQuantity - damagedQuantity - inspectionQuantity;
  String? get coverPhoto => photos.isEmpty ? null : photos.first;
  bool get isService => kind == OfferingType.service;

  static const columns = '*, listing_photos(storage_path, sort), '
      'businesses(id, name, logo_path, neighbourhood, verification_status, whatsapp, phone)';

  factory Listing.fromRow(Map<String, dynamic> r, {String Function(String path)? photoUrl}) {
    final photos = [...(r['listing_photos'] as List? ?? const [])]
      ..sort((a, b) => (a['sort'] as int).compareTo(b['sort'] as int));
    return Listing(
      id: r['id'],
      businessId: r['business_id'],
      kind: OfferingType.parse(r['kind']),
      title: r['title'],
      categoryId: r['category_id'],
      description: r['description'] ?? '',
      status: ListingStatus.parse(r['status']),
      priceAmount: _num(r['price_amount']),
      priceUnit: PriceUnit.parse(r['price_unit']),
      depositAmount: _num(r['deposit_amount']),
      depositNote: r['deposit_note'],
      terms: r['terms'] ?? '',
      condition: r['condition'],
      totalQuantity: r['total_quantity'] ?? 0,
      damagedQuantity: r['damaged_quantity'] ?? 0,
      inspectionQuantity: r['inspection_quantity'] ?? 0,
      tracksStock: r['tracks_stock'] ?? true,
      serviceAreaKm: r['service_area_km'],
      packageItems: [for (final p in (r['package_items'] as List? ?? const [])) '$p'],
      photos: [for (final p in photos) photoUrl?.call(p['storage_path']) ?? p['storage_path'] as String],
      moderation: ModerationStatus.parse(r['moderation_status']),
      moderationReason: r['moderation_reason'],
      publishedAt: _dt(r['published_at']),
      updatedAt: _dt(r['updated_at']),
      business: r['businesses'] is Map ? BizRef.fromRow(r['businesses']) : null,
    );
  }

  Listing copyWith({
    ListingStatus? status,
    int? totalQuantity,
    int? damagedQuantity,
    int? inspectionQuantity,
    ModerationStatus? moderation,
    String? moderationReason,
    BizRef? business,
    List<String>? photos,
  }) =>
      Listing(
        id: id,
        businessId: businessId,
        kind: kind,
        title: title,
        categoryId: categoryId,
        description: description,
        status: status ?? this.status,
        priceAmount: priceAmount,
        priceUnit: priceUnit,
        depositAmount: depositAmount,
        depositNote: depositNote,
        terms: terms,
        condition: condition,
        totalQuantity: totalQuantity ?? this.totalQuantity,
        damagedQuantity: damagedQuantity ?? this.damagedQuantity,
        inspectionQuantity: inspectionQuantity ?? this.inspectionQuantity,
        tracksStock: tracksStock,
        serviceAreaKm: serviceAreaKm,
        packageItems: packageItems,
        photos: photos ?? this.photos,
        moderation: moderation ?? this.moderation,
        moderationReason: moderationReason ?? this.moderationReason,
        publishedAt: publishedAt ?? (status == ListingStatus.published ? DateTime.now() : null),
        updatedAt: DateTime.now(),
        business: business ?? this.business,
      );
}

/// Editable fields of a listing (create and update).
class ListingDraft {
  ListingDraft({
    required this.businessId,
    this.kind = OfferingType.rental,
    this.title = '',
    this.description = '',
    this.categoryId,
    this.status = ListingStatus.draft,
    this.priceAmount,
    this.priceUnit = PriceUnit.perItemPerDay,
    this.depositAmount,
    this.depositNote,
    this.terms = '',
    this.condition,
    this.totalQuantity = 0,
    this.tracksStock = true,
    this.serviceAreaKm,
    this.packageItems = const [],
    this.photos = const [],
  });

  String businessId;
  OfferingType kind;
  String title;
  String description;
  String? categoryId;
  ListingStatus status;
  double? priceAmount;
  PriceUnit priceUnit;
  double? depositAmount;
  String? depositNote;
  String terms;
  String? condition;
  int totalQuantity;
  bool tracksStock;
  int? serviceAreaKm;
  List<String> packageItems;
  List<String> photos;

  factory ListingDraft.from(Listing l) => ListingDraft(
        businessId: l.businessId,
        kind: l.kind,
        title: l.title,
        description: l.description,
        categoryId: l.categoryId,
        status: l.status,
        priceAmount: l.priceAmount,
        priceUnit: l.priceUnit,
        depositAmount: l.depositAmount,
        depositNote: l.depositNote,
        terms: l.terms,
        condition: l.condition,
        totalQuantity: l.totalQuantity,
        tracksStock: l.tracksStock,
        serviceAreaKm: l.serviceAreaKm,
        packageItems: [...l.packageItems],
        photos: [...l.photos],
      );

  Map<String, dynamic> toJson() => {
        'business_id': businessId,
        'kind': kind.wire,
        'title': title.trim(),
        'description': description.trim(),
        'category_id': categoryId,
        'status': status.wire,
        'price_amount': priceUnit == PriceUnit.onQuote ? null : priceAmount,
        'price_unit': priceUnit.wire,
        'deposit_amount': depositAmount,
        'deposit_note': depositNote,
        'terms': terms.trim(),
        'condition': condition,
        'total_quantity': totalQuantity,
        'tracks_stock': tracksStock,
        'service_area_km': serviceAreaKm,
        'package_items': packageItems,
      };
}

class Reservation {
  const Reservation({
    required this.id,
    required this.listingId,
    required this.quantity,
    required this.startsOn,
    required this.endsOn,
    required this.source,
    required this.status,
    this.bookingId,
    this.clientLabel,
    this.note,
    this.listingTitle,
  });

  final String id;
  final String listingId;
  final int quantity;
  final DateTime startsOn;
  final DateTime endsOn;
  final ReservationSource source;
  final ReservationStatus status;
  final String? bookingId;
  final String? clientLabel;
  final String? note;
  final String? listingTitle;

  bool covers(DateTime day) => !day.isBefore(startsOn) && !day.isAfter(endsOn);

  factory Reservation.fromRow(Map<String, dynamic> r) => Reservation(
        id: r['id'],
        listingId: r['listing_id'],
        quantity: r['quantity'],
        startsOn: _d(r['starts_on']),
        endsOn: _d(r['ends_on']),
        source: ReservationSource.parse(r['source']),
        status: ReservationStatus.parse(r['status']),
        bookingId: r['booking_id'],
        clientLabel: r['client_label'],
        note: r['note'],
        listingTitle: r['listings'] is Map ? r['listings']['title'] : null,
      );

  Reservation withStatus(ReservationStatus s) => Reservation(
        id: id,
        listingId: listingId,
        quantity: quantity,
        startsOn: startsOn,
        endsOn: endsOn,
        source: source,
        status: s,
        bookingId: bookingId,
        clientLabel: clientLabel,
        note: note,
        listingTitle: listingTitle,
      );
}

class AvailabilityDay {
  const AvailabilityDay({required this.day, required this.usable, required this.reserved, required this.available, required this.blocked});
  final DateTime day;
  final int usable;
  final int reserved;
  final int available;
  final bool blocked;

  factory AvailabilityDay.fromRow(Map<String, dynamic> r) => AvailabilityDay(
        day: _d(r['day']),
        usable: r['usable'],
        reserved: r['reserved'],
        available: r['available'],
        blocked: r['blocked'] ?? false,
      );
}

class AvailabilityBlock {
  const AvailabilityBlock({required this.id, required this.startsOn, required this.endsOn, this.listingId, this.reason});
  final String id;
  final String? listingId;
  final DateTime startsOn;
  final DateTime endsOn;
  final String? reason;

  factory AvailabilityBlock.fromRow(Map<String, dynamic> r) => AvailabilityBlock(
        id: r['id'],
        listingId: r['listing_id'],
        startsOn: _d(r['starts_on']),
        endsOn: _d(r['ends_on']),
        reason: r['reason'],
      );
}

class InventoryConflict {
  const InventoryConflict({required this.listingId, required this.title, required this.day, required this.usable, required this.committed});
  final String listingId;
  final String title;
  final DateTime day;
  final int usable;
  final int committed;
  int get shortfall => committed - usable;

  factory InventoryConflict.fromRow(Map<String, dynamic> r) => InventoryConflict(
        listingId: r['listing_id'],
        title: r['title'],
        day: _d(r['day']),
        usable: r['usable'],
        committed: r['committed'],
      );
}

/// A broadcast about another supplier's inventory, shown in feeds.
class InventoryUpdate {
  const InventoryUpdate({
    required this.id,
    required this.type,
    required this.supplier,
    required this.createdAt,
    this.listing,
    this.payload = const {},
  });
  final String id;
  final String type;
  final BizRef supplier;
  final Listing? listing;
  final Map<String, dynamic> payload;
  final DateTime createdAt;

  String get headline => switch (type) {
        'listing_published' => 'New listing',
        'stock_added' => '+${payload['delta']} added',
        'stock_restored' => 'Back in service',
        'availability_opened' => 'Dates opened',
        _ => 'Updated',
      };
}

// ---------------------------------------------------------------------------
// Discovery
// ---------------------------------------------------------------------------

class SearchQuery {
  const SearchQuery({
    this.text = '',
    this.categoryId,
    this.from,
    this.to,
    this.quantity,
    this.neighbourhood,
    this.maxPrice,
    this.savedOnly = false,
    this.kind,
  });

  final String text;
  final String? categoryId;
  final DateTime? from;
  final DateTime? to;
  final int? quantity;
  final String? neighbourhood;
  final double? maxPrice;
  final bool savedOnly;
  final OfferingType? kind;

  bool get hasDates => from != null;
  bool get isEmpty =>
      text.isEmpty && categoryId == null && from == null && quantity == null && neighbourhood == null && maxPrice == null && !savedOnly;

  SearchQuery copyWith({
    String? text,
    String? Function()? categoryId,
    DateTime? Function()? from,
    DateTime? Function()? to,
    int? Function()? quantity,
    String? Function()? neighbourhood,
    double? Function()? maxPrice,
    bool? savedOnly,
  }) =>
      SearchQuery(
        text: text ?? this.text,
        categoryId: categoryId != null ? categoryId() : this.categoryId,
        from: from != null ? from() : this.from,
        to: to != null ? to() : this.to,
        quantity: quantity != null ? quantity() : this.quantity,
        neighbourhood: neighbourhood != null ? neighbourhood() : this.neighbourhood,
        maxPrice: maxPrice != null ? maxPrice() : this.maxPrice,
        savedOnly: savedOnly ?? this.savedOnly,
        kind: kind,
      );
}

class SearchResult {
  const SearchResult({required this.listing, this.available, this.distanceKm});
  final Listing listing;

  /// Date-aware available quantity when the query has dates (backend computed).
  final int? available;
  final double? distanceKm;
}

class SupplierFollow {
  const SupplierFollow({required this.supplier, this.muted = false, this.pushEnabled = true});
  final BizRef supplier;
  final bool muted;
  final bool pushEnabled;
}

// ---------------------------------------------------------------------------
// Quotations & bookings
// ---------------------------------------------------------------------------

class QuoteRequestItem {
  const QuoteRequestItem({required this.description, required this.quantity, this.listingId, this.id});
  final String? id;
  final String? listingId;
  final String description;
  final int quantity;

  Map<String, dynamic> toJson() => {'listing_id': listingId, 'description': description, 'quantity': quantity};
  factory QuoteRequestItem.fromRow(Map<String, dynamic> r) =>
      QuoteRequestItem(id: r['id'], listingId: r['listing_id'], description: r['description'], quantity: r['quantity']);
}

class QuoteMessage {
  const QuoteMessage({required this.id, required this.senderBusinessId, required this.body, required this.createdAt});
  final String id;
  final String senderBusinessId;
  final String body;
  final DateTime createdAt;

  factory QuoteMessage.fromRow(Map<String, dynamic> r) =>
      QuoteMessage(id: r['id'], senderBusinessId: r['sender_business_id'], body: r['body'], createdAt: _dt(r['created_at'])!);
}

class Charge {
  const Charge(this.label, this.amount);
  final String label;
  final double amount;
  Map<String, dynamic> toJson() => {'label': label, 'amount': amount};
  factory Charge.fromJson(Map<String, dynamic> j) => Charge(j['label'], (j['amount'] as num).toDouble());
}

class QuotationItem {
  const QuotationItem({required this.description, required this.quantity, required this.unitPrice, this.days = 1, this.listingId});
  final String? listingId;
  final String description;
  final int quantity;
  final double unitPrice;
  final int days;
  double get lineTotal => quantity * unitPrice * days;

  Map<String, dynamic> toJson() =>
      {'listing_id': listingId, 'description': description, 'quantity': quantity, 'unit_price': unitPrice, 'days': days};
  factory QuotationItem.fromRow(Map<String, dynamic> r) => QuotationItem(
        listingId: r['listing_id'],
        description: r['description'],
        quantity: r['quantity'],
        unitPrice: (r['unit_price'] as num).toDouble(),
        days: r['days'] ?? 1,
      );
}

class Quotation {
  const Quotation({
    required this.id,
    required this.requestId,
    required this.version,
    required this.status,
    required this.items,
    required this.validUntil,
    required this.createdAt,
    this.charges = const [],
    this.depositAmount = 0,
    this.depositTerms,
    this.paymentTerms = '',
    this.conditions = '',
  });

  final String id;
  final String requestId;
  final int version;
  final QuotationStatus status;
  final List<QuotationItem> items;
  final List<Charge> charges;
  final double depositAmount;
  final String? depositTerms;
  final String paymentTerms;
  final DateTime validUntil;
  final String conditions;
  final DateTime createdAt;

  double get subtotal => items.fold(0, (s, i) => s + i.lineTotal);
  double get chargesTotal => charges.fold(0, (s, c) => s + c.amount);
  double get total => subtotal + chargesTotal;

  factory Quotation.fromRow(Map<String, dynamic> r) => Quotation(
        id: r['id'],
        requestId: r['request_id'],
        version: r['version'],
        status: QuotationStatus.parse(r['status']),
        items: [for (final i in (r['quotation_items'] as List? ?? const [])) QuotationItem.fromRow(i)],
        charges: [for (final c in (r['additional_charges'] as List? ?? const [])) Charge.fromJson(c)],
        depositAmount: _num(r['deposit_amount']) ?? 0,
        depositTerms: r['deposit_terms'],
        paymentTerms: r['payment_terms'] ?? '',
        validUntil: _d(r['valid_until']),
        conditions: r['conditions'] ?? '',
        createdAt: _dt(r['created_at'])!,
      );

  Quotation withStatus(QuotationStatus s) => Quotation(
        id: id,
        requestId: requestId,
        version: version,
        status: s,
        items: items,
        charges: charges,
        depositAmount: depositAmount,
        depositTerms: depositTerms,
        paymentTerms: paymentTerms,
        validUntil: validUntil,
        conditions: conditions,
        createdAt: createdAt,
      );
}

class QuoteRequest {
  const QuoteRequest({
    required this.id,
    required this.requester,
    required this.supplier,
    required this.status,
    required this.neededFrom,
    required this.neededTo,
    required this.items,
    required this.createdAt,
    this.eventId,
    this.fulfilment = Fulfilment.pickup,
    this.venue,
    this.deliveryNotes,
    this.message = '',
    this.quotations = const [],
    this.messages = const [],
    this.bookingId,
  });

  final String id;
  final BizRef requester;
  final BizRef supplier;
  final QuoteRequestStatus status;
  final DateTime neededFrom;
  final DateTime neededTo;
  final List<QuoteRequestItem> items;
  final DateTime createdAt;
  final String? eventId;
  final Fulfilment fulfilment;
  final String? venue;
  final String? deliveryNotes;
  final String message;
  final List<Quotation> quotations;
  final List<QuoteMessage> messages;
  final String? bookingId;

  Quotation? get latestQuotation => quotations.isEmpty ? null : (quotations.toList()..sort((a, b) => b.version.compareTo(a.version))).first;
  Quotation? get openQuotation => quotations.where((q) => q.status == QuotationStatus.sent).firstOrNull;
  bool isIncomingFor(String businessId) => supplier.id == businessId;
  int get days => neededTo.difference(neededFrom).inDays + 1;

  static const columns = '*, requester:businesses!quote_requests_requester_business_id_fkey(id, name, logo_path, neighbourhood, verification_status, whatsapp, phone), '
      'supplier:businesses!quote_requests_supplier_business_id_fkey(id, name, logo_path, neighbourhood, verification_status, whatsapp, phone), '
      'quote_request_items(*), quotations(*, quotation_items(*)), quote_messages(*), bookings(id)';

  factory QuoteRequest.fromRow(Map<String, dynamic> r) => QuoteRequest(
        id: r['id'],
        requester: BizRef.fromRow(r['requester']),
        supplier: BizRef.fromRow(r['supplier']),
        status: QuoteRequestStatus.parse(r['status']),
        neededFrom: _d(r['needed_from']),
        neededTo: _d(r['needed_to']),
        items: [for (final i in (r['quote_request_items'] as List? ?? const [])) QuoteRequestItem.fromRow(i)],
        createdAt: _dt(r['created_at'])!,
        eventId: r['event_id'],
        fulfilment: Fulfilment.parse(r['fulfilment']),
        venue: r['venue'],
        deliveryNotes: r['delivery_notes'],
        message: r['message'] ?? '',
        quotations: [for (final q in (r['quotations'] as List? ?? const [])) Quotation.fromRow(q)],
        messages: [for (final m in (r['quote_messages'] as List? ?? const [])) QuoteMessage.fromRow(m)]
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt)),
        bookingId: (r['bookings'] as List?)?.firstOrNull?['id'],
      );
}

class QuoteRequestDraft {
  QuoteRequestDraft({
    required this.requesterId,
    required this.supplierId,
    required this.neededFrom,
    required this.neededTo,
    required this.items,
    required this.idempotencyKey,
    this.eventId,
    this.fulfilment = Fulfilment.pickup,
    this.venue,
    this.deliveryNotes,
    this.message = '',
  });
  final String requesterId;
  final String supplierId;
  final DateTime neededFrom;
  final DateTime neededTo;
  final List<QuoteRequestItem> items;
  final String idempotencyKey;
  final String? eventId;
  final Fulfilment fulfilment;
  final String? venue;
  final String? deliveryNotes;
  final String message;
}

class QuotationDraft {
  QuotationDraft({
    required this.requestId,
    required this.items,
    required this.validUntil,
    this.charges = const [],
    this.depositAmount = 0,
    this.depositTerms,
    this.paymentTerms = '',
    this.conditions = '',
  });
  final String requestId;
  final List<QuotationItem> items;
  final List<Charge> charges;
  final double depositAmount;
  final String? depositTerms;
  final String paymentTerms;
  final DateTime validUntil;
  final String conditions;
}

class BookingItem {
  const BookingItem({required this.description, required this.quantity, required this.unitPrice, required this.lineTotal, this.listingId});
  final String? listingId;
  final String description;
  final int quantity;
  final double unitPrice;
  final double lineTotal;

  factory BookingItem.fromRow(Map<String, dynamic> r) => BookingItem(
        listingId: r['listing_id'],
        description: r['description'],
        quantity: r['quantity'],
        unitPrice: (r['unit_price'] as num).toDouble(),
        lineTotal: (r['line_total'] as num).toDouble(),
      );
}

class BookingEvent {
  const BookingEvent({required this.to, required this.at, this.from, this.note});
  final BookingStatus? from;
  final BookingStatus to;
  final DateTime at;
  final String? note;

  factory BookingEvent.fromRow(Map<String, dynamic> r) => BookingEvent(
        from: r['from_status'] == null ? null : BookingStatus.parse(r['from_status']),
        to: BookingStatus.parse(r['to_status']),
        at: _dt(r['created_at'])!,
        note: r['note'],
      );
}

class PaymentRecord {
  const PaymentRecord({
    required this.id,
    required this.amount,
    required this.method,
    required this.kind,
    required this.recordedByBusinessId,
    required this.createdAt,
    this.reference,
    this.confirmedAt,
    this.note,
  });
  final String id;
  final double amount;
  final String method;
  final String kind;
  final String recordedByBusinessId;
  final DateTime createdAt;
  final String? reference;
  final DateTime? confirmedAt;
  final String? note;

  String get methodLabel => switch (method) {
        'mobile_money' => 'Mobile money',
        'bank_transfer' => 'Bank transfer',
        'cash' => 'Cash',
        _ => 'Other',
      };

  factory PaymentRecord.fromRow(Map<String, dynamic> r) => PaymentRecord(
        id: r['id'],
        amount: (r['amount'] as num).toDouble(),
        method: r['method'],
        kind: r['kind'],
        recordedByBusinessId: r['recorded_by_business'],
        createdAt: _dt(r['created_at'])!,
        reference: r['reference'],
        confirmedAt: _dt(r['confirmed_by_counterparty_at']),
        note: r['note'],
      );
}

class Booking {
  const Booking({
    required this.id,
    required this.reference,
    required this.source,
    required this.requester,
    required this.supplier,
    required this.startsOn,
    required this.endsOn,
    required this.status,
    required this.paymentStatus,
    required this.total,
    required this.fulfilment,
    required this.createdAt,
    this.depositAmount = 0,
    this.quotationId,
    this.requestId,
    this.nowOfferId,
    this.eventId,
    this.deliveryNotes,
    this.items = const [],
    this.history = const [],
    this.payments = const [],
  });

  final String id;
  final String reference;
  final BookingSource source;
  final BizRef requester;
  final BizRef supplier;
  final DateTime startsOn;
  final DateTime endsOn;
  final BookingStatus status;
  final PaymentStatus paymentStatus;
  final double total;
  final double depositAmount;
  final Fulfilment fulfilment;
  final DateTime createdAt;
  final String? quotationId;
  final String? requestId;
  final String? nowOfferId;
  final String? eventId;
  final String? deliveryNotes;
  final List<BookingItem> items;
  final List<BookingEvent> history;
  final List<PaymentRecord> payments;

  bool isSupplier(String businessId) => supplier.id == businessId;
  BizRef counterparty(String businessId) => isSupplier(businessId) ? requester : supplier;
  double get confirmedPaid => payments
      .where((p) => p.confirmedAt != null)
      .fold(0.0, (s, p) => s + (p.kind == 'refund' ? -p.amount : p.amount));

  static const columns = '*, requester:businesses!bookings_requester_business_id_fkey(id, name, logo_path, neighbourhood, verification_status, whatsapp, phone), '
      'supplier:businesses!bookings_supplier_business_id_fkey(id, name, logo_path, neighbourhood, verification_status, whatsapp, phone), '
      'booking_items(*), booking_status_history(*), payment_records(*)';

  factory Booking.fromRow(Map<String, dynamic> r) => Booking(
        id: r['id'],
        reference: r['reference'],
        source: BookingSource.parse(r['source']),
        requester: BizRef.fromRow(r['requester']),
        supplier: BizRef.fromRow(r['supplier']),
        startsOn: _d(r['starts_on']),
        endsOn: _d(r['ends_on']),
        status: BookingStatus.parse(r['status']),
        paymentStatus: PaymentStatus.parse(r['payment_status']),
        total: (r['total'] as num).toDouble(),
        depositAmount: _num(r['deposit_amount']) ?? 0,
        fulfilment: Fulfilment.parse(r['fulfilment']),
        createdAt: _dt(r['created_at'])!,
        quotationId: r['quotation_id'],
        requestId: r['request_id'],
        nowOfferId: r['now_offer_id'],
        eventId: r['event_id'],
        deliveryNotes: r['delivery_notes'],
        items: [for (final i in (r['booking_items'] as List? ?? const [])) BookingItem.fromRow(i)],
        history: [for (final h in (r['booking_status_history'] as List? ?? const [])) BookingEvent.fromRow(h)]
          ..sort((a, b) => a.at.compareTo(b.at)),
        payments: [for (final p in (r['payment_records'] as List? ?? const [])) PaymentRecord.fromRow(p)]
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt)),
      );
}

// ---------------------------------------------------------------------------
// My Work
// ---------------------------------------------------------------------------

class Requirement {
  const Requirement({
    required this.id,
    required this.label,
    required this.responsibility,
    this.categoryId,
    this.quantity,
    this.supplierName,
    this.supplierBusinessId,
    this.bookingId,
    this.notes,
  });
  final String id;
  final String label;
  final Responsibility responsibility;
  final String? categoryId;
  final int? quantity;
  final String? supplierName;
  final String? supplierBusinessId;
  final String? bookingId;
  final String? notes;

  factory Requirement.fromRow(Map<String, dynamic> r) => Requirement(
        id: r['id'],
        label: r['label'],
        responsibility: Responsibility.parse(r['responsibility']),
        categoryId: r['category_id'],
        quantity: r['quantity'],
        supplierBusinessId: r['supplier_business_id'],
        supplierName: r['businesses'] is Map ? r['businesses']['name'] : null,
        bookingId: r['booking_id'],
        notes: r['notes'],
      );

  Map<String, dynamic> toJson(String eventId) => {
        'event_id': eventId,
        'label': label,
        'responsibility': responsibility.wire,
        'category_id': categoryId,
        'quantity': quantity,
        'supplier_business_id': supplierBusinessId,
        'booking_id': bookingId,
        'notes': notes,
      };
}

class EventPlan {
  const EventPlan({
    required this.id,
    required this.businessId,
    required this.name,
    required this.type,
    required this.startsAt,
    required this.endsAt,
    this.venueName,
    this.venueAddress,
    this.clientName,
    this.guestCount,
    this.notes = '',
    this.status = EventStatus.planning,
    this.sourceBookingId,
    this.requirements = const [],
  });

  final String id;
  final String businessId;
  final String name;
  final EventType type;
  final DateTime startsAt;
  final DateTime endsAt;
  final String? venueName;
  final String? venueAddress;
  final String? clientName;
  final int? guestCount;
  final String notes;
  final EventStatus status;
  final String? sourceBookingId;
  final List<Requirement> requirements;

  factory EventPlan.fromRow(Map<String, dynamic> r) => EventPlan(
        id: r['id'],
        businessId: r['business_id'],
        name: r['name'],
        type: EventType.parse(r['event_type']),
        startsAt: _dt(r['starts_at'])!,
        endsAt: _dt(r['ends_at'])!,
        venueName: r['venue_name'],
        venueAddress: r['venue_address'],
        clientName: r['client_name'],
        guestCount: r['guest_count'],
        notes: r['notes'] ?? '',
        status: EventStatus.parse(r['status']),
        sourceBookingId: r['source_booking_id'],
        requirements: [for (final q in (r['event_requirements'] as List? ?? const [])) Requirement.fromRow(q)],
      );
}

class EventDraft {
  EventDraft({
    required this.businessId,
    this.name = '',
    this.type = EventType.wedding,
    DateTime? startsAt,
    DateTime? endsAt,
    this.venueName,
    this.venueAddress,
    this.clientName,
    this.guestCount,
    this.notes = '',
    this.status = EventStatus.planning,
    List<Requirement>? requirements,
  })  : startsAt = startsAt ?? DateTime.now().add(const Duration(days: 7)),
        endsAt = endsAt ?? DateTime.now().add(const Duration(days: 7, hours: 6)),
        requirements = requirements ?? [];

  String businessId;
  String name;
  EventType type;
  DateTime startsAt;
  DateTime endsAt;
  String? venueName;
  String? venueAddress;
  String? clientName;
  int? guestCount;
  String notes;
  EventStatus status;
  List<Requirement> requirements;

  factory EventDraft.from(EventPlan e) => EventDraft(
        businessId: e.businessId,
        name: e.name,
        type: e.type,
        startsAt: e.startsAt,
        endsAt: e.endsAt,
        venueName: e.venueName,
        venueAddress: e.venueAddress,
        clientName: e.clientName,
        guestCount: e.guestCount,
        notes: e.notes,
        status: e.status,
        requirements: [...e.requirements],
      );

  Map<String, dynamic> toJson() => {
        'business_id': businessId,
        'name': name.trim(),
        'event_type': type.wire,
        'starts_at': startsAt.toUtc().toIso8601String(),
        'ends_at': endsAt.toUtc().toIso8601String(),
        'venue_name': venueName,
        'venue_address': venueAddress,
        'client_name': clientName,
        'guest_count': guestCount,
        'notes': notes,
        'status': status.wire,
      };
}

class WorkTask {
  const WorkTask({
    required this.id,
    required this.businessId,
    required this.title,
    required this.dueAt,
    required this.priority,
    required this.status,
    this.notes = '',
    this.eventId,
    this.eventName,
    this.bookingId,
    this.requirementId,
    this.generatedKey,
    this.offsetMinutes,
    this.assigneeName,
    this.completedAt,
  });

  final String id;
  final String businessId;
  final String title;
  final DateTime dueAt;
  final TaskPriority priority;
  final TaskStatus status;
  final String notes;
  final String? eventId;
  final String? eventName;
  final String? bookingId;
  final String? requirementId;
  final String? generatedKey;
  final int? offsetMinutes;
  final String? assigneeName;
  final DateTime? completedAt;

  bool get overdue => status.open && dueAt.isBefore(DateTime.now());
  bool get generated => generatedKey != null;

  factory WorkTask.fromRow(Map<String, dynamic> r) => WorkTask(
        id: r['id'],
        businessId: r['business_id'],
        title: r['title'],
        dueAt: _dt(r['due_at'])!,
        priority: TaskPriority.parse(r['priority']),
        status: TaskStatus.parse(r['status']),
        notes: r['notes'] ?? '',
        eventId: r['event_id'],
        eventName: r['events'] is Map ? r['events']['name'] : null,
        bookingId: r['booking_id'],
        requirementId: r['requirement_id'],
        generatedKey: r['generated_key'],
        offsetMinutes: r['offset_minutes'],
        completedAt: _dt(r['completed_at']),
      );

  WorkTask copyWith({String? title, DateTime? dueAt, TaskPriority? priority, TaskStatus? status, String? notes, String? eventName}) =>
      WorkTask(
        id: id,
        businessId: businessId,
        title: title ?? this.title,
        dueAt: dueAt ?? this.dueAt,
        priority: priority ?? this.priority,
        status: status ?? this.status,
        notes: notes ?? this.notes,
        eventId: eventId,
        eventName: eventName ?? this.eventName,
        bookingId: bookingId,
        requirementId: requirementId,
        generatedKey: generatedKey,
        offsetMinutes: offsetMinutes,
        assigneeName: assigneeName,
        completedAt: (status ?? this.status) == TaskStatus.done ? (completedAt ?? DateTime.now()) : null,
      );
}

class TaskReminder {
  const TaskReminder({required this.id, required this.remindAt, required this.kind, required this.status});
  final String id;
  final DateTime remindAt;
  final String kind;
  final String status;

  factory TaskReminder.fromRow(Map<String, dynamic> r) =>
      TaskReminder(id: r['id'], remindAt: _dt(r['remind_at'])!, kind: r['kind'], status: r['status']);
}

class WorkloadDay {
  const WorkloadDay({required this.day, this.events = 0, this.tasksDue = 0, this.overdue = 0, this.overlapping = false});
  final DateTime day;
  final int events;
  final int tasksDue;
  final int overdue;
  final bool overlapping;

  int get load => events * 3 + tasksDue;

  factory WorkloadDay.fromRow(Map<String, dynamic> r) => WorkloadDay(
        day: _d(r['day']),
        events: r['events'],
        tasksDue: r['tasks_due'],
        overdue: r['tasks_overdue'],
        overlapping: r['overlapping_events'] ?? false,
      );
}

// ---------------------------------------------------------------------------
// Notifications
// ---------------------------------------------------------------------------

class AppNotification {
  const AppNotification({
    required this.id,
    required this.category,
    required this.title,
    required this.body,
    required this.createdAt,
    this.imageUrl,
    this.route,
    this.data = const {},
    this.readAt,
    this.digest = false,
  });

  final String id;
  final NotificationCategory category;
  final String title;
  final String body;
  final DateTime createdAt;
  final String? imageUrl;
  final String? route;
  final Map<String, dynamic> data;
  final DateTime? readAt;
  final bool digest;

  bool get unread => readAt == null;

  factory AppNotification.fromRow(Map<String, dynamic> r, {String Function(String)? photoUrl}) => AppNotification(
        id: r['id'],
        category: NotificationCategory.parse(r['category']),
        title: r['title'],
        body: r['body'] ?? '',
        createdAt: _dt(r['created_at'])!,
        imageUrl: r['image_path'] == null ? null : (photoUrl?.call(r['image_path']) ?? r['image_path']),
        route: r['action_route'],
        data: Map<String, dynamic>.from(r['data'] ?? const {}),
        readAt: _dt(r['read_at']),
        digest: r['delivery_mode'] == 'digest',
      );

  AppNotification markRead() => AppNotification(
        id: id,
        category: category,
        title: title,
        body: body,
        createdAt: createdAt,
        imageUrl: imageUrl,
        route: route,
        data: data,
        readAt: readAt ?? DateTime.now(),
        digest: digest,
      );
}

class NotificationPrefs {
  const NotificationPrefs({
    this.inventoryUpdates = PrefLevel.digest,
    this.bookingActivity = PrefLevel.immediate,
    this.taskReminders = PrefLevel.immediate,
    this.nowRequests = true,
    this.quietStart = const Duration(hours: 21),
    this.quietEnd = const Duration(hours: 6, minutes: 30),
    this.digestHour = 7,
    this.preferredRadiusKm = 30,
    this.subscribedCategories = const {},
  });

  final PrefLevel inventoryUpdates;
  final PrefLevel bookingActivity;
  final PrefLevel taskReminders;
  final bool nowRequests;
  final Duration quietStart;
  final Duration quietEnd;
  final int digestHour;
  final int preferredRadiusKm;
  final Set<String> subscribedCategories;

  static Duration _time(String? s, Duration fallback) {
    if (s == null) return fallback;
    final p = s.split(':');
    return Duration(hours: int.parse(p[0]), minutes: int.parse(p[1]));
  }

  static String timeWire(Duration d) =>
      '${d.inHours.toString().padLeft(2, '0')}:${(d.inMinutes % 60).toString().padLeft(2, '0')}';

  factory NotificationPrefs.fromRow(Map<String, dynamic> r, Set<String> subs) => NotificationPrefs(
        inventoryUpdates: PrefLevel.parse(r['inventory_updates']),
        bookingActivity: PrefLevel.parse(r['booking_activity']),
        taskReminders: PrefLevel.parse(r['task_reminders']),
        nowRequests: r['now_requests'] ?? true,
        quietStart: _time(r['quiet_start'], const Duration(hours: 21)),
        quietEnd: _time(r['quiet_end'], const Duration(hours: 6, minutes: 30)),
        digestHour: r['digest_hour'] ?? 7,
        preferredRadiusKm: r['preferred_radius_km'] ?? 30,
        subscribedCategories: subs,
      );

  NotificationPrefs copyWith({
    PrefLevel? inventoryUpdates,
    PrefLevel? bookingActivity,
    PrefLevel? taskReminders,
    bool? nowRequests,
    Duration? quietStart,
    Duration? quietEnd,
    int? digestHour,
    int? preferredRadiusKm,
    Set<String>? subscribedCategories,
  }) =>
      NotificationPrefs(
        inventoryUpdates: inventoryUpdates ?? this.inventoryUpdates,
        bookingActivity: bookingActivity ?? this.bookingActivity,
        taskReminders: taskReminders ?? this.taskReminders,
        nowRequests: nowRequests ?? this.nowRequests,
        quietStart: quietStart ?? this.quietStart,
        quietEnd: quietEnd ?? this.quietEnd,
        digestHour: digestHour ?? this.digestHour,
        preferredRadiusKm: preferredRadiusKm ?? this.preferredRadiusKm,
        subscribedCategories: subscribedCategories ?? this.subscribedCategories,
      );
}

// ---------------------------------------------------------------------------
// Evenda Now
// ---------------------------------------------------------------------------

class NowRequest {
  const NowRequest({
    required this.id,
    required this.requester,
    required this.status,
    required this.categoryId,
    required this.itemDescription,
    required this.quantity,
    required this.neededFrom,
    required this.neededTo,
    required this.location,
    required this.locationLabel,
    required this.radiusKm,
    required this.expiresAt,
    required this.createdAt,
    this.neededByTime,
    this.fulfilment = Fulfilment.pickup,
    this.maxBudget,
    this.notes = '',
    this.broadcastAt,
    this.recipientsCount = 0,
  });

  final String id;
  final BizRef requester;
  final NowStatus status;
  final String categoryId;
  final String itemDescription;
  final int quantity;
  final DateTime neededFrom;
  final DateTime neededTo;
  final String? neededByTime;
  final Fulfilment fulfilment;
  final LatLng location;
  final String locationLabel;
  final int radiusKm;
  final double? maxBudget;
  final String notes;
  final DateTime expiresAt;
  final DateTime? broadcastAt;
  final int recipientsCount;
  final DateTime createdAt;

  static const columns = '*, requester:businesses!now_requests_requester_business_id_fkey(id, name, logo_path, neighbourhood, verification_status, whatsapp, phone)';

  factory NowRequest.fromRow(Map<String, dynamic> r) {
    final loc = r['location'];
    LatLng p = kLusakaCentre;
    if (loc is Map && loc['coordinates'] is List) {
      p = LatLng((loc['coordinates'][1] as num).toDouble(), (loc['coordinates'][0] as num).toDouble());
    }
    return NowRequest(
      id: r['id'],
      requester: BizRef.fromRow(r['requester']),
      status: NowStatus.parse(r['status']),
      categoryId: r['category_id'],
      itemDescription: r['item_description'],
      quantity: r['quantity'],
      neededFrom: _d(r['needed_from']),
      neededTo: _d(r['needed_to']),
      neededByTime: (r['needed_by_time'] as String?)?.substring(0, 5),
      fulfilment: Fulfilment.parse(r['fulfilment']),
      location: p,
      locationLabel: r['location_label'],
      radiusKm: r['radius_km'],
      maxBudget: _num(r['max_budget']),
      notes: r['notes'] ?? '',
      expiresAt: _dt(r['expires_at'])!,
      broadcastAt: _dt(r['broadcast_at']),
      recipientsCount: r['recipients_count'] ?? 0,
      createdAt: _dt(r['created_at'])!,
    );
  }

  NowRequest copyWith({NowStatus? status, int? radiusKm, DateTime? broadcastAt, int? recipientsCount}) => NowRequest(
        id: id,
        requester: requester,
        status: status ?? this.status,
        categoryId: categoryId,
        itemDescription: itemDescription,
        quantity: quantity,
        neededFrom: neededFrom,
        neededTo: neededTo,
        neededByTime: neededByTime,
        fulfilment: fulfilment,
        location: location,
        locationLabel: locationLabel,
        radiusKm: radiusKm ?? this.radiusKm,
        maxBudget: maxBudget,
        notes: notes,
        expiresAt: expiresAt,
        broadcastAt: broadcastAt ?? this.broadcastAt,
        recipientsCount: recipientsCount ?? this.recipientsCount,
        createdAt: createdAt,
      );
}

class NowRequestDraft {
  NowRequestDraft({
    required this.requesterId,
    required this.idempotencyKey,
    this.categoryId,
    this.itemDescription = '',
    this.quantity = 1,
    DateTime? neededFrom,
    this.neededByTime,
    this.fulfilment = Fulfilment.pickup,
    this.location,
    this.locationLabel = '',
    this.radiusKm = 15,
    this.maxBudget,
    this.notes = '',
  }) : neededFrom = neededFrom ?? DateTime.now().add(const Duration(days: 1));

  final String requesterId;
  final String idempotencyKey;
  String? categoryId;
  String itemDescription;
  int quantity;
  DateTime neededFrom;
  String? neededByTime;
  Fulfilment fulfilment;
  LatLng? location;
  String locationLabel;
  int radiusKm;
  double? maxBudget;
  String notes;
}

/// A supplier shown on the requester's Evenda Now map. Coordinates are the
/// supplier's public location; [approximate] means rounded to ~500 m.
class NowMapVendor {
  const NowMapVendor({
    required this.businessId,
    required this.name,
    required this.location,
    required this.distanceKm,
    required this.available,
    this.logoUrl,
    this.hasOffer = false,
    this.declined = false,
    this.approximate = true,
  });
  final String businessId;
  final String name;
  final String? logoUrl;
  final LatLng location;
  final double distanceKm;
  final int available;
  final bool hasOffer;
  final bool declined;
  final bool approximate;

  factory NowMapVendor.fromRow(Map<String, dynamic> r) => NowMapVendor(
        businessId: r['business_id'],
        name: r['name'],
        logoUrl: r['logo_path'],
        location: LatLng((r['lat'] as num).toDouble(), (r['lng'] as num).toDouble()),
        distanceKm: (r['distance_km'] as num).toDouble(),
        available: r['available_quantity'],
        hasOffer: r['has_offer'] ?? false,
        declined: r['declined'] ?? false,
        approximate: r['approximate'] ?? true,
      );
}

class NowOffer {
  const NowOffer({
    required this.id,
    required this.requestId,
    required this.supplier,
    required this.listingId,
    required this.listingTitle,
    required this.quantity,
    required this.unitPrice,
    required this.status,
    required this.createdAt,
    this.canDeliver = false,
    this.note = '',
    this.bookingId,
    this.distanceKm,
  });
  final String id;
  final String requestId;
  final BizRef supplier;
  final String listingId;
  final String listingTitle;
  final int quantity;
  final double unitPrice;
  final NowOfferStatus status;
  final DateTime createdAt;
  final bool canDeliver;
  final String note;
  final String? bookingId;
  final double? distanceKm;

  double get total => quantity * unitPrice;

  static const columns = '*, businesses(id, name, logo_path, neighbourhood, verification_status, whatsapp, phone), listings(title)';

  factory NowOffer.fromRow(Map<String, dynamic> r) => NowOffer(
        id: r['id'],
        requestId: r['request_id'],
        supplier: BizRef.fromRow(r['businesses']),
        listingId: r['listing_id'],
        listingTitle: r['listings']?['title'] ?? '',
        quantity: r['quantity'],
        unitPrice: (r['unit_price'] as num).toDouble(),
        status: NowOfferStatus.parse(r['status']),
        createdAt: _dt(r['created_at'])!,
        canDeliver: r['can_deliver'] ?? false,
        note: r['note'] ?? '',
        bookingId: r['booking_id'],
      );

  NowOffer withStatus(NowOfferStatus s, {String? bookingId}) => NowOffer(
        id: id,
        requestId: requestId,
        supplier: supplier,
        listingId: listingId,
        listingTitle: listingTitle,
        quantity: quantity,
        unitPrice: unitPrice,
        status: s,
        createdAt: createdAt,
        canDeliver: canDeliver,
        note: note,
        bookingId: bookingId ?? this.bookingId,
        distanceKm: distanceKm,
      );
}

/// An urgent request in a supplier's inbox.
class NowInboxItem {
  const NowInboxItem({required this.request, required this.distanceKm, required this.availableQuantity, this.matchedListing, this.myOffer, this.declined = false});
  final NowRequest request;
  final double distanceKm;
  final int availableQuantity;
  final Listing? matchedListing;
  final NowOffer? myOffer;
  final bool declined;
}

class NowOfferDraft {
  NowOfferDraft({required this.requestId, required this.supplierId, required this.listingId, required this.quantity, required this.unitPrice, this.canDeliver = false, this.note = ''});
  final String requestId;
  final String supplierId;
  final String listingId;
  final int quantity;
  final double unitPrice;
  final bool canDeliver;
  final String note;
}

// ---------------------------------------------------------------------------
// Admin
// ---------------------------------------------------------------------------

class AdminSession {
  const AdminSession({required this.userId, required this.role, required this.displayName, this.isDemo = false});
  final String userId;
  final AdminRole role;
  final String displayName;
  final bool isDemo;
}

class AdminBusinessRow {
  const AdminBusinessRow({
    required this.id,
    required this.name,
    required this.verification,
    required this.status,
    required this.createdAt,
    this.neighbourhood,
    this.primaryCategory,
    this.listings = 0,
    this.documents = 0,
  });
  final String id;
  final String name;
  final String? neighbourhood;
  final String? primaryCategory;
  final VerificationStatus verification;
  final BusinessStatus status;
  final DateTime createdAt;
  final int listings;
  final int documents;

  factory AdminBusinessRow.fromRow(Map<String, dynamic> r) => AdminBusinessRow(
        id: r['id'],
        name: r['name'],
        neighbourhood: r['neighbourhood'],
        primaryCategory: r['primary_category'],
        verification: VerificationStatus.parse(r['verification_status']),
        status: BusinessStatus.parse(r['status']),
        createdAt: _dt(r['created_at'])!,
        listings: r['listings'] ?? 0,
        documents: r['documents'] ?? 0,
      );
}

class AuditEntry {
  const AuditEntry({required this.id, required this.action, required this.targetTable, required this.targetId, required this.createdAt, this.actorRole, this.reason, this.before, this.after});
  final int id;
  final String action;
  final String targetTable;
  final String targetId;
  final DateTime createdAt;
  final AdminRole? actorRole;
  final String? reason;
  final Map<String, dynamic>? before;
  final Map<String, dynamic>? after;

  factory AuditEntry.fromRow(Map<String, dynamic> r) => AuditEntry(
        id: r['id'],
        action: r['action'],
        targetTable: r['target_table'],
        targetId: r['target_id'],
        createdAt: _dt(r['created_at'])!,
        actorRole: AdminRole.tryParse(r['actor_role']),
        reason: r['reason'],
        before: r['before'],
        after: r['after'],
      );
}

class Dispute {
  const Dispute({required this.id, required this.bookingId, required this.reason, required this.status, required this.createdAt, this.bookingReference, this.openedBy, this.resolution});
  final String id;
  final String bookingId;
  final String reason;
  final String status;
  final DateTime createdAt;
  final String? bookingReference;
  final String? openedBy;
  final String? resolution;

  factory Dispute.fromRow(Map<String, dynamic> r) => Dispute(
        id: r['id'],
        bookingId: r['booking_id'],
        reason: r['reason'],
        status: r['status'],
        createdAt: _dt(r['created_at'])!,
        bookingReference: r['bookings']?['reference'],
        openedBy: r['businesses']?['name'],
        resolution: r['resolution'],
      );
}

/// Everything an admin needs to judge one business (admin_business_detail).
class AdminBusinessDetail {
  AdminBusinessDetail(this.raw);
  final Map<String, dynamic> raw;

  String get id => raw['id'];
  String get name => raw['name'] ?? '';
  String get description => raw['description'] ?? '';
  String? get logoPath => raw['logo_path'];
  String? get primaryCategory => raw['primary_category'];
  List<String> get offeringTypes => [for (final o in (raw['offering_types'] as List? ?? const [])) o.toString()];
  String? get phone => raw['phone'];
  String? get whatsapp => raw['whatsapp'];
  String? get email => raw['email'];
  String? get neighbourhood => raw['neighbourhood'];
  String? get addressLine => raw['address_line'];
  double? get lat => (raw['lat'] as num?)?.toDouble();
  double? get lng => (raw['lng'] as num?)?.toDouble();
  int get serviceRadiusKm => (raw['service_radius_km'] as num?)?.toInt() ?? 0;
  VerificationStatus get verification => VerificationStatus.parse(raw['verification_status']);
  BusinessStatus get status => BusinessStatus.parse(raw['status']);
  DateTime get createdAt => DateTime.parse(raw['created_at']).toLocal();
  bool get onboarded => raw['onboarding_completed_at'] != null;
  Map<String, dynamic> get owner => (raw['owner'] as Map?)?.cast<String, dynamic>() ?? const {};
  Map<String, dynamic> get counts => (raw['counts'] as Map?)?.cast<String, dynamic>() ?? const {};
  List<AdminDocument> get documents => [for (final d in (raw['documents'] as List? ?? const [])) AdminDocument((d as Map).cast())];
  List<Map<String, dynamic>> get team => [for (final t in (raw['team'] as List? ?? const [])) (t as Map).cast()];
  List<Map<String, dynamic>> get history => [for (final h in (raw['history'] as List? ?? const [])) (h as Map).cast()];
  bool get hasAcceptedDocument => documents.any((d) => d.status == 'accepted');
}

class AdminDocument {
  AdminDocument(this.raw);
  final Map<String, dynamic> raw;
  String get id => raw['id'];
  String get docType => raw['doc_type'] ?? 'other';
  String get storagePath => raw['storage_path'];
  String get status => raw['status'] ?? 'submitted';
  DateTime get createdAt => DateTime.parse(raw['created_at']).toLocal();
  DateTime? get reviewedAt => raw['reviewed_at'] == null ? null : DateTime.parse(raw['reviewed_at']).toLocal();
  String? get reviewNote => raw['review_note'];
  String? get reviewedBy => raw['reviewed_by'];
  bool get isPdf => storagePath.toLowerCase().endsWith('.pdf');

  String get typeLabel => switch (docType) {
        'pacra_certificate' => 'PACRA certificate',
        'tpin' => 'ZRA TPIN certificate',
        'national_id' => 'National ID (NRC)',
        _ => 'Other document',
      };
}
