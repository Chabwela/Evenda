import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../app/providers.dart';
import '../../data/backend.dart';
import '../../design/ev.dart';
import '../../domain/models.dart';
import '../shared/feed_cards.dart';

final myListingsProvider = FutureProvider.autoDispose<List<Listing>>((ref) async {
  ref.watchDomains(const [DataDomain.listings]);
  return ref.watch(backendProvider).listings.mine(ref.watch(bizIdProvider));
});

class ListingsScreen extends ConsumerStatefulWidget {
  const ListingsScreen({super.key});
  @override
  ConsumerState<ListingsScreen> createState() => _ListingsScreenState();
}

class _ListingsScreenState extends ConsumerState<ListingsScreen> {
  ListingStatus? _filter;

  Future<void> _new() async {
    final biz = ref.read(myBusinessProvider).value!;
    final kinds = biz.offeringTypes.isEmpty ? OfferingType.values.toSet() : biz.offeringTypes;
    if (kinds.length == 1) {
      context.push('/business/listings/new?kind=${kinds.first.wire}');
      return;
    }
    final k = await pickFromSheet<OfferingType>(context, title: 'What are you listing?', icon: (k) => switch (k) {
          OfferingType.rental => LucideIcons.boxes,
          OfferingType.service => LucideIcons.handshake,
          OfferingType.package => LucideIcons.packageCheck,
        }, options: [for (final k in kinds) (k, k.label, k.hint)]);
    if (k != null && mounted) context.push('/business/listings/new?kind=${k.wire}');
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(myListingsProvider);
    final all = data.value ?? const <Listing>[];
    final counts = {for (final s in ListingStatus.values) s: all.where((l) => l.status == s).length};
    return Scaffold(
      appBar: AppBar(
        title: const Text('Listings'),
        actions: [EvIconButton(LucideIcons.plus, tooltip: 'New listing', onPressed: _new), const SizedBox(width: 8)],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(50),
          child: Padding(
            padding: const EdgeInsets.only(bottom: EvSpace.x2),
            child: EvSegmented<ListingStatus?>(
              value: _filter,
              onChanged: (v) => setState(() => _filter = v),
              counts: counts,
              segments: const [
                (null, 'All'),
                (ListingStatus.published, 'Published'),
                (ListingStatus.draft, 'Drafts'),
                (ListingStatus.paused, 'Paused'),
                (ListingStatus.archived, 'Archived'),
              ],
            ),
          ),
        ),
      ),
      body: AsyncView(
        value: data,
        onRetry: () => ref.invalidate(myListingsProvider),
        isEmpty: (l) => l.isEmpty,
        empty: EmptyState(
          mascot: Mascot.crate,
          title: 'No listings yet',
          body: 'List what you hire out or the services you offer. Other vendors find you through your listings.',
          action: 'Create a listing',
          onAction: _new,
        ),
        data: (list) {
          final shown = _filter == null ? list.where((l) => l.status != ListingStatus.archived).toList() : list.where((l) => l.status == _filter).toList();
          if (shown.isEmpty) return EmptyState(title: 'Nothing here', body: 'No ${_filter?.label.toLowerCase() ?? ''} listings.', compact: true);
          return ListView.separated(
            padding: const EdgeInsets.only(top: EvSpace.x2, bottom: EvSpace.x10),
            itemCount: shown.length,
            separatorBuilder: (_, _) => const EvDivider(indent: 104),
            itemBuilder: (c, i) {
              final l = shown[i];
              return InkWell(
                onTap: () => context.push('/business/listings/${l.id}'),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: EvSpace.gutter, vertical: 12),
                  child: Row(children: [
                    EvPhoto(l.coverPhoto, width: 72, height: 72, radius: EvRadius.sm, icon: categoryIcon(l.categoryId)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(l.title, style: EvType.bodyStrong, maxLines: 2, overflow: TextOverflow.ellipsis),
                        const SizedBox(height: 2),
                        Text(priceLabel(l), style: EvType.small),
                        const SizedBox(height: 6),
                        Row(children: [
                          StatusPill(l.status.label, tone: toneForListing(l.status), dense: true),
                          const SizedBox(width: 8),
                          if (l.tracksStock && !l.isService) Text('${l.usable} usable of ${l.totalQuantity}', style: EvType.caption),
                          if (l.isService) Text('${l.totalQuantity} job${l.totalQuantity == 1 ? '' : 's'} per day', style: EvType.caption),
                          if (l.moderation != ModerationStatus.ok) ...[
                            const SizedBox(width: 8),
                            StatusPill(l.moderation == ModerationStatus.flagged ? 'Flagged' : 'Removed', tone: Tone.critical, dense: true),
                          ],
                        ]),
                      ]),
                    ),
                    PopupMenuButton<ListingStatus>(
                      icon: const Icon(LucideIcons.ellipsisVertical, size: 18),
                      onSelected: (s) => guard(context, () => ref.read(backendProvider).listings.setStatus(l.id, s),
                          success: s == ListingStatus.published ? 'Published — relevant vendors will be told' : 'Listing ${s.label.toLowerCase()}'),
                      itemBuilder: (_) => [
                        if (l.status != ListingStatus.published) const PopupMenuItem(value: ListingStatus.published, child: Text('Publish')),
                        if (l.status == ListingStatus.published) const PopupMenuItem(value: ListingStatus.paused, child: Text('Pause')),
                        if (l.status != ListingStatus.archived) const PopupMenuItem(value: ListingStatus.archived, child: Text('Archive')),
                        if (l.status == ListingStatus.archived) const PopupMenuItem(value: ListingStatus.draft, child: Text('Restore as draft')),
                      ],
                    ),
                  ]),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
