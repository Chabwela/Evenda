import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../app/providers.dart';
import '../../core/format.dart';
import '../../data/backend.dart';
import '../../design/ev.dart';
import '../../domain/models.dart';

final _inventoryProvider = FutureProvider.autoDispose<(List<Listing>, List<Reservation>, List<InventoryConflict>)>((ref) async {
  ref.watchDomains(const [DataDomain.listings, DataDomain.bookings]);
  final id = ref.watch(bizIdProvider);
  final l = ref.watch(backendProvider).listings;
  final r = await Future.wait([l.mine(id), l.reservations(id), l.conflicts(id)]);
  return (
    (r[0] as List<Listing>).where((x) => x.tracksStock && !x.isService && x.status != ListingStatus.archived).toList(),
    r[1] as List<Reservation>,
    r[2] as List<InventoryConflict>,
  );
});

/// Physical stock: what's free today, booked, out on hire, back for
/// inspection and out of service. Every change goes through a stock RPC.
class InventoryScreen extends ConsumerWidget {
  const InventoryScreen({super.key, this.focusListingId});
  final String? focusListingId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(_inventoryProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Inventory')),
      body: AsyncView(
        value: data,
        onRetry: () => ref.invalidate(_inventoryProvider),
        isEmpty: (d) => d.$1.isEmpty,
        empty: EmptyState(
          mascot: Mascot.crate,
          title: 'No stock tracked',
          body: 'Create a rental listing with a quantity to track availability by date.',
          action: 'New rental listing',
          onAction: () => context.push('/business/listings/new?kind=rental'),
        ),
        data: (d) {
          final (listings, reservations, conflicts) = d;
          final sorted = [...listings]..sort((a, b) => a.id == focusListingId ? -1 : (b.id == focusListingId ? 1 : 0));
          return ListView(padding: const EdgeInsets.only(bottom: EvSpace.x10), children: [
            if (conflicts.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(EvSpace.gutter, 0, EvSpace.gutter, EvSpace.x3),
                child: EvSurface(
                  color: EvColors.warningTint,
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Icon(LucideIcons.triangleAlert, color: EvColors.warning, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('Over-committed', style: EvType.bodyStrong.copyWith(color: EvColors.warning)),
                        for (final c in conflicts.take(3))
                          Text('${c.title}: ${c.committed} booked, ${c.usable} usable on ${EvDates.day(c.day)}', style: EvType.small.copyWith(color: EvColors.warning)),
                        const SizedBox(height: 6),
                        Text('Repair damaged items, add stock, or source the shortfall with Evenda Now.', style: EvType.caption.copyWith(color: EvColors.warning)),
                      ]),
                    ),
                  ]),
                ),
              ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: EvSpace.gutter),
              child: Wrap(spacing: 14, runSpacing: 6, children: [
                _Key(EvColors.forest, 'Free today'),
                _Key(EvColors.bronze, 'Booked today'),
                _Key(EvColors.info, 'Out on hire'),
                _Key(EvColors.warning, 'Awaiting inspection'),
                _Key(EvColors.danger, 'Damaged'),
              ]),
            ),
            const SizedBox(height: EvSpace.x3),
            for (final l in sorted)
              Padding(
                padding: const EdgeInsets.fromLTRB(EvSpace.gutter, 0, EvSpace.gutter, EvSpace.x3),
                child: _StockCard(
                  listing: l,
                  reservations: reservations.where((r) => r.listingId == l.id).toList(),
                  conflicts: conflicts.where((c) => c.listingId == l.id).toList(),
                  highlighted: l.id == focusListingId,
                ),
              ),
          ]);
        },
      ),
    );
  }
}

class _Key extends StatelessWidget {
  const _Key(this.color, this.label);
  final Color color;
  final String label;
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 5),
        Text(label, style: EvType.caption),
      ]);
}

class _StockCard extends ConsumerWidget {
  const _StockCard({required this.listing, required this.reservations, required this.conflicts, this.highlighted = false});
  final Listing listing;
  final List<Reservation> reservations;
  final List<InventoryConflict> conflicts;
  final bool highlighted;

  Future<void> _adjust(BuildContext context, WidgetRef ref, bool add) async {
    var qty = add ? 10 : 1;
    var reason = add ? 'purchase' : 'loss';
    final ok = await showEvSheet<bool>(
      context,
      title: add ? 'Add stock' : 'Remove stock',
      subtitle: listing.title,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => Padding(
          padding: const EdgeInsets.fromLTRB(EvSpace.gutter, 0, EvSpace.gutter, EvSpace.x6),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            EvQuantityStepper(value: qty, min: 1, max: add ? null : listing.usable, step: qty >= 20 ? 10 : 1, onChanged: (v) => set(() => qty = v)),
            const SizedBox(height: EvSpace.x4),
            const EvFieldLabel('Reason'),
            Wrap(spacing: 8, children: [
              for (final (k, l) in add ? const [('purchase', 'Bought new'), ('correction', 'Count correction')] : const [('loss', 'Lost or stolen'), ('write_off', 'Written off'), ('correction', 'Count correction')])
                EvChip(label: l, selected: reason == k, onTap: () => set(() => reason = k)),
            ]),
            if (add && listing.status == ListingStatus.published) ...[
              const SizedBox(height: EvSpace.x3),
              Text(qty >= 20 || qty * 4 >= listing.totalQuantity
                  ? 'Vendors who follow you or this category will hear about the extra stock.'
                  : 'Small additions are not broadcast.', style: EvType.caption),
            ],
            const SizedBox(height: EvSpace.x5),
            EvButton(add ? 'Add $qty' : 'Remove $qty', expand: true, onPressed: () => Navigator.pop(c, true)),
          ]),
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    await guard(context, () => ref.read(backendProvider).listings.adjustStock(listing.id, add ? qty : -qty, reason),
        success: add ? 'Added $qty × ${listing.title}' : 'Removed $qty × ${listing.title}');
  }

  Future<void> _damage(BuildContext context, WidgetRef ref) async {
    var v = listing.damagedQuantity;
    final ok = await showEvSheet<bool>(
      context,
      title: 'Damaged / out of service',
      subtitle: 'These are excluded from availability until repaired.',
      builder: (c) => StatefulBuilder(
        builder: (c, set) => Padding(
          padding: const EdgeInsets.fromLTRB(EvSpace.gutter, 0, EvSpace.gutter, EvSpace.x6),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            EvQuantityStepper(value: v, min: 0, max: listing.totalQuantity - listing.inspectionQuantity, onChanged: (x) => set(() => v = x)),
            const SizedBox(height: EvSpace.x5),
            EvButton('Save', expand: true, onPressed: () => Navigator.pop(c, true)),
          ]),
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    await guard(context, () => ref.read(backendProvider).listings.setDamaged(listing.id, v),
        success: v < listing.damagedQuantity ? '${listing.damagedQuantity - v} back in service' : 'Damaged count updated');
  }

  Future<void> _inspect(BuildContext context, WidgetRef ref) async {
    var good = listing.inspectionQuantity;
    var bad = 0;
    final ok = await showEvSheet<bool>(
      context,
      title: 'Inspect returned items',
      subtitle: '${listing.inspectionQuantity} × ${listing.title} came back from jobs.',
      builder: (c) => StatefulBuilder(
        builder: (c, set) => Padding(
          padding: const EdgeInsets.fromLTRB(EvSpace.gutter, 0, EvSpace.gutter, EvSpace.x6),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            EvQuantityStepper(label: 'Good — back in service', value: good, min: 0, max: listing.inspectionQuantity - bad, onChanged: (x) => set(() => good = x)),
            const SizedBox(height: EvSpace.x4),
            EvQuantityStepper(label: 'Damaged', value: bad, min: 0, max: listing.inspectionQuantity - good, onChanged: (x) => set(() => bad = x)),
            const SizedBox(height: EvSpace.x5),
            EvButton('Complete inspection', expand: true, onPressed: good + bad == 0 ? null : () => Navigator.pop(c, true)),
          ]),
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    await guard(context, () => ref.read(backendProvider).listings.completeInspection(listing.id, good: good, damaged: bad), success: 'Inspection recorded');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = listing;
    final today = EvDates.today();
    final bookedToday = reservations.where((r) => r.covers(today) && (r.status == ReservationStatus.confirmed || r.status == ReservationStatus.held)).fold(0, (s, r) => s + r.quantity);
    final out = reservations.where((r) => r.status == ReservationStatus.dispatched).fold(0, (s, r) => s + r.quantity);
    final free = (l.usable - bookedToday - out).clamp(0, 1 << 30);
    final upcoming = reservations.where((r) => r.status.holdsStock).take(4).toList();

    return AnimatedContainer(
      duration: EvMotion.of(context, EvMotion.slow),
      decoration: BoxDecoration(
        color: EvColors.warmWhite,
        borderRadius: EvRadius.mdAll,
        border: Border.all(color: highlighted ? EvColors.warning : EvColors.sand, width: highlighted ? 1.6 : 1),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(EvSpace.x4, EvSpace.x4, EvSpace.x2, 0),
          child: Row(children: [
            EvPhoto(l.coverPhoto, width: 44, height: 44, radius: EvRadius.sm, icon: categoryIcon(l.categoryId)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(l.title, style: EvType.bodyStrong, maxLines: 1, overflow: TextOverflow.ellipsis),
                Row(children: [
                  EvAnimatedCount(value: l.totalQuantity, style: EvType.small, format: (n) => '$n owned'),
                  Text(' · ', style: EvType.small),
                  EvAnimatedCount(value: l.usable, style: EvType.small, format: (n) => '$n usable'),
                ]),
              ]),
            ),
            PopupMenuButton<String>(
              icon: const Icon(LucideIcons.ellipsisVertical, size: 18),
              onSelected: (v) {
                switch (v) {
                  case 'add':
                    _adjust(context, ref, true);
                  case 'remove':
                    _adjust(context, ref, false);
                  case 'damage':
                    _damage(context, ref);
                  case 'calendar':
                    context.push('/business/availability?listing=${l.id}');
                  case 'edit':
                    context.push('/business/listings/${l.id}');
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'add', child: Text('Add stock')),
                PopupMenuItem(value: 'remove', child: Text('Remove stock')),
                PopupMenuItem(value: 'damage', child: Text('Damaged / repaired')),
                PopupMenuItem(value: 'calendar', child: Text('Availability calendar')),
                PopupMenuItem(value: 'edit', child: Text('Edit listing')),
              ],
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(EvSpace.x4, EvSpace.x3, EvSpace.x4, 0),
          child: StockBar(segments: [
            (free, EvColors.forest),
            (bookedToday, EvColors.bronze),
            (out, EvColors.info),
            (l.inspectionQuantity, EvColors.warning),
            (l.damagedQuantity, EvColors.danger),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(EvSpace.x4, EvSpace.x3, EvSpace.x4, 0),
          child: Wrap(spacing: 14, runSpacing: 6, children: [
            LegendDot(EvColors.forest, 'Free', free),
            if (bookedToday > 0) LegendDot(EvColors.bronze, 'Booked', bookedToday),
            if (out > 0) LegendDot(EvColors.info, 'Out', out),
            if (l.inspectionQuantity > 0) LegendDot(EvColors.warning, 'Inspect', l.inspectionQuantity),
            if (l.damagedQuantity > 0) LegendDot(EvColors.danger, 'Damaged', l.damagedQuantity),
          ]),
        ),
        if (l.inspectionQuantity > 0 || conflicts.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(EvSpace.x4, EvSpace.x3, EvSpace.x4, 0),
            child: Wrap(spacing: 8, runSpacing: 8, children: [
              if (l.inspectionQuantity > 0) EvButton('Inspect ${l.inspectionQuantity} returned', compact: true, kind: EvButtonKind.secondary, icon: LucideIcons.clipboardCheck, onPressed: () => _inspect(context, ref)),
              if (conflicts.isNotEmpty)
                EvButton('Source ${conflicts.first.shortfall} for ${EvDates.dayShort(conflicts.first.day)}', compact: true, kind: EvButtonKind.secondary, icon: LucideIcons.zap,
                    onPressed: () => context.push('/now/new?category=${l.categoryId}&qty=${conflicts.first.shortfall}&item=${Uri.encodeComponent(l.title)}&date=${EvDates.iso(conflicts.first.day)}')),
            ]),
          ),
        if (upcoming.isNotEmpty) ...[
          const Padding(padding: EdgeInsets.only(top: EvSpace.x3), child: EvDivider(indent: EvSpace.x4)),
          for (final r in upcoming)
            _ReservationLine(reservation: r),
        ],
        const SizedBox(height: EvSpace.x3),
      ]),
    );
  }
}

class _ReservationLine extends ConsumerWidget {
  const _ReservationLine({required this.reservation});
  final Reservation reservation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = reservation;
    final api = ref.read(backendProvider).listings;
    final canDispatch = r.source == ReservationSource.manual && (r.status == ReservationStatus.confirmed || r.status == ReservationStatus.held);
    final canReturn = r.source == ReservationSource.manual && r.status == ReservationStatus.dispatched;
    return Padding(
      padding: const EdgeInsets.fromLTRB(EvSpace.x4, 8, EvSpace.x2, 0),
      child: Row(children: [
        SizedBox(width: 64, child: Text(EvDates.dayShort(r.startsOn), style: EvType.smallStrong)),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${r.quantity} · ${r.clientLabel ?? 'Booking'}', style: EvType.small.copyWith(color: EvColors.ink), maxLines: 1, overflow: TextOverflow.ellipsis),
            Text('${r.source.label}${r.status == ReservationStatus.dispatched ? ' · out' : ''}', style: EvType.caption),
          ]),
        ),
        if (r.bookingId != null)
          TextButton(onPressed: () => context.push('/bookings/${r.bookingId}'), child: const Text('Booking'))
        else if (canDispatch)
          TextButton(onPressed: () => guard(context, () => api.moveReservation(r.id, 'dispatch'), success: 'Marked out'), child: const Text('Mark out'))
        else if (canReturn)
          TextButton(onPressed: () => guard(context, () => api.moveReservation(r.id, 'return'), success: 'Returned — awaiting inspection'), child: const Text('Returned')),
      ]),
    );
  }
}
