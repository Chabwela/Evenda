import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/providers.dart';
import '../../core/format.dart';
import '../../data/backend.dart';
import '../../design/ev.dart';
import '../../domain/models.dart';
import '../shared/feed_cards.dart';
import 'listing_detail.dart';

final _supplierProvider = FutureProvider.autoDispose.family<(Business, List<Listing>), String>((ref, id) async {
  ref.watchDomains(const [DataDomain.discovery, DataDomain.listings]);
  final d = ref.watch(backendProvider).discovery;
  final r = await Future.wait([d.supplier(id), d.supplierListings(id)]);
  return (r[0] as Business, r[1] as List<Listing>);
});

class SupplierScreen extends ConsumerWidget {
  const SupplierScreen({super.key, required this.id});
  final String id;

  String _today(Business b) {
    const keys = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
    final h = b.operatingHours[keys[EvDates.nowLusaka().weekday - 1]];
    if (h == null) return 'Hours not set';
    return h == 'closed' ? 'Closed today' : 'Open today ${h.replaceAll('-', '–')}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(_supplierProvider(id));
    final myId = ref.watch(bizIdProvider);
    final follow = (ref.watch(followsProvider).value ?? const []).where((f) => f.supplier.id == id).firstOrNull;
    final d = ref.read(backendProvider).discovery;

    return Scaffold(
      appBar: AppBar(
        actions: [
          if (follow != null)
            PopupMenuButton<String>(
              icon: const Icon(LucideIcons.ellipsis),
              onSelected: (v) {
                if (v == 'mute') guard(context, () => d.setFollowMuted(myId, id, !follow.muted), success: follow.muted ? 'Updates unmuted' : 'Updates muted');
                if (v == 'unfollow') guard(context, () => d.unfollow(myId, id), success: 'Unfollowed');
              },
              itemBuilder: (_) => [
                PopupMenuItem(value: 'mute', child: Text(follow.muted ? 'Unmute updates' : 'Mute updates')),
                const PopupMenuItem(value: 'unfollow', child: Text('Unfollow')),
              ],
            ),
        ],
      ),
      body: AsyncView(
        value: data,
        onRetry: () => ref.invalidate(_supplierProvider(id)),
        data: (r) {
          final (b, listings) = r;
          return ListView(padding: const EdgeInsets.only(bottom: EvSpace.x10), children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: EvSpace.gutter),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                BusinessAvatar(name: b.name, logoUrl: b.logoUrl, size: 72, verified: b.verified),
                const SizedBox(height: EvSpace.x4),
                Text(b.name, style: EvType.display),
                const SizedBox(height: 6),
                Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  StatusPill(b.verification.label, tone: toneForVerification(b.verification), dense: true, icon: b.verified ? LucideIcons.badgeCheck : null),
                  if (b.neighbourhood != null) Text(b.neighbourhood!, style: EvType.small),
                  Text('· ${_today(b)}', style: EvType.small),
                ]),
                const SizedBox(height: EvSpace.x4),
                if (b.description.isNotEmpty) Text(b.description, style: EvType.body.copyWith(color: EvColors.ink2, height: 1.5)),
                const SizedBox(height: EvSpace.x4),
                Row(children: [
                  if (id != myId)
                    Expanded(
                      child: EvButton(follow != null ? (follow.muted ? 'Following (muted)' : 'Following') : 'Follow',
                          kind: follow != null ? EvButtonKind.secondary : EvButtonKind.primary,
                          icon: follow != null ? LucideIcons.check : LucideIcons.bookmark,
                          onPressed: follow != null ? null : () => guard(context, () => d.follow(myId, id), success: 'You’ll be told when ${b.name} adds stock')),
                    ),
                  if (b.phone != null) ...[
                    const SizedBox(width: 8),
                    EvButton('', kind: EvButtonKind.secondary, icon: LucideIcons.phone, onPressed: () => launchUrl(Uri.parse('tel:${b.phone}'))),
                  ],
                  if (b.whatsapp != null) ...[
                    const SizedBox(width: 8),
                    EvButton('', kind: EvButtonKind.secondary, icon: LucideIcons.messageCircle,
                        onPressed: () => launchUrl(Uri.parse('https://wa.me/${ZambianPhone.waDigits(b.whatsapp!)}'), mode: LaunchMode.externalApplication)),
                  ],
                ]),
                const SizedBox(height: EvSpace.x2),
                Text('Serves within ${b.serviceRadiusKm} km${b.locationPrecision == LocationPrecision.approximate ? ' · location shown approximately' : ''}', style: EvType.caption),
              ]),
            ),
            SectionHeader('Listings', count: listings.length),
            if (listings.isEmpty)
              const EmptyState(title: 'No published listings', compact: true)
            else
              for (final (i, l) in listings.indexed) ...[
                if (i > 0) const EvDivider(indent: 144),
                ListingResultCard(result: SearchResult(listing: l), onTap: () => context.push('/listing/${l.id}')),
              ],
          ]);
        },
      ),
    );
  }
}
