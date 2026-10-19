/// Enums mirror the Postgres enums one-to-one. `wire` is the database value.
library;

T _parse<T extends Enum>(List<T> values, String? wire, T fallback) {
  if (wire == null) return fallback;
  final camel = wire.replaceAllMapped(RegExp(r'_([a-z])'), (m) => m[1]!.toUpperCase());
  return values.firstWhere((v) => v.name == camel, orElse: () => fallback);
}

String _wire(Enum e) => e.name.replaceAllMapped(RegExp(r'[A-Z]'), (m) => '_${m[0]!.toLowerCase()}');

extension EnumWire on Enum {
  String get wire => _wire(this);
}

enum OfferingType {
  rental('Rental inventory', 'Chairs, tents, décor, equipment you hire out'),
  service('Services', 'Styling, catering, photography, DJ and other work you perform'),
  package('Packages', 'Bundles that combine items and services at one price');

  const OfferingType(this.label, this.hint);
  final String label;
  final String hint;
  static OfferingType parse(String? w) => _parse(values, w, OfferingType.rental);
}

enum MemberRole {
  owner('Owner'),
  manager('Manager'),
  staff('Staff');

  const MemberRole(this.label);
  final String label;
  static MemberRole parse(String? w) => _parse(values, w, MemberRole.staff);
}

enum VerificationStatus {
  unverified('Not verified'),
  pending('Verification pending'),
  verified('Verified'),
  rejected('Verification rejected');

  const VerificationStatus(this.label);
  final String label;
  static VerificationStatus parse(String? w) => _parse(values, w, VerificationStatus.unverified);
}

enum BusinessStatus {
  active,
  suspended;

  static BusinessStatus parse(String? w) => _parse(values, w, BusinessStatus.active);
}

enum LocationPrecision {
  exact('Exact location', 'Other vendors see your pin'),
  approximate('Approximate area', 'Other vendors see a point within about 500 m');

  const LocationPrecision(this.label, this.hint);
  final String label;
  final String hint;
  static LocationPrecision parse(String? w) => _parse(values, w, LocationPrecision.approximate);
}

enum ListingStatus {
  draft('Draft'),
  published('Published'),
  paused('Paused'),
  archived('Archived');

  const ListingStatus(this.label);
  final String label;
  static ListingStatus parse(String? w) => _parse(values, w, ListingStatus.draft);
}

enum PriceUnit {
  perItemPerDay('per item / day', 'Per item per day'),
  perItemPerEvent('per item / event', 'Per item per event'),
  perEvent('per event', 'Per event'),
  perHour('per hour', 'Per hour'),
  perPackage('per package', 'Per package'),
  onQuote('on quotation', 'Price on quotation');

  const PriceUnit(this.short, this.label);
  final String short;
  final String label;
  bool get perItem => this == perItemPerDay || this == perItemPerEvent;
  static PriceUnit parse(String? w) => _parse(values, w, PriceUnit.onQuote);
}

enum ModerationStatus {
  ok,
  flagged,
  removed;

  static ModerationStatus parse(String? w) => _parse(values, w, ModerationStatus.ok);
}

enum ReservationSource {
  booking('Evenda booking'),
  manual('Recorded manually'),
  now('Evenda Now');

  const ReservationSource(this.label);
  final String label;
  static ReservationSource parse(String? w) => _parse(values, w, ReservationSource.manual);
}

enum ReservationStatus {
  held,
  confirmed,
  dispatched,
  returned,
  cancelled;

  bool get holdsStock => this == held || this == confirmed || this == dispatched;
  static ReservationStatus parse(String? w) => _parse(values, w, ReservationStatus.confirmed);
}

enum Fulfilment {
  pickup('Requester collects'),
  supplierDelivers('Supplier delivers'),
  supplierSetsUp('Supplier delivers and sets up');

  const Fulfilment(this.label);
  final String label;
  static Fulfilment parse(String? w) => _parse(values, w, Fulfilment.pickup);
}

enum QuoteRequestStatus {
  open('Awaiting quote'),
  quoted('Quoted'),
  accepted('Accepted'),
  declined('Declined'),
  cancelled('Cancelled'),
  expired('Expired');

  const QuoteRequestStatus(this.label);
  final String label;
  bool get isOpen => this == open || this == quoted;
  static QuoteRequestStatus parse(String? w) => _parse(values, w, QuoteRequestStatus.open);
}

enum QuotationStatus {
  sent('Open'),
  superseded('Superseded'),
  accepted('Accepted'),
  declined('Declined'),
  expired('Expired'),
  withdrawn('Withdrawn');

  const QuotationStatus(this.label);
  final String label;
  static QuotationStatus parse(String? w) => _parse(values, w, QuotationStatus.sent);
}

enum BookingStatus {
  confirmed('Confirmed'),
  preparing('Preparing'),
  dispatched('Dispatched'),
  inProgress('In progress'),
  returned('Returned'),
  completed('Completed'),
  cancelled('Cancelled'),
  disputed('Disputed');

  const BookingStatus(this.label);
  final String label;
  bool get isActive => this != completed && this != cancelled;

  /// The forward path shown on the booking stepper.
  static const path = [confirmed, preparing, dispatched, inProgress, returned, completed];
  static BookingStatus parse(String? w) => _parse(values, w, BookingStatus.confirmed);
}

enum PaymentStatus {
  unpaid('Unpaid'),
  depositRecorded('Deposit recorded'),
  partiallyPaid('Part paid'),
  paid('Paid'),
  refunded('Refunded');

  const PaymentStatus(this.label);
  final String label;
  static PaymentStatus parse(String? w) => _parse(values, w, PaymentStatus.unpaid);
}

enum BookingSource {
  quotation,
  now,
  manual;

  static BookingSource parse(String? w) => _parse(values, w, BookingSource.quotation);
}

enum Responsibility {
  self('My business'),
  venue('Venue'),
  client('Client'),
  otherVendor('Another vendor'),
  unassigned('Unassigned');

  const Responsibility(this.label);
  final String label;
  static Responsibility parse(String? w) => _parse(values, w, Responsibility.unassigned);
}

enum EventStatus {
  planning('Planning'),
  confirmed('Confirmed'),
  completed('Completed'),
  cancelled('Cancelled');

  const EventStatus(this.label);
  final String label;
  static EventStatus parse(String? w) => _parse(values, w, EventStatus.planning);
}

enum EventType {
  wedding('Wedding'),
  kitchenParty('Kitchen party'),
  corporate('Corporate'),
  funeral('Funeral'),
  birthday('Birthday'),
  graduation('Graduation'),
  church('Church event'),
  other('Other');

  const EventType(this.label);
  final String label;
  static EventType parse(String? w) => _parse(values, w, EventType.other);
}

enum TaskPriority {
  low('Low'),
  normal('Normal'),
  high('High'),
  critical('Critical');

  const TaskPriority(this.label);
  final String label;
  static TaskPriority parse(String? w) => _parse(values, w, TaskPriority.normal);
}

enum TaskStatus {
  todo('To do'),
  inProgress('In progress'),
  done('Done'),
  cancelled('Cancelled');

  const TaskStatus(this.label);
  final String label;
  bool get open => this == todo || this == inProgress;
  static TaskStatus parse(String? w) => _parse(values, w, TaskStatus.todo);
}

enum NotificationCategory {
  inventory('Inventory updates'),
  booking('Booking activity'),
  task('Tasks'),
  now('Evenda Now'),
  system('Evenda');

  const NotificationCategory(this.label);
  final String label;
  static NotificationCategory parse(String? w) => _parse(values, w, NotificationCategory.system);
}

enum PrefLevel {
  off('Off'),
  digest('Daily digest'),
  immediate('Immediately');

  const PrefLevel(this.label);
  final String label;
  static PrefLevel parse(String? w) => _parse(values, w, PrefLevel.digest);
}

enum NowStatus {
  draft('Draft'),
  broadcasting('Searching for suppliers'),
  receivingOffers('Receiving offers'),
  offerSelected('Offer selected'),
  bookingConfirmed('Booking confirmed'),
  completed('Completed'),
  cancelled('Cancelled'),
  expired('Expired');

  const NowStatus(this.label);
  final String label;
  bool get live => this == broadcasting || this == receivingOffers || this == offerSelected;
  static NowStatus parse(String? w) => _parse(values, w, NowStatus.draft);
}

enum NowOfferStatus {
  pending('Pending'),
  selected('Selected'),
  rejected('Not selected'),
  withdrawn('Withdrawn'),
  expired('Expired');

  const NowOfferStatus(this.label);
  final String label;
  static NowOfferStatus parse(String? w) => _parse(values, w, NowOfferStatus.pending);
}

enum AdminRole {
  superAdmin('Super admin'),
  moderator('Moderator'),
  support('Support'),
  finance('Finance');

  const AdminRole(this.label);
  final String label;
  static AdminRole? tryParse(String? w) => w == null ? null : _parse(values, w, AdminRole.support);

  /// Mirrors public.admin_has() so the UI can hide what the server would refuse.
  bool can(String permission) => switch (this) {
        superAdmin => true,
        moderator => const {
            'business.read', 'business.verify', 'listing.moderate', 'category.manage', 'activity.read', 'now.read',
            'audit.read'
          }.contains(permission),
        support => const {'business.read', 'booking.read', 'dispute.manage', 'activity.read', 'now.read'}
            .contains(permission),
        finance => const {'business.read', 'booking.read', 'payment.read', 'report.read'}.contains(permission),
      };
}
