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

    // This month as a supplier (rules in SupplierMonth: Lusaka month, confirmed
    // non-voided payments, each booking counted at most to its own total).
    final month = SupplierMonth.of(hub?.$2 ?? const <Booking>[], biz.id);
    final quoted = (hub?.$3 ?? const <QuoteRequest>[]).where((q) => q.supplier.id == biz.id && q.quotations.isNotEmpty).toList();
    final won = quoted.where((q) => q.status == QuoteRequestStatus.accepted).length;

    final stock = listings.where((l) => l.kind == OfferingType.rental && l.tracksStock && l.status != ListingStatus.archived).toList();
    final attention = stock.where((l) => l.inspectionQuantity > 0 || l.damagedQuantity > 0).length;

    // Plain grouped list: white surface, hairline dividers, no icon tiles.
    Widget group(List<Widget> rows) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: EvSpace.gutter),
          child: EvSurface(
            padding: EdgeInsets.zero,
            child: Column(children: [
              for (final (i, r) in rows.indexed) ...[if (i > 0) const EvDivider(indent: EvSpace.x4), r],
            ]),
          ),
        );

    final verifiedText = switch (biz.verification) {
      VerificationStatus.verified => 'Verified',
      VerificationStatus.pending => 'Verification in review',
      VerificationStatus.rejected => 'Verification needs new documents',
      VerificationStatus.unverified => 'Not verified',
    };

    return Scaffold(
      appBar: const TabHeader(title: 'Business'),
      body: ListView(padding: const EdgeInsets.only(bottom: EvSpace.x10), children: [
        // Who you are: compact, on the page.
        InkWell(
          onTap: () => context.push('/business/profile'),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x2, EvSpace.gutter, EvSpace.x2),
            child: Row(children: [
              BusinessAvatar(name: biz.name, logoUrl: biz.logoUrl, size: 56, verified: biz.verified),
              const SizedBox(width: EvSpace.x3),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(biz.name, style: EvType.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text([categoryById(biz.primaryCategory).name, if (biz.neighbourhood != null) biz.neighbourhood!].join(' · '),
                      style: EvType.small, maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Row(children: [
                    if (biz.verified) const Padding(padding: EdgeInsets.only(right: 4), child: Icon(LucideIcons.badgeCheck, size: 14, color: EvColors.forest)),
                    Text(verifiedText, style: EvType.caption.copyWith(color: biz.verified ? EvColors.forest : EvColors.ink3, fontWeight: FontWeight.w600)),
                  ]),
                ]),
              ),
              const Icon(LucideIcons.chevronRight, size: 18, color: EvColors.ink3),
            ]),
          ),
        ),
        if (!biz.verified && biz.verification != VerificationStatus.pending)
          InkWell(
            onTap: () => context.push('/business/profile'),
            child: Padding(
            padding: const EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x1, EvSpace.gutter, EvSpace.x1),
            child: Text.rich(
              TextSpan(style: EvType.small, children: [
                const TextSpan(text: 'Get the verified badge: '),
                TextSpan(
                  text: 'upload your PACRA or TPIN',
                  style: EvType.small.copyWith(color: EvColors.forest, fontWeight: FontWeight.w600),
                ),
              ]),
            ),
            ),
          ),

        const SectionHeader('This month'),
        EvStatRow(stats: [
          EvStat('Booked · ${plural(month.bookings.length, 'booking')}', Money.k(month.booked)),
          EvStat(month.collectedPercent == null ? 'Paid' : 'Paid · ${month.collectedPercent}%', Money.k(month.paid), highlight: month.paid > 0),
          EvStat('Quotes won', quoted.isEmpty ? '—' : '$won/${quoted.length}'),
        ]),
        // Never hide an inconsistency inside a capped figure: name it.
        for (final b in month.overpaid)
          InkWell(
            onTap: () => context.push('/bookings/${b.id}'),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x3, EvSpace.gutter, 0),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(LucideIcons.triangleAlert, size: 16, color: EvColors.danger),
                const SizedBox(width: 6),
                Expanded(
                  child: Text('${b.reference}: ${Money.k(b.confirmedPaid)} confirmed against a ${Money.k(b.total)} booking. Check the payment record →',
                      style: EvType.small.copyWith(color: EvColors.danger)),
                ),
              ]),
            ),
          ),

        const SectionHeader('Stock & marketplace'),
        group([
          if (biz.rents)
            EvRow(
              title: 'My stock',
              subtitle: stock.isEmpty ? 'Count what you own' : '${plural(stock.length, 'item')} · ${stock.fold<int>(0, (s, l) => s + l.totalQuantity)} units',
              trailing: _Trail(note: attention > 0 ? '$attention to check' : null, alert: true),
              onTap: () => context.push('/business/inventory'),
            ),
          EvRow(
            title: 'On the marketplace',
            subtitle: '$published live',
            trailing: _Trail(note: drafts > 0 ? '$drafts not listed' : null),
            onTap: () => context.push('/business/listings'),
          ),
          EvRow(
            title: 'Availability & jobs',
            subtitle: 'Closed dates, jobs booked outside Evenda',
            trailing: const _Trail(),
            onTap: () => context.push('/business/availability'),
          ),
        ]),

        const SectionHeader('Your business'),
        group([
          EvRow(title: 'Business profile', subtitle: 'Logo, contacts, location, hours', trailing: const _Trail(), onTap: () => context.push('/business/profile')),
          EvRow(title: 'Team', subtitle: 'Who can quote, book and manage stock', trailing: const _Trail(), onTap: () => context.push('/business/team')),
          EvRow(title: 'Notifications', subtitle: 'Supplier updates, reminders, quiet hours', trailing: const _Trail(), onTap: () => context.push('/business/notifications')),
          EvRow(title: 'Account & privacy', subtitle: 'Your data and account options', trailing: const _Trail(), onTap: () => context.push('/business/account')),
        ]),

        // Sign out on its own, far from anything destructive.
        const SizedBox(height: EvSpace.x8),
        Center(
          child: TextButton.icon(
            onPressed: () async {
              if (await confirmAction(context, title: 'Sign out?', body: 'You can sign back in any time with your email and password.', confirm: 'Sign out')) {
                await ref.read(backendProvider).auth.signOut();
              }
            },
            icon: const Icon(LucideIcons.logOut, size: 18),
            label: const Text('Sign out'),
          ),
        ),
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

/// Row end: a short note when something needs doing, then a chevron.
class _Trail extends StatelessWidget {
  const _Trail({this.note, this.alert = false});
  final String? note;
  final bool alert;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        if (note != null) ...[
          Text(note!, style: EvType.caption.copyWith(color: alert ? EvColors.warning : EvColors.ink2, fontWeight: FontWeight.w600)),
          const SizedBox(width: 4),
        ],
        const Icon(LucideIcons.chevronRight, size: 18, color: EvColors.ink3),
      ]);
}
