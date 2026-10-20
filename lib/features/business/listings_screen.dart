import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../app/providers.dart';
import '../../core/format.dart';
import '../../data/backend.dart';
import '../../design/ev.dart';
import '../../domain/models.dart';
import '../shared/feed_cards.dart';
import 'inventory_screen.dart' show addStockItem;

final myListingsProvider = FutureProvider.autoDispose<List<Listing>>((ref) async {
  ref.watchDomains(const [DataDomain.listings]);
  return ref.watch(backendProvider).listings.mine(ref.watch(bizIdProvider));
});

enum _Show {
  live('Live'),
  paused('Paused'),
  drafts('Not listed'),
  archived('Archived');

  const _Show(this.label);
  final String label;

  bool matches(Listing l) => switch (this) {
        live => l.status == ListingStatus.published,
        paused => l.status == ListingStatus.paused,
        drafts => l.status == ListingStatus.draft,
        archived => l.status == ListingStatus.archived,
      };
}

/// What other vendors see. A rental listing shows stock from Inventory, so
/// quantities are managed there; this screen decides what is offered, how it
/// looks (photos, price, terms) and whether it is showing right now.
class ListingsScreen extends ConsumerStatefulWidget {
  const ListingsScreen({super.key});
  @override
  ConsumerState<ListingsScreen> createState() => _ListingsScreenState();
}

class _ListingsScreenState extends ConsumerState<ListingsScreen> {
  _Show _show = _Show.live;
  bool _picked = false;

  Future<void> _add(List<Listing> all) async {
    final biz = ref.read(myBusinessProvider).value!;
    final kinds = biz.offeringTypes.isEmpty ? OfferingType.values.toSet() : biz.offeringTypes;
    final unlisted = all.where((l) => l.kind == OfferingType.rental && l.tracksStock && l.status == ListingStatus.draft).toList();
    final choice = await showEvSheet<String>(
      context,
      title: 'Put something on the marketplace',
      builder: (c) => Padding(
        padding: const EdgeInsets.only(bottom: EvSpace.x6),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (kinds.contains(OfferingType.rental)) ...[
            EvRow(
              leading: const IconTile(LucideIcons.boxes, tone: Tone.positive),
              title: 'From my stock',
              subtitle: unlisted.isEmpty ? 'Everything you own is already listed' : '${plural(unlisted.length, 'item')} not on the marketplace yet',
              onTap: unlisted.isEmpty ? null : () => Navigator.pop(c, 'stock'),
            ),
            const EvDivider(indent: 72),
            EvRow(
              leading: const IconTile(LucideIcons.packagePlus),
              title: 'New rental item',
              subtitle: 'Adds it to your stock and lists it',
              onTap: () => Navigator.pop(c, 'rental'),
            ),
          ],
          if (kinds.contains(OfferingType.service)) ...[
            const EvDivider(indent: 72),
            EvRow(leading: const IconTile(LucideIcons.handshake), title: 'A service', subtitle: OfferingType.service.hint, onTap: () => Navigator.pop(c, 'service')),
          ],
          if (kinds.contains(OfferingType.package)) ...[
            const EvDivider(indent: 72),
            EvRow(leading: const IconTile(LucideIcons.packageCheck), title: 'A package', subtitle: OfferingType.package.hint, onTap: () => Navigator.pop(c, 'package')),
          ],
        ]),
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'stock') {
      final pick = await showEvSheet<Listing>(
        context,
        title: 'Which item?',
        subtitle: 'Add photos and a price, then publish.',
        builder: (c) => ListView(shrinkWrap: true, padding: const EdgeInsets.only(bottom: EvSpace.x6), children: [
          for (final l in unlisted)
            EvRow(
              leading: EvPhoto(l.coverPhoto, width: 44, height: 44, radius: EvRadius.sm, icon: categoryIcon(l.categoryId)),
              title: l.title,
              subtitle: '${l.totalQuantity} owned · ${categoryById(l.categoryId).name}',
              onTap: () => Navigator.pop(c, l),
            ),
        ]),
      );
      if (pick != null && mounted) context.push('/business/listings/${pick.id}');
    } else {
      context.push('/business/listings/new?kind=$choice');
    }
  }

  /// Why a listing can't go live yet, so the switch never fails silently.
  String? _blocker(Listing l) {
    if (l.moderation != ModerationStatus.ok) return 'Held by Evenda moderation';
    if (l.priceUnit != PriceUnit.onQuote && l.priceAmount == null) return 'Add a price';
    if (l.tracksStock && !l.isService && l.totalQuantity == 0) return 'No stock: add some in My stock';
    return null;
  }

  Future<void> _toggle(Listing l, bool show) async {
    final block = show ? _blocker(l) : null;
    if (block != null) {
      showToast(context, '$block before it can go live.', icon: LucideIcons.circleAlert, action: 'Open', onAction: () => context.push('/business/listings/${l.id}'));
      return;
    }
    await guard(context, () => ref.read(backendProvider).listings.setStatus(l.id, show ? ListingStatus.published : ListingStatus.paused),
        success: show ? 'Live — vendors following this category will hear about it' : 'Paused: hidden from the marketplace');
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(myListingsProvider);
    final all = data.value ?? const <Listing>[];
    // Open on what matters: live if anything is live, otherwise what isn't listed.
    if (!_picked && data.hasValue) {
      _show = all.any(_Show.live.matches) ? _Show.live : (all.any(_Show.drafts.matches) ? _Show.drafts : _Show.live);
    }
    final live = all.where(_Show.live.matches).toList();
    final unlistedStock = all.where((l) => l.kind == OfferingType.rental && l.tracksStock && l.status == ListingStatus.draft).length;

    return Scaffold(
      appBar: AppBar(title: const Text('On the marketplace'), centerTitle: false),
      floatingActionButton: data.hasValue && all.isNotEmpty
          ? FloatingActionButton.extended(
              onPressed: () => _add(all),
              backgroundColor: EvColors.forest,
              foregroundColor: EvColors.inkOnDark,
              icon: const Icon(LucideIcons.store),
              label: const Text('List something'),
            )
          : null,
      body: AsyncView(
        value: data,
        onRetry: () => ref.invalidate(myListingsProvider),
        isEmpty: (l) => l.isEmpty,
        empty: EmptyState(
          mascot: Mascot.crate,
          title: 'Nothing on the marketplace yet',
          body: 'Start with what you own: add your stock, then choose which items other vendors can see and book.',
          action: 'Add stock',
          onAction: () => addStockItem(context, ref),
        ),
        data: (list) {
          final shown = list.where(_show.matches).toList();
          return ListView(padding: const EdgeInsets.only(bottom: 96), children: [
            Container(
              margin: const EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x2, EvSpace.gutter, 0),
              padding: const EdgeInsets.all(EvSpace.x4),
              decoration: BoxDecoration(color: EvColors.forest, borderRadius: EvRadius.lgAll),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('VENDORS CAN SEE', style: EvType.overline.copyWith(color: EvColors.sand)),
                    const SizedBox(height: 4),
                    Text('${live.length} live listing${live.length == 1 ? '' : 's'}', style: EvType.displaySm.copyWith(color: EvColors.inkOnDark)),
                    const SizedBox(height: 2),
                    Text('Stock counts come from My stock.', style: EvType.caption.copyWith(color: EvColors.sand)),
                  ]),
                ),
                const Icon(LucideIcons.store, size: 40, color: Color(0xFFC9A27A)),
              ]),
            ),
            if (unlistedStock > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x3, EvSpace.gutter, 0),
                child: EvSurface(
                  color: EvColors.bronzeTint,
                  onTap: () => setState(() {
                    _picked = true;
                    _show = _Show.drafts;
                  }),
                  child: Row(children: [
                    const Icon(LucideIcons.lightbulb, size: 18, color: EvColors.bronzeDeep),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text('${plural(unlistedStock, 'stock item')} ${unlistedStock == 1 ? 'isn’t' : 'aren’t'} on the marketplace. Listing them helps vendors find you.',
                          style: EvType.small.copyWith(color: EvColors.bronzeDeep)),
                    ),
                    const Icon(LucideIcons.chevronRight, size: 18, color: EvColors.bronzeDeep),
                  ]),
                ),
              ),
            const SizedBox(height: EvSpace.x3),
            EvSegmented<_Show>(
              value: _show,
              onChanged: (v) => setState(() {
                _picked = true;
                _show = v;
              }),
              segments: [for (final s in _Show.values) (s, '${s.label} ${list.where(s.matches).length}')],
            ),
            const SizedBox(height: EvSpace.x2),
            if (shown.isEmpty)
              EmptyState(
                title: switch (_show) { _Show.live => 'Nothing live', _Show.paused => 'Nothing paused', _Show.drafts => 'Everything is listed', _Show.archived => 'Nothing archived' },
                body: _show == _Show.live ? 'Turn on a listing to show it to other vendors.' : null,
                compact: true,
              )
            else
              for (final l in shown)
                Padding(
                  padding: const EdgeInsets.fromLTRB(EvSpace.gutter, 0, EvSpace.gutter, EvSpace.x2),
                  child: _ListingCard(listing: l, blocker: _blocker(l), onToggle: (v) => _toggle(l, v)),
                ),
          ]);
        },
      ),
    );
  }
}

class _ListingCard extends ConsumerWidget {
  const _ListingCard({required this.listing, required this.blocker, required this.onToggle});
  final Listing listing;
  final String? blocker;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = listing;
    final live = l.status == ListingStatus.published;
    final missingPhoto = l.photos.isEmpty;
    return EvSurface(
      onTap: () => context.push('/business/listings/${l.id}'),
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Stack(children: [
            EvPhoto(l.coverPhoto, width: 76, height: 76, radius: EvRadius.sm, icon: categoryIcon(l.categoryId)),
            if (live)
              Positioned(
                left: 4,
                top: 4,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(color: EvColors.success, borderRadius: BorderRadius.circular(EvRadius.pill)),
                  child: Text('LIVE', style: EvType.overline.copyWith(color: EvColors.inkOnDark, fontSize: 9)),
                ),
              ),
          ]),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l.title, style: EvType.bodyStrong, maxLines: 2, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Text(priceLabel(l), style: EvType.money.copyWith(fontSize: 14)),
              const SizedBox(height: 4),
              Text(
                l.isService
                    ? '${l.totalQuantity} job${l.totalQuantity == 1 ? '' : 's'} per day'
                    : l.tracksStock
                        ? '${l.usable} of ${l.totalQuantity} in service · from My stock'
                        : categoryById(l.categoryId).name,
                style: EvType.caption,
              ),
            ]),
          ),
          if (l.status != ListingStatus.archived)
            Column(children: [
              Switch(value: live, onChanged: onToggle, activeThumbColor: EvColors.inkOnDark, activeTrackColor: EvColors.success),
              Text(live ? 'Showing' : 'Hidden', style: EvType.caption.copyWith(color: live ? EvColors.success : EvColors.ink3)),
            ]),
        ]),
        if (blocker != null || (missingPhoto && l.status != ListingStatus.archived) || l.moderation != ModerationStatus.ok) ...[
          const SizedBox(height: 10),
          Wrap(spacing: 6, runSpacing: 6, children: [
            if (l.moderation != ModerationStatus.ok)
              StatusPill(l.moderation == ModerationStatus.flagged ? 'Flagged by Evenda' : 'Removed by Evenda', tone: Tone.critical, dense: true, icon: LucideIcons.shieldAlert)
            else if (blocker != null)
              StatusPill(blocker!, tone: Tone.waiting, dense: true, icon: LucideIcons.circleAlert),
            if (missingPhoto) const StatusPill('No photos: listings with photos get more requests', tone: Tone.neutral, dense: true, icon: LucideIcons.imageOff),
          ]),
        ],
        if (l.status == ListingStatus.archived) ...[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => guard(context, () => ref.read(backendProvider).listings.setStatus(l.id, ListingStatus.draft), success: 'Restored. Not listed yet'),
              child: const Text('Restore'),
            ),
          ),
        ],
      ]),
    );
  }
}
