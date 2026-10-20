import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../app/providers.dart';
import '../../app/shell.dart';
import '../../core/format.dart';
import '../../data/backend.dart';
import '../../design/ev.dart';
import '../../domain/models.dart';

final _hubProvider = FutureProvider.autoDispose<(List<Listing>, List<Booking>, List<QuoteRequest>)>((ref) async {
  ref.watchDomains(const [DataDomain.listings, DataDomain.bookings]);
  final id = ref.watch(bizIdProvider);
  final b = ref.watch(backendProvider);
  final r = await Future.wait([b.listings.mine(id), b.bookings.bookings(id), b.bookings.requests(id)]);
  return (r[0] as List<Listing>, r[1] as List<Booking>, r[2] as List<QuoteRequest>);
});

class BusinessScreen extends ConsumerWidget {
  const BusinessScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final biz = ref.watch(myBusinessProvider).value;
    final hub = ref.watch(_hubProvider).value;
    final session = ref.watch(sessionProvider).value;
    if (biz == null) return const Scaffold(body: Skeleton());

    final listings = hub?.$1 ?? const <Listing>[];
    final published = listings.where((l) => l.status == ListingStatus.published).length;
    final drafts = listings.where((l) => l.status == ListingStatus.draft).length;

    // This month's report (supplier side).
    final now = DateTime.now();
    final monthStart = DateTime(now.year, now.month);
    final asSupplier = (hub?.$2 ?? const <Booking>[]).where((b) => b.supplier.id == biz.id && !b.createdAt.isBefore(monthStart) && b.status != BookingStatus.cancelled).toList();
    final value = asSupplier.fold(0.0, (s, b) => s + b.total);
    final collected = asSupplier.fold(0.0, (s, b) => s + b.confirmedPaid);
    final quoted = (hub?.$3 ?? const <QuoteRequest>[]).where((q) => q.supplier.id == biz.id && q.quotations.isNotEmpty).toList();
    final won = quoted.where((q) => q.status == QuoteRequestStatus.accepted).length;

    final stock = listings.where((l) => l.kind == OfferingType.rental && l.tracksStock && l.status != ListingStatus.archived).toList();
    final attention = stock.where((l) => l.inspectionQuantity > 0 || l.damagedQuantity > 0).length;
    const gold = Color(0xFFC9A27A);

    Widget group(List<Widget> rows) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: EvSpace.gutter),
          child: EvSurface(
            padding: EdgeInsets.zero,
            child: Column(children: [
              for (final (i, r) in rows.indexed) ...[if (i > 0) const EvDivider(indent: 64), r],
            ]),
          ),
        );

    return Scaffold(
      appBar: const TabHeader(title: 'Business'),
      body: ListView(padding: const EdgeInsets.only(bottom: EvSpace.x10), children: [
        // Who you are on Evenda, and how this month is going.
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: EvSpace.gutter),
          child: Material(
            color: EvColors.forest,
            borderRadius: EvRadius.lgAll,
            child: InkWell(
              onTap: () => context.push('/business/profile'),
              borderRadius: EvRadius.lgAll,
              child: Padding(
                padding: const EdgeInsets.all(EvSpace.x4),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Container(
                      padding: const EdgeInsets.all(2),
                      decoration: const BoxDecoration(color: EvColors.cream, borderRadius: BorderRadius.all(Radius.circular(18))),
                      child: BusinessAvatar(name: biz.name, logoUrl: biz.logoUrl, size: 56, verified: biz.verified),
                    ),
                    const SizedBox(width: EvSpace.x3),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(biz.name, style: EvType.title.copyWith(color: EvColors.inkOnDark), maxLines: 2, overflow: TextOverflow.ellipsis),
                        const SizedBox(height: 2),
                        Text([categoryById(biz.primaryCategory).name, if (biz.neighbourhood != null) biz.neighbourhood!].join(' · '),
                            style: EvType.small.copyWith(color: EvColors.sand), maxLines: 1, overflow: TextOverflow.ellipsis),
                      ]),
                    ),
                    const Icon(LucideIcons.chevronRight, color: EvColors.sand),
                  ]),
                  const SizedBox(height: EvSpace.x3),
                  Row(children: [
                    Icon(biz.verified ? LucideIcons.badgeCheck : LucideIcons.shieldQuestion, size: 16, color: biz.verified ? gold : EvColors.sand),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        switch (biz.verification) {
                          VerificationStatus.verified => 'Verified business',
                          VerificationStatus.pending => 'Verification in review',
                          VerificationStatus.rejected => 'Verification needs new documents',
                          VerificationStatus.unverified => 'Not verified yet: upload your PACRA or TPIN',
                        },
                        style: EvType.smallStrong.copyWith(color: biz.verified ? gold : EvColors.inkOnDark),
                      ),
                    ),
                  ]),
                  const Padding(padding: EdgeInsets.symmetric(vertical: EvSpace.x3), child: Divider(height: 1, color: EvColors.forestSoft)),
                  Text('THIS MONTH', style: EvType.overline.copyWith(color: EvColors.sand)),
                  const SizedBox(height: 6),
                  Row(children: [
                    Expanded(child: _HeadStat('Booked', Money.k(value), plural(asSupplier.length, 'booking'), EvColors.inkOnDark)),
                    Expanded(child: _HeadStat('Paid', Money.k(collected), value == 0 ? '—' : '${(collected / value * 100).round()}% confirmed', gold)),
                    Expanded(child: _HeadStat('Quotes won', quoted.isEmpty ? '—' : '$won/${quoted.length}', 'all time', EvColors.inkOnDark)),
                  ]),
                ]),
              ),
            ),
          ),
        ),

        const SectionHeader('Stock & marketplace'),
        group([
          if (biz.rents)
            EvRow(
              leading: const IconTile(LucideIcons.boxes, tone: Tone.positive),
              title: 'My stock',
              subtitle: stock.isEmpty ? 'Count what you own' : '${plural(stock.length, 'item')} · ${stock.fold<int>(0, (s, l) => s + l.totalQuantity)} units',
              trailing: _Trail(count: attention, tone: Tone.attention, label: 'to check'),
              onTap: () => context.push('/business/inventory'),
            ),
          EvRow(
            leading: const IconTile(LucideIcons.store, tone: Tone.positive),
            title: 'On the marketplace',
            subtitle: '$published live${drafts > 0 ? ' · $drafts not listed' : ''}',
            trailing: _Trail(count: drafts, tone: Tone.waiting, label: 'to list'),
            onTap: () => context.push('/business/listings'),
          ),
          EvRow(
            leading: const IconTile(LucideIcons.calendarRange, tone: Tone.positive),
            title: 'Availability & jobs',
            subtitle: 'Closed dates and jobs booked outside Evenda',
            trailing: const _Trail(),
            onTap: () => context.push('/business/availability'),
          ),
        ]),

        const SectionHeader('Your business'),
        group([
          EvRow(leading: const IconTile(LucideIcons.idCard), title: 'Business profile', subtitle: 'Logo, contacts, location, hours, verification',
              trailing: const _Trail(), onTap: () => context.push('/business/profile')),
          EvRow(leading: const IconTile(LucideIcons.users), title: 'Team', subtitle: 'Who can quote, book and manage stock', trailing: const _Trail(), onTap: () => context.push('/business/team')),
          EvRow(
            leading: const IconTile(LucideIcons.bellRing),
            title: 'Notifications',
            subtitle: 'Supplier updates, reminders, quiet hours',
            trailing: const _Trail(),
            onTap: () => context.push('/business/notifications'),
          ),
        ]),

        const SectionHeader('Account'),
        group([
          EvRow(
            leading: const IconTile(LucideIcons.shieldCheck),
            title: 'Account & privacy',
            subtitle: 'Your data, privacy policy, account options',
            trailing: const _Trail(),
            onTap: () => context.push('/business/account'),
          ),
        ]),

        // Sign out on its own, far from anything destructive.
        const SizedBox(height: EvSpace.x5),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: EvSpace.gutter),
          child: EvButton('Sign out', kind: EvButtonKind.secondary, icon: LucideIcons.logOut, expand: true, onPressed: () async {
            if (await confirmAction(context, title: 'Sign out?', body: 'You can sign back in any time with your email and password.', confirm: 'Sign out')) {
              await ref.read(backendProvider).auth.signOut();
            }
          }),
        ),
        const SizedBox(height: EvSpace.x2),
        if (session != null)
          Center(child: Text('Signed in as ${session.fullName.isEmpty ? 'you' : session.fullName}', style: EvType.caption)),
        const SizedBox(height: EvSpace.x6),
        const Center(child: EvendaLogo(size: 18)),
        const SizedBox(height: 4),
        Center(child: Text('by DanTech Solutions Group', style: EvType.caption)),
      ]),
    );
  }
}

class _HeadStat extends StatelessWidget {
  const _HeadStat(this.label, this.value, this.sub, this.color);
  final String label;
  final String value;
  final String sub;
  final Color color;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(value, style: EvType.number.copyWith(fontSize: 19, color: color))),
        Text(label, style: EvType.caption.copyWith(color: EvColors.sand)),
        Text(sub, style: EvType.caption.copyWith(color: EvColors.sand, fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
      ]);
}

/// Row end: a count pill when something needs doing, otherwise a chevron.
class _Trail extends StatelessWidget {
  const _Trail({this.count = 0, this.tone = Tone.neutral, this.label = ''});
  final int count;
  final Tone tone;
  final String label;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        if (count > 0) ...[StatusPill('$count $label', tone: tone, dense: true), const SizedBox(width: 4)],
        const Icon(LucideIcons.chevronRight, size: 18, color: EvColors.ink3),
      ]);
}
