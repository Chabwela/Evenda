import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../app/providers.dart';
import '../../core/format.dart';
import '../../data/backend.dart';
import '../../design/ev.dart';
import '../../domain/models.dart';
import '../shared/feed_cards.dart' show priceLabel;

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

enum _StockFilter { all, attention, unlisted }

/// Inventory = what the business owns. Every physical item, how many are free
/// today, out on jobs, back for inspection or damaged. Adding stock here never
/// puts it on the marketplace: that is a separate choice made in Listings.
class InventoryScreen extends ConsumerStatefulWidget {
  const InventoryScreen({super.key, this.focusListingId});
  final String? focusListingId;
  @override
  ConsumerState<InventoryScreen> createState() => _InventoryScreenState();
}

class _InventoryScreenState extends ConsumerState<InventoryScreen> {
  _StockFilter _filter = _StockFilter.all;

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(_inventoryProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('My stock'), centerTitle: false),
      floatingActionButton: data.hasValue && data.value!.$1.isNotEmpty
          ? FloatingActionButton.extended(
              onPressed: () => addStockItem(context, ref),
              backgroundColor: EvColors.forest,
              foregroundColor: EvColors.inkOnDark,
              icon: const Icon(LucideIcons.packagePlus),
              label: const Text('Add item'),
            )
          : null,
      body: AsyncView(
        value: data,
        onRetry: () => ref.invalidate(_inventoryProvider),
        isEmpty: (d) => d.$1.isEmpty,
        empty: EmptyState(
          mascot: Mascot.crate,
          title: 'Count what you own',
          body: 'Add each item you hire out (chairs, tents, linen…) with how many you have. You decide later which ones appear on the marketplace.',
          action: 'Add your first item',
          onAction: () => addStockItem(context, ref),
        ),
        data: (d) {
          final (listings, reservations, conflicts) = d;
          final today = EvDates.today();
          int bookedToday(Listing l) => reservations
              .where((r) => r.listingId == l.id && r.covers(today) && (r.status == ReservationStatus.confirmed || r.status == ReservationStatus.held))
              .fold(0, (s, r) => s + r.quantity);
          int outNow(Listing l) => reservations.where((r) => r.listingId == l.id && r.status == ReservationStatus.dispatched).fold(0, (s, r) => s + r.quantity);
          final owned = listings.fold<int>(0, (s, l) => s + l.totalQuantity);
          final out = listings.fold<int>(0, (s, l) => s + outNow(l));
          final free = listings.fold<int>(0, (s, l) => s + (l.usable - bookedToday(l) - outNow(l)).clamp(0, 1 << 30));
          bool needsAttention(Listing l) => l.inspectionQuantity > 0 || l.damagedQuantity > 0 || conflicts.any((c) => c.listingId == l.id);
          final attention = listings.where(needsAttention).length;
          final unlisted = listings.where((l) => l.status != ListingStatus.published).length;

          final shown = switch (_filter) {
            _StockFilter.all => listings,
            _StockFilter.attention => listings.where(needsAttention).toList(),
            _StockFilter.unlisted => listings.where((l) => l.status != ListingStatus.published).toList(),
          };
          final sorted = [...shown]..sort((a, b) => a.id == widget.focusListingId ? -1 : (b.id == widget.focusListingId ? 1 : a.title.compareTo(b.title)));

          return ListView(padding: const EdgeInsets.only(bottom: 96), children: [
            // What you own, at a glance.
            Container(
              margin: const EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x2, EvSpace.gutter, 0),
              padding: const EdgeInsets.all(EvSpace.x4),
              decoration: BoxDecoration(color: EvColors.forest, borderRadius: EvRadius.lgAll),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('WHAT YOU OWN', style: EvType.overline.copyWith(color: EvColors.sand)),
                const SizedBox(height: 4),
                Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  EvAnimatedCount(value: owned, style: EvType.display.copyWith(color: EvColors.inkOnDark)),
                  const SizedBox(width: 8),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text('units · ${plural(listings.length, 'item')}', style: EvType.small.copyWith(color: EvColors.sand)),
                  ),
                ]),
                const SizedBox(height: EvSpace.x3),
                Row(children: [
                  Expanded(child: _HeadStat('Free today', free, const Color(0xFFC9A27A))),
                  Expanded(child: _HeadStat('Out on jobs', out, EvColors.inkOnDark)),
                  Expanded(child: _HeadStat('Need attention', attention, attention > 0 ? const Color(0xFFE8B4A4) : EvColors.inkOnDark)),
                ]),
              ]),
            ),
            if (conflicts.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x3, EvSpace.gutter, 0),
                child: EvSurface(
                  color: EvColors.warningTint,
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Icon(LucideIcons.triangleAlert, color: EvColors.warning, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('Booked more than you have', style: EvType.bodyStrong.copyWith(color: EvColors.warning)),
                        for (final c in conflicts.take(3))
                          Text('${c.title}: ${c.committed} booked, ${c.usable} usable on ${EvDates.day(c.day)}', style: EvType.small.copyWith(color: EvColors.warning)),
                        const SizedBox(height: 6),
                        Text('Repair damaged items, add stock, or source the shortfall with Evenda Now.', style: EvType.caption.copyWith(color: EvColors.warning)),
                      ]),
                    ),
                  ]),
                ),
              ),
            const SizedBox(height: EvSpace.x3),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: EvSpace.gutter),
              child: Row(children: [
                EvChip(label: 'All ${listings.length}', selected: _filter == _StockFilter.all, onTap: () => setState(() => _filter = _StockFilter.all)),
                const SizedBox(width: 8),
                EvChip(label: 'Need attention $attention', icon: LucideIcons.wrench, selected: _filter == _StockFilter.attention, onTap: () => setState(() => _filter = _StockFilter.attention)),
                const SizedBox(width: 8),
                EvChip(label: 'Not on marketplace $unlisted', icon: LucideIcons.eyeOff, selected: _filter == _StockFilter.unlisted, onTap: () => setState(() => _filter = _StockFilter.unlisted)),
              ]),
            ),
            const SizedBox(height: EvSpace.x3),
            if (sorted.isEmpty)
              const EmptyState(title: 'Nothing here', body: 'No items match this filter.', compact: true)
            else
              for (final l in sorted)
                Padding(
                  padding: const EdgeInsets.fromLTRB(EvSpace.gutter, 0, EvSpace.gutter, EvSpace.x3),
                  child: _StockCard(
                    listing: l,
                    reservations: reservations.where((r) => r.listingId == l.id).toList(),
                    conflicts: conflicts.where((c) => c.listingId == l.id).toList(),
                    highlighted: l.id == widget.focusListingId,
                  ),
                ),
          ]);
        },
      ),
    );
  }
}

class _HeadStat extends StatelessWidget {
  const _HeadStat(this.label, this.value, this.color);
  final String label;
  final int value;
  final Color color;
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        EvAnimatedCount(value: value, style: EvType.number.copyWith(color: color)),
        Text(label, style: EvType.caption.copyWith(color: EvColors.sand)),
      ]);
}

/// Quick add: name, category, how many. No price or photos, and not on the
/// marketplace until the vendor lists it.
Future<void> addStockItem(BuildContext context, WidgetRef ref) async {
  final biz = ref.read(myBusinessProvider).value;
  if (biz == null) return;
  final name = TextEditingController();
  final cats = kCategories.where((c) => c.kind == OfferingType.rental).toList();
  var category = cats.any((c) => c.id == biz.primaryCategory) ? biz.primaryCategory! : cats.first.id;
  var qty = 10;
  var condition = 'good';
  final form = GlobalKey<FormState>();
  final ok = await showEvSheet<bool>(
    context,
    title: 'Add a stock item',
    subtitle: 'Something you own and hire out. It stays private until you list it.',
    builder: (c) => StatefulBuilder(
      builder: (c, set) => SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(EvSpace.gutter, 0, EvSpace.gutter, EvSpace.x6 + MediaQuery.viewInsetsOf(c).bottom),
        child: Form(
          key: form,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            EvField(
              label: 'Item',
              controller: name,
              hint: 'e.g. White Chiavari chairs',
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              validator: (v) => (v == null || v.trim().length < 2) ? 'Name the item' : null,
            ),
            const SizedBox(height: EvSpace.x4),
            const EvFieldLabel('Category'),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final cat in cats) EvChip(label: cat.name, icon: categoryIcon(cat.id), selected: category == cat.id, onTap: () => set(() => category = cat.id)),
            ]),
            const SizedBox(height: EvSpace.x4),
            EvQuantityStepper(label: 'How many you own', value: qty, min: 1, step: qty >= 20 ? 10 : 1, onChanged: (v) => set(() => qty = v)),
            const SizedBox(height: EvSpace.x4),
            const EvFieldLabel('Condition'),
            Wrap(spacing: 8, children: [
              for (final (k, l) in const [('new', 'New'), ('excellent', 'Excellent'), ('good', 'Good'), ('fair', 'Fair')])
                EvChip(label: l, selected: condition == k, onTap: () => set(() => condition = k)),
            ]),
            const SizedBox(height: EvSpace.x5),
            EvButton('Add to my stock', icon: LucideIcons.check, expand: true, onPressed: () {
              if (form.currentState!.validate()) Navigator.pop(c, true);
            }),
          ]),
        ),
      ),
    ),
  );
  if (ok != true || !context.mounted) return;
  final draft = ListingDraft(
    businessId: biz.id,
    kind: OfferingType.rental,
    title: name.text.trim(),
    categoryId: category,
    status: ListingStatus.draft,
    priceUnit: PriceUnit.onQuote,
    condition: condition,
    totalQuantity: qty,
    tracksStock: true,
  );
  await guard(context, () => ref.read(backendProvider).listings.create(draft), success: 'Added $qty × ${draft.title} to your stock');
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
                PopupMenuItem(value: 'edit', child: Text('Edit details & marketplace listing')),
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
        // Everyday stock changes, one tap away (damage and repairs: ⋮ menu).
        Padding(
          padding: const EdgeInsets.fromLTRB(EvSpace.x4, EvSpace.x3, EvSpace.x4, 0),
          child: Row(children: [
            Expanded(child: EvButton('Add', compact: true, kind: EvButtonKind.secondary, icon: LucideIcons.plus, expand: true, onPressed: () => _adjust(context, ref, true))),
            const SizedBox(width: 8),
            Expanded(child: EvButton('Remove', compact: true, kind: EvButtonKind.secondary, icon: LucideIcons.minus, expand: true, onPressed: l.usable == 0 ? null : () => _adjust(context, ref, false))),
          ]),
        ),
        if (upcoming.isNotEmpty) ...[
          const Padding(padding: EdgeInsets.only(top: EvSpace.x3), child: EvDivider(indent: EvSpace.x4)),
          for (final r in upcoming)
            _ReservationLine(reservation: r),
        ],
        // Marketplace: is this stock offered to other vendors?
        const Padding(padding: EdgeInsets.only(top: EvSpace.x3), child: EvDivider(indent: 0)),
        InkWell(
          onTap: () => context.push('/business/listings/${l.id}'),
          borderRadius: const BorderRadius.vertical(bottom: Radius.circular(EvRadius.md)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(EvSpace.x4, 10, EvSpace.x3, 10),
            child: Row(children: [
              Icon(l.status == ListingStatus.published ? LucideIcons.store : LucideIcons.eyeOff, size: 16,
                  color: l.status == ListingStatus.published ? EvColors.success : EvColors.ink3),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  switch (l.status) {
                    ListingStatus.published => 'On the marketplace · ${priceLabel(l)}',
                    ListingStatus.paused => 'Paused on the marketplace',
                    _ => 'Not on the marketplace',
                  },
                  style: EvType.small.copyWith(color: l.status == ListingStatus.published ? EvColors.success : EvColors.ink2),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(l.status == ListingStatus.published ? 'Edit listing' : 'List it', style: EvType.smallStrong.copyWith(color: EvColors.forest)),
              const Icon(LucideIcons.chevronRight, size: 16, color: EvColors.forest),
            ]),
          ),
        ),
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
