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
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: EvSpace.gutter),
          child: EvSurface(
            onTap: () => context.push('/business/profile'),
            child: Row(children: [
              BusinessAvatar(name: biz.name, logoUrl: biz.logoUrl, size: 56, verified: biz.verified),
              const SizedBox(width: EvSpace.x4),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(biz.name, style: EvType.headline),
                  const SizedBox(height: 2),
                  Text([categoryById(biz.primaryCategory).name, if (biz.neighbourhood != null) biz.neighbourhood!].join(' · '), style: EvType.small),
                  const SizedBox(height: 6),
                  StatusPill(biz.verification.label, tone: toneForVerification(biz.verification), dense: true),
                ]),
              ),
              const Icon(LucideIcons.chevronRight, color: EvColors.ink3),
            ]),
          ),
        ),

        const SectionHeader('This month'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: EvSpace.gutter),
          child: Row(children: [
            _Stat(label: 'Booked as supplier', value: Money.k(value), sub: plural(asSupplier.length, 'booking')),
            const SizedBox(width: 8),
            _Stat(label: 'Payments confirmed', value: Money.k(collected), sub: value == 0 ? '—' : '${(collected / value * 100).round()}% of booked'),
            const SizedBox(width: 8),
            _Stat(label: 'Quotes won', value: quoted.isEmpty ? '—' : '$won/${quoted.length}', sub: 'all time'),
          ]),
        ),

        const SectionHeader('Catalogue'),
        group([
          EvRow(
            leading: const IconTile(LucideIcons.layoutGrid, tone: Tone.positive),
            title: 'Listings',
            subtitle: '$published published${drafts > 0 ? ' · $drafts draft${drafts == 1 ? '' : 's'}' : ''}',
            onTap: () => context.push('/business/listings'),
          ),
          if (biz.rents)
            EvRow(
              leading: const IconTile(LucideIcons.boxes, tone: Tone.positive),
              title: 'Inventory',
              subtitle: 'Stock, damage, returns awaiting inspection',
              onTap: () => context.push('/business/inventory'),
            ),
          EvRow(
            leading: const IconTile(LucideIcons.calendarRange, tone: Tone.positive),
            title: 'Availability & jobs',
            subtitle: 'Calendar, closed dates, jobs booked outside Evenda',
            onTap: () => context.push('/business/availability'),
          ),
        ]),

        const SectionHeader('Team & settings'),
        group([
          EvRow(leading: const IconTile(LucideIcons.users), title: 'Team', subtitle: 'Who can quote, book and manage stock', onTap: () => context.push('/business/team')),
          EvRow(
            leading: const IconTile(LucideIcons.bellRing),
            title: 'Notifications & supplier updates',
            subtitle: 'Categories, followed suppliers, quiet hours',
            onTap: () => context.push('/business/notifications'),
          ),
          EvRow(leading: const IconTile(LucideIcons.store), title: 'Business profile', subtitle: 'Contact, location, hours, verification', onTap: () => context.push('/business/profile')),
        ]),

        const SizedBox(height: EvSpace.x6),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: EvSpace.gutter),
          child: Column(children: [
            if (session != null) Text('Signed in as ${session.fullName.isEmpty ? 'you' : session.fullName}${session.phone != null ? ' · ${ZambianPhone.display(session.phone)}' : ''}', style: EvType.caption),
            const SizedBox(height: EvSpace.x2),
            EvButton('Sign out', kind: EvButtonKind.quiet, icon: LucideIcons.logOut, onPressed: () async {
              if (await confirmAction(context, title: 'Sign out?', body: 'You’ll need your phone to sign back in.', confirm: 'Sign out')) {
                await ref.read(backendProvider).auth.signOut();
              }
            }),
            const SizedBox(height: EvSpace.x4),
            const EvendaLogo(size: 18),
            const SizedBox(height: 4),
            Text('by DanTech Solutions Group', style: EvType.caption),
          ]),
        ),
      ]),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, required this.sub});
  final String label;
  final String value;
  final String sub;

  @override
  Widget build(BuildContext context) => Expanded(
        child: EvSurface(
          padding: const EdgeInsets.all(EvSpace.x3),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: EvType.caption, maxLines: 2),
            const SizedBox(height: 6),
            FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(value, style: EvType.number.copyWith(fontSize: 19))),
            Text(sub, style: EvType.caption, maxLines: 1, overflow: TextOverflow.ellipsis),
          ]),
        ),
      );
}
