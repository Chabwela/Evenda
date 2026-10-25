import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../../app/providers.dart';
import '../../core/errors.dart';
import '../../core/format.dart';
import '../../data/backend.dart';
import '../../design/ev.dart';
import '../../domain/models.dart';
import 'quotation_pdf.dart';

final requestProvider = FutureProvider.autoDispose.family<QuoteRequest, String>((ref, id) async {
  ref.watchDomains(const [DataDomain.bookings]);
  return ref.watch(backendProvider).bookings.request(id);
});

class RequestDetailScreen extends ConsumerStatefulWidget {
  const RequestDetailScreen({super.key, required this.id});
  final String id;

  @override
  ConsumerState<RequestDetailScreen> createState() => _RequestDetailScreenState();
}

class _RequestDetailScreenState extends ConsumerState<RequestDetailScreen> {
  // One key per quotation acceptance attempt: retries reuse it.
  final _acceptKeys = <String, String>{};
  final _msg = TextEditingController();
  bool _sending = false;
  bool _accepting = false;

  @override
  void dispose() {
    _msg.dispose();
    super.dispose();
  }

  Future<void> _sendMessage(String me) async {
    if (_msg.text.trim().isEmpty) return;
    setState(() => _sending = true);
    await guard(context, () => ref.read(backendProvider).bookings.postMessage(widget.id, me, _msg.text.trim()));
    if (mounted) {
      _msg.clear();
      setState(() => _sending = false);
    }
  }

  Future<void> _accept(QuoteRequest q, Quotation qt) async {
    final ok = await showEvSheet<bool>(
      context,
      title: 'Accept quotation v${qt.version}?',
      subtitle: 'Creates a confirmed booking with ${q.supplier.name} and reserves the stock for ${EvDates.range(q.neededFrom, q.neededTo)}.',
      builder: (c) => Padding(
        padding: const EdgeInsets.fromLTRB(EvSpace.gutter, 0, EvSpace.gutter, EvSpace.x6),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final i in qt.items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                Expanded(child: Text('${i.quantity} × ${i.description}', style: EvType.body)),
                Text(Money.k(i.lineTotal), style: EvType.money),
              ]),
            ),
          for (final ch in qt.charges)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [Expanded(child: Text(ch.label, style: EvType.small)), Text(Money.k(ch.amount), style: EvType.money)]),
            ),
          const Divider(height: 24),
          Row(children: [Expanded(child: Text('Total', style: EvType.headline)), Text(Money.k(qt.total), style: EvType.title.copyWith(color: EvColors.forest))]),
          if (qt.depositAmount > 0) Padding(padding: const EdgeInsets.only(top: 4), child: Text('Deposit ${Money.k(qt.depositAmount)}${qt.depositTerms != null ? ' · ${qt.depositTerms}' : ''}', style: EvType.small)),
          const SizedBox(height: EvSpace.x3),
          Text('Payment is arranged between you and the supplier. Evenda records payments but does not hold money.', style: EvType.caption),
          const SizedBox(height: EvSpace.x5),
          EvButton('Accept and book', expand: true, onPressed: () => Navigator.pop(c, true)),
        ]),
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _accepting = true);
    final key = _acceptKeys.putIfAbsent(qt.id, () => const Uuid().v4());
    try {
      final bookingId = await ref.read(backendProvider).bookings.acceptQuotation(qt.id, key);
      if (!mounted) return;
      await _celebrate(q.supplier.name);
      if (mounted) context.pushReplacement('/bookings/$bookingId');
    } catch (e) {
      if (!mounted) return;
      final err = EvError.from(e);
      if (err.code == 'insufficient_availability') {
        await showDialog<void>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Stock changed'),
            content: Text('${err.userMessage}\n\nNothing was booked. Message the supplier for a revised quotation, or look for the shortfall elsewhere.'),
            actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))],
          ),
        );
      } else {
        showError(context, e);
      }
    } finally {
      if (mounted) setState(() => _accepting = false);
    }
  }

  Future<void> _celebrate(String supplier) => showDialog<void>(
        context: context,
        builder: (c) => Dialog(
          child: Padding(
            padding: const EdgeInsets.all(EvSpace.x6),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Celebration(size: 110),
              Text('Booked', style: EvType.displaySm),
              const SizedBox(height: 6),
              Text('$supplier has been notified and the stock is reserved for you.', style: EvType.small, textAlign: TextAlign.center),
              const SizedBox(height: EvSpace.x5),
              EvButton('View booking', expand: true, onPressed: () => Navigator.pop(c)),
            ]),
          ),
        ),
      );

  Future<void> _decline(QuoteRequest q, bool asSupplier, String me) async {
    final reason = await confirmWithReason(
      context,
      title: asSupplier ? 'Decline this request?' : 'Cancel your request?',
      body: asSupplier ? '${q.requester.name} will be told you can’t supply this.' : '${q.supplier.name} will be told you no longer need a quotation.',
      confirm: asSupplier ? 'Decline' : 'Cancel request',
      required: false,
      destructive: true,
    );
    if (reason == null || !mounted) return;
    await guard(context, () => ref.read(backendProvider).bookings.declineRequest(q.id, me, reason: reason.isEmpty ? null : reason));
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(requestProvider(widget.id));
    final me = ref.watch(bizIdProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Quotation request')),
      body: AsyncView(
        value: data,
        onRetry: () => ref.invalidate(requestProvider(widget.id)),
        data: (q) {
          final asSupplier = q.supplier.id == me;
          final other = asSupplier ? q.requester : q.supplier;
          final timeline = <(DateTime, Widget)>[
            for (final m in q.messages) (m.createdAt, _MessageBubble(message: m, mine: m.senderBusinessId == me, author: m.senderBusinessId == q.supplier.id ? q.supplier.name : q.requester.name)),
            for (final qt in q.quotations)
              (qt.createdAt, _QuotationCard(request: q, quotation: qt, asSupplier: asSupplier, accepting: _accepting, onAccept: () => _accept(q, qt))),
          ]..sort((a, b) => a.$1.compareTo(b.$1));

          return Column(children: [
            Expanded(
              child: ListView(padding: const EdgeInsets.fromLTRB(EvSpace.gutter, 0, EvSpace.gutter, EvSpace.x6), children: [
                Row(children: [
                  BusinessAvatar(name: other.name, logoUrl: other.logoUrl, verified: other.verified, size: 44),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(other.name, style: EvType.headline),
                      Text(asSupplier ? 'Asked you for a quotation' : 'Supplier you asked', style: EvType.small),
                      // Under the name, so long names keep the full width.
                      const SizedBox(height: 6),
                      StatusPill(q.status.label, tone: toneForRequest(q.status), dense: true),
                    ]),
                  ),
                ]),
                const SizedBox(height: EvSpace.x4),
                _RequestCard(request: q),
                const SizedBox(height: EvSpace.x4),
                for (final (_, w) in timeline) Padding(padding: const EdgeInsets.only(bottom: EvSpace.x3), child: EvArrive(child: w)),
                if (q.status == QuoteRequestStatus.accepted && q.bookingId != null)
                  EvSurface(
                    color: EvColors.successTint,
                    onTap: () => context.push('/bookings/${q.bookingId}'),
                    child: Row(children: [
                      Icon(LucideIcons.circleCheck, color: EvColors.success),
                      const SizedBox(width: 10),
                      Expanded(child: Text('Booked. Open the booking to track preparation and payment.', style: EvType.bodyStrong.copyWith(color: EvColors.success))),
                      Icon(LucideIcons.chevronRight, color: EvColors.success),
                    ]),
                  ),
              ]),
            ),
            if (q.status.isOpen) _ActionBar(
              request: q,
              asSupplier: asSupplier,
              controller: _msg,
              sending: _sending,
              onSend: () => _sendMessage(me),
              onQuote: () => context.push('/bookings/request/${q.id}/quote'),
              onDecline: () => _decline(q, asSupplier, me),
              otherWhatsapp: other.whatsapp,
            ),
          ]);
        },
      ),
    );
  }
}

class _RequestCard extends StatelessWidget {
  const _RequestCard({required this.request});
  final QuoteRequest request;

  @override
  Widget build(BuildContext context) {
    final q = request;
    return EvSurface(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('Request', style: EvType.smallStrong.copyWith(color: EvColors.ink2)),
          const Spacer(),
          Text(EvDates.ago(q.createdAt), style: EvType.caption),
        ]),
        const SizedBox(height: 8),
        for (final i in q.items)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(children: [
              SizedBox(width: 56, child: Text('${i.quantity} ×', style: EvType.money)),
              Expanded(child: Text(i.description, style: EvType.body)),
            ]),
          ),
        const Divider(height: 22),
        KeyValue('Dates', '${EvDates.range(q.neededFrom, q.neededTo)} (${plural(q.days, 'day')})'),
        KeyValue('Arrangement', q.fulfilment.label),
        if (q.venue != null) KeyValue('Venue', q.venue!),
        if (q.message.isNotEmpty) ...[
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: EvColors.cream, borderRadius: EvRadius.smAll),
            child: Text('“${q.message}”', style: EvType.body.copyWith(fontStyle: FontStyle.italic, color: EvColors.ink2)),
          ),
        ],
      ]),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message, required this.mine, required this.author});
  final QuoteMessage message;
  final bool mine;
  final String author;

  @override
  Widget build(BuildContext context) => Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.78),
          child: Column(crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start, children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: mine ? EvColors.forest : EvColors.warmWhite,
                border: mine ? null : Border.all(color: EvColors.sand),
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(14),
                  topRight: const Radius.circular(14),
                  bottomLeft: Radius.circular(mine ? 14 : 4),
                  bottomRight: Radius.circular(mine ? 4 : 14),
                ),
              ),
              child: Text(message.body, style: EvType.body.copyWith(color: mine ? EvColors.inkOnDark : EvColors.ink)),
            ),
            const SizedBox(height: 3),
            Text('${mine ? 'You' : author} · ${EvDates.ago(message.createdAt)}', style: EvType.caption),
          ]),
        ),
      );
}

class _QuotationCard extends ConsumerWidget {
  const _QuotationCard({required this.request, required this.quotation, required this.asSupplier, required this.onAccept, required this.accepting});
  final QuoteRequest request;
  final Quotation quotation;
  final bool asSupplier;
  final VoidCallback onAccept;
  final bool accepting;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final qt = quotation;
    final open = qt.status == QuotationStatus.sent;
    final faded = qt.status == QuotationStatus.superseded;
    final tone = switch (qt.status) {
      QuotationStatus.sent => Tone.progress,
      QuotationStatus.accepted => Tone.positive,
      _ => Tone.neutral,
    };
    return Opacity(
      opacity: faded ? 0.6 : 1,
      child: Container(
        decoration: BoxDecoration(
          color: EvColors.warmWhite,
          borderRadius: EvRadius.mdAll,
          border: Border.all(color: open ? EvColors.forest : EvColors.sand, width: open ? 1.4 : 1),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(EvSpace.x4, EvSpace.x4, EvSpace.x2, EvSpace.x2),
            child: Row(children: [
              Icon(LucideIcons.fileText, size: 18, color: EvColors.forest),
              const SizedBox(width: 8),
              Text('Quotation v${qt.version}', style: EvType.headline),
              const SizedBox(width: 8),
              StatusPill(qt.status.label, tone: tone, dense: true),
              const Spacer(),
              PopupMenuButton<String>(
                icon: const Icon(LucideIcons.share2, size: 18),
                tooltip: 'Share',
                onSelected: (v) async {
                  if (v == 'pdf') await guard(context, () => shareQuotationPdf(request, qt));
                  if (v == 'wa') {
                    final to = asSupplier ? request.requester.whatsapp : request.supplier.whatsapp;
                    final text = quotationSummaryText(request, qt);
                    await launchUrl(Uri.parse('https://wa.me/${to == null ? '' : ZambianPhone.waDigits(to)}?text=${Uri.encodeComponent(text)}'),
                        mode: LaunchMode.externalApplication);
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'pdf', child: Text('Share as PDF')),
                  PopupMenuItem(value: 'wa', child: Text('Send summary on WhatsApp')),
                ],
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: EvSpace.x4),
            child: Column(children: [
              for (final i in qt.items)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(i.description, style: EvType.body),
                        Text('${i.quantity} × ${Money.k(i.unitPrice)}${i.days > 1 ? ' × ${i.days} days' : ''}', style: EvType.caption),
                      ]),
                    ),
                    Text(Money.k(i.lineTotal), style: EvType.money),
                  ]),
                ),
              for (final c in qt.charges)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(children: [Expanded(child: Text(c.label, style: EvType.small)), Text(Money.k(c.amount), style: EvType.money.copyWith(color: EvColors.ink2))]),
                ),
              const Divider(height: 20),
              Row(children: [
                Expanded(child: Text('Total', style: EvType.bodyStrong)),
                EvAnimatedCount(value: qt.total.round(), format: (n) => Money.k(n), style: EvType.title.copyWith(color: EvColors.forest)),
              ]),
              const SizedBox(height: 8),
              if (qt.depositAmount > 0) KeyValue('Deposit', '${Money.k(qt.depositAmount)}${qt.depositTerms != null ? ' · ${qt.depositTerms}' : ''}'),
              if (qt.paymentTerms.isNotEmpty) KeyValue('Payment', qt.paymentTerms),
              KeyValue('Valid until', EvDates.day(qt.validUntil)),
              if (qt.conditions.isNotEmpty) KeyValue('Conditions', qt.conditions),
            ]),
          ),
          if (open && !asSupplier)
            Padding(
              padding: const EdgeInsets.all(EvSpace.x4),
              child: EvButton('Accept quotation', expand: true, icon: LucideIcons.circleCheck, loading: accepting, onPressed: onAccept),
            )
          else
            const SizedBox(height: EvSpace.x3),
        ]),
      ),
    );
  }
}

class _ActionBar extends StatelessWidget {
  const _ActionBar({
    required this.request,
    required this.asSupplier,
    required this.controller,
    required this.sending,
    required this.onSend,
    required this.onQuote,
    required this.onDecline,
    this.otherWhatsapp,
  });
  final QuoteRequest request;
  final bool asSupplier;
  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;
  final VoidCallback onQuote;
  final VoidCallback onDecline;
  final String? otherWhatsapp;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(color: EvColors.warmWhite, border: Border(top: BorderSide(color: EvColors.sand))),
      padding: EdgeInsets.fromLTRB(EvSpace.x3, EvSpace.x2, EvSpace.x3, EvSpace.x2 + MediaQuery.paddingOf(context).bottom),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (asSupplier)
          Padding(
            padding: const EdgeInsets.only(bottom: EvSpace.x2),
            child: Row(children: [
              Expanded(
                child: EvButton(request.quotations.isEmpty ? 'Send quotation' : 'Revise quotation',
                    icon: LucideIcons.fileText, expand: true, onPressed: onQuote),
              ),
              const SizedBox(width: 8),
              EvButton('Decline', kind: EvButtonKind.quiet, onPressed: onDecline),
            ]),
          ),
        Row(children: [
          Expanded(
            child: TextField(
              controller: controller,
              minLines: 1,
              maxLines: 4,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                hintText: asSupplier ? 'Ask a question…' : 'Message the supplier…',
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              ),
            ),
          ),
          const SizedBox(width: 6),
          EvIconButton(LucideIcons.send, tooltip: 'Send', color: EvColors.forest, onPressed: sending ? null : onSend),
          if (!asSupplier) PopupMenuButton<String>(
            icon: const Icon(LucideIcons.ellipsisVertical),
            onSelected: (_) => onDecline(),
            itemBuilder: (_) => const [PopupMenuItem(value: 'cancel', child: Text('Cancel request'))],
          ),
        ]),
      ]),
    );
  }
}
