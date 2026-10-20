import 'package:evenda/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// Payment maths behind the Business dashboard and the record-payment sheet.
/// Regression for EV-7AFD36: K3,000 confirmed against a K300 booking showed
/// "Paid 167%".
const me = BizRef(id: 'feluna', name: 'Feluna');
const them = BizRef(id: 'kabwata', name: 'Kabwata');
final now = DateTime.utc(2026, 10, 20, 10);

PaymentRecord pay(double amount, {String kind = 'payment', bool confirmed = true, bool voided = false}) => PaymentRecord(
      id: 'p$amount$kind$confirmed$voided',
      amount: amount,
      method: 'mobile_money',
      kind: kind,
      recordedByBusinessId: them.id,
      createdAt: now,
      confirmedAt: confirmed ? now : null,
      voidedAt: voided ? now : null,
      voidReason: voided ? 'typo' : null,
    );

Booking booking(double total, List<PaymentRecord> payments,
        {BizRef supplier = me, BookingStatus status = BookingStatus.confirmed, DateTime? created, String ref = 'EV-TEST'}) =>
    Booking(
      id: ref,
      reference: ref,
      source: BookingSource.quotation,
      requester: supplier == me ? them : me,
      supplier: supplier,
      startsOn: DateTime(2026, 10, 25),
      endsOn: DateTime(2026, 10, 25),
      status: status,
      paymentStatus: PaymentStatus.unpaid,
      total: total,
      fulfilment: Fulfilment.pickup,
      createdAt: created ?? now,
      payments: payments,
    );

void main() {
  group('Booking payment figures', () {
    test('a payment equal to the total is fully paid, nothing remaining', () {
      final b = booking(300, [pay(300)]);
      expect(b.confirmedPaid, 300);
      expect(b.remainingToRecord, 0);
      expect(b.overpaid, isFalse);
    });

    test('partial payments and deposits accumulate', () {
      final b = booking(1500, [pay(500, kind: 'deposit'), pay(250)]);
      expect(b.confirmedPaid, 750);
      expect(b.remainingToRecord, 750);
    });

    test('a record awaiting confirmation does not count as paid but does reduce what can still be recorded', () {
      final b = booking(300, [pay(300, confirmed: false)]);
      expect(b.confirmedPaid, 0);
      expect(b.remainingToRecord, 0, reason: 'a second K300 would double-record the booking');
    });

    test('voided records never count and free up the balance', () {
      final b = booking(300, [pay(3000, voided: true), pay(300)]);
      expect(b.confirmedPaid, 300);
      expect(b.recordedNet, 300);
      expect(b.overpaid, isFalse);
    });

    test('refunds subtract', () {
      final b = booking(300, [pay(300), pay(100, kind: 'refund')]);
      expect(b.confirmedPaid, 200);
      expect(b.remainingToRecord, 100);
    });

    test('EV-7AFD36: K3,000 confirmed on K300 is flagged as overpaid', () {
      final b = booking(300, [pay(3000)]);
      expect(b.overpaid, isTrue);
      expect(b.remainingToRecord, 0);
    });

    test('ngwee precision: K0.10 + K0.20 settles K0.30', () {
      final b = booking(0.30, [pay(0.10), pay(0.20)]);
      expect(b.overpaid, isFalse);
      expect(b.remainingToRecord, closeTo(0, 0.001));
    });
  });

  group('SupplierMonth (Business dashboard)', () {
    test('EV-7AFD36 + K1,500 unpaid: paid counts at most each booking total, never 167%', () {
      final m = SupplierMonth.of([booking(300, [pay(3000)], ref: 'EV-7AFD36'), booking(1500, [], ref: 'EV-1D2548')], me.id, now: now);
      expect(m.booked, 1800);
      expect(m.paid, 300);
      expect(m.collectedPercent, 17);
      expect(m.outstanding, 1500);
      expect(m.overpaid.map((b) => b.reference), ['EV-7AFD36']);
    });

    test('pending and voided payments are excluded from paid', () {
      final m = SupplierMonth.of([booking(1000, [pay(400, confirmed: false), pay(300, voided: true), pay(200)])], me.id, now: now);
      expect(m.paid, 200);
      expect(m.collectedPercent, 20);
    });

    test('cancelled bookings and bookings where we are the hirer are excluded', () {
      final m = SupplierMonth.of([
        booking(500, [pay(500)], status: BookingStatus.cancelled, ref: 'C'),
        booking(800, [pay(800)], supplier: them, ref: 'H'),
        booking(200, [pay(100)], ref: 'S'),
      ], me.id, now: now);
      expect(m.booked, 200);
      expect(m.paid, 100);
    });

    test('month is decided in Lusaka time (UTC+2)', () {
      final lateSept = DateTime.utc(2026, 9, 30, 21, 30); // 23:30 in Lusaka on 30 Sep: last month
      final earlyOct = DateTime.utc(2026, 9, 30, 22, 30); // 00:30 in Lusaka on 1 Oct: this month
      final m = SupplierMonth.of([booking(100, [], created: lateSept, ref: 'A'), booking(200, [], created: earlyOct, ref: 'B')], me.id, now: now);
      expect(m.bookings.map((b) => b.reference), ['B']);
    });

    test('no bookings: no percentage rather than a fabricated 0%', () {
      final m = SupplierMonth.of(const [], me.id, now: now);
      expect(m.collectedPercent, isNull);
      expect(m.paid, 0);
    });
  });
}
