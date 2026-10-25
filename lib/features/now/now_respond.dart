import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../app/providers.dart';
import '../../core/format.dart';
import '../../data/backend.dart';
import '../../design/ev.dart';
import '../../domain/models.dart';
import '../shared/map_widgets.dart';

final _inboxItemProvider = FutureProvider.autoDispose.family<NowInboxItem, String>((ref, id) async {
  ref.watchDomains(const [DataDomain.now, DataDomain.listings]);
  return ref.watch(backendProvider).now.inboxItem(id, ref.watch(bizIdProvider));
});

/// Supplier side of Evenda Now: see the request, check what you have free on
/// that date (live from your calendar), and offer some or all of it.
class NowRespondScreen extends ConsumerStatefulWidget {
  const NowRespondScreen({super.key, required this.id});
  final String id;
  @override
  ConsumerState<NowRespondScreen> createState() => _NowRespondScreenState();
}

class _NowRespondScreenState extends ConsumerState<NowRespondScreen> {
  int? _qty;
  final _price = TextEditingController();
  final _note = TextEditingController();
  bool _deliver = false;
  bool _busy = false;
  bool _seeded = false;

  void _seed(NowInboxItem it) {
    if (_seeded) return;
    _seeded = true;
    final o = it.myOffer;
    _qty = o?.quantity ?? (it.availableQuantity >= it.request.quantity ? it.request.quantity : it.availableQuantity);
    _price.text = (o?.unitPrice ?? it.matchedListing?.priceAmount ?? 0).toStringAsFixed(0);
    _note.text = o?.note ?? '';
    _deliver = o?.canDeliver ?? it.request.fulfilment != Fulfilment.pickup;
  }

  Future<void> _submit(NowInboxItem it) async {
    final price = double.tryParse(_price.text);
    if (price == null) {
      showToast(context, 'Enter your price per item.', icon: LucideIcons.circleAlert);
      return;
    }
    setState(() => _busy = true);
    final ok = await guard(context, () async {
      await ref.read(backendProvider).now.submitOffer(NowOfferDraft(
            requestId: it.request.id,
            supplierId: ref.read(bizIdProvider),
            listingId: it.matchedListing!.id,
            quantity: _qty!,
            unitPrice: price,
            canDeliver: _deliver,
            note: _note.text.trim(),
          ));
      return true;
    }, success: it.myOffer == null ? 'Offer sent to ${it.request.requester.name}' : 'Offer updated');
    if (mounted) setState(() => _busy = false);
    if (ok == true) HapticFeedback.mediumImpact();
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(_inboxItemProvider(widget.id));
    return Scaffold(
      appBar: AppBar(title: Row(children: [
        Icon(LucideIcons.zap, size: 18, color: EvColors.bronze),
        const SizedBox(width: 6),
        Text('Urgent request', style: EvType.title),
      ])),
      body: AsyncView(
        value: data,
        onRetry: () => ref.invalidate(_inboxItemProvider(widget.id)),
        data: (it) {
          _seed(it);
          final r = it.request;
          final l = it.matchedListing;
          final open = r.status.live && r.expiresAt.isAfter(DateTime.now());
          final mine = it.myOffer;
          final total = (_qty ?? 0) * (double.tryParse(_price.text) ?? 0);
          return ListView(padding: const EdgeInsets.fromLTRB(EvSpace.gutter, 0, EvSpace.gutter, 140), children: [
            Row(children: [
              BusinessAvatar(name: r.requester.name, logoUrl: r.requester.logoUrl, verified: r.requester.verified, size: 44),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(r.requester.name, style: EvType.headline),
                  Text('${it.distanceKm} km from you · asked ${EvDates.ago(r.createdAt)}', style: EvType.small),
                ]),
              ),
              StatusPill(r.status.label, tone: toneForNow(r.status), dense: true),
            ]),
            const SizedBox(height: EvSpace.x4),
            Text('${r.quantity} × ${r.itemDescription}', style: EvType.display),
            const SizedBox(height: EvSpace.x3),
            Wrap(spacing: 8, runSpacing: 6, children: [
              StatusPill('${EvDates.relativeDay(r.neededFrom)}${r.neededByTime != null ? ' by ${r.neededByTime}' : ''}', tone: Tone.waiting, icon: LucideIcons.clock),
              StatusPill(r.fulfilment == Fulfilment.pickup ? 'They collect' : 'Delivery wanted', icon: LucideIcons.truck),
              if (r.maxBudget != null) StatusPill('Budget ${Money.k(r.maxBudget)}', icon: LucideIcons.wallet),
            ]),
            if (r.notes.isNotEmpty) ...[
              const SizedBox(height: EvSpace.x3),
              Text('“${r.notes}”', style: EvType.body.copyWith(fontStyle: FontStyle.italic, color: EvColors.ink2)),
            ],
            const SizedBox(height: EvSpace.x4),
            ClipRRect(
              borderRadius: EvRadius.mdAll,
              child: SizedBox(
                height: 150,
                child: FlutterMap(
                  options: MapOptions(initialCenter: r.location, initialZoom: 13.5, interactionOptions: const InteractionOptions(flags: InteractiveFlag.none)),
                  children: [
                    ...evTileLayers(),
                    MarkerLayer(markers: [
                      Marker(point: r.location, width: 36, height: 36, child: Icon(LucideIcons.mapPin, color: EvColors.forest, size: 34, fill: 1)),
                    ]),
                    evAttribution(),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(r.locationLabel, style: EvType.caption),

            const SectionHeader('Your stock', padding: EdgeInsets.fromLTRB(0, EvSpace.x6, 0, EvSpace.x2)),
            if (l == null)
              Text('The matching listing is no longer available.', style: EvType.small)
            else
              EvSurface(
                padding: const EdgeInsets.all(EvSpace.x3),
                child: Row(children: [
                  EvPhoto(l.coverPhoto, width: 56, height: 56, radius: EvRadius.sm),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(l.title, style: EvType.bodyStrong),
                      Text(l.priceAmount != null ? 'Listed at ${Money.k(l.priceAmount)} ${l.priceUnit.short}' : 'Price on quotation', style: EvType.caption),
                    ]),
                  ),
                  Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    EvAnimatedCount(value: it.availableQuantity >= 999 ? 0 : it.availableQuantity, style: EvType.number.copyWith(color: it.availableQuantity > 0 ? EvColors.forest : EvColors.danger),
                        format: (n) => it.availableQuantity >= 999 ? '✓' : '$n'),
                    Text('free that day', style: EvType.caption),
                  ]),
                ]),
              ),

            if (mine != null && mine.status != NowOfferStatus.pending) ...[
              const SizedBox(height: EvSpace.x5),
              EvSurface(
                color: mine.status == NowOfferStatus.selected ? EvColors.successTint : EvColors.neutralTint,
                child: Row(children: [
                  Icon(mine.status == NowOfferStatus.selected ? LucideIcons.circleCheck : LucideIcons.info, color: mine.status == NowOfferStatus.selected ? EvColors.success : EvColors.ink2),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      mine.status == NowOfferStatus.selected
                          ? 'You were selected for ${mine.quantity}. The booking is confirmed and the stock is reserved.'
                          : 'Your offer was ${mine.status.label.toLowerCase()}.',
                      style: EvType.bodyStrong,
                    ),
                  ),
                  if (mine.bookingId != null) TextButton(onPressed: () => context.push('/bookings/${mine.bookingId}'), child: const Text('Booking')),
                ]),
              ),
            ] else if (!open) ...[
              const SizedBox(height: EvSpace.x5),
              Text('This request is ${r.status.label.toLowerCase()}. No more offers can be sent.', style: EvType.small),
            ] else if (it.declined) ...[
              const SizedBox(height: EvSpace.x5),
              Text('You declined this request.', style: EvType.small),
            ] else if (l != null && it.availableQuantity > 0) ...[
              SectionHeader(mine == null ? 'Your offer' : 'Your offer (you can update it)', padding: const EdgeInsets.fromLTRB(0, EvSpace.x6, 0, EvSpace.x2)),
              EvQuantityStepper(
                label: 'Quantity you can supply',
                value: _qty ?? 1,
                min: 1,
                max: it.availableQuantity >= 999 ? r.quantity : it.availableQuantity,
                step: (_qty ?? 1) >= 20 ? 10 : 1,
                helper: it.availableQuantity < r.quantity ? 'You can cover part of it; the requester can combine offers.' : null,
                onChanged: (v) => setState(() => _qty = v),
              ),
              const SizedBox(height: EvSpace.x4),
              EvField(
                label: 'Price per item',
                controller: _price,
                prefixText: 'K ',
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                onChanged: (_) => setState(() {}),
              ),
              if (r.fulfilment != Fulfilment.pickup) EvSwitchRow(title: 'I can deliver', subtitle: 'Agree the delivery details directly; Evenda records them on the booking.', value: _deliver, onChanged: (v) => setState(() => _deliver = v)),
              const SizedBox(height: EvSpace.x3),
              EvField(label: 'Note', controller: _note, hint: 'e.g. Ready for collection from 07:00', optional: true),
              const SizedBox(height: EvSpace.x4),
              Row(children: [
                Text('Offer total', style: EvType.small),
                const Spacer(),
                EvAnimatedCount(value: total.round(), format: (n) => Money.k(n), style: EvType.title.copyWith(color: r.maxBudget != null && total > r.maxBudget! ? EvColors.warning : EvColors.forest)),
              ]),
            ] else ...[
              const SizedBox(height: EvSpace.x5),
              Text('You have none free on that date, so you can’t offer. Thanks for checking.', style: EvType.small),
            ],
          ]);
        },
      ),
      bottomSheet: data.hasValue && data.value!.request.status.live && !data.value!.declined && data.value!.matchedListing != null && data.value!.availableQuantity > 0 &&
              (data.value!.myOffer == null || data.value!.myOffer!.status == NowOfferStatus.pending)
          ? Container(
              color: EvColors.warmWhite,
              padding: EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x3, EvSpace.gutter, EvSpace.x3 + MediaQuery.paddingOf(context).bottom),
              child: Row(children: [
                EvButton('Can’t help', kind: EvButtonKind.quiet, onPressed: () async {
                  await guard(context, () => ref.read(backendProvider).now.decline(widget.id, ref.read(bizIdProvider)), success: 'Declined');
                }),
                const SizedBox(width: 8),
                Expanded(child: EvButton(data.value!.myOffer == null ? 'Send offer' : 'Update offer', icon: LucideIcons.send, expand: true, loading: _busy, onPressed: () => _submit(data.value!))),
              ]),
            )
          : null,
    );
  }
}
