import 'dart:typed_data';

import 'package:latlong2/latlong.dart';

import '../domain/models.dart';

/// Data domains. Mutations bump the revision of the domains they affect so
/// screens watching those domains refetch. Realtime events do the same.
enum DataDomain { session, business, listings, discovery, bookings, work, notifications, now, admin }

/// The contract every screen talks to. There are exactly two implementations:
///
/// * `SupabaseBackend` — production. All business rules run in Postgres
///   (RLS, transactional RPCs, triggers). Used whenever Supabase is configured.
/// * `DemoBackend` — an in-memory, clearly labelled demo with seeded Lusaka
///   vendors. Used only when no backend is configured. It mirrors the same
///   rules so the workflows behave as they will in production.
///
/// There is no silent fallback from one to the other.
abstract class Backend {
  bool get isDemo;

  /// Emits the domains that changed (from the local user or realtime).
  Stream<Set<DataDomain>> get changes;

  AuthApi get auth;
  BusinessApi get business;
  ListingApi get listings;
  DiscoveryApi get discovery;
  BookingApi get bookings;
  WorkApi get work;
  NotificationApi get notifications;
  NowApi get now;
  AdminApi get admin;

  /// Turn a stored image reference into something the UI can display.
  String photoUrl(String storagePathOrUrl);

  /// Re-establish live updates after the connection returns.
  Future<void> reconnect();

  void dispose();
}

abstract class AuthApi {
  Session? get current;
  Stream<Session?> get sessions;

  /// Vendor sign-in for email + password.
  Future<Session> signIn(String email, String password);

  /// Creates a vendor account. Returns true when the email must be confirmed
  /// with the 6-digit code Supabase sends before a session exists.
  Future<bool> signUp(String email, String password, String fullName);

  /// Confirms a new account with the code from the sign-up email.
  Future<void> verifyEmail(String email, String code);
  Future<void> resendEmailCode(String email);

  /// Password recovery: email a code, verify it (which signs the user in),
  /// then set a new password.
  Future<void> sendPasswordReset(String email);
  Future<void> verifyPasswordReset(String email, String code);
  Future<void> updatePassword(String newPassword);

  /// Sends an SMS one-time code through Supabase Auth's configured provider.
  Future<void> sendOtp(String e164Phone);
  Future<void> verifyOtp(String e164Phone, String code);
  Future<void> updateProfileName(String name);
  Future<void> signOut();
}

abstract class BusinessApi {
  /// The business the signed-in user belongs to (owner or member), if any.
  Future<Business?> mine();
  Future<Business> get(String id);
  Future<String> create(String name);
  Future<void> update(Business b);
  Future<void> setCategories(String businessId, List<String> categoryIds);
  Future<void> setLocation(String businessId, LatLng point, LocationPrecision precision, String neighbourhood);

  /// The business's exact pin, readable by its own members only.
  /// [Business.location] is the public (possibly rounded) point.
  Future<LatLng?> exactLocation(String businessId);
  Future<void> completeOnboarding(String businessId);
  Future<String> uploadLogo(String businessId, Uint8List bytes, String extension);
  Future<void> uploadVerificationDocument(String businessId, String docType, Uint8List bytes, String extension);
  Future<void> submitForVerification(String businessId);

  Future<List<TeamMember>> team(String businessId);
  Future<void> inviteMember(String businessId, String email, String name, MemberRole role);
  Future<void> setMemberRole(String memberId, MemberRole role);
  Future<void> removeMember(String memberId);
}

abstract class ListingApi {
  Future<List<Listing>> mine(String businessId);
  Future<Listing> get(String id);
  Future<String> create(ListingDraft draft);
  Future<void> update(String id, ListingDraft draft);
  Future<void> setStatus(String id, ListingStatus status);
  Future<List<String>> uploadPhotos(String businessId, List<(Uint8List, String)> files);

  Future<void> adjustStock(String listingId, int delta, String reason, {String? note});
  Future<void> setDamaged(String listingId, int damaged);
  Future<void> completeInspection(String listingId, {required int good, required int damaged});

  /// Backend-computed availability for the whole range (minimum across days).
  Future<int> availableQuantity(String listingId, DateTime from, DateTime to);
  Future<List<AvailabilityDay>> calendar(String listingId, DateTime from, DateTime to);

  Future<List<Reservation>> reservations(String businessId, {String? listingId, bool upcomingOnly = true});
  Future<void> recordManualReservation(String listingId, int quantity, DateTime from, DateTime to, String clientLabel, {String? note});
  Future<void> moveReservation(String reservationId, String action);

  Future<List<AvailabilityBlock>> blocks(String businessId);
  Future<void> addBlock(String businessId, DateTime from, DateTime to, {String? listingId, String? reason});
  Future<void> removeBlock(String blockId);

  Future<List<InventoryConflict>> conflicts(String businessId);
}

abstract class DiscoveryApi {
  Future<List<SearchResult>> search(String myBusinessId, SearchQuery query);
  Future<Business> supplier(String businessId);
  Future<List<Listing>> supplierListings(String businessId);
  Future<List<InventoryUpdate>> inventoryFeed(String myBusinessId, {int limit = 12});

  Future<List<SupplierFollow>> follows(String myBusinessId);
  Future<void> follow(String myBusinessId, String supplierId);
  Future<void> unfollow(String myBusinessId, String supplierId);
  Future<void> setFollowMuted(String myBusinessId, String supplierId, bool muted);
}

abstract class BookingApi {
  Future<List<QuoteRequest>> requests(String businessId);
  Future<QuoteRequest> request(String id);
  Future<String> createRequest(QuoteRequestDraft draft);
  Future<void> postMessage(String requestId, String businessId, String body);
  Future<String> sendQuotation(QuotationDraft draft);
  Future<void> declineRequest(String requestId, String businessId, {String? reason});

  /// Idempotent: retrying with the same key returns the same booking id.
  Future<String> acceptQuotation(String quotationId, String idempotencyKey);

  Future<List<Booking>> bookings(String businessId);
  Future<Booking> booking(String id);
  Future<void> updateStatus(String bookingId, BookingStatus to, {String? note});
  Future<void> recordPayment(String bookingId, String businessId,
      {required double amount, required String method, required String kind, String? reference, String? note});
  Future<void> confirmPayment(String paymentId);
  Future<void> openDispute(String bookingId, String businessId, String reason);
}

abstract class WorkApi {
  Future<List<EventPlan>> events(String businessId);
  Future<EventPlan> event(String id);

  /// Creates the event and its requirements, then generates tasks.
  Future<String> createEvent(EventDraft draft);
  Future<void> updateEvent(String id, EventDraft draft);
  Future<int> generateTasks(String eventId);
  Future<String> createEventFromBooking(String bookingId, String businessId);

  Future<List<WorkTask>> tasks(String businessId, {String? eventId, bool includeDone = false});
  Future<WorkTask> task(String id);
  Future<String> createTask(String businessId, {required String title, required DateTime dueAt, TaskPriority priority, String? eventId, String notes});
  Future<void> updateTask(WorkTask task);
  Future<void> setTaskStatus(String taskId, TaskStatus status);
  Future<void> snoozeTask(String taskId, DateTime until);
  Future<List<TaskReminder>> reminders(String taskId);

  Future<List<WorkloadDay>> workload(String businessId, DateTime from, DateTime to);
}

abstract class NotificationApi {
  Future<List<AppNotification>> list(String businessId);
  Future<int> unreadCount(String businessId);
  Future<void> markRead(String notificationId);
  Future<void> markAllRead(String businessId);

  /// New notifications as they are created (for the in-app banner).
  Stream<AppNotification> incoming(String businessId);

  Future<NotificationPrefs> prefs(String businessId);
  Future<void> savePrefs(String businessId, NotificationPrefs prefs);
  Future<void> registerDevice(String token, String platform);
}

abstract class NowApi {
  Future<String> create(NowRequestDraft draft);

  /// Server-side eligibility and fan-out. Returns the number of suppliers notified.
  Future<int> broadcast(String requestId, {int? radiusKm});
  Future<NowRequest> request(String id);
  Future<List<NowRequest>> mine(String businessId);
  Future<List<NowMapVendor>> map(String requestId);
  Future<List<NowOffer>> offers(String requestId);
  Future<String> selectOffer(String offerId, String idempotencyKey);
  Future<void> close(String requestId, NowStatus to);

  Future<List<NowInboxItem>> inbox(String businessId);
  Future<NowInboxItem> inboxItem(String requestId, String businessId);
  Future<void> submitOffer(NowOfferDraft draft);
  Future<void> decline(String requestId, String businessId);
}

abstract class AdminApi {
  AdminSession? get current;
  Future<AdminSession> signIn(String email, String password);
  Future<void> signOut();

  Future<Map<String, int>> stats();
  Future<List<AdminBusinessRow>> businesses({String? search, VerificationStatus? verification});
  Future<void> setVerification(String businessId, VerificationStatus status, String reason);
  Future<void> setBusinessStatus(String businessId, BusinessStatus status, String reason);
  Future<List<Listing>> listingsForReview({ModerationStatus? status});
  Future<void> moderateListing(String listingId, ModerationStatus status, String reason);
  Future<List<NowRequest>> nowRequests();
  Future<List<Booking>> recentBookings();
  Future<List<Dispute>> disputes();
  Future<void> resolveDispute(String disputeId, String status, String resolution);
  Future<List<AuditEntry>> auditLog();
  Future<void> upsertCategory(Category category, bool active, String reason);
}
