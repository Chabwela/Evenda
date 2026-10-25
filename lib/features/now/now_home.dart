import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../app/providers.dart';
import '../../core/format.dart';
import '../../data/backend.dart';
import '../../design/ev.dart';
import '../../domain/models.dart';

final nowOverviewProvider = FutureProvider.autoDispose<(List<NowRequest>, List<NowInboxItem>)>((ref) async {
  ref.watchDomains(const [DataDomain.now]);
  final id = ref.watch(bizIdProvider);
  final n = ref.watch(backendProvider).now;
  final r = await Future.wait([n.mine(id), n.inbox(id)]);
  return (r[0] as List<NowRequest>, r[1] as List<NowInboxItem>);
});

/// Evenda Now: time-critical sourcing. Distinct from browsing — the request
/// goes to nearby suppliers who have the item free, and they reply with offers.
class NowHomeScreen extends ConsumerWidget {
  const NowHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(nowOverviewProvider);
    return Scaffold(
      appBar: AppBar(
        title: Row(children: [
          Icon(LucideIcons.zap, color: EvColors.bronze, size: 20),
          const SizedBox(width: 6),
          Text('Evenda Now', style: EvType.title),
        ]),
      ),
      body: AsyncView(
        value: data,
        onRetry: () => ref.invalidate(nowOverviewProvider),
        data: (d) {
          final (mine, inbox) = d;
          final liveInbox = inbox.where((i) => i.request.status.live).toList();
          return ListView(padding: const EdgeInsets.only(bottom: 120), children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: EvSpace.gutter),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Short on stock for an event?', style: EvType.display),
                    const SizedBox(height: EvSpace.x2),
                    Text('Tell us what you need and where. Suppliers nearby who have it free on that date get an alert and reply with offers you can compare.',
                        style: EvType.body.copyWith(color: EvColors.ink2)),
                  ]),
                ),
                const MascotImage(Mascot.pin, size: 92),
              ]),
            ),
            const SizedBox(height: EvSpace.x4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: EvSpace.gutter),
              child: Row(children: const [
                _Step(1, 'Describe', LucideIcons.squarePen),
                _Step(2, 'Nearby suppliers alerted', LucideIcons.radar),
                _Step(3, 'Pick the best offer', LucideIcons.circleCheck),
              ]),
            ),
            if (liveInbox.isNotEmpty) ...[
              SectionHeader('Requests for you', count: liveInbox.length),
              for (final (i, it) in liveInbox.indexed) ...[
                if (i > 0) const EvDivider(indent: 72),
                EvRow(
                  leading: BusinessAvatar(name: it.request.requester.name, logoUrl: it.request.requester.logoUrl),
                  title: '${it.request.quantity} × ${it.request.itemDescription}',
                  subtitle: '${it.request.requester.name} · ${EvDates.relativeDay(it.request.neededFrom)}${it.request.neededByTime != null ? ' by ${it.request.neededByTime}' : ''} · ${it.distanceKm} km',
                  trailing: it.myOffer != null
                      ? StatusPill(it.myOffer!.status == NowOfferStatus.selected ? 'Selected' : 'Offer sent', tone: it.myOffer!.status == NowOfferStatus.selected ? Tone.positive : Tone.progress, dense: true)
                      : it.declined
                          ? const StatusPill('Declined', dense: true)
                          : Text('Respond', style: EvType.smallStrong.copyWith(color: EvColors.forest)),
                  onTap: () => context.push('/now/respond/${it.request.id}'),
                ),
              ],
            ],
            SectionHeader('Your requests', count: mine.length),
            if (mine.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: EvSpace.gutter),
                child: Text('No urgent requests yet.', style: EvType.small),
              ),
            for (final (i, r) in mine.indexed) ...[
              if (i > 0) const EvDivider(indent: 72),
              EvRow(
                leading: IconTile(categoryIcon(r.categoryId), tone: r.status.live ? Tone.waiting : Tone.neutral),
                title: '${r.quantity} × ${r.itemDescription}',
                subtitle: '${EvDates.day(r.neededFrom)} · ${plural(r.recipientsCount, 'supplier')} notified · ${EvDates.ago(r.createdAt)}',
                trailing: StatusPill(r.status.label, tone: toneForNow(r.status), dense: true),
                onTap: () => context.push('/now/${r.id}'),
              ),
            ],
          ]);
        },
      ),
      bottomSheet: Container(
        color: EvColors.warmWhite,
        padding: EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x3, EvSpace.gutter, EvSpace.x3 + MediaQuery.paddingOf(context).bottom),
        child: EvButton('New urgent request', icon: LucideIcons.zap, expand: true, onPressed: () => context.push('/now/new')),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step(this.n, this.label, this.icon);
  final int n;
  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              width: 22,
              height: 22,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: EvColors.forest, shape: BoxShape.circle),
              child: Text('$n', style: EvType.caption.copyWith(color: EvColors.inkOnDark, fontWeight: FontWeight.w700)),
            ),
            if (n < 3) Expanded(child: Container(height: 1.5, margin: const EdgeInsets.symmetric(horizontal: 6), color: EvColors.sand)),
          ]),
          const SizedBox(height: 6),
          Padding(padding: const EdgeInsets.only(right: 8), child: Text(label, style: EvType.caption.copyWith(color: EvColors.ink, fontWeight: FontWeight.w600))),
        ]),
      );
}
