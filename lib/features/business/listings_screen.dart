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
    final biz = ref.read(myBusinessProvider).value;
    if (biz == null) return;
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
              subtitle: 'Adds it to your stock and lists it in one go',
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
      appBar: AppBar(
        title: const Text('On the marketplace'),
        centerTitle: false,
        actions: [
          if (data.hasValue && all.isNotEmpty)
            TextButton.icon(onPressed: () => _add(all), icon: const Icon(LucideIcons.plus, size: 18), label: const Text('List')),
          const SizedBox(width: 8),
        ],
      ),
      body: AsyncView(
        value: data,
        onRetry: () => ref.invalidate(myListingsProvider),
        isEmpty: (l) => l.isEmpty,
        empty: EmptyState(
          mascot: Mascot.crate,
          title: 'Nothing on the marketplace yet',
          body: 'Start with what you own: add your stock, then choose which items other vendors can see and book.',
          action: 'Add stock',
          onAction: () => context.push('/business/stock/new'),
        ),
        data: (list) {
          final shown = list.where(_show.matches).toList();
          return ListView(padding: const EdgeInsets.only(bottom: EvSpace.x10), children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x1, EvSpace.gutter, 0),
              child: Text.rich(TextSpan(style: EvType.body.copyWith(color: EvColors.ink2), children: [
                TextSpan(text: '${live.length} live', style: EvType.bodyStrong.copyWith(color: EvColors.forest)),
                const TextSpan(text: ' · what other vendors see. Stock counts come from My stock.'),
              ])),
            ),
            if (unlistedStock > 0)
              InkWell(
                onTap: () => setState(() {
                  _picked = true;
                  _show = _Show.drafts;
                }),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x2, EvSpace.gutter, EvSpace.x1),
                  child: Text('${plural(unlistedStock, 'stock item')} not listed yet. Listing them helps vendors find you →',
                      style: EvType.small.copyWith(color: EvColors.bronzeDeep, fontWeight: FontWeight.w600)),
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
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: EvSpace.gutter),
                child: EvSurface(
                  padding: EdgeInsets.zero,
                  child: Column(children: [
                    for (final (i, l) in shown.indexed) ...[
                      if (i > 0) const EvDivider(indent: 100),
                      _ListingCard(listing: l, blocker: _blocker(l), onToggle: (v) => _toggle(l, v)),
                    ],
                  ]),
                ),
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
    final (statusText, statusColor) = switch (l.status) {
      ListingStatus.published => ('Live', EvColors.success),
      ListingStatus.paused => ('Paused', EvColors.warning),
      ListingStatus.draft => ('Not listed', EvColors.ink3),
      ListingStatus.archived => ('Archived', EvColors.ink3),
    };
    final note = l.moderation != ModerationStatus.ok
        ? (l.moderation == ModerationStatus.flagged ? 'Flagged by Evenda' : 'Removed by Evenda')
        : blocker ?? (missingPhoto && l.status != ListingStatus.archived ? 'No photos yet' : null);
    return InkWell(
      onTap: () => context.push('/business/listings/${l.id}'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(EvSpace.x3, EvSpace.x3, EvSpace.x2, EvSpace.x3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          EvPhoto(l.coverPhoto, width: 72, height: 72, radius: EvRadius.sm, icon: categoryIcon(l.categoryId)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l.title, style: EvType.bodyStrong, maxLines: 2, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Text.rich(TextSpan(children: [
                TextSpan(text: statusText, style: EvType.caption.copyWith(color: statusColor, fontWeight: FontWeight.w700)),
                TextSpan(text: '  ·  ${priceLabel(l)}', style: EvType.caption.copyWith(color: EvColors.ink)),
              ])),
              const SizedBox(height: 2),
              Text(
                l.isService
                    ? '${l.totalQuantity} job${l.totalQuantity == 1 ? '' : 's'} per day'
                    : l.tracksStock
                        ? (l.listedQuantity == null ? 'Offering all ${l.usable} in service' : 'Offering up to ${l.offeredQuantity} of ${l.totalQuantity}')
                        : categoryById(l.categoryId).name,
                style: EvType.caption,
              ),
              if (note != null) ...[
                const SizedBox(height: 4),
                Text(note, style: EvType.caption.copyWith(color: l.moderation != ModerationStatus.ok ? EvColors.danger : EvColors.warning, fontWeight: FontWeight.w600)),
              ],
              if (l.status == ListingStatus.archived)
                TextButton(
                  style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
                  onPressed: () => guard(context, () => ref.read(backendProvider).listings.setStatus(l.id, ListingStatus.draft), success: 'Restored. Not listed yet'),
                  child: const Text('Restore'),
                ),
            ]),
          ),
          if (l.status != ListingStatus.archived)
            Switch(value: live, onChanged: onToggle, activeThumbColor: EvColors.inkOnDark, activeTrackColor: EvColors.success),
        ]),
      ),
    );
  }
}
