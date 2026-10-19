import 'dart:async';
import 'dart:math' as math;

import 'package:latlong2/latlong.dart';
import 'package:uuid/uuid.dart';

import '../../core/errors.dart';
import '../../core/format.dart';
import '../../domain/models.dart';
import '../backend.dart';

const _uuid = Uuid();
String newId() => _uuid.v4();

/// Mutable in-memory state for demo mode, plus the rule helpers that mirror
/// the Postgres functions (availability, reservation, notifications, task
/// generation). Everything here is labelled demo data in the UI.
class DemoDb {
  // Accounts
  final users = <String, Session>{}; // userId -> session
  final userBusiness = <String, String>{}; // userId -> businessId
  String? sessionUserId;

  // Businesses
  final businesses = <String, Business>{};
  final team = <String, List<TeamMember>>{};
  final verificationDocs = <String, int>{};

  // Inventory
  final listings = <String, Listing>{};
  final reservations = <Reservation>[];
  final blocks = <(String businessId, AvailabilityBlock block)>[];
  final stockLedger = <(String listingId, int delta, String reason, DateTime at)>[];

  // Discovery & notifications
  final follows = <String, Map<String, SupplierFollow>>{};
  final prefs = <String, NotificationPrefs>{};
  final notifications = <String, List<AppNotification>>{};
  final _notificationKeys = <String>{};
  final inventoryEvents = <(String dedupe, String businessId, InventoryUpdate update)>[];

  // Transactions
  final requests = <String, QuoteRequest>{};
  final bookings = <String, Booking>{};
  final idempotency = <String, String>{}; // key -> booking id

  // Work
  final events = <String, EventPlan>{};
  final tasks = <String, WorkTask>{};
  final reminders = <String, List<TaskReminder>>{};

  // Evenda Now
  final nowRequests = <String, NowRequest>{};
  final nowRecipients = <String, Map<String, (double distanceKm, int available, String listingId, bool declined)>>{};
  final nowOffers = <String, NowOffer>{};

  // Admin
  final audit = <AuditEntry>[];
  final disputes = <String, Dispute>{};
  int _auditSeq = 1;

  final _changes = StreamController<Set<DataDomain>>.broadcast();
  final _incoming = StreamController<(String businessId, AppNotification n)>.broadcast();
  Stream<Set<DataDomain>> get changes => _changes.stream;
  Stream<(String, AppNotification)> get incoming => _incoming.stream;

  void touch(Set<DataDomain> d) => _changes.add(d);

  // -------------------------------------------------------------------------
  // Session helpers
  // -------------------------------------------------------------------------
  Session requireSession() {
    final s = sessionUserId == null ? null : users[sessionUserId];
    if (s == null) throw const EvError('not_authenticated');
    return s;
  }

  String? currentBusinessId() => sessionUserId == null ? null : userBusiness[sessionUserId];

  void requireMember(String businessId) {
    requireSession();
    if (currentBusinessId() != businessId) throw const EvError('forbidden');
  }

  BizRef ref(String businessId) => businesses[businessId]!.ref;

  // -------------------------------------------------------------------------
  // Availability (mirrors public.available_quantity)
  // -------------------------------------------------------------------------
  bool isBlocked(Listing l, DateTime from, DateTime to) => blocks.any((b) =>
      b.$1 == l.businessId &&
      (b.$2.listingId == null || b.$2.listingId == l.id) &&
      !b.$2.startsOn.isAfter(to) &&
      !b.$2.endsOn.isBefore(from));

  int reservedOn(String listingId, DateTime day, {String? excludeBooking}) => reservations
      .where((r) =>
          r.listingId == listingId && r.status.holdsStock && r.covers(day) && (excludeBooking == null || r.bookingId != excludeBooking))
      .fold(0, (s, r) => s + r.quantity);

  int available(String listingId, DateTime from, DateTime to) {
    final l = listings[listingId];
    if (l == null) return 0;
    if (!l.tracksStock) return 1 << 30;
    if (isBlocked(l, from, to)) return 0;
    var peak = 0;
    for (var d = EvDates.dateOnly(from); !d.isAfter(to); d = d.add(const Duration(days: 1))) {
      peak = math.max(peak, reservedOn(listingId, d));
    }
    return math.max(l.usable - peak, 0);
  }

  /// Mirrors public.reserve_stock: the single path that holds quantity.
  String reserve(String listingId, int qty, DateTime from, DateTime to, ReservationSource source,
      {String? bookingId, String? clientLabel, String? note}) {
    final l = listings[listingId];
    if (l == null) throw const EvError('listing_not_found');
    if (to.isBefore(from)) throw const EvError('invalid_dates');
    if (from.isBefore(EvDates.today())) throw const EvError('dates_in_past');
    final avail = available(listingId, from, to);
    if (avail < qty) {
      throw EvError('insufficient_availability', 'Only $avail of ${l.title} available for those dates.',
          {'requested': qty, 'available': avail});
    }
    final id = newId();
    reservations.add(Reservation(
      id: id,
      listingId: listingId,
      quantity: qty,
      startsOn: EvDates.dateOnly(from),
      endsOn: EvDates.dateOnly(to),
      source: source,
      status: ReservationStatus.confirmed,
      bookingId: bookingId,
      clientLabel: clientLabel,
      note: note,
      listingTitle: l.title,
    ));
    return id;
  }

  // -------------------------------------------------------------------------
  // Notifications (mirrors public.notify; deduplicated by key)
  // -------------------------------------------------------------------------
  void notify(String recipient, NotificationCategory category, String title, String body, String dedupeKey,
      {String? route, Map<String, dynamic> data = const {}, String? image, bool digest = false, DateTime? at}) {
    final key = '$recipient|$dedupeKey';
    if (!_notificationKeys.add(key)) return;
    final n = AppNotification(
      id: newId(),
      category: category,
      title: title,
      body: body,
      createdAt: at ?? DateTime.now(),
      imageUrl: image,
      route: route,
      data: data,
      digest: digest,
    );
    notifications.putIfAbsent(recipient, () => []).insert(0, n);
    if (at == null) _incoming.add((recipient, n));
  }

  // -------------------------------------------------------------------------
  // Inventory broadcasts (mirrors inventory_event_recipients + fanout)
  // -------------------------------------------------------------------------
  void emitInventoryEvent(Listing l, String type, {bool high = false, Map<String, dynamic> payload = const {}, String suffix = ''}) {
    final supplier = businesses[l.businessId]!;
    if (!supplier.onboardingCompleted || l.moderation != ModerationStatus.ok) return;
    final dedupe = '$type:${l.id}:${EvDates.iso(EvDates.today())}:$suffix';
    if (inventoryEvents.any((e) => e.$1 == dedupe)) return;
    final update = InventoryUpdate(
      id: newId(),
      type: type,
      supplier: supplier.ref,
      listing: l.copyWith(business: supplier.ref),
      payload: payload,
      createdAt: DateTime.now(),
    );
    inventoryEvents.insert(0, (dedupe, l.businessId, update));
    if (type == 'listing_paused' || type == 'listing_removed') return;

    final title = switch (type) {
      'listing_published' => '${supplier.name} listed ${l.title}',
      'stock_added' => '${supplier.name} added ${payload['delta']} × ${l.title}',
      'stock_restored' => '${l.title} back in service at ${supplier.name}',
      'availability_opened' => '${supplier.name} opened dates for ${l.title}',
      _ => '${supplier.name} updated ${l.title}',
    };
    final body = [
      categoryById(l.categoryId).name,
      if (supplier.neighbourhood != null) supplier.neighbourhood!,
      'Availability is confirmed only by quotation',
    ].join(' · ');

    for (final b in businesses.values) {
      if (b.id == supplier.id || !b.onboardingCompleted || b.status != BusinessStatus.active) continue;
      final p = prefs[b.id] ?? const NotificationPrefs();
      if (p.inventoryUpdates == PrefLevel.off) continue;
      final f = follows[b.id]?[supplier.id];
      if (f?.muted == true) continue;
      final subscribed = p.subscribedCategories.contains(l.categoryId) &&
          (b.location == null || supplier.location == null || distanceKm(b.location!, supplier.location!) <= p.preferredRadiusKm);
      if (f == null && !subscribed) continue;
      final immediate = (f?.pushEnabled ?? false) || (p.inventoryUpdates == PrefLevel.immediate && high);
      notify(b.id, NotificationCategory.inventory, title, body, 'inv:$dedupe',
          route: '/listing/${l.id}',
          data: {'listing_id': l.id, 'supplier_id': supplier.id, 'type': type},
          image: l.coverPhoto,
          digest: !immediate);
    }
  }

  // -------------------------------------------------------------------------
  // Tasks & reminders (mirrors schedule_task_reminders / generate_*_tasks)
  // -------------------------------------------------------------------------
  void scheduleReminders(WorkTask t) {
    final list = reminders.putIfAbsent(t.id, () => []);
    for (var i = 0; i < list.length; i++) {
      if (list[i].status == 'pending') {
        list[i] = TaskReminder(id: list[i].id, remindAt: list[i].remindAt, kind: list[i].kind, status: 'cancelled');
      }
    }
    if (!t.status.open) return;
    final now = DateTime.now();
    if (t.priority != TaskPriority.low && t.dueAt.subtract(const Duration(hours: 24)).isAfter(now)) {
      list.add(TaskReminder(id: newId(), remindAt: t.dueAt.subtract(const Duration(hours: 24)), kind: 'advance', status: 'pending'));
    }
    if ((t.priority == TaskPriority.high || t.priority == TaskPriority.critical) &&
        t.dueAt.subtract(const Duration(hours: 2)).isAfter(now)) {
      list.add(TaskReminder(id: newId(), remindAt: t.dueAt.subtract(const Duration(hours: 2)), kind: 'deadline', status: 'pending'));
    }
  }

  /// Insert-if-absent by (business, generatedKey) so regeneration never duplicates.
  bool putTask(WorkTask t) {
    if (t.generatedKey != null &&
        tasks.values.any((x) => x.businessId == t.businessId && x.generatedKey == t.generatedKey)) {
      return false;
    }
    tasks[t.id] = t;
    scheduleReminders(t);
    return true;
  }

  static const eventTemplates = [
    ('confirm_venue_access', 'Confirm venue access and setup time', -4320, TaskPriority.high),
    ('complete_setup', 'Complete setup', -60, TaskPriority.critical),
  ];

  int generateEventTasks(String eventId) {
    final e = events[eventId]!;
    var n = 0;
    WorkTask mk(String key, String title, int offset, TaskPriority p, {String? reqId}) => WorkTask(
          id: newId(),
          businessId: e.businessId,
          title: title,
          dueAt: e.startsAt.add(Duration(minutes: offset)),
          offsetMinutes: offset,
          priority: p,
          status: TaskStatus.todo,
          eventId: e.id,
          eventName: e.name,
          requirementId: reqId,
          generatedKey: key,
        );
    for (final t in eventTemplates) {
      if (putTask(mk('event:${e.id}:${t.$1}', t.$2, t.$3, t.$4))) n++;
    }
    for (final r in e.requirements) {
      final qty = r.quantity != null ? ' (${r.quantity})' : '';
      switch (r.responsibility) {
        case Responsibility.self when r.bookingId == null:
          if (putTask(mk('req:${r.id}', 'Arrange ${r.label}$qty', -4320, TaskPriority.high, reqId: r.id))) n++;
        case Responsibility.unassigned:
          if (putTask(mk('req-assign:${r.id}', 'Decide who supplies ${r.label}', -7200, TaskPriority.normal, reqId: r.id))) n++;
        case Responsibility.venue || Responsibility.client || Responsibility.otherVendor:
          final who = r.responsibility == Responsibility.otherVendor ? (r.supplierName ?? 'the other vendor') : r.responsibility.label.toLowerCase();
          if (putTask(mk('req-confirm:${r.id}', 'Confirm $who is providing ${r.label}', -2880, TaskPriority.low, reqId: r.id))) n++;
        default:
          break;
      }
    }
    return n;
  }

  void generateBookingTasks(Booking b) {
    final start = DateTime(b.startsOn.year, b.startsOn.month, b.startsOn.day, 8);
    final rentsStock = b.items.any((i) => i.listingId != null && (listings[i.listingId]?.tracksStock ?? false));
    final supplierTpl = rentsStock
        ? [
            ('confirm_payment', 'Confirm deposit or payment', -4320, TaskPriority.normal),
            ('check_stock', 'Check and count stock for this job', -2880, TaskPriority.high),
            ('prepare_load', 'Prepare and load equipment', -720, TaskPriority.high),
            ('inspect_returns', 'Inspect returned equipment', 1440, TaskPriority.normal),
          ]
        : [('prepare_materials', 'Prepare materials', -1440, TaskPriority.normal)];
    final requesterTpl = [
      ('confirm_supplier', 'Confirm supplier availability', -2880, TaskPriority.high),
      if (rentsStock) ('collect_equipment', 'Collect hired equipment', 720, TaskPriority.normal),
    ];
    final floor = DateTime.now().add(const Duration(hours: 1));
    DateTime due(int offset) {
      final d = start.add(Duration(minutes: offset));
      return d.isBefore(floor) ? floor : d;
    }

    for (final t in supplierTpl) {
      putTask(WorkTask(
        id: newId(),
        businessId: b.supplier.id,
        title: '${t.$2} · ${b.reference}',
        dueAt: due(t.$3),
        priority: t.$4,
        status: TaskStatus.todo,
        bookingId: b.id,
        generatedKey: 'booking:${b.id}:${t.$1}',
      ));
    }
    for (final t in requesterTpl) {
      putTask(WorkTask(
        id: newId(),
        businessId: b.requester.id,
        title: '${t.$2} · ${b.reference}',
        dueAt: due(t.$3),
        priority: t.$4,
        status: TaskStatus.todo,
        bookingId: b.id,
        eventId: b.eventId,
        eventName: b.eventId == null ? null : events[b.eventId]?.name,
        generatedKey: 'booking:${b.id}:${t.$1}',
      ));
    }
  }

  /// Mirrors process_due_reminders, run by a timer in demo mode.
  int processDueReminders() {
    var sent = 0;
    final now = DateTime.now();
    for (final entry in reminders.entries) {
      final t = tasks[entry.key];
      if (t == null) continue;
      for (var i = 0; i < entry.value.length; i++) {
        final r = entry.value[i];
        if (r.status != 'pending' || r.remindAt.isAfter(now)) continue;
        if (!t.status.open) {
          entry.value[i] = TaskReminder(id: r.id, remindAt: r.remindAt, kind: r.kind, status: 'cancelled');
          continue;
        }
        final allowed = nextAllowedSend(t.businessId, now);
        if (allowed.isAfter(now) && t.priority != TaskPriority.critical) {
          entry.value[i] = TaskReminder(id: r.id, remindAt: allowed, kind: r.kind, status: 'pending');
          continue;
        }
        notify(t.businessId, NotificationCategory.task, '${r.kind == 'deadline' ? 'Due soon' : 'Reminder'}: ${t.title}',
            'Due ${EvDates.dayTime(t.dueAt)}', 'rem:${r.id}',
            route: '/work/task/${t.id}', data: {'task_id': t.id});
        entry.value[i] = TaskReminder(id: r.id, remindAt: r.remindAt, kind: r.kind, status: 'sent');
        sent++;
      }
    }
    return sent;
  }

  DateTime nextAllowedSend(String businessId, DateTime at) {
    final p = prefs[businessId] ?? const NotificationPrefs();
    final t = Duration(hours: at.hour, minutes: at.minute);
    final inQuiet = p.quietStart > p.quietEnd ? (t >= p.quietStart || t < p.quietEnd) : (t >= p.quietStart && t < p.quietEnd);
    if (!inQuiet) return at;
    final base = DateTime(at.year, at.month, at.day).add(p.quietEnd);
    return t >= p.quietEnd ? base.add(const Duration(days: 1)) : base;
  }

  // -------------------------------------------------------------------------
  // Admin
  // -------------------------------------------------------------------------
  void writeAudit(AdminRole role, String action, String table, String id, String? reason, Map<String, dynamic>? before, Map<String, dynamic>? after) {
    audit.insert(
        0,
        AuditEntry(
          id: _auditSeq++,
          action: action,
          targetTable: table,
          targetId: id,
          createdAt: DateTime.now(),
          actorRole: role,
          reason: reason,
          before: before,
          after: after,
        ));
  }

  // -------------------------------------------------------------------------
  // Misc
  // -------------------------------------------------------------------------
  static final _distance = const Distance();
  static double distanceKm(LatLng a, LatLng b) => (_distance.as(LengthUnit.Meter, a, b) / 1000 * 100).round() / 100;

  int _refSeq = 0x3A21C;
  String nextReference() => 'EV-${(_refSeq++).toRadixString(16).toUpperCase()}';

  void dispose() {
    _changes.close();
    _incoming.close();
  }
}
