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

enum _Section {
  overview('Overview', LucideIcons.layoutDashboard, 'activity.read'),
  businesses('Businesses', LucideIcons.store, 'business.read'),
  listings('Listings', LucideIcons.layoutGrid, 'listing.moderate'),
  now('Evenda Now', LucideIcons.zap, 'now.read'),
  bookings('Bookings & payments', LucideIcons.handshake, 'booking.read'),
  disputes('Disputes', LucideIcons.gavel, 'dispute.manage'),
  categories('Categories', LucideIcons.tags, 'category.manage'),
  audit('Audit log', LucideIcons.scrollText, 'audit.read');

  const _Section(this.label, this.icon, this.permission);
  final String label;
  final IconData icon;
  final String permission;
}

FutureProvider<T> _adminQuery<T>(Future<T> Function(AdminApi a) f) => FutureProvider.autoDispose<T>((ref) async {
      ref.watchDomains(const [DataDomain.admin, DataDomain.listings, DataDomain.business, DataDomain.bookings, DataDomain.now]);
      return f(ref.watch(backendProvider).admin);
    });

final _statsProvider = _adminQuery((a) => a.stats());
final _nowProvider = _adminQuery((a) => a.nowRequests());
final _bookingsProvider = _adminQuery((a) => a.recentBookings());
final _disputesProvider = _adminQuery((a) => a.disputes());
final _auditProvider = _adminQuery((a) => a.auditLog());

/// Admin console. Sections the role can't use are hidden, and the server
/// rejects anything the UI shouldn't offer anyway.
class AdminConsoleScreen extends ConsumerStatefulWidget {
  const AdminConsoleScreen({super.key});
  @override
  ConsumerState<AdminConsoleScreen> createState() => _AdminConsoleScreenState();
}

class _AdminConsoleScreenState extends ConsumerState<AdminConsoleScreen> {
  _Section _s = _Section.overview;

  @override
  Widget build(BuildContext context) {
    final restoring = ref.watch(adminSessionProvider);
    final session = restoring.value ?? ref.watch(backendProvider).admin.current;
    if (session == null && restoring.isLoading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (session == null) {
      return Scaffold(
        appBar: AppBar(),
        body: EmptyState(mascot: Mascot.coordinator, title: 'Sign in required', body: 'Admin access needs a staff account.', action: 'Admin sign-in',
            onAction: () => context.pushReplacement('/admin/login')),
      );
    }
    final sections = _Section.values.where((s) => session.role.can(s.permission)).toList();
    if (!sections.contains(_s)) _s = sections.first;
    final wide = MediaQuery.sizeOf(context).width >= EvBreakpoints.tablet;

    final content = AnimatedSwitcher(
      duration: EvMotion.of(context, EvMotion.fast),
      child: KeyedSubtree(key: ValueKey(_s), child: _body(_s, session.role)),
    );

    final header = AppBar(
      backgroundColor: EvColors.cream,
      // Left-aligned: centred, the title only had the gap between the menu
      // button and the role badge.
      centerTitle: false,
      titleSpacing: 0,
      // Long section names ("Bookings & payments") ran into the role badge.
      title: Text(_s.label, maxLines: 1, overflow: TextOverflow.ellipsis),
      actions: [
        // On phones the role badge lives in the drawer, so long section
        // titles ("Bookings & payments") fit.
        if (wide)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Center(child: StatusPill(session.role.label, tone: Tone.progress, icon: LucideIcons.shieldCheck, dense: true)),
          ),
        IconButton(
          tooltip: 'Sign out',
          icon: const Icon(LucideIcons.logOut),
          onPressed: () async {
            await ref.read(backendProvider).admin.signOut();
            if (context.mounted) context.go('/welcome');
          },
        ),
      ],
    );

    if (wide) {
      return Scaffold(
        body: Row(children: [
          NavigationRail(
            backgroundColor: EvColors.forest,
            extended: MediaQuery.sizeOf(context).width >= EvBreakpoints.desktop,
            selectedIndex: sections.indexOf(_s),
            onDestinationSelected: (i) => setState(() => _s = sections[i]),
            indicatorColor: EvColors.forestSoft,
            leading: const Padding(padding: EdgeInsets.symmetric(vertical: EvSpace.x5), child: EvendaMark(size: 34, onDark: true)),
            selectedIconTheme: const IconThemeData(color: EvColors.inkOnDark),
            unselectedIconTheme: const IconThemeData(color: EvColors.sand),
            selectedLabelTextStyle: EvType.smallStrong.copyWith(color: EvColors.inkOnDark),
            unselectedLabelTextStyle: EvType.small.copyWith(color: EvColors.sand),
            destinations: [for (final s in sections) NavigationRailDestination(icon: Icon(s.icon), label: Text(s.label))],
          ),
          Expanded(child: Scaffold(appBar: header, body: content)),
        ]),
      );
    }
    return Scaffold(
      appBar: header,
      drawer: Drawer(
        backgroundColor: EvColors.warmWhite,
        child: SafeArea(
          child: ListView(children: [
            Padding(
              padding: const EdgeInsets.all(EvSpace.gutter),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const EvendaLogo(size: 26),
                const SizedBox(height: EvSpace.x3),
                StatusPill(session.role.label, tone: Tone.progress, icon: LucideIcons.shieldCheck, dense: true),
              ]),
            ),
            for (final s in sections)
              ListTile(
                leading: Icon(s.icon, color: s == _s ? EvColors.forest : EvColors.ink2),
                title: Text(s.label, style: s == _s ? EvType.bodyStrong.copyWith(color: EvColors.forest) : EvType.body),
                selected: s == _s,
                selectedTileColor: EvColors.forestTint,
                onTap: () {
                  setState(() => _s = s);
                  Navigator.pop(context);
                },
              ),
          ]),
        ),
      ),
      body: content,
    );
  }

  Widget _body(_Section s, AdminRole role) => switch (s) {
        _Section.overview => _Overview(onOpen: (x) => setState(() => _s = x), role: role),
        _Section.businesses => const _Businesses(),
        _Section.listings => const _Listings(),
        _Section.now => const _NowMonitor(),
        _Section.bookings => _Bookings(showPayments: role.can('payment.read')),
        _Section.disputes => const _Disputes(),
        _Section.categories => const _Categories(),
        _Section.audit => const _Audit(),
      };
}

class _Overview extends ConsumerWidget {
  const _Overview({required this.onOpen, required this.role});
  final ValueChanged<_Section> onOpen;
  final AdminRole role;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(_statsProvider);
    return AsyncView(
      value: stats,
      onRetry: () => ref.invalidate(_statsProvider),
      data: (m) {
        // Two columns on a phone, more on wider screens (a fixed 180 px left
        // half of a phone screen empty). Measured, so the tablet rail counts.
        return LayoutBuilder(builder: (context, box) {
        final avail = box.maxWidth - 2 * EvSpace.gutter;
        final cols = ((avail + 10) / 190).floor().clamp(2, 6);
        final tileWidth = (avail - 10 * (cols - 1)) / cols;
        Widget tile(String label, int v, {Tone tone = Tone.neutral, _Section? open}) => SizedBox(
              width: tileWidth,
              child: EvSurface(
                onTap: open != null && role.can(open.permission) ? () => onOpen(open) : null,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(label, style: EvType.caption, maxLines: 2, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 6),
                  EvAnimatedCount(value: v, style: EvType.number.copyWith(color: tone == Tone.neutral ? EvColors.ink : tone.fg)),
                ]),
              ),
            );
        return ListView(padding: const EdgeInsets.all(EvSpace.gutter), children: [
          Text('NEEDS ATTENTION', style: EvType.overline),
          const SizedBox(height: EvSpace.x2),
          Wrap(spacing: 10, runSpacing: 10, children: [
            tile('Verification requests', m['pending_verification'] ?? 0, tone: (m['pending_verification'] ?? 0) > 0 ? Tone.waiting : Tone.neutral, open: _Section.businesses),
            tile('Flagged listings', m['flagged_listings'] ?? 0, tone: (m['flagged_listings'] ?? 0) > 0 ? Tone.attention : Tone.neutral, open: _Section.listings),
            tile('Open disputes', m['open_disputes'] ?? 0, tone: (m['open_disputes'] ?? 0) > 0 ? Tone.critical : Tone.neutral, open: _Section.disputes),
            tile('Failed pushes (24 h)', m['push_failed_24h'] ?? 0, tone: (m['push_failed_24h'] ?? 0) > 0 ? Tone.attention : Tone.neutral),
          ]),
          const SizedBox(height: EvSpace.x6),
          Text('PLATFORM', style: EvType.overline),
          const SizedBox(height: EvSpace.x2),
          Wrap(spacing: 10, runSpacing: 10, children: [
            tile('Active businesses', m['businesses'] ?? 0, open: _Section.businesses),
            tile('Published listings', m['published_listings'] ?? 0, open: _Section.listings),
            tile('Open quote requests', m['open_quote_requests'] ?? 0),
            tile('Bookings (30 days)', m['bookings_30d'] ?? 0, open: _Section.bookings),
            tile('Live Evenda Now', m['now_open'] ?? 0, tone: Tone.progress, open: _Section.now),
          ]),
        ]);
        });
      },
    );
  }
}

class _Businesses extends ConsumerStatefulWidget {
  const _Businesses();
  @override
  ConsumerState<_Businesses> createState() => _BusinessesState();
}

class _BusinessesState extends ConsumerState<_Businesses> {
  VerificationStatus? _filter = VerificationStatus.pending;
  String _search = '';

  @override
  Widget build(BuildContext context) {
    ref.watch(revisionProvider.select((m) => m[DataDomain.admin]));
    final api = ref.read(backendProvider).admin;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x2, EvSpace.gutter, EvSpace.x2),
        child: TextField(
          onChanged: (v) => setState(() => _search = v),
          decoration: const InputDecoration(hintText: 'Search businesses', prefixIcon: Icon(LucideIcons.search, size: 18)),
        ),
      ),
      EvSegmented<VerificationStatus?>(
        value: _filter,
        onChanged: (v) => setState(() => _filter = v),
        segments: const [(VerificationStatus.pending, 'Pending'), (null, 'All'), (VerificationStatus.verified, 'Verified'), (VerificationStatus.unverified, 'Unverified'), (VerificationStatus.rejected, 'Rejected')],
      ),
      const SizedBox(height: EvSpace.x2),
      Expanded(
        child: FutureBuilder<List<AdminBusinessRow>>(
          future: api.businesses(search: _search, verification: _filter),
          builder: (c, snap) {
            if (snap.hasError) return ErrorState(error: snap.error!, onRetry: () => setState(() {}));
            if (!snap.hasData) return const Skeleton();
            final rows = snap.data!;
            if (rows.isEmpty) return const EmptyState(title: 'No businesses', compact: true);
            return ListView.separated(
              itemCount: rows.length,
              separatorBuilder: (_, _) => const EvDivider(indent: 72),
              itemBuilder: (c, i) {
                final b = rows[i];
                return EvRow(
                  leading: BusinessAvatar(name: b.name, verified: b.verification == VerificationStatus.verified),
                  title: b.name,
                  subtitle: '${categoryById(b.primaryCategory).name} · ${b.neighbourhood ?? '—'} · ${b.listings} listings · ${b.documents} documents',
                  meta: Row(children: [
                    StatusPill(b.verification.label, tone: toneForVerification(b.verification), dense: true),
                    if (b.status == BusinessStatus.suspended) ...[const SizedBox(width: 6), const StatusPill('Suspended', tone: Tone.critical, dense: true)],
                  ]),
                  // Decisions happen on the review screen, after the documents
                  // have been opened; the list no longer offers blind verify.
                  trailing: const Icon(LucideIcons.chevronRight, size: 18, color: EvColors.ink3),
                  onTap: () async {
                    await context.push('/admin/business/${b.id}');
                    if (mounted) setState(() {});
                  },
                );
              },
            );
          },
        ),
      ),
    ]);
  }
}

class _Listings extends ConsumerStatefulWidget {
  const _Listings();
  @override
  ConsumerState<_Listings> createState() => _ListingsState();
}

class _ListingsState extends ConsumerState<_Listings> {
  ModerationStatus? _filter;

  @override
  Widget build(BuildContext context) {
    ref.watch(revisionProvider.select((m) => m[DataDomain.admin]));
    final api = ref.read(backendProvider).admin;
    return Column(children: [
      const SizedBox(height: EvSpace.x2),
      EvSegmented<ModerationStatus?>(
        value: _filter,
        onChanged: (v) => setState(() => _filter = v),
        segments: const [(null, 'All published'), (ModerationStatus.flagged, 'Flagged'), (ModerationStatus.removed, 'Removed')],
      ),
      const SizedBox(height: EvSpace.x2),
      Expanded(
        child: FutureBuilder<List<Listing>>(
          future: api.listingsForReview(status: _filter),
          builder: (c, snap) {
            if (snap.hasError) return ErrorState(error: snap.error!, onRetry: () => setState(() {}));
            if (!snap.hasData) return const Skeleton(media: true);
            final list = snap.data!;
            if (list.isEmpty) return const EmptyState(title: 'Nothing to review', compact: true);
            return ListView.separated(
              itemCount: list.length,
              separatorBuilder: (_, _) => const EvDivider(indent: 92),
              itemBuilder: (c, i) {
                final l = list[i];
                return EvRow(
                  leading: EvPhoto(l.coverPhoto, width: 56, height: 56, radius: EvRadius.sm),
                  title: l.title,
                  subtitle: '${l.business?.name ?? ''} · ${priceLabel(l)}',
                  meta: l.moderation == ModerationStatus.ok ? null : StatusPill(l.moderation.name, tone: Tone.critical, dense: true),
                  // See what you are moderating: photos, description, terms.
                  onTap: () => _previewListing(context, l),
                  trailing: PopupMenuButton<ModerationStatus>(
                    icon: const Icon(LucideIcons.ellipsisVertical, size: 18),
                    onSelected: (st) async {
                      final reason = await confirmWithReason(context,
                          title: switch (st) { ModerationStatus.ok => 'Restore listing?', ModerationStatus.flagged => 'Flag listing?', ModerationStatus.removed => 'Remove listing?' },
                          body: 'The vendor is told the reason. This is recorded in the audit log.',
                          required: st != ModerationStatus.ok,
                          destructive: st == ModerationStatus.removed);
                      if (reason != null && context.mounted) {
                        await guard(context, () => api.moderateListing(l.id, st, reason), success: 'Moderation recorded');
                        setState(() {});
                      }
                    },
                    itemBuilder: (_) => [
                      if (l.moderation != ModerationStatus.ok) const PopupMenuItem(value: ModerationStatus.ok, child: Text('Restore')),
                      if (l.moderation != ModerationStatus.flagged) const PopupMenuItem(value: ModerationStatus.flagged, child: Text('Flag for review')),
                      if (l.moderation != ModerationStatus.removed) const PopupMenuItem(value: ModerationStatus.removed, child: Text('Remove from Evenda')),
                    ],
                  ),
                );
              },
            );
          },
        ),
      ),
    ]);
  }
}

class _NowMonitor extends ConsumerWidget {
  const _NowMonitor();
  @override
  Widget build(BuildContext context, WidgetRef ref) => AsyncView(
        value: ref.watch(_nowProvider),
        onRetry: () => ref.invalidate(_nowProvider),
        isEmpty: (l) => l.isEmpty,
        empty: const EmptyState(mascot: Mascot.pin, title: 'No Evenda Now requests yet', compact: true),
        data: (list) => ListView.separated(
          itemCount: list.length,
          separatorBuilder: (_, _) => const EvDivider(indent: 68),
          itemBuilder: (c, i) {
            final r = list[i];
            return EvRow(
              leading: IconTile(categoryIcon(r.categoryId), tone: r.status.live ? Tone.progress : Tone.neutral),
              title: '${r.quantity} × ${r.itemDescription}',
              subtitle: '${r.requester.name} · ${EvDates.day(r.neededFrom)} · ${r.radiusKm} km · ${plural(r.recipientsCount, 'recipient')}',
              trailing: StatusPill(r.status.label, tone: toneForNow(r.status), dense: true),
            );
          },
        ),
      );
}

class _Bookings extends ConsumerWidget {
  const _Bookings({required this.showPayments});
  final bool showPayments;
  @override
  Widget build(BuildContext context, WidgetRef ref) => AsyncView(
        value: ref.watch(_bookingsProvider),
        onRetry: () => ref.invalidate(_bookingsProvider),
        isEmpty: (l) => l.isEmpty,
        empty: const EmptyState(title: 'No bookings yet', compact: true),
        data: (list) => ListView.separated(
          itemCount: list.length,
          separatorBuilder: (_, _) => const EvDivider(indent: EvSpace.gutter),
          itemBuilder: (c, i) {
            final b = list[i];
            return ExpansionTile(
              tilePadding: const EdgeInsets.symmetric(horizontal: EvSpace.gutter),
              shape: const Border(),
              title: Text('${b.reference} · ${b.supplier.name}', style: EvType.bodyStrong),
              subtitle: Text('Hired by ${b.requester.name} · ${EvDates.range(b.startsOn, b.endsOn)} · ${Money.k(b.total)}', style: EvType.small),
              trailing: StatusPill(b.status.label, tone: toneForBooking(b.status), dense: true),
              children: [
                if (showPayments)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(EvSpace.gutter, 0, EvSpace.gutter, EvSpace.x3),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [StatusPill(b.paymentStatus.label, tone: toneForPayment(b.paymentStatus), dense: true), const SizedBox(width: 8), Text('${Money.k(b.confirmedPaid)} confirmed', style: EvType.small)]),
                      for (final p in b.payments)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text('${Money.k(p.amount)} ${p.kind} · ${p.methodLabel}${p.reference != null ? ' · ${p.reference}' : ''} · ${p.confirmedAt != null ? 'confirmed' : 'unconfirmed'}',
                              style: EvType.caption),
                        ),
                      if (b.payments.isEmpty) Text('No payment records.', style: EvType.caption),
                    ]),
                  )
                else
                  Padding(padding: const EdgeInsets.all(EvSpace.gutter), child: Text('Payment records need the finance role.', style: EvType.caption)),
              ],
            );
          },
        ),
      );
}

class _Disputes extends ConsumerWidget {
  const _Disputes();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.read(backendProvider).admin;
    return AsyncView(
      value: ref.watch(_disputesProvider),
      onRetry: () => ref.invalidate(_disputesProvider),
      isEmpty: (l) => l.isEmpty,
      empty: const EmptyState(mascot: Mascot.chair, title: 'No disputes', body: 'Disputes opened from bookings appear here.', compact: true),
      data: (list) => ListView.separated(
        itemCount: list.length,
        separatorBuilder: (_, _) => const EvDivider(indent: EvSpace.gutter),
        itemBuilder: (c, i) {
          final d = list[i];
          final open = d.status == 'open' || d.status == 'investigating';
          return EvRow(
            title: '${d.bookingReference ?? 'Booking'} · opened by ${d.openedBy ?? '—'}',
            subtitle: d.resolution != null ? '${d.reason}\nResolution: ${d.resolution}' : d.reason,
            meta: StatusPill(d.status, tone: open ? Tone.critical : Tone.neutral, dense: true),
            trailing: open
                ? PopupMenuButton<String>(
                    icon: const Icon(LucideIcons.ellipsisVertical, size: 18),
                    onSelected: (st) async {
                      final reason = await confirmWithReason(context, title: st == 'investigating' ? 'Start investigating' : 'Close dispute', body: 'Record what was decided and why.');
                      if (reason != null && context.mounted) await guard(context, () => api.resolveDispute(d.id, st, reason), success: 'Dispute updated');
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'investigating', child: Text('Mark investigating')),
                      PopupMenuItem(value: 'resolved', child: Text('Resolve')),
                      PopupMenuItem(value: 'dismissed', child: Text('Dismiss')),
                    ],
                  )
                : null,
          );
        },
      ),
    );
  }
}

final _categoryAdminProvider = FutureProvider.autoDispose<(List<Category>, Map<String, ({int listings, int businesses})>)>((ref) async {
  ref.watchDomains(const [DataDomain.admin]);
  final backend = ref.watch(backendProvider);
  final all = await backend.discovery.categories();
  CategoryCatalog.apply(all);
  final usage = await backend.admin.categoryUsage();
  return (all, usage);
});

/// Category catalogue. Categories drive what vendors can list, search and
/// subscribe to, so each card shows real usage before anyone edits it.
class _Categories extends ConsumerWidget {
  const _Categories();

  @override
  Widget build(BuildContext context, WidgetRef ref) => AsyncView(
        value: ref.watch(_categoryAdminProvider),
        onRetry: () => ref.invalidate(_categoryAdminProvider),
        data: (data) {
          final (all, usage) = data;
          final active = all.where((c) => c.active).length;
          final listings = usage.values.fold<int>(0, (s, u) => s + u.listings);
          final unused = all.where((c) => c.active && (usage[c.id]?.businesses ?? 0) == 0 && (usage[c.id]?.listings ?? 0) == 0).length;
          final groups = [
            (OfferingType.rental, 'Equipment & rentals', LucideIcons.package),
            (OfferingType.service, 'Services', LucideIcons.handHelping),
            (OfferingType.package, 'Packages', LucideIcons.boxes),
          ];
          void edit(Category? c) => _editCategory(context, ref, c, all);

          return ListView(padding: const EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x2, EvSpace.gutter, EvSpace.x10), children: [
            // Summary
            Row(children: [
              Expanded(child: _MiniStat('Live', '$active', of: '${all.length}')),
              const SizedBox(width: 8),
              Expanded(child: _MiniStat('Listings', '$listings')),
              const SizedBox(width: 8),
              Expanded(child: _MiniStat('Unused', '$unused', tone: unused > 0 ? Tone.waiting : Tone.neutral)),
            ]),
            const SizedBox(height: EvSpace.x3),
            EvButton('New category', icon: LucideIcons.plus, expand: true, onPressed: () => edit(null)),
            const SizedBox(height: EvSpace.x2),
            Text('Vendors pick from these when they list stock, search and subscribe to supplier updates. Hidden categories disappear from pickers; existing listings keep them.',
                style: EvType.caption),
            for (final (kind, title, icon) in groups)
              if (all.any((c) => c.kind == kind)) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(0, EvSpace.x6, 0, EvSpace.x2),
                  child: Row(children: [
                    Icon(icon, size: 16, color: EvColors.forest),
                    const SizedBox(width: 6),
                    Text(title.toUpperCase(), style: EvType.overline.copyWith(color: EvColors.forest)),
                    const SizedBox(width: 6),
                    Text('${all.where((c) => c.kind == kind && c.active).length}', style: EvType.overline.copyWith(color: EvColors.bronze)),
                  ]),
                ),
                for (final c in all.where((c) => c.kind == kind)) ...[
                  _CategoryCard(category: c, usage: usage[c.id], onTap: () => edit(c)),
                  const SizedBox(height: 8),
                ],
              ],
          ]);
        },
      );
}

class _MiniStat extends StatelessWidget {
  const _MiniStat(this.label, this.value, {this.of, this.tone = Tone.neutral});
  final String label;
  final String value;
  final String? of;
  final Tone tone;

  @override
  Widget build(BuildContext context) => EvSurface(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: EvType.caption),
          Text.rich(TextSpan(children: [
            TextSpan(text: value, style: EvType.number.copyWith(color: tone == Tone.neutral ? EvColors.ink : tone.fg)),
            if (of != null) TextSpan(text: ' / $of', style: EvType.small),
          ])),
        ]),
      );
}

class _CategoryCard extends StatelessWidget {
  const _CategoryCard({required this.category, required this.usage, required this.onTap});
  final Category category;
  final ({int listings, int businesses})? usage;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = category;
    final l = usage?.listings ?? 0, b = usage?.businesses ?? 0;
    return Opacity(
      opacity: c.active ? 1 : 0.6,
      child: EvSurface(
        onTap: onTap,
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: c.active ? (c.kind == OfferingType.service ? EvColors.bronzeTint : EvColors.forestTint) : EvColors.neutralTint,
              borderRadius: EvRadius.mdAll,
            ),
            child: Icon(iconForCategoryKey(c.icon), size: 22, color: c.active ? (c.kind == OfferingType.service ? EvColors.bronzeDeep : EvColors.forest) : EvColors.ink3),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(c.name, style: EvType.bodyStrong, maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Text(
                l == 0 && b == 0 ? 'Not used yet' : '$l listing${l == 1 ? '' : 's'} · $b business${b == 1 ? '' : 'es'}',
                style: EvType.small.copyWith(color: l == 0 && b == 0 ? EvColors.ink3 : EvColors.ink2),
              ),
            ]),
          ),
          if (!c.active) const StatusPill('Hidden', tone: Tone.neutral, dense: true, icon: LucideIcons.eyeOff),
          const SizedBox(width: 4),
          const Icon(LucideIcons.chevronRight, size: 18, color: EvColors.ink3),
        ]),
      ),
    );
  }
}

Future<void> _editCategory(BuildContext context, WidgetRef ref, Category? existing, List<Category> all) async {
  final saved = await showEvSheet<bool>(
    context,
    title: existing == null ? 'New category' : 'Edit category',
    subtitle: existing == null ? 'Vendors can use it as soon as you save.' : 'Changes apply to every vendor straight away.',
    builder: (c) => _CategoryEditor(existing: existing, all: all),
  );
  if (saved == true) {
    ref.invalidate(_categoryAdminProvider);
    ref.invalidate(categoryCatalogProvider);
  }
}

class _CategoryEditor extends ConsumerStatefulWidget {
  const _CategoryEditor({required this.existing, required this.all});
  final Category? existing;
  final List<Category> all;

  @override
  ConsumerState<_CategoryEditor> createState() => _CategoryEditorState();
}

class _CategoryEditorState extends ConsumerState<_CategoryEditor> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  final _reason = TextEditingController();
  late OfferingType _kind = widget.existing?.kind ?? OfferingType.rental;
  late String _icon = widget.existing?.icon ?? 'package';
  late bool _active = widget.existing?.active ?? true;
  bool _busy = false;

  bool get _isNew => widget.existing == null;
  bool get _hiding => !_isNew && widget.existing!.active && !_active;

  String _slug(String name) => name.toLowerCase().replaceAll('&', 'and').replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');

  @override
  void dispose() {
    _name.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final id = widget.existing?.id ?? _slug(_name.text);
    if (_isNew && widget.all.any((c) => c.id == id)) {
      showToast(context, 'A category with this name already exists.', icon: LucideIcons.circleAlert);
      return;
    }
    final sort = widget.existing?.sort ?? (widget.all.fold<int>(0, (m, c) => c.sort > m ? c.sort : m) + 10);
    setState(() => _busy = true);
    final ok = await guard(context, () async {
      await ref.read(backendProvider).admin.upsertCategory(
            Category(id, _name.text.trim(), _kind, _icon, active: _active, sort: sort),
            _active,
            _reason.text.trim().isEmpty ? (_isNew ? 'New category' : 'Updated') : _reason.text.trim(),
          );
      return true;
    }, success: 'Saved and recorded in the audit log');
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok == true) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(EvSpace.gutter, 0, EvSpace.gutter, EvSpace.x6 + MediaQuery.viewInsetsOf(context).bottom),
      child: Form(
        key: _form,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // Live preview of how vendors will see it.
          EvSurface(
            color: EvColors.cream,
            child: Row(children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(color: _kind == OfferingType.service ? EvColors.bronzeTint : EvColors.forestTint, borderRadius: EvRadius.mdAll),
                child: Icon(iconForCategoryKey(_icon), color: _kind == OfferingType.service ? EvColors.bronzeDeep : EvColors.forest),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ValueListenableBuilder(
                  valueListenable: _name,
                  builder: (_, v, _) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(v.text.trim().isEmpty ? 'Category name' : v.text.trim(), style: EvType.bodyStrong),
                    Text(_isNew ? 'id: ${_slug(v.text).isEmpty ? '…' : _slug(v.text)}' : 'id: ${widget.existing!.id}', style: EvType.caption),
                  ]),
                ),
              ),
            ]),
          ),
          const SizedBox(height: EvSpace.x4),
          EvField(
            label: 'Name',
            controller: _name,
            hint: 'e.g. Bouncy castles',
            textCapitalization: TextCapitalization.words,
            validator: (v) => (v == null || v.trim().length < 2 || v.trim().length > 60) ? 'Use 2–60 characters' : null,
          ),
          const SizedBox(height: EvSpace.x4),
          const EvFieldLabel('Type'),
          EvSegmented<OfferingType>(
            value: _kind,
            onChanged: (v) => setState(() => _kind = v),
            segments: const [(OfferingType.rental, 'Rental'), (OfferingType.service, 'Service'), (OfferingType.package, 'Package')],
          ),
          const SizedBox(height: EvSpace.x4),
          const EvFieldLabel('Icon'),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final k in kCategoryIconKeys)
              InkWell(
                onTap: () => setState(() => _icon = k),
                borderRadius: EvRadius.smAll,
                child: AnimatedContainer(
                  duration: EvMotion.of(context, EvMotion.fast),
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: _icon == k ? EvColors.forest : EvColors.warmWhite,
                    borderRadius: EvRadius.smAll,
                    border: Border.all(color: _icon == k ? EvColors.forest : EvColors.sand),
                  ),
                  child: Icon(iconForCategoryKey(k), size: 20, color: _icon == k ? EvColors.inkOnDark : EvColors.ink2),
                ),
              ),
          ]),
          if (!_isNew) ...[
            const SizedBox(height: EvSpace.x4),
            EvSwitchRow(
              title: 'Visible to vendors',
              subtitle: _active ? 'Shown in listing, search and subscription pickers' : 'Hidden from pickers; existing listings keep it',
              value: _active,
              onChanged: (v) => setState(() => _active = v),
            ),
          ],
          const SizedBox(height: EvSpace.x3),
          EvField(
            label: _hiding ? 'Reason for hiding' : 'Note for the audit log',
            controller: _reason,
            optional: !_hiding,
            hint: _hiding ? 'e.g. Merged into “Décor & backdrops”' : null,
            validator: (v) => _hiding && (v == null || v.trim().length < 5) ? 'Give a reason (at least 5 characters)' : null,
          ),
          const SizedBox(height: EvSpace.x5),
          EvButton(_isNew ? 'Create category' : 'Save changes', icon: LucideIcons.check, expand: true, loading: _busy, onPressed: _save),
        ]),
      ),
    );
  }
}

class _Audit extends ConsumerWidget {
  const _Audit();
  @override
  Widget build(BuildContext context, WidgetRef ref) => AsyncView(
        value: ref.watch(_auditProvider),
        onRetry: () => ref.invalidate(_auditProvider),
        isEmpty: (l) => l.isEmpty,
        empty: const EmptyState(mascot: Mascot.calendar, title: 'No admin actions yet', body: 'Every verification, moderation and dispute decision is recorded here and cannot be edited.', compact: true),
        data: (list) => ListView.separated(
          itemCount: list.length,
          separatorBuilder: (_, _) => const EvDivider(indent: EvSpace.gutter),
          itemBuilder: (c, i) {
            final a = list[i];
            return EvRow(
              dense: true,
              title: a.action,
              subtitle: '${a.targetTable}/${a.targetId.length > 12 ? '${a.targetId.substring(0, 12)}…' : a.targetId} · ${a.actorRole?.label ?? 'system'} · ${EvDates.dayTime(a.createdAt)}'
                  '${a.reason != null && a.reason!.isNotEmpty ? '\n“${a.reason}”' : ''}',
              trailing: Text('${a.before?.values.firstOrNull ?? '—'} → ${a.after?.values.firstOrNull ?? '—'}', style: EvType.caption),
            );
          },
        ),
      );
}

void _previewListing(BuildContext context, Listing l) {
  showEvSheet<void>(
    context,
    title: l.title,
    subtitle: '${l.business?.name ?? ''} · ${categoryById(l.categoryId).name}',
    // showEvSheet does not scroll its content itself; photos make this tall.
    builder: (c) => SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(EvSpace.gutter, 0, EvSpace.gutter, EvSpace.x8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (l.photos.isEmpty)
          EvSurface(color: EvColors.warningTint, child: Text('No photos.', style: EvType.small.copyWith(color: EvColors.warning)))
        else
          for (final p in l.photos)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: AspectRatio(aspectRatio: 4 / 3, child: EvPhoto(p, radius: EvRadius.md)),
            ),
        const SizedBox(height: EvSpace.x2),
        Text(priceLabel(l), style: EvType.money),
        if (l.tracksStock && l.kind != OfferingType.service) Text('${l.usable} in stock · ${l.totalQuantity} owned', style: EvType.small),
        if (l.description.isNotEmpty) ...[const SizedBox(height: EvSpace.x3), Text(l.description, style: EvType.body)],
        if (l.terms.isNotEmpty) ...[
          const SizedBox(height: EvSpace.x3),
          Text('TERMS', style: EvType.overline),
          Text(l.terms, style: EvType.small),
        ],
        if (l.moderationReason != null) ...[
          const SizedBox(height: EvSpace.x3),
          Text('Moderation note: ${l.moderationReason}', style: EvType.small.copyWith(color: EvColors.danger)),
        ],
        const SizedBox(height: EvSpace.x4),
        EvButton('Review ${l.business?.name ?? 'business'}', kind: EvButtonKind.secondary, icon: LucideIcons.store, expand: true, onPressed: () {
          Navigator.pop(c);
          context.push('/admin/business/${l.businessId}');
        }),
      ]),
    ),
  );
}
