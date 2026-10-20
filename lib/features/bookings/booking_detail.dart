import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/providers.dart';
import '../../core/format.dart';
import '../../data/backend.dart';
import '../../design/ev.dart';
import '../../domain/models.dart';

final bookingProvider = FutureProvider.autoDispose.family<Booking, String>((ref, id) async {
  ref.watchDomains(const [DataDomain.bookings]);
  return ref.watch(backendProvider).bookings.booking(id);
});

class BookingDetailScreen extends ConsumerWidget {
  const BookingDetailScreen({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(bookingProvider(id));
    return Scaffold(
      appBar: AppBar(title: Text(data.value?.reference ?? 'Booking')),
      body: AsyncView(value: data, onRetry: () => ref.invalidate(bookingProvider(id)), data: (b) => _Body(b: b)),
    );
  }
}

class _Body extends ConsumerStatefulWidget {
  const _Body({required this.b});
  final Booking b;
  @override
  ConsumerState<_Body> createState() => _BodyState();
}

class _BodyState extends ConsumerState<_Body> {
  bool _busy = false;

  Future<void> _move(BookingStatus to, {String? confirmTitle, String? confirmBody}) async {
    if (confirmTitle != null && !await confirmAction(context, title: confirmTitle, body: confirmBody ?? '', destructive: to == BookingStatus.cancelled)) return;
    if (!mounted) return;
    setState(() => _busy = true);
    await guard(context, () => ref.read(backendProvider).bookings.updateStatus(widget.b.id, to), success: 'Marked ${to.label.toLowerCase()}');
    HapticFeedback.mediumImpact();
    if (mounted) setState(() => _busy = false);
  }

  (BookingStatus, String, IconData)? _next(Booking b) => switch (b.status) {
        BookingStatus.confirmed => (BookingStatus.preparing, 'Start preparing', LucideIcons.boxes),
        BookingStatus.preparing => (BookingStatus.dispatched, b.fulfilment == Fulfilment.pickup ? 'Mark collected' : 'Mark dispatched', LucideIcons.packageCheck),
        BookingStatus.dispatched => (BookingStatus.returned, 'Mark returned', LucideIcons.undo2),
        BookingStatus.inProgress => (BookingStatus.returned, 'Mark returned', LucideIcons.undo2),
        BookingStatus.returned => (BookingStatus.completed, 'Complete booking', LucideIcons.circleCheck),
        _ => null,
      };

  Future<void> _recordPayment(Booking b, String me) async {
    final amount = TextEditingController(text: b.paymentStatus == PaymentStatus.unpaid && b.depositAmount > 0 ? b.depositAmount.toStringAsFixed(0) : '');
    final ref0 = TextEditingController();
    var method = 'mobile_money';
    var kind = b.paymentStatus == PaymentStatus.unpaid && b.depositAmount > 0 ? 'deposit' : 'payment';
    final ok = await showEvSheet<bool>(
      context,
      title: 'Record a payment',
      subtitle: 'The other business confirms it before it counts. Evenda does not move money.',
      builder: (c) => StatefulBuilder(
        builder: (c, set) => ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(EvSpace.gutter, 0, EvSpace.gutter, EvSpace.x6), children: [
          Text(
            kind == 'refund'
                ? 'Up to ${Money.k(b.confirmedPaid.clamp(0, double.infinity))} can be refunded (confirmed as paid).'
                : '${Money.k(b.remainingToRecord)} still due of ${Money.k(b.total)}${b.recordedNet > b.confirmedPaid ? ' (some records await confirmation)' : ''}.',
            style: EvType.small,
          ),
          const SizedBox(height: EvSpace.x3),
          EvField(label: 'Amount', controller: amount, prefixText: 'K ', keyboardType: const TextInputType.numberWithOptions(decimal: true), inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))]),
          const SizedBox(height: EvSpace.x4),
          const EvFieldLabel('Type'),
          Wrap(spacing: 8, children: [
            for (final (k, l) in const [('deposit', 'Deposit'), ('payment', 'Payment'), ('refund', 'Refund')])
              EvChip(label: l, selected: kind == k, onTap: () => set(() => kind = k)),
          ]),
          const SizedBox(height: EvSpace.x4),
          const EvFieldLabel('Method'),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final (k, l) in const [('mobile_money', 'Mobile money'), ('bank_transfer', 'Bank transfer'), ('cash', 'Cash'), ('other', 'Other')])
              EvChip(label: l, selected: method == k, onTap: () => set(() => method = k)),
          ]),
          const SizedBox(height: EvSpace.x4),
          EvField(label: 'Reference', controller: ref0, hint: 'e.g. Airtel Money transaction ID', optional: true),
          const SizedBox(height: EvSpace.x5),
          EvButton('Save record', expand: true, onPressed: () {
            // Mirrors the server rules for a clear message before sending;
            // the server stays the authority (record_payment).
            final v = double.tryParse(amount.text);
            final limit = kind == 'refund' ? b.confirmedPaid : b.remainingToRecord;
            if (v == null || v <= 0 || (v * 100).roundToDouble() != v * 100) {
              showToast(c, 'Enter an amount above zero with at most two decimals.', icon: LucideIcons.circleAlert);
            } else if (v > limit + 0.001) {
              showToast(c, kind == 'refund' ? 'A refund can’t be more than ${Money.k(limit)}.' : 'Only ${Money.k(limit)} is still due on this booking.',
                  icon: LucideIcons.circleAlert);
            } else {
              Navigator.pop(c, true);
            }
          }),
        ]),
      ),
    );
    if (ok != true || !mounted) return;
    await guard(
      context,
      () => ref.read(backendProvider).bookings.recordPayment(b.id, me,
          amount: double.tryParse(amount.text) ?? 0, method: method, kind: kind, reference: ref0.text.trim().isEmpty ? null : ref0.text.trim()),
      success: 'Payment recorded — waiting for ${b.counterparty(me).name} to confirm',
    );
  }

  Future<void> _dispute(Booking b, String me) async {
    final reason = await confirmWithReason(context,
        title: 'Report a problem',
        body: 'An Evenda support agent will review this booking with both businesses. Describe what went wrong.',
        confirm: 'Open dispute',
        destructive: true);
    if (reason == null || !mounted) return;
    await guard(context, () => ref.read(backendProvider).bookings.openDispute(b.id, me, reason), success: 'Dispute opened');
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.b;
    final me = ref.watch(bizIdProvider);
    final supplier = b.isSupplier(me);
    final other = b.counterparty(me);
    final next = supplier ? _next(b) : null;
    final canCancel = b.status == BookingStatus.confirmed || b.status == BookingStatus.preparing;

    return ListView(padding: const EdgeInsets.only(bottom: EvSpace.x10), children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(EvSpace.gutter, 0, EvSpace.gutter, 0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            BusinessAvatar(name: other.name, logoUrl: other.logoUrl, verified: other.verified, size: 44),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(other.name, style: EvType.headline),
                Text(supplier ? 'You are supplying' : 'You hired from them', style: EvType.small),
              ]),
            ),
            if (other.phone != null) EvIconButton(LucideIcons.phone, tooltip: 'Call', onPressed: () => launchUrl(Uri.parse('tel:${other.phone}'))),
            if (other.whatsapp != null)
              EvIconButton(LucideIcons.messageCircle, tooltip: 'WhatsApp', onPressed: () => launchUrl(Uri.parse('https://wa.me/${ZambianPhone.waDigits(other.whatsapp!)}?text=${Uri.encodeComponent('Re: Evenda booking ${b.reference}')}'), mode: LaunchMode.externalApplication)),
          ]),
          const SizedBox(height: EvSpace.x4),
          Row(children: [
            StatusPill(b.status.label, tone: toneForBooking(b.status)),
            const SizedBox(width: 8),
            if (b.source == BookingSource.now) const StatusPill('Evenda Now', tone: Tone.waiting, icon: LucideIcons.zap),
          ]),
        ]),
      ),
      if (b.status != BookingStatus.cancelled && b.status != BookingStatus.disputed)
        Padding(padding: const EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x5, EvSpace.gutter, 0), child: _Stepper(status: b.status)),
      Padding(
        padding: const EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x5, EvSpace.gutter, 0),
        child: EvSurface(
          child: Column(children: [
            KeyValue('Dates', EvDates.range(b.startsOn, b.endsOn)),
            KeyValue('Arrangement', b.fulfilment.label),
            if (b.deliveryNotes != null) KeyValue('Notes', b.deliveryNotes!),
            const Divider(height: 20),
            for (final i in b.items)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(children: [
                  Expanded(child: Text('${i.quantity} × ${i.description}', style: EvType.body)),
                  Text(Money.k(i.lineTotal), style: EvType.money),
                ]),
              ),
            const Divider(height: 20),
            Row(children: [Expanded(child: Text('Booking total', style: EvType.bodyStrong)), Text(Money.k(b.total), style: EvType.title.copyWith(color: EvColors.forest))]),
          ]),
        ),
      ),
      if (next != null || canCancel)
        Padding(
          padding: const EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x4, EvSpace.gutter, 0),
          child: Row(children: [
            if (next != null)
              Expanded(child: EvButton(next.$2, icon: next.$3, loading: _busy, expand: true, onPressed: () => _move(next.$1))),
            if (next != null && canCancel) const SizedBox(width: 8),
            if (canCancel)
              EvButton('Cancel', kind: EvButtonKind.quiet, onPressed: () => _move(BookingStatus.cancelled,
                  confirmTitle: 'Cancel this booking?', confirmBody: 'Reserved stock is released and ${other.name} is notified. This can’t be undone.')),
          ]),
        ),

      // Payments: separate from booking status.
      SectionHeader('Payments', action: b.status != BookingStatus.cancelled ? 'Record' : null, onAction: () => _recordPayment(b, me)),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: EvSpace.gutter),
        child: EvSurface(
          padding: EdgeInsets.zero,
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.all(EvSpace.x4),
              child: Row(children: [
                StatusPill(b.paymentStatus.label, tone: toneForPayment(b.paymentStatus), icon: LucideIcons.wallet),
                const Spacer(),
                Text('${Money.k(b.confirmedPaid)} of ${Money.k(b.total)} confirmed', style: EvType.small),
              ]),
            ),
            if (b.payments.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(EvSpace.x4, 0, EvSpace.x4, EvSpace.x4),
                child: Text(b.depositAmount > 0 ? 'Deposit of ${Money.k(b.depositAmount)} agreed. No payments recorded yet.' : 'No payments recorded yet.', style: EvType.small),
              ),
            for (final p in b.payments) ...[
              const EvDivider(indent: EvSpace.x4),
              EvRow(
                padding: const EdgeInsets.symmetric(horizontal: EvSpace.x4, vertical: 10),
                leading: IconTile(p.kind == 'refund' ? LucideIcons.undo2 : LucideIcons.handCoins, tone: p.voided ? Tone.neutral : (p.confirmedAt != null ? Tone.positive : Tone.waiting), size: 32),
                title: '${Money.k(p.amount)} ${p.kind}${p.voided ? ' · voided' : ''}',
                titleStyle: p.voided ? EvType.bodyStrong.copyWith(color: EvColors.ink3, decoration: TextDecoration.lineThrough) : null,
                subtitle: p.voided
                    ? 'Voided: ${p.voidReason ?? ''}'
                    : '${p.methodLabel}${p.reference != null ? ' · ${p.reference}' : ''} · ${p.recordedByBusinessId == me ? 'you recorded' : 'they recorded'} ${EvDates.ago(p.createdAt)}',
                trailing: p.voided
                    ? null
                    : p.confirmedAt == null && p.recordedByBusinessId == me
                        ? TextButton(
                            onPressed: () async {
                              final reason = await confirmWithReason(context,
                                  title: 'Void this record?', body: 'Use this for a typing mistake. It stays in the history but no longer counts.', confirm: 'Void');
                              if (reason != null && context.mounted) {
                                await guard(context, () => ref.read(backendProvider).bookings.voidPayment(p.id, reason), success: 'Record voided');
                              }
                            },
                            child: const Text('Void'),
                          )
                        : p.confirmedAt != null
                    ? const Icon(LucideIcons.circleCheck, size: 18, color: EvColors.success)
                    : p.recordedByBusinessId != me
                        ? EvButton('Confirm', compact: true, kind: EvButtonKind.secondary,
                            onPressed: () => guard(context, () => ref.read(backendProvider).bookings.confirmPayment(p.id), success: 'Payment confirmed'))
                        : Text('Awaiting', style: EvType.caption),
              ),
            ],
          ]),
        ),
      ),

      SectionHeader('Planning'),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: EvSpace.gutter),
        child: EvSurface(
          padding: EdgeInsets.zero,
          child: Column(children: [
            EvRow(
              leading: const IconTile(LucideIcons.calendarPlus, tone: Tone.positive),
              title: b.eventId != null && !supplier ? 'Open linked event' : 'Plan this job in My Work',
              subtitle: 'Tasks and reminders for preparation, setup and returns',
              onTap: () async {
                if (b.eventId != null && !supplier) {
                  context.push('/work/event/${b.eventId}');
                  return;
                }
                final id = await guard(context, () => ref.read(backendProvider).work.createEventFromBooking(b.id, me));
                if (id != null && context.mounted) context.push('/work/event/$id');
              },
            ),
            if (b.status != BookingStatus.disputed && b.status != BookingStatus.cancelled) ...[
              const EvDivider(indent: 68),
              EvRow(
                leading: const IconTile(LucideIcons.flag, tone: Tone.critical),
                title: 'Report a problem',
                subtitle: 'Opens a dispute reviewed by Evenda support',
                onTap: () => _dispute(b, me),
              ),
            ],
          ]),
        ),
      ),

      SectionHeader('History'),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: EvSpace.gutter),
        child: Column(children: [
          for (final (i, h) in b.history.reversed.indexed)
            _TimelineRow(
              title: h.to.label,
              subtitle: '${EvDates.dayTime(h.at)}${h.note != null && h.note!.isNotEmpty ? ' · ${h.note}' : ''}',
              tone: toneForBooking(h.to),
              last: i == b.history.length - 1,
            ),
        ]),
      ),
    ]);
  }
}

/// Horizontal status stepper. The active dot and connector animate forward
/// when the status advances.
class _Stepper extends StatelessWidget {
  const _Stepper({required this.status});
  final BookingStatus status;

  @override
  Widget build(BuildContext context) {
    const steps = [
      (BookingStatus.confirmed, 'Confirmed'),
      (BookingStatus.preparing, 'Preparing'),
      (BookingStatus.dispatched, 'Out'),
      (BookingStatus.returned, 'Returned'),
      (BookingStatus.completed, 'Done'),
    ];
    final idx = switch (status) {
      BookingStatus.inProgress => 2,
      _ => steps.indexWhere((s) => s.$1 == status),
    };
    return Row(children: [
      for (var i = 0; i < steps.length; i++) ...[
        Column(children: [
          AnimatedContainer(
            duration: EvMotion.of(context, EvMotion.slow),
            curve: EvMotion.spring,
            width: i == idx ? 22 : 16,
            height: i == idx ? 22 : 16,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: i <= idx ? EvColors.forest : EvColors.warmWhite,
              border: Border.all(color: i <= idx ? EvColors.forest : EvColors.sandDeep, width: 2),
            ),
            child: i < idx ? const Icon(LucideIcons.check, size: 10, color: EvColors.inkOnDark) : null,
          ),
          const SizedBox(height: 6),
          Text(steps[i].$2, style: EvType.caption.copyWith(color: i <= idx ? EvColors.forest : EvColors.ink3, fontWeight: i == idx ? FontWeight.w700 : FontWeight.w500)),
        ]),
        if (i < steps.length - 1)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 20),
              child: Stack(children: [
                Container(height: 2, color: EvColors.sand),
                AnimatedFractionallySizedBox(
                  duration: EvMotion.of(context, EvMotion.slow),
                  curve: EvMotion.standard,
                  widthFactor: i < idx ? 1 : 0,
                  child: Container(height: 2, color: EvColors.forest),
                ),
              ]),
            ),
          ),
      ],
    ]);
  }
}

class _TimelineRow extends StatelessWidget {
  const _TimelineRow({required this.title, required this.subtitle, required this.tone, required this.last});
  final String title;
  final String subtitle;
  final Tone tone;
  final bool last;

  @override
  Widget build(BuildContext context) => IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(
            width: 20,
            child: Column(children: [
              const SizedBox(height: 4),
              Container(width: 10, height: 10, decoration: BoxDecoration(color: tone.fg, shape: BoxShape.circle)),
              if (!last) Expanded(child: Container(width: 1.5, color: EvColors.sand)),
            ]),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: EvType.bodyStrong),
                Text(subtitle, style: EvType.small),
              ]),
            ),
          ),
        ]),
      );
}
