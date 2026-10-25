import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/providers.dart';
import '../../core/errors.dart';
import '../../core/format.dart';
import '../../data/backend.dart';
import '../../design/ev.dart';
import '../../domain/models.dart';

typedef DisputeCase = ({Dispute dispute, Booking booking, List<AuditEntry> history});

final disputeCaseProvider = FutureProvider.autoDispose.family<DisputeCase, String>((ref, id) async {
  ref.watchDomains(const [DataDomain.admin, DataDomain.bookings]);
  final backend = ref.watch(backendProvider);
  final dispute = (await backend.admin.disputes()).firstWhere((d) => d.id == id, orElse: () => throw const EvError('not_found'));
  final results = await Future.wait([
    backend.bookings.booking(dispute.bookingId),
    backend.admin.auditLog().then((l) => l.where((a) => a.targetTable == 'disputes' && a.targetId == id).toList()).catchError((_) => <AuditEntry>[]),
  ]);
  return (dispute: dispute, booking: results[0] as Booking, history: results[1] as List<AuditEntry>);
});

/// One dispute as a case file: the complaint, both sides, what was booked and
/// paid, what happened, and a ruling with real consequences for the booking.
class AdminDisputeCaseScreen extends ConsumerWidget {
  const AdminDisputeCaseScreen({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ref.watch(disputeCaseProvider(id));
    final role = ref.watch(adminSessionProvider).value?.role ?? ref.read(backendProvider).admin.current?.role;
    final canRule = role?.can('dispute.manage') ?? false;
    final v = c.value;
    return Scaffold(
      appBar: AppBar(title: Text(v == null ? 'Dispute' : 'Dispute · ${v.booking.reference}'), centerTitle: false),
      body: AsyncView<DisputeCase>(
        value: c,
        onRetry: () => ref.invalidate(disputeCaseProvider(id)),
        data: (v) => _Case(c: v, showPayments: role?.can('payment.read') ?? false),
      ),
      bottomNavigationBar: v == null || !canRule || !v.dispute.isOpen ? null : _RulingBar(c: v),
    );
  }
}

class _Case extends StatelessWidget {
  const _Case({required this.c, required this.showPayments});
  final DisputeCase c;
  final bool showPayments;

  @override
  Widget build(BuildContext context) {
    final d = c.dispute;
    final b = c.booking;
    final complainantIsSupplier = d.openedByBusinessId == b.supplier.id;
    final days = DateTime.now().difference(d.createdAt).inDays;
    final ruling = c.history.where((h) => h.action == 'dispute.rule' || h.action == 'dispute.update').firstOrNull;
    final outcome = ruling?.after?['outcome'] as String?;
    const section = EdgeInsets.fromLTRB(0, EvSpace.x6, 0, EvSpace.x2);

    final (stageTitle, stageDetail, stageColor) = switch (d.status) {
      'open' => (
          'Waiting for your ruling',
          'Opened ${days == 0 ? 'today' : '${plural(days, 'day')} ago'}. The booking is on hold until Evenda rules.',
          days >= 2 ? EvColors.danger : EvColors.warning
        ),
      'investigating' => ('Investigating', 'Evenda has taken the case and both businesses were told. Rule when you have heard both sides.', EvColors.info),
      'resolved' => ('Complaint upheld', 'Ruled ${EvDates.day(d.updatedAt ?? d.createdAt)}.', EvColors.success),
      _ => ('Complaint not upheld', 'Ruled ${EvDates.day(d.updatedAt ?? d.createdAt)}.', EvColors.ink2),
    };

    return ListView(padding: const EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x2, EvSpace.gutter, EvSpace.x10), children: [
      // Where the case stands.
      Container(
        padding: const EdgeInsets.only(left: EvSpace.x3),
        decoration: BoxDecoration(border: Border(left: BorderSide(color: stageColor, width: 3))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(stageTitle, style: EvType.title.copyWith(color: stageColor)),
          const SizedBox(height: 2),
          Text(stageDetail, style: EvType.small),
        ]),
      ),

      // The ruling, when there is one: what was decided is the headline.
      if (!d.isOpen && d.resolution != null) ...[
        const SectionHeader('Ruling', padding: section),
        Text(d.resolution!, style: EvType.body),
        if (outcome != null) ...[
          const SizedBox(height: 4),
          Text(switch (outcome) { 'cancel' => 'Booking cancelled', 'complete' => 'Booking marked completed', _ => 'Booking went ahead' },
              style: EvType.smallStrong),
        ],
      ],

      // The complaint, in the complainant's words.
      const SectionHeader('The complaint', padding: section),
      Container(
        padding: const EdgeInsets.fromLTRB(EvSpace.x4, EvSpace.x3, EvSpace.x4, EvSpace.x3),
        decoration: BoxDecoration(color: EvColors.warmWhite, borderRadius: EvRadius.mdAll, border: Border.all(color: EvColors.hairline)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('“${d.reason}”', style: EvType.body),
          const SizedBox(height: 8),
          Text('${d.openedBy ?? 'A business'} (${complainantIsSupplier ? 'supplier' : 'hirer'}) · ${EvDates.dayTime(d.createdAt)}', style: EvType.caption),
        ]),
      ),

      // Both sides, reachable in one tap.
      const SectionHeader('Both sides', padding: section),
      EvSurface(
        padding: EdgeInsets.zero,
        child: Column(children: [
          _Party(biz: b.supplier, role: 'Supplier', complainant: complainantIsSupplier, reference: b.reference),
          const EvDivider(indent: EvSpace.x4),
          _Party(biz: b.requester, role: 'Hirer', complainant: !complainantIsSupplier, reference: b.reference),
        ]),
      ),

      // What was agreed and what was paid.
      const SectionHeader('The booking', padding: section),
      EvSurface(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('${EvDates.range(b.startsOn, b.endsOn)} · ${b.fulfilment.label}', style: EvType.small),
          const SizedBox(height: 8),
          for (final i in b.items)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(children: [
                Expanded(child: Text('${i.quantity} × ${i.description}', style: EvType.body)),
                Text(Money.k(i.lineTotal), style: EvType.money),
              ]),
            ),
          const EvDivider(),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: Text('Total', style: EvType.bodyStrong)),
            Text(Money.k(b.total), style: EvType.money),
          ]),
          const SizedBox(height: 4),
          if (showPayments) ...[
            Row(children: [
              Expanded(child: Text('Confirmed paid', style: EvType.small)),
              Text(Money.k(b.confirmedPaid), style: EvType.small.copyWith(color: b.overpaid ? EvColors.danger : EvColors.ink)),
            ]),
            for (final p in b.payments)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '${Money.k(p.amount)} ${p.kind} · ${p.methodLabel} · ${p.voided ? 'voided${p.voidReason == null ? '' : ': ${p.voidReason}'}' : p.confirmedAt != null ? 'confirmed' : 'not confirmed'}',
                  style: EvType.caption.copyWith(decoration: p.voided ? TextDecoration.lineThrough : null),
                ),
              ),
          ] else
            Text('Payment records need the finance or super admin role.', style: EvType.caption),
        ]),
      ),

      SectionHeader('What happened', count: b.history.length, padding: section),
      for (final h in b.history.reversed)
        Padding(
          padding: const EdgeInsets.only(bottom: EvSpace.x2),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(width: 8, height: 8, margin: const EdgeInsets.only(top: 6, right: 10), decoration: BoxDecoration(color: toneForBooking(h.to).fg, shape: BoxShape.circle)),
            Expanded(
              child: Text.rich(TextSpan(children: [
                TextSpan(text: h.to.label, style: EvType.smallStrong),
                TextSpan(text: ' · ${EvDates.dayTime(h.at)}${h.note != null && h.note!.isNotEmpty ? ' · ${h.note}' : ''}', style: EvType.caption),
              ])),
            ),
          ]),
        ),

      if (c.history.isNotEmpty) ...[
        SectionHeader('Case history', count: c.history.length, padding: section),
        for (final h in c.history)
          Padding(
            padding: const EdgeInsets.only(bottom: EvSpace.x3),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(switch (h.action) {
                'dispute.take' => 'Case taken',
                'dispute.rule' || 'dispute.update' => switch (h.after?['status']) {
                    'resolved' => 'Ruled: upheld',
                    'dismissed' => 'Ruled: not upheld',
                    'investigating' => 'Case taken',
                    final s => 'Status: $s',
                  },
                final a => a,
              }, style: EvType.smallStrong),
              if (h.reason != null && h.reason!.isNotEmpty) Text('“${h.reason}”', style: EvType.small),
              Text('${h.actorRole?.label ?? 'Admin'} · ${EvDates.dayTime(h.createdAt)}', style: EvType.caption),
            ]),
          ),
      ],
    ]);
  }
}

class _Party extends StatelessWidget {
  const _Party({required this.biz, required this.role, required this.complainant, required this.reference});
  final BizRef biz;
  final String role;
  final bool complainant;
  final String reference;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(EvSpace.x4, 10, EvSpace.x2, 10),
        child: Row(children: [
          BusinessAvatar(name: biz.name, logoUrl: biz.logoUrl, size: 40, verified: biz.verified),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(biz.name, style: EvType.bodyStrong, maxLines: 1, overflow: TextOverflow.ellipsis),
              Text(complainant ? '$role · opened the dispute' : role, style: EvType.caption.copyWith(color: complainant ? EvColors.danger : EvColors.ink3)),
            ]),
          ),
          if (biz.phone != null) EvIconButton(LucideIcons.phone, tooltip: 'Call', onPressed: () => launchUrl(Uri.parse('tel:${biz.phone}'))),
          if (biz.whatsapp != null)
            EvIconButton(LucideIcons.messageCircle,
                tooltip: 'WhatsApp',
                onPressed: () => launchUrl(Uri.parse('https://wa.me/${ZambianPhone.waDigits(biz.whatsapp!)}?text=${Uri.encodeComponent('Hello from the Evenda team about the dispute on booking $reference.')}'),
                    mode: LaunchMode.externalApplication)),
          EvIconButton(LucideIcons.store, tooltip: 'Review business', onPressed: () => context.push('/admin/business/${biz.id}')),
        ]),
      );
}

/// Take the case, then rule. Pinned; only while the dispute is open.
class _RulingBar extends ConsumerWidget {
  const _RulingBar({required this.c});
  final DisputeCase c;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = c.dispute;
    Future<void> take() async {
      await guard(context, () => ref.read(backendProvider).admin.takeDispute(d.id), success: 'Case taken. Both businesses were told.');
      ref.invalidate(disputeCaseProvider(d.id));
    }

    return Container(
      decoration: BoxDecoration(color: EvColors.cream, border: Border(top: BorderSide(color: EvColors.hairline))),
      padding: EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x3, EvSpace.gutter, EvSpace.x3 + MediaQuery.paddingOf(context).bottom),
      child: Row(children: [
        if (d.status == 'open') ...[
          Expanded(child: EvButton('Take the case', kind: EvButtonKind.secondary, expand: true, onPressed: take)),
          const SizedBox(width: EvSpace.x2),
        ],
        Expanded(child: EvButton('Rule', icon: LucideIcons.gavel, expand: true, onPressed: () => showRulingSheet(context, ref, c))),
      ]),
    );
  }
}

/// The ruling: upheld or not, what happens to the booking, and the words both
/// businesses will read. Nothing is pre-selected: the admin decides each part.
Future<void> showRulingSheet(BuildContext context, WidgetRef ref, DisputeCase c) async {
  final d = c.dispute;
  final b = c.booking;
  final before = b.history.where((h) => h.to == BookingStatus.disputed && h.from != null).lastOrNull?.from ?? BookingStatus.confirmed;
  String? decision;
  String? outcome;
  final text = TextEditingController();
  var busy = false;

  await showEvSheet<void>(
    context,
    title: 'Rule on ${b.reference}',
    subtitle: 'Both businesses are notified and it is recorded in the audit log.',
    builder: (sheet) => StatefulBuilder(builder: (sheet, set) {
      final ready = decision != null && outcome != null && text.text.trim().length >= 10 && !busy;
      // Scrolls itself (the sheet caps its height and already pads for the keyboard).
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(EvSpace.gutter, 0, EvSpace.gutter, EvSpace.x6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          const EvFieldLabel('Decision'),
          Wrap(spacing: 8, runSpacing: 8, children: [
            EvChip(label: 'Uphold the complaint', selected: decision == 'resolved', onTap: () => set(() => decision = 'resolved')),
            EvChip(label: 'Don’t uphold it', selected: decision == 'dismissed', onTap: () => set(() => decision = 'dismissed')),
          ]),
          const SizedBox(height: EvSpace.x4),
          const EvFieldLabel('What happens to the booking'),
          EvOptionTile(
            title: 'Booking goes ahead',
            subtitle: 'Back to “${before.label}”, as before the dispute',
            selected: outcome == 'resume',
            onTap: () => set(() => outcome = 'resume'),
          ),
          const SizedBox(height: 6),
          EvOptionTile(title: 'Mark it completed', subtitle: 'The job is done; nothing more to deliver', selected: outcome == 'complete', onTap: () => set(() => outcome = 'complete')),
          const SizedBox(height: 6),
          EvOptionTile(
            title: 'Cancel the booking',
            subtitle: 'Releases the reserved stock and open tasks',
            selected: outcome == 'cancel',
            onTap: () => set(() => outcome = 'cancel'),
          ),
          const SizedBox(height: EvSpace.x4),
          EvField(
            label: 'Ruling',
            controller: text,
            maxLines: 4,
            minLines: 3,
            hint: 'What you found and what each business should do next. Both businesses read this.',
            onChanged: (_) => set(() {}),
          ),
          const SizedBox(height: EvSpace.x4),
          EvButton('Issue ruling', icon: LucideIcons.gavel, expand: true, loading: busy, onPressed: !ready
              ? null
              : () async {
                  set(() => busy = true);
                  final ok = await guard(sheet, () async {
                    await ref.read(backendProvider).admin.ruleDispute(d.id, decision: decision!, ruling: text.text.trim(), bookingOutcome: outcome!);
                    return true;
                  }, success: 'Ruling issued. Both businesses were notified.');
                  if (ok == true) {
                    ref.invalidate(disputeCaseProvider(d.id));
                    if (sheet.mounted) Navigator.pop(sheet);
                  } else {
                    set(() => busy = false);
                  }
                }),
        ]),
      );
    }),
  );
}
