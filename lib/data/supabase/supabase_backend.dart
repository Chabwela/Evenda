import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;
import 'package:uuid/uuid.dart';

import '../../core/errors.dart';
import '../../core/format.dart';
import '../../domain/models.dart';
import '../backend.dart';

const _uuid = Uuid();

/// Production backend. Reads go through RLS-protected tables; every write
/// with business rules is a Postgres RPC (see supabase/migrations). The
/// client never decides availability, booking acceptance, payment state or
/// permissions.
class SupabaseBackend implements Backend {
  SupabaseBackend(this.client) {
    _authSub = client.auth.onAuthStateChange.listen((e) {
      _sessions.add(_toSession(e.session));
      _changes.add(DataDomain.values.toSet());
      _resubscribe();
    });
    _resubscribe();
  }

  final sb.SupabaseClient client;
  final _sessions = StreamController<Session?>.broadcast();
  final _changes = StreamController<Set<DataDomain>>.broadcast();
  final _incoming = StreamController<AppNotification>.broadcast();
  StreamSubscription? _authSub;
  sb.RealtimeChannel? _channel;
  String? _businessId;
  Profile? _profileCache;
  String? _deviceToken; // this phone's push token, removed again on sign-out

  /// Sign out, first unregistering this phone so the next person to use it
  /// never receives the previous account's notifications.
  Future<void> _signOut() async {
    final token = _deviceToken;
    if (token != null) {
      try {
        await client.from('device_tokens').delete().eq('token', token).timeout(const Duration(seconds: 6));
      } catch (_) {
        // Offline: sign out anyway. send-push drops tokens FCM reports as dead,
        // and the token moves to the next account that signs in on this phone.
      }
      _deviceToken = null;
    }
    await client.auth.signOut();
  }

  Session? _toSession(sb.Session? s) => s == null
      ? null
      : Session(userId: s.user.id, phone: s.user.phone == null || s.user.phone!.isEmpty ? null : '+${s.user.phone!.replaceAll('+', '')}',
          fullName: _profileCache?.name ?? (s.user.userMetadata?['full_name'] as String? ?? ''));

  /// Realtime: one channel per signed-in business. Events only signal that a
  /// domain changed; screens refetch through RLS, so no data leaks via payloads.
  Future<void> _resubscribe() async {
    final uid = client.auth.currentUser?.id;
    if (_channel != null) {
      await client.removeChannel(_channel!);
      _channel = null;
    }
    if (uid == null) return;
    final Map<String, dynamic>? m;
    try {
      m = await client.from('business_members').select('business_id').eq('user_id', uid).eq('status', 'active').maybeSingle();
    } catch (_) {
      // Offline or server unreachable: live updates resume via reconnect().
      return;
    }
    _businessId = m?['business_id'];
    final biz = _businessId;
    if (biz == null) return;

    void on(String table, Set<DataDomain> domains, {String? filter}) {
      _channel!.onPostgresChanges(
        event: sb.PostgresChangeEvent.all,
        schema: 'public',
        table: table,
        filter: filter == null ? null : sb.PostgresChangeFilter(type: sb.PostgresChangeFilterType.eq, column: filter, value: biz),
        callback: (payload) {
          _changes.add(domains);
          if (table == 'notifications' && payload.eventType == sb.PostgresChangeEvent.insert) {
            _incoming.add(AppNotification.fromRow(payload.newRecord, photoUrl: photoUrl));
          }
        },
      );
    }

    _channel = client.channel('evenda:$biz');
    on('notifications', {DataDomain.notifications}, filter: 'recipient_business_id');
    on('quote_requests', {DataDomain.bookings}, filter: 'supplier_business_id');
    on('quote_requests', {DataDomain.bookings}, filter: 'requester_business_id');
    on('quotations', {DataDomain.bookings});
    on('bookings', {DataDomain.bookings, DataDomain.listings}, filter: 'supplier_business_id');
    on('bookings', {DataDomain.bookings}, filter: 'requester_business_id');
    on('tasks', {DataDomain.work}, filter: 'business_id');
    on('now_requests', {DataDomain.now});
    on('now_offers', {DataDomain.now});
    on('now_request_recipients', {DataDomain.now}, filter: 'business_id');
    _channel!.subscribe();
  }

  void touch(Set<DataDomain> d) => _changes.add(d);

  @override
  Future<void> reconnect() => _resubscribe();

  /// Runs a call and converts Postgres/PostgREST/Auth errors to [EvError].
  Future<T> call<T>(Future<T> Function() f) async {
    try {
      return await f().timeout(const Duration(seconds: 25));
    } on sb.PostgrestException catch (e) {
      throw _mapPostgrest(e);
    } on sb.AuthException catch (e) {
      throw _mapAuth(e);
    } on sb.StorageException catch (e) {
      throw EvError('storage', e.message);
    } catch (e) {
      throw EvError.from(e);
    }
  }

  EvError _mapAuth(sb.AuthException e) {
    // The request never reached Supabase (no connection, dropped network,
    // or a browser extension blocking it). Never show the raw URL.
    if (e is sb.AuthRetryableFetchException || e.message.contains('ClientException') || e.message.contains('Failed to fetch')) {
      return const EvError('offline');
    }
    switch (e.code) {
      case 'invalid_credentials':
        return const EvError('invalid_credentials');
      case 'email_not_confirmed':
        return const EvError('email_not_confirmed');
      case 'user_already_exists' || 'email_exists':
        return const EvError('email_taken');
      case 'weak_password':
        return const EvError('weak_password');
      case 'same_password':
        return const EvError('same_password');
      case 'otp_expired':
        return const EvError('invalid_otp');
      case 'over_email_send_rate_limit' || 'over_request_rate_limit' || 'over_sms_send_rate_limit':
        return const EvError('rate_limited');
      case 'signup_disabled' || 'email_provider_disabled':
        return const EvError('signup_disabled');
      case 'sms_send_failed' || 'phone_provider_disabled':
        return const EvError('otp_not_configured');
    }
    final m = e.message.toLowerCase();
    if (m.contains('token') && (m.contains('expired') || m.contains('invalid'))) return const EvError('invalid_otp');
    if (m.contains('sms') || m.contains('unsupported phone')) return const EvError('otp_not_configured');
    return EvError('auth', e.message);
  }

  EvError _mapPostgrest(sb.PostgrestException e) {
    Map<String, dynamic>? detail;
    try {
      if (e.details is String && (e.details as String).startsWith('{')) detail = jsonDecode(e.details as String);
    } catch (_) {}
    final code = e.message.trim();
    if (RegExp(r'^[a-z_]+$').hasMatch(code)) {
      if (code == 'insufficient_availability' && detail?['available'] != null) {
        return EvError(code, 'Only ${detail!['available']} available for those dates.', detail);
      }
      if (code == 'onboarding_incomplete' && e.details != null) {
        return EvError(code, 'Still needed: ${e.details.toString().replaceAll('_', ' ').replaceAll(',', ', ')}.');
      }
      return EvError(code, e.hint, detail);
    }
    if (e.code == '42501') return const EvError('forbidden');
    if (e.code == 'PGRST116') return const EvError('not_found', 'Not found, or you do not have access.');
    return EvError('server', e.message);
  }

  Future<dynamic> rpc(String fn, [Map<String, dynamic>? params]) => call(() => client.rpc(fn, params: params));

  String _date(DateTime d) => EvDates.iso(d);

  @override
  bool get isDemo => false;

  @override
  Stream<Set<DataDomain>> get changes => _changes.stream;

  @override
  late final AuthApi auth = _SbAuth(this);
  @override
  late final BusinessApi business = _SbBusiness(this);
  @override
  late final ListingApi listings = _SbListings(this);
  @override
  late final DiscoveryApi discovery = _SbDiscovery(this);
  @override
  late final BookingApi bookings = _SbBookings(this);
  @override
  late final WorkApi work = _SbWork(this);
  @override
  late final NotificationApi notifications = _SbNotifications(this);
  @override
  late final NowApi now = _SbNow(this);
  @override
  late final AdminApi admin = _SbAdmin(this);

  @override
  String photoUrl(String p) {
    if (p.startsWith('http') || p.startsWith('asset:')) return p;
    final slash = p.indexOf('/');
    // Stored as "<bucket>/<business_id>/<file>".
    final bucket = p.substring(0, slash);
    return client.storage.from(bucket).getPublicUrl(p.substring(slash + 1));
  }

  @override
  void dispose() {
    _authSub?.cancel();
    if (_channel != null) client.removeChannel(_channel!);
    _sessions.close();
    _changes.close();
    _incoming.close();
  }
}

class Profile {
  const Profile(this.name);
  final String name;
}

// ============================================================================
class _SbAuth implements AuthApi {
  _SbAuth(this.b);
  final SupabaseBackend b;

  @override
  Session? get current => b._toSession(b.client.auth.currentSession);

  @override
  Stream<Session?> get sessions => b._sessions.stream;

  @override
  Future<Session> signIn(String email, String password) async {
    await b.call(() => b.client.auth.signInWithPassword(email: email.trim(), password: password));
    await _loadProfile();
    final s = current;
    if (s == null) throw const EvError('not_authenticated', 'Your session could not be created.');
    return s;
  }

  @override
  Future<bool> signUp(String email, String password, String fullName) async {
    final r = await b.call(() => b.client.auth.signUp(email: email.trim(), password: password, data: {'full_name': fullName.trim()}));
    // With email confirmation on, Supabase returns a user with no identities
    // (instead of an error) when the address is already registered.
    if (r.user != null && (r.user!.identities?.isEmpty ?? false)) throw const EvError('email_taken');
    if (r.session == null) return true;
    await _loadProfile();
    return false;
  }

  @override
  Future<void> verifyEmail(String email, String code) async {
    await b.call(() => b.client.auth.verifyOTP(email: email.trim(), token: code, type: sb.OtpType.email));
    await _loadProfile();
  }

  @override
  Future<void> resendEmailCode(String email) => b.call(() => b.client.auth.resend(type: sb.OtpType.signup, email: email.trim()));

  @override
  Future<void> sendPasswordReset(String email) => b.call(() => b.client.auth.resetPasswordForEmail(email.trim()));

  @override
  Future<void> verifyPasswordReset(String email, String code) async {
    await b.call(() => b.client.auth.verifyOTP(email: email.trim(), token: code, type: sb.OtpType.recovery));
    await _loadProfile();
  }

  @override
  Future<void> updatePassword(String newPassword) => b.call(() => b.client.auth.updateUser(sb.UserAttributes(password: newPassword)));

  @override
  Future<void> sendOtp(String e164Phone) => b.call(() => b.client.auth.signInWithOtp(phone: e164Phone));

  @override
  Future<void> verifyOtp(String e164Phone, String code) async {
    await b.call(() => b.client.auth.verifyOTP(phone: e164Phone, token: code, type: sb.OtpType.sms));
    await _loadProfile();
  }

  Future<void> _loadProfile() async {
    final uid = b.client.auth.currentUser?.id;
    if (uid == null) return;
    final p = await b.call(() => b.client.from('profiles').select('full_name').eq('id', uid).maybeSingle());
    b._profileCache = Profile(p?['full_name'] ?? '');
    b._sessions.add(current);
  }

  @override
  Future<void> updateProfileName(String name) async {
    final uid = b.client.auth.currentUser!.id;
    await b.call(() => b.client.from('profiles').update({'full_name': name.trim()}).eq('id', uid));
    b._profileCache = Profile(name.trim());
    b._sessions.add(current);
  }

  @override
  Future<void> signOut() => b.call(b._signOut);
}

// ============================================================================
class _SbBusiness implements BusinessApi {
  _SbBusiness(this.b);
  final SupabaseBackend b;

  @override
  Future<Business?> mine() async {
    final uid = b.client.auth.currentUser?.id;
    if (uid == null) return null;
    final m = await b.call(() => b.client.from('business_members').select('business_id').eq('user_id', uid).eq('status', 'active').maybeSingle());
    if (m == null) return null;
    return get(m['business_id']);
  }

  @override
  Future<Business> get(String id) async =>
      Business.fromRow(await b.call(() => b.client.from('businesses').select(Business.columns).eq('id', id).single()));

  @override
  Future<String> create(String name) async {
    final id = await b.rpc('create_business', {'p_name': name.trim()}) as String;
    await b._resubscribe();
    b.touch({DataDomain.business});
    return id;
  }

  @override
  Future<void> update(Business x) async {
    await b.call(() => b.client.from('businesses').update({
          'name': x.name,
          'description': x.description,
          'logo_path': x.logoUrl,
          'primary_category': x.primaryCategory,
          'offering_types': [for (final o in x.offeringTypes) o.wire],
          'phone': x.phone,
          'whatsapp': x.whatsapp,
          'email': x.email,
          'address_line': x.addressLine,
          'service_radius_km': x.serviceRadiusKm,
          'operating_hours': x.operatingHours,
          'onboarding_step': x.onboardingStep,
        }).eq('id', x.id));
    b.touch({DataDomain.business});
  }

  @override
  Future<void> setCategories(String businessId, List<String> categoryIds) async {
    await b.call(() => b.client.from('business_categories').delete().eq('business_id', businessId));
    if (categoryIds.isNotEmpty) {
      await b.call(() => b.client.from('business_categories').insert([for (final c in categoryIds) {'business_id': businessId, 'category_id': c}]));
    }
    b.touch({DataDomain.business});
  }

  @override
  Future<LatLng?> exactLocation(String businessId) async {
    final rows = await b.rpc('my_business_location', {'p_business': businessId}) as List;
    if (rows.isEmpty) return null;
    final r = rows.first as Map<String, dynamic>;
    return LatLng((r['lat'] as num).toDouble(), (r['lng'] as num).toDouble());
  }

  @override
  Future<void> setLocation(String businessId, LatLng p, LocationPrecision precision, String neighbourhood) async {
    await b.rpc('set_business_location', {
      'p_business': businessId,
      'p_lat': p.latitude,
      'p_lng': p.longitude,
      'p_precision': precision.wire,
      'p_neighbourhood': neighbourhood,
    });
    b.touch({DataDomain.business});
  }

  @override
  Future<void> completeOnboarding(String businessId) async {
    await b.rpc('complete_onboarding', {'p_business': businessId});
    b.touch({DataDomain.business, DataDomain.session});
  }

  @override
  Future<String> uploadLogo(String businessId, Uint8List bytes, String ext) async {
    final path = '$businessId/logo-${DateTime.now().millisecondsSinceEpoch}.$ext';
    await b.call(() => b.client.storage.from('business-logos').uploadBinary(path, bytes,
        // Each logo gets a fresh path, so no upsert: overwriting would need a
        // storage UPDATE policy, which we deliberately do not grant.
        fileOptions: sb.FileOptions(contentType: 'image/${ext == 'jpg' ? 'jpeg' : ext}')));
    return 'business-logos/$path';
  }

  @override
  Future<void> uploadVerificationDocument(String businessId, String docType, Uint8List bytes, String ext) async {
    final path = '$businessId/${_uuid.v4()}.$ext';
    await b.call(() => b.client.storage.from('verification').uploadBinary(path, bytes,
        fileOptions: sb.FileOptions(contentType: ext == 'pdf' ? 'application/pdf' : 'image/${ext == 'jpg' ? 'jpeg' : ext}')));
    await b.call(() => b.client.from('verification_documents').insert({'business_id': businessId, 'doc_type': docType, 'storage_path': path}));
  }

  @override
  Future<void> submitForVerification(String businessId) async {
    await b.rpc('submit_for_verification', {'p_business': businessId});
    b.touch({DataDomain.business});
  }

  @override
  Future<List<TeamMember>> team(String businessId) async {
    final rows = await b.call(() => b.client.from('business_members').select().eq('business_id', businessId).neq('status', 'removed').order('created_at'));
    return [for (final r in rows) TeamMember.fromRow(r)];
  }

  @override
  Future<void> inviteMember(String businessId, String email, String name, MemberRole role) async {
    await b.call(() => b.client.from('business_members').insert({
          'business_id': businessId,
          'invited_email': email.trim(),
          'display_name': name,
          'role': role.wire,
          'status': 'invited',
        }));
    b.touch({DataDomain.business});
  }

  @override
  Future<void> setMemberRole(String memberId, MemberRole role) async {
    await b.call(() => b.client.from('business_members').update({'role': role.wire}).eq('id', memberId));
    b.touch({DataDomain.business});
  }

  @override
  Future<void> removeMember(String memberId) async {
    await b.call(() => b.client.from('business_members').update({'status': 'removed'}).eq('id', memberId));
    b.touch({DataDomain.business});
  }
}

// ============================================================================
class _SbListings implements ListingApi {
  _SbListings(this.b);
  final SupabaseBackend b;

  Listing _map(Map<String, dynamic> r) => Listing.fromRow(r, photoUrl: (p) => b.photoUrl('listing-photos/$p'));

  @override
  Future<List<Listing>> mine(String businessId) async {
    final rows = await b.call(() => b.client.from('listings').select(Listing.columns).eq('business_id', businessId).order('updated_at', ascending: false));
    return [for (final r in rows) _map(r)];
  }

  @override
  Future<Listing> get(String id) async => _map(await b.call(() => b.client.from('listings').select(Listing.columns).eq('id', id).single()));

  Future<void> _syncPhotos(String listingId, List<String> photos) async {
    await b.call(() => b.client.from('listing_photos').delete().eq('listing_id', listingId));
    if (photos.isEmpty) return;
    await b.call(() => b.client.from('listing_photos').insert([
          for (var i = 0; i < photos.length; i++) {'listing_id': listingId, 'storage_path': _storagePath(photos[i]), 'sort': i}
        ]));
  }

  /// Public URL -> `business_id/file` inside the listing-photos bucket.
  String _storagePath(String p) {
    const marker = '/listing-photos/';
    final i = p.indexOf(marker);
    if (i >= 0) return p.substring(i + marker.length);
    return p.startsWith('listing-photos/') ? p.substring('listing-photos/'.length) : p;
  }

  @override
  Future<String> create(ListingDraft d) async {
    final id = await b.rpc('create_listing', {'p': d.toJson()}) as String;
    await _syncPhotos(id, d.photos);
    b.touch({DataDomain.listings, DataDomain.discovery});
    return id;
  }

  @override
  Future<void> update(String id, ListingDraft d) async {
    final current = await get(id);
    final j = d.toJson()
      ..remove('business_id')
      ..remove('total_quantity')
      ..remove('status');
    await b.call(() => b.client.from('listings').update(j).eq('id', id));
    if (d.totalQuantity != current.totalQuantity) {
      await adjustStock(id, d.totalQuantity - current.totalQuantity, 'correction', note: 'Edited on listing form');
    }
    await _syncPhotos(id, d.photos);
    if (d.status != current.status) await setStatus(id, d.status);
    b.touch({DataDomain.listings, DataDomain.discovery});
  }

  @override
  Future<void> setStatus(String id, ListingStatus status) async {
    // Status changes fire the inventory-event trigger server-side.
    await b.call(() => b.client.from('listings').update({'status': status.wire}).eq('id', id));
    b.touch({DataDomain.listings, DataDomain.discovery});
  }

  @override
  Future<List<String>> uploadPhotos(String businessId, List<(Uint8List, String)> files) async {
    final out = <String>[];
    for (final (bytes, ext) in files) {
      final path = '$businessId/${_uuid.v4()}.$ext';
      await b.call(() => b.client.storage.from('listing-photos').uploadBinary(path, bytes,
          fileOptions: sb.FileOptions(contentType: 'image/${ext == 'jpg' ? 'jpeg' : ext}')));
      out.add(b.client.storage.from('listing-photos').getPublicUrl(path));
    }
    return out;
  }

  @override
  Future<void> adjustStock(String listingId, int delta, String reason, {String? note}) async {
    if (delta == 0) return;
    await b.rpc('adjust_stock', {'p_listing': listingId, 'p_delta': delta, 'p_reason': reason, 'p_note': note});
    b.touch({DataDomain.listings, DataDomain.discovery});
  }

  @override
  Future<void> setDamaged(String listingId, int damaged) async {
    await b.rpc('set_damaged', {'p_listing': listingId, 'p_damaged': damaged});
    b.touch({DataDomain.listings});
  }

  @override
  Future<void> completeInspection(String listingId, {required int good, required int damaged}) async {
    await b.rpc('complete_inspection', {'p_listing': listingId, 'p_good': good, 'p_damaged': damaged});
    b.touch({DataDomain.listings});
  }

  @override
  Future<int> availableQuantity(String listingId, DateTime from, DateTime to) async =>
      await b.rpc('available_quantity', {'p_listing': listingId, 'p_from': b._date(from), 'p_to': b._date(to)}) as int;

  @override
  Future<List<AvailabilityDay>> calendar(String listingId, DateTime from, DateTime to) async {
    final rows = await b.rpc('availability_calendar', {'p_listing': listingId, 'p_from': b._date(from), 'p_to': b._date(to)}) as List;
    return [for (final r in rows) AvailabilityDay.fromRow(r)];
  }

  @override
  Future<List<Reservation>> reservations(String businessId, {String? listingId, bool upcomingOnly = true}) async {
    var q = b.client.from('reservations').select('*, listings(title)').eq('business_id', businessId).neq('status', 'cancelled');
    if (listingId != null) q = q.eq('listing_id', listingId);
    if (upcomingOnly) q = q.gte('ends_on', b._date(EvDates.today()));
    final rows = await b.call(() => q.order('starts_on'));
    return [for (final r in rows) Reservation.fromRow(r)];
  }

  @override
  Future<void> recordManualReservation(String listingId, int quantity, DateTime from, DateTime to, String clientLabel, {String? note}) async {
    await b.rpc('record_manual_reservation', {
      'p_listing': listingId,
      'p_quantity': quantity,
      'p_from': b._date(from),
      'p_to': b._date(to),
      'p_client_label': clientLabel,
      'p_note': note,
    });
    b.touch({DataDomain.listings});
  }

  @override
  Future<void> moveReservation(String reservationId, String action) async {
    await b.rpc('move_reservation', {'p_reservation': reservationId, 'p_action': action});
    b.touch({DataDomain.listings});
  }

  @override
  Future<List<AvailabilityBlock>> blocks(String businessId) async {
    final rows = await b.call(() => b.client.from('availability_blocks').select().eq('business_id', businessId).order('starts_on'));
    return [for (final r in rows) AvailabilityBlock.fromRow(r)];
  }

  @override
  Future<void> addBlock(String businessId, DateTime from, DateTime to, {String? listingId, String? reason}) async {
    await b.call(() => b.client.from('availability_blocks').insert({
          'business_id': businessId,
          'listing_id': listingId,
          'starts_on': b._date(from),
          'ends_on': b._date(to),
          'reason': reason,
        }));
    b.touch({DataDomain.listings});
  }

  @override
  Future<void> removeBlock(String blockId) async {
    await b.call(() => b.client.from('availability_blocks').delete().eq('id', blockId));
    b.touch({DataDomain.listings, DataDomain.discovery});
  }

  @override
  Future<List<InventoryConflict>> conflicts(String businessId) async {
    final rows = await b.rpc('inventory_conflicts', {'p_business': businessId}) as List;
    return [for (final r in rows) InventoryConflict.fromRow(r)];
  }
}

// ============================================================================
class _SbDiscovery implements DiscoveryApi {
  _SbDiscovery(this.b);
  final SupabaseBackend b;

  @override
  Future<List<SearchResult>> search(String myBusinessId, SearchQuery q) async {
    final me = await b.business.get(myBusinessId);
    var query = b.client.from('listings').select(Listing.columns).eq('status', 'published').eq('moderation_status', 'ok').neq('business_id', myBusinessId);
    if (q.categoryId != null) query = query.eq('category_id', q.categoryId!);
    if (q.kind != null) query = query.eq('kind', q.kind!.wire);
    if (q.maxPrice != null) query = query.lte('price_amount', q.maxPrice!);
    if (q.text.trim().isNotEmpty) {
      final t = q.text.trim().replaceAll(RegExp(r'[%,()]'), ' ');
      query = query.or('title.ilike.%$t%,description.ilike.%$t%');
    }
    if (q.savedOnly) {
      final f = await follows(myBusinessId);
      if (f.isEmpty) return [];
      query = query.inFilter('business_id', [for (final x in f) x.supplier.id]);
    }
    final rows = await b.call(() => query.limit(60));
    final listings = [for (final r in rows) Listing.fromRow(r, photoUrl: (p) => b.photoUrl('listing-photos/$p'))];

    // Locations for distance ranking (public_location only).
    final ids = {for (final l in listings) l.businessId}.toList();
    final bizRows = ids.isEmpty
        ? const []
        : await b.call(() => b.client.from('businesses').select('id, public_location').inFilter('id', ids));
    final locs = {for (final r in bizRows) r['id'] as String: Business.fromRow({...r, 'owner_id': '', 'name': ''}).location};
    final hood = q.neighbourhood == null ? null : kNeighbourhoods.where((n) => n.name == q.neighbourhood).firstOrNull;
    final origin = hood?.point ?? me.location;
    const dist = Distance();

    final out = <SearchResult>[];
    for (final l in listings) {
      int? avail;
      if (q.from != null && l.tracksStock) {
        // Authoritative, date-aware availability from the database.
        avail = await b.listings.availableQuantity(l.id, q.from!, q.to ?? q.from!);
        if (avail == 0 || (q.quantity != null && avail < q.quantity!)) continue;
      } else if (q.quantity != null && l.tracksStock && l.usable < q.quantity!) {
        continue;
      }
      final loc = locs[l.businessId];
      final km = origin != null && loc != null ? dist.as(LengthUnit.Meter, origin, loc) / 1000 : null;
      if (hood != null && km != null && km > 12) continue;
      out.add(SearchResult(listing: l, available: avail, distanceKm: km == null ? null : (km * 10).round() / 10));
    }
    out.sort((a, c) => (a.distanceKm ?? 999).compareTo(c.distanceKm ?? 999));
    return out;
  }

  @override
  Future<Business> supplier(String businessId) => b.business.get(businessId);

  @override
  Future<List<Listing>> supplierListings(String businessId) async {
    final rows = await b.call(() => b.client.from('listings').select(Listing.columns).eq('business_id', businessId).eq('status', 'published').eq('moderation_status', 'ok'));
    return [for (final r in rows) Listing.fromRow(r, photoUrl: (p) => b.photoUrl('listing-photos/$p'))];
  }

  @override
  Future<List<InventoryUpdate>> inventoryFeed(String myBusinessId, {int limit = 12}) async {
    // The feed is the business's own inventory notifications: relevance,
    // follows, mutes and preferences were already applied by the fan-out.
    final rows = await b.call(() => b.client
        .from('notifications')
        .select('id, data, created_at')
        .eq('recipient_business_id', myBusinessId)
        .eq('category', 'inventory')
        .order('created_at', ascending: false)
        .limit(limit));
    final ids = {for (final r in rows) if (r['data']?['listing_id'] != null) r['data']['listing_id'] as String}.toList();
    if (ids.isEmpty) return [];
    final ls = await b.call(() => b.client.from('listings').select(Listing.columns).inFilter('id', ids));
    final byId = {for (final r in ls) r['id'] as String: Listing.fromRow(r, photoUrl: (p) => b.photoUrl('listing-photos/$p'))};
    return [
      for (final r in rows)
        if (byId[r['data']?['listing_id']] case final l?)
          InventoryUpdate(
            id: r['id'],
            type: r['data']['type'] ?? 'listing_published',
            supplier: l.business!,
            listing: l,
            payload: Map<String, dynamic>.from(r['data']),
            createdAt: DateTime.parse(r['created_at']).toLocal(),
          )
    ];
  }

  @override
  Future<List<SupplierFollow>> follows(String myBusinessId) async {
    final rows = await b.call(() => b.client
        .from('supplier_follows')
        .select('muted, push_enabled, supplier:businesses!supplier_follows_supplier_id_fkey(id, name, logo_path, neighbourhood, verification_status, whatsapp, phone)')
        .eq('business_id', myBusinessId));
    return [
      for (final r in rows) SupplierFollow(supplier: BizRef.fromRow(r['supplier']), muted: r['muted'], pushEnabled: r['push_enabled'])
    ];
  }

  @override
  Future<void> follow(String myBusinessId, String supplierId) async {
    await b.call(() => b.client.from('supplier_follows').upsert({'business_id': myBusinessId, 'supplier_id': supplierId}));
    b.touch({DataDomain.discovery});
  }

  @override
  Future<void> unfollow(String myBusinessId, String supplierId) async {
    await b.call(() => b.client.from('supplier_follows').delete().eq('business_id', myBusinessId).eq('supplier_id', supplierId));
    b.touch({DataDomain.discovery});
  }

  @override
  Future<void> setFollowMuted(String myBusinessId, String supplierId, bool muted) async {
    await b.call(() => b.client.from('supplier_follows').upsert({'business_id': myBusinessId, 'supplier_id': supplierId, 'muted': muted}));
    b.touch({DataDomain.discovery});
  }
}

// ============================================================================
class _SbBookings implements BookingApi {
  _SbBookings(this.b);
  final SupabaseBackend b;

  @override
  Future<List<QuoteRequest>> requests(String businessId) async {
    final rows = await b.call(() => b.client
        .from('quote_requests')
        .select(QuoteRequest.columns)
        .or('requester_business_id.eq.$businessId,supplier_business_id.eq.$businessId')
        .order('created_at', ascending: false)
        .limit(100));
    return [for (final r in rows) QuoteRequest.fromRow(r)];
  }

  @override
  Future<QuoteRequest> request(String id) async =>
      QuoteRequest.fromRow(await b.call(() => b.client.from('quote_requests').select(QuoteRequest.columns).eq('id', id).single()));

  @override
  Future<String> createRequest(QuoteRequestDraft d) async {
    final id = await b.rpc('create_quote_request', {
      'p': {
        'requester_business_id': d.requesterId,
        'supplier_business_id': d.supplierId,
        'event_id': d.eventId,
        'needed_from': b._date(d.neededFrom),
        'needed_to': b._date(d.neededTo),
        'fulfilment': d.fulfilment.wire,
        'venue': d.venue,
        'delivery_notes': d.deliveryNotes,
        'message': d.message,
        'idempotency_key': d.idempotencyKey,
        'items': [for (final i in d.items) i.toJson()],
      }
    }) as String;
    b.touch({DataDomain.bookings});
    return id;
  }

  @override
  Future<void> postMessage(String requestId, String businessId, String body) async {
    await b.rpc('post_quote_message', {'p_request': requestId, 'p_business': businessId, 'p_body': body.trim()});
    b.touch({DataDomain.bookings});
  }

  @override
  Future<String> sendQuotation(QuotationDraft d) async {
    final id = await b.rpc('send_quotation', {
      'p': {
        'request_id': d.requestId,
        'items': [for (final i in d.items) i.toJson()],
        'additional_charges': [for (final c in d.charges) c.toJson()],
        'deposit_amount': d.depositAmount,
        'deposit_terms': d.depositTerms,
        'payment_terms': d.paymentTerms,
        'valid_until': b._date(d.validUntil),
        'conditions': d.conditions,
      }
    }) as String;
    b.touch({DataDomain.bookings});
    return id;
  }

  @override
  Future<void> declineRequest(String requestId, String businessId, {String? reason}) async {
    await b.rpc('decline_quote_request', {'p_request': requestId, 'p_business': businessId, 'p_reason': reason});
    b.touch({DataDomain.bookings});
  }

  @override
  Future<String> acceptQuotation(String quotationId, String idempotencyKey) async {
    final id = await b.rpc('accept_quotation', {'p_quotation': quotationId, 'p_idempotency_key': idempotencyKey}) as String;
    b.touch({DataDomain.bookings, DataDomain.listings, DataDomain.work});
    return id;
  }

  @override
  Future<List<Booking>> bookings(String businessId) async {
    final rows = await b.call(() => b.client
        .from('bookings')
        .select(Booking.columns)
        .or('requester_business_id.eq.$businessId,supplier_business_id.eq.$businessId')
        .order('starts_on')
        .limit(200));
    return [for (final r in rows) Booking.fromRow(r)];
  }

  @override
  Future<Booking> booking(String id) async => Booking.fromRow(await b.call(() => b.client.from('bookings').select(Booking.columns).eq('id', id).single()));

  @override
  Future<void> updateStatus(String bookingId, BookingStatus to, {String? note}) async {
    await b.rpc('update_booking_status', {'p_booking': bookingId, 'p_to': to.wire, 'p_note': note});
    b.touch({DataDomain.bookings, DataDomain.listings, DataDomain.work});
  }

  @override
  Future<void> recordPayment(String bookingId, String businessId,
      {required double amount, required String method, required String kind, String? reference, String? note}) async {
    await b.rpc('record_payment', {
      'p_booking': bookingId,
      'p_business': businessId,
      'p_amount': amount,
      'p_method': method,
      'p_kind': kind,
      'p_reference': reference,
      'p_note': note,
    });
    b.touch({DataDomain.bookings});
  }

  @override
  Future<void> confirmPayment(String paymentId) async {
    await b.rpc('confirm_payment', {'p_payment': paymentId});
    b.touch({DataDomain.bookings});
  }

  @override
  Future<void> openDispute(String bookingId, String businessId, String reason) async {
    await b.rpc('open_dispute', {'p_booking': bookingId, 'p_business': businessId, 'p_reason': reason});
    b.touch({DataDomain.bookings});
  }
}

// ============================================================================
class _SbWork implements WorkApi {
  _SbWork(this.b);
  final SupabaseBackend b;

  static const _eventCols = '*, event_requirements(*, businesses(name))';

  @override
  Future<List<EventPlan>> events(String businessId) async {
    final rows = await b.call(() => b.client.from('events').select(_eventCols).eq('business_id', businessId).order('starts_at'));
    return [for (final r in rows) EventPlan.fromRow(r)];
  }

  @override
  Future<EventPlan> event(String id) async => EventPlan.fromRow(await b.call(() => b.client.from('events').select(_eventCols).eq('id', id).single()));

  Future<void> _syncRequirements(String eventId, List<Requirement> reqs) async {
    final keep = [for (final r in reqs) if (r.id.isNotEmpty) r.id];
    var del = b.client.from('event_requirements').delete().eq('event_id', eventId);
    if (keep.isNotEmpty) del = del.not('id', 'in', '(${keep.join(',')})');
    await b.call(() => del);
    for (final r in reqs) {
      final row = r.toJson(eventId);
      if (r.id.isEmpty) {
        await b.call(() => b.client.from('event_requirements').insert(row));
      } else {
        await b.call(() => b.client.from('event_requirements').update(row).eq('id', r.id));
      }
    }
  }

  @override
  Future<String> createEvent(EventDraft d) async {
    final row = await b.call(() => b.client.from('events').insert(d.toJson()).select('id').single());
    final id = row['id'] as String;
    await _syncRequirements(id, d.requirements);
    await generateTasks(id);
    b.touch({DataDomain.work});
    return id;
  }

  @override
  Future<void> updateEvent(String id, EventDraft d) async {
    // The events_reschedule trigger moves relative tasks and their reminders.
    await b.call(() => b.client.from('events').update(d.toJson()..remove('business_id')).eq('id', id));
    await _syncRequirements(id, d.requirements);
    await generateTasks(id);
    b.touch({DataDomain.work});
  }

  @override
  Future<int> generateTasks(String eventId) async {
    final n = await b.rpc('generate_event_tasks', {'p_event': eventId}) as int;
    b.touch({DataDomain.work});
    return n;
  }

  @override
  Future<String> createEventFromBooking(String bookingId, String businessId) async {
    final id = await b.rpc('create_event_from_booking', {'p_booking': bookingId, 'p_business': businessId}) as String;
    b.touch({DataDomain.work});
    return id;
  }

  @override
  Future<List<WorkTask>> tasks(String businessId, {String? eventId, bool includeDone = false}) async {
    var q = b.client.from('tasks').select('*, events(name)').eq('business_id', businessId);
    if (eventId != null) q = q.eq('event_id', eventId);
    if (!includeDone) q = q.inFilter('status', ['todo', 'in_progress']);
    final rows = await b.call(() => q.order('due_at').limit(300));
    return [for (final r in rows) WorkTask.fromRow(r)];
  }

  @override
  Future<WorkTask> task(String id) async => WorkTask.fromRow(await b.call(() => b.client.from('tasks').select('*, events(name)').eq('id', id).single()));

  @override
  Future<String> createTask(String businessId,
      {required String title, required DateTime dueAt, TaskPriority priority = TaskPriority.normal, String? eventId, String notes = ''}) async {
    int? offset;
    if (eventId != null) {
      final e = await event(eventId);
      offset = dueAt.difference(e.startsAt).inMinutes;
    }
    final row = await b.call(() => b.client.from('tasks').insert({
          'business_id': businessId,
          'title': title.trim(),
          'due_at': dueAt.toUtc().toIso8601String(),
          'priority': priority.wire,
          'event_id': eventId,
          'offset_minutes': offset,
          'notes': notes,
        }).select('id').single());
    b.touch({DataDomain.work});
    return row['id'];
  }

  @override
  Future<void> updateTask(WorkTask t) async {
    int? offset = t.offsetMinutes;
    if (t.eventId != null) {
      final e = await event(t.eventId!);
      offset = t.dueAt.difference(e.startsAt).inMinutes;
    }
    // The tasks_reminders trigger reschedules reminders on due/priority/status change.
    await b.call(() => b.client.from('tasks').update({
          'title': t.title,
          'notes': t.notes,
          'due_at': t.dueAt.toUtc().toIso8601String(),
          'priority': t.priority.wire,
          'status': t.status.wire,
          'offset_minutes': offset,
        }).eq('id', t.id));
    b.touch({DataDomain.work});
  }

  @override
  Future<void> setTaskStatus(String taskId, TaskStatus status) async {
    await b.call(() => b.client.from('tasks').update({'status': status.wire}).eq('id', taskId));
    b.touch({DataDomain.work});
  }

  @override
  Future<void> snoozeTask(String taskId, DateTime until) async {
    await b.rpc('snooze_task', {'p_task': taskId, 'p_until': until.toUtc().toIso8601String()});
    b.touch({DataDomain.work});
  }

  @override
  Future<List<TaskReminder>> reminders(String taskId) async {
    final rows = await b.call(() => b.client.from('reminders').select().eq('task_id', taskId).order('remind_at'));
    return [for (final r in rows) TaskReminder.fromRow(r)];
  }

  @override
  Future<List<WorkloadDay>> workload(String businessId, DateTime from, DateTime to) async {
    final rows = await b.rpc('workload', {'p_business': businessId, 'p_from': b._date(from), 'p_to': b._date(to)}) as List;
    return [for (final r in rows) WorkloadDay.fromRow(r)];
  }
}

// ============================================================================
class _SbNotifications implements NotificationApi {
  _SbNotifications(this.b);
  final SupabaseBackend b;

  @override
  Future<List<AppNotification>> list(String businessId) async {
    final rows = await b.call(() =>
        b.client.from('notifications').select().eq('recipient_business_id', businessId).order('created_at', ascending: false).limit(150));
    return [for (final r in rows) AppNotification.fromRow(r, photoUrl: (p) => b.photoUrl('listing-photos/$p'))];
  }

  @override
  Future<int> unreadCount(String businessId) async {
    final res = await b.call(() => b.client.from('notifications').select('id').eq('recipient_business_id', businessId).isFilter('read_at', null).count(sb.CountOption.exact));
    return res.count;
  }

  @override
  Future<void> markRead(String id) async {
    await b.call(() => b.client.from('notifications').update({'read_at': DateTime.now().toUtc().toIso8601String()}).eq('id', id));
    b.touch({DataDomain.notifications});
  }

  @override
  Future<void> markAllRead(String businessId) async {
    await b.call(() => b.client
        .from('notifications')
        .update({'read_at': DateTime.now().toUtc().toIso8601String()})
        .eq('recipient_business_id', businessId)
        .isFilter('read_at', null));
    b.touch({DataDomain.notifications});
  }

  @override
  Stream<AppNotification> incoming(String businessId) => b._incoming.stream;

  @override
  Future<NotificationPrefs> prefs(String businessId) async {
    final row = await b.call(() => b.client.from('notification_preferences').select().eq('business_id', businessId).maybeSingle());
    final subs = await b.call(() => b.client.from('category_subscriptions').select('category_id').eq('business_id', businessId));
    return NotificationPrefs.fromRow(row ?? const {}, {for (final s in subs) s['category_id'] as String});
  }

  @override
  Future<void> savePrefs(String businessId, NotificationPrefs p) async {
    await b.call(() => b.client.from('notification_preferences').upsert({
          'business_id': businessId,
          'inventory_updates': p.inventoryUpdates.wire,
          'booking_activity': p.bookingActivity.wire,
          'task_reminders': p.taskReminders.wire,
          'now_requests': p.nowRequests,
          'quiet_start': NotificationPrefs.timeWire(p.quietStart),
          'quiet_end': NotificationPrefs.timeWire(p.quietEnd),
          'digest_hour': p.digestHour,
          'preferred_radius_km': p.preferredRadiusKm,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        }));
    await b.call(() => b.client.from('category_subscriptions').delete().eq('business_id', businessId));
    if (p.subscribedCategories.isNotEmpty) {
      await b.call(() => b.client
          .from('category_subscriptions')
          .insert([for (final c in p.subscribedCategories) {'business_id': businessId, 'category_id': c}]));
    }
    b.touch({DataDomain.notifications});
  }

  @override
  Future<void> registerDevice(String token, String platform) async {
    final uid = b.client.auth.currentUser?.id;
    if (uid == null) return;
    b._deviceToken = token;
    await b.rpc('register_device', {'p_token': token, 'p_platform': platform});
  }
}

// ============================================================================
class _SbNow implements NowApi {
  _SbNow(this.b);
  final SupabaseBackend b;

  @override
  Future<String> create(NowRequestDraft d) async {
    final id = await b.rpc('create_now_request', {
      'p': {
        'requester_business_id': d.requesterId,
        'category_id': d.categoryId,
        'item_description': d.itemDescription.trim(),
        'quantity': d.quantity,
        'needed_from': b._date(d.neededFrom),
        'needed_to': b._date(d.neededFrom),
        'needed_by_time': d.neededByTime,
        'fulfilment': d.fulfilment.wire,
        'lat': d.location!.latitude,
        'lng': d.location!.longitude,
        'location_label': d.locationLabel,
        'radius_km': d.radiusKm,
        'max_budget': d.maxBudget,
        'notes': d.notes,
        'idempotency_key': d.idempotencyKey,
      }
    }) as String;
    b.touch({DataDomain.now});
    return id;
  }

  @override
  Future<int> broadcast(String requestId, {int? radiusKm}) async {
    final n = await b.rpc('broadcast_now_request', {'p_request': requestId, 'p_radius_km': radiusKm}) as int;
    b.touch({DataDomain.now});
    return n;
  }

  @override
  Future<NowRequest> request(String id) async =>
      NowRequest.fromRow(await b.call(() => b.client.from('now_requests').select(NowRequest.columns).eq('id', id).single()));

  @override
  Future<List<NowRequest>> mine(String businessId) async {
    final rows = await b.call(() => b.client.from('now_requests').select(NowRequest.columns).eq('requester_business_id', businessId).order('created_at', ascending: false).limit(30));
    return [for (final r in rows) NowRequest.fromRow(r)];
  }

  @override
  Future<List<NowMapVendor>> map(String requestId) async {
    final rows = await b.rpc('now_request_map', {'p_request': requestId}) as List;
    return [for (final r in rows) NowMapVendor.fromRow(r)];
  }

  @override
  Future<List<NowOffer>> offers(String requestId) async {
    final rows = await b.call(() => b.client.from('now_offers').select(NowOffer.columns).eq('request_id', requestId).neq('status', 'withdrawn').order('created_at'));
    return [for (final r in rows) NowOffer.fromRow(r)];
  }

  @override
  Future<String> selectOffer(String offerId, String idempotencyKey) async {
    final id = await b.rpc('select_now_offer', {'p_offer': offerId, 'p_idempotency_key': idempotencyKey}) as String;
    b.touch({DataDomain.now, DataDomain.bookings, DataDomain.work});
    return id;
  }

  @override
  Future<void> close(String requestId, NowStatus to) async {
    await b.rpc('close_now_request', {'p_request': requestId, 'p_to': to.wire});
    b.touch({DataDomain.now});
  }

  @override
  Future<List<NowInboxItem>> inbox(String businessId) async {
    final rows = await b.call(() => b.client
        .from('now_request_recipients')
        .select('*, now_requests(${NowRequest.columns}), listings(${Listing.columns})')
        .eq('business_id', businessId)
        .order('notified_at', ascending: false)
        .limit(30));
    final offers = await b.call(() => b.client.from('now_offers').select(NowOffer.columns).eq('supplier_business_id', businessId).neq('status', 'withdrawn'));
    final byRequest = {for (final o in offers) o['request_id'] as String: NowOffer.fromRow(o)};
    return [
      for (final r in rows)
        NowInboxItem(
          request: NowRequest.fromRow(r['now_requests']),
          distanceKm: (r['distance_km'] as num).toDouble(),
          availableQuantity: r['available_quantity'],
          matchedListing: r['listings'] == null ? null : Listing.fromRow(r['listings'], photoUrl: (p) => b.photoUrl('listing-photos/$p')),
          myOffer: byRequest[r['request_id']],
          declined: r['declined_at'] != null,
        )
    ];
  }

  @override
  Future<NowInboxItem> inboxItem(String requestId, String businessId) async {
    final all = await inbox(businessId);
    final item = all.where((i) => i.request.id == requestId).firstOrNull;
    if (item == null) throw const EvError('not_a_recipient');
    // Refresh availability against the current calendar.
    final avail = item.matchedListing == null
        ? 0
        : await b.listings.availableQuantity(item.matchedListing!.id, item.request.neededFrom, item.request.neededTo);
    return NowInboxItem(request: item.request, distanceKm: item.distanceKm, availableQuantity: avail, matchedListing: item.matchedListing, myOffer: item.myOffer, declined: item.declined);
  }

  @override
  Future<void> submitOffer(NowOfferDraft d) async {
    await b.rpc('submit_now_offer', {
      'p': {
        'request_id': d.requestId,
        'supplier_business_id': d.supplierId,
        'listing_id': d.listingId,
        'quantity': d.quantity,
        'unit_price': d.unitPrice,
        'can_deliver': d.canDeliver,
        'note': d.note,
      }
    });
    b.touch({DataDomain.now});
  }

  @override
  Future<void> decline(String requestId, String businessId) async {
    await b.rpc('decline_now_request', {'p_request': requestId, 'p_supplier': businessId});
    b.touch({DataDomain.now});
  }
}

// ============================================================================
class _SbAdmin implements AdminApi {
  _SbAdmin(this.b);
  final SupabaseBackend b;
  AdminSession? _session;

  @override
  AdminSession? get current => _session;

  /// Admins sign in with email + password (Supabase Auth). The role comes
  /// only from platform_admins, which no client can write.
  @override
  Future<AdminSession> signIn(String email, String password) async {
    await b.call(() => b.client.auth.signInWithPassword(email: email.trim(), password: password));
    final role = AdminRole.tryParse(await b.rpc('my_admin_role') as String?);
    if (role == null) {
      await b.client.auth.signOut();
      throw const EvError('admin_forbidden', 'This account is not a platform administrator.');
    }
    return _session = AdminSession(userId: b.client.auth.currentUser!.id, role: role, displayName: email.trim());
  }

  @override
  Future<void> signOut() async {
    _session = null;
    await b._signOut();
  }

  @override
  Future<Map<String, int>> stats() async {
    final m = await b.rpc('admin_platform_stats') as Map<String, dynamic>;
    return m.map((k, v) => MapEntry(k, (v as num).toInt()));
  }

  @override
  Future<List<AdminBusinessRow>> businesses({String? search, VerificationStatus? verification}) async {
    final rows = await b.rpc('admin_list_businesses', {'p_search': search, 'p_verification': verification?.wire}) as List;
    return [for (final r in rows) AdminBusinessRow.fromRow(r)];
  }

  @override
  Future<void> setVerification(String businessId, VerificationStatus status, String reason) =>
      b.rpc('admin_set_verification', {'p_business': businessId, 'p_status': status.wire, 'p_reason': reason});

  @override
  Future<void> setBusinessStatus(String businessId, BusinessStatus status, String reason) =>
      b.rpc('admin_set_business_status', {'p_business': businessId, 'p_status': status.wire, 'p_reason': reason});

  @override
  Future<List<Listing>> listingsForReview({ModerationStatus? status}) async {
    var q = b.client.from('listings').select(Listing.columns).eq('status', 'published');
    if (status != null) q = q.eq('moderation_status', status.wire);
    final rows = await b.call(() => q.order('published_at', ascending: false).limit(100));
    return [for (final r in rows) Listing.fromRow(r, photoUrl: (p) => b.photoUrl('listing-photos/$p'))];
  }

  @override
  Future<void> moderateListing(String listingId, ModerationStatus status, String reason) =>
      b.rpc('admin_moderate_listing', {'p_listing': listingId, 'p_status': status.wire, 'p_reason': reason});

  @override
  Future<List<NowRequest>> nowRequests() async {
    final rows = await b.call(() => b.client.from('now_requests').select(NowRequest.columns).order('created_at', ascending: false).limit(100));
    return [for (final r in rows) NowRequest.fromRow(r)];
  }

  @override
  Future<List<Booking>> recentBookings() async {
    final rows = await b.call(() => b.client.from('bookings').select(Booking.columns).order('created_at', ascending: false).limit(100));
    return [for (final r in rows) Booking.fromRow(r)];
  }

  @override
  Future<List<Dispute>> disputes() async {
    final rows = await b.call(() => b.client.from('disputes').select('*, bookings(reference), businesses(name)').order('created_at', ascending: false));
    return [for (final r in rows) Dispute.fromRow(r)];
  }

  @override
  Future<void> resolveDispute(String disputeId, String status, String resolution) =>
      b.rpc('admin_resolve_dispute', {'p_dispute': disputeId, 'p_status': status, 'p_resolution': resolution});

  @override
  Future<List<AuditEntry>> auditLog() async {
    final rows = await b.call(() => b.client.from('audit_logs').select().order('created_at', ascending: false).limit(200));
    return [for (final r in rows) AuditEntry.fromRow(r)];
  }

  @override
  Future<void> upsertCategory(Category c, bool active, String reason) =>
      b.rpc('admin_upsert_category', {'p_id': c.id, 'p_name': c.name, 'p_kind': c.kind.wire, 'p_active': active, 'p_reason': reason});
}
