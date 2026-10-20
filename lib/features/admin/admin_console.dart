import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
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
import '../shared/map_widgets.dart';

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

enum _NowFilter {
  live('Live'),
  matched('Matched'),
  noReach('No suppliers'),
  closed('Closed'),
  all('All');

  const _NowFilter(this.label);
  final String label;

  bool matches(NowRequest r) => switch (this) {
        live => r.status.live || r.status == NowStatus.draft && r.expiresAt.isAfter(DateTime.now()),
        matched => r.status == NowStatus.bookingConfirmed || r.status == NowStatus.completed,
        noReach => r.recipientsCount == 0 && !r.status.live,
        closed => r.status == NowStatus.expired || r.status == NowStatus.cancelled,
        all => true,
      };
}

/// Evenda Now command view: what is urgent right now, whether the network
/// is answering, and the power to shut a request down.
class _NowMonitor extends ConsumerStatefulWidget {
  const _NowMonitor();
  @override
  ConsumerState<_NowMonitor> createState() => _NowMonitorState();
}

class _NowMonitorState extends ConsumerState<_NowMonitor> {
  _NowFilter? _filter;

  @override
  Widget build(BuildContext context) => AsyncView(
        value: ref.watch(_nowProvider),
        onRetry: () => ref.invalidate(_nowProvider),
        isEmpty: (l) => l.isEmpty,
        empty: const EmptyState(mascot: Mascot.pin, title: 'No Evenda Now requests yet', body: 'Urgent vendor-to-vendor requests appear here as they go out.', compact: true),
        data: (all) {
          final live = all.where(_NowFilter.live.matches).length;
          final sent = all.where((r) => r.status != NowStatus.draft).toList();
          final reached = sent.where((r) => r.recipientsCount > 0).length;
          final matched = all.where(_NowFilter.matched.matches).length;
          final alerted = sent.fold<int>(0, (s, r) => s + r.recipientsCount);
          String pct(int n, int d) => d == 0 ? '—' : '${(100 * n / d).round()}%';
          final filter = _filter ?? (live > 0 ? _NowFilter.live : _NowFilter.all);
          final list = all.where(filter.matches).toList();

          return ListView(padding: const EdgeInsets.only(bottom: EvSpace.x10), children: [
            Container(
              margin: const EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x2, EvSpace.gutter, 0),
              padding: const EdgeInsets.all(EvSpace.x4),
              decoration: BoxDecoration(color: EvColors.forest, borderRadius: EvRadius.lgAll),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  _LiveDot(active: live > 0),
                  const SizedBox(width: 8),
                  Text(live > 0 ? 'LIVE NOW' : 'NOTHING URGENT RIGHT NOW', style: EvType.overline.copyWith(color: live > 0 ? const Color(0xFFC9A27A) : EvColors.sand)),
                ]),
                const SizedBox(height: 6),
                Text('$live open request${live == 1 ? '' : 's'}', style: EvType.display.copyWith(color: EvColors.inkOnDark)),
                Text('${all.length} in the last 100 · ${plural(alerted, 'supplier alert')}', style: EvType.caption.copyWith(color: EvColors.sand)),
                const SizedBox(height: EvSpace.x4),
                Row(children: [
                  Expanded(child: _MoneyFact('Reached a supplier', pct(reached, sent.length), EvColors.inkOnDark)),
                  Expanded(child: _MoneyFact('Ended in a booking', pct(matched, sent.length), const Color(0xFFC9A27A))),
                ]),
                if (sent.isNotEmpty && reached < sent.length) ...[
                  const SizedBox(height: EvSpace.x3),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(color: EvColors.forestSoft, borderRadius: EvRadius.mdAll),
                    child: Row(children: [
                      const Icon(LucideIcons.radar, size: 18, color: Color(0xFFC9A27A)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text('${sent.length - reached} request${sent.length - reached == 1 ? '' : 's'} found no supplier in range. Recruit vendors in those categories and areas.',
                            style: EvType.small.copyWith(color: EvColors.inkOnDark)),
                      ),
                    ]),
                  ),
                ],
              ]),
            ),
            const SizedBox(height: EvSpace.x3),
            EvSegmented<_NowFilter>(
              value: filter,
              onChanged: (v) => setState(() => _filter = v),
              segments: [for (final f in _NowFilter.values) (f, '${f.label} ${all.where(f.matches).length}')],
            ),
            const SizedBox(height: EvSpace.x2),
            if (list.isEmpty)
              const EmptyState(title: 'Nothing here', body: 'No requests match this filter.', compact: true)
            else
              for (final r in list)
                Padding(
                  padding: const EdgeInsets.fromLTRB(EvSpace.gutter, 0, EvSpace.gutter, 8),
                  child: _NowCard(request: r, onTap: () => _openNowFile(context, ref, r)),
                ),
          ]);
        },
      );
}

class _LiveDot extends StatefulWidget {
  const _LiveDot({required this.active});
  final bool active;
  @override
  State<_LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<_LiveDot> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.active && !EvMotion.reduced(context)) {
      _c.repeat(reverse: true);
    } else {
      _c.value = 1;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: Tween(begin: 0.35, end: 1.0).animate(_c),
        child: Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: widget.active ? const Color(0xFFC9A27A) : EvColors.sand, shape: BoxShape.circle),
        ),
      );
}

class _NowCard extends StatelessWidget {
  const _NowCard({required this.request, required this.onTap});
  final NowRequest request;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final r = request;
    final left = r.expiresAt.difference(DateTime.now());
    final noReach = r.recipientsCount == 0 && r.status != NowStatus.draft;
    return EvSurface(
      onTap: onTap,
      padding: EdgeInsets.zero,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: EvRadius.lgAll,
          border: r.status.live ? const Border(left: BorderSide(color: EvColors.bronze, width: 4)) : null,
        ),
        padding: const EdgeInsets.all(EvSpace.x3),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(color: r.status.live ? EvColors.bronzeTint : EvColors.neutralTint, borderRadius: EvRadius.mdAll),
              child: Icon(categoryIcon(r.categoryId), color: r.status.live ? EvColors.bronzeDeep : EvColors.ink2),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${r.quantity} × ${r.itemDescription}', style: EvType.bodyStrong, maxLines: 2, overflow: TextOverflow.ellipsis),
                Text(r.requester.name, style: EvType.small, maxLines: 1, overflow: TextOverflow.ellipsis),
              ]),
            ),
            const SizedBox(width: 8),
            StatusPill(r.status.label, tone: toneForNow(r.status), dense: true),
          ]),
          const SizedBox(height: EvSpace.x3),
          Wrap(spacing: 14, runSpacing: 6, children: [
            _Meta(LucideIcons.calendarClock, '${EvDates.day(r.neededFrom)}${r.neededByTime != null ? ' by ${r.neededByTime!.substring(0, 5)}' : ''}'),
            _Meta(LucideIcons.mapPin, '${r.locationLabel} · ${r.radiusKm} km'),
            _Meta(LucideIcons.bellRing, '${plural(r.recipientsCount, 'supplier')} alerted', color: noReach ? EvColors.danger : null),
            if (r.maxBudget != null) _Meta(LucideIcons.wallet, 'Budget ${Money.k(r.maxBudget!)}'),
            if (r.status.live && !left.isNegative)
              _Meta(LucideIcons.timer, left.inHours > 0 ? '${left.inHours} h ${left.inMinutes % 60} min left' : '${left.inMinutes} min left', color: EvColors.bronzeDeep),
          ]),
        ]),
      ),
    );
  }
}

class _Meta extends StatelessWidget {
  const _Meta(this.icon, this.text, {this.color});
  final IconData icon;
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 14, color: color ?? EvColors.ink3),
        const SizedBox(width: 4),
        Text(text, style: EvType.caption.copyWith(color: color, fontWeight: color != null ? FontWeight.w700 : null)),
      ]);
}

void _openNowFile(BuildContext context, WidgetRef ref, NowRequest r) {
  showEvSheet<void>(
    context,
    title: '${r.quantity} × ${r.itemDescription}',
    subtitle: '${categoryById(r.categoryId).name} · ${r.broadcastAt != null ? 'sent ${EvDates.ago(r.broadcastAt!)}' : 'never sent to suppliers'}',
    builder: (c) => _NowFile(request: r, onChanged: () => ref.invalidate(_nowProvider)),
  );
}

final _nowDetailProvider = FutureProvider.autoDispose.family<AdminNowDetail, String>((ref, id) => ref.watch(backendProvider).admin.nowDetail(id));

class _NowFile extends ConsumerWidget {
  const _NowFile({required this.request, required this.onChanged});
  final NowRequest request;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = request;
    final role = ref.watch(adminSessionProvider).value?.role ?? ref.read(backendProvider).admin.current?.role;
    final canClose = (role?.can('dispute.manage') ?? false) && (r.status.live || r.status == NowStatus.draft);
    final detail = ref.watch(_nowDetailProvider(r.id));

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(EvSpace.gutter, 0, EvSpace.gutter, EvSpace.x8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: 6, runSpacing: 6, children: [
          StatusPill(r.status.label, tone: toneForNow(r.status)),
          StatusPill(r.fulfilment.label, tone: Tone.neutral, icon: LucideIcons.truck),
        ]),
        const SizedBox(height: EvSpace.x3),
        // Where it's needed, and how far the alert reached.
        ClipRRect(
          borderRadius: EvRadius.mdAll,
          child: SizedBox(
            height: 170,
            child: FlutterMap(
              options: MapOptions(
                initialCenter: r.location,
                initialZoom: r.radiusKm <= 5 ? 12 : r.radiusKm <= 15 ? 11 : r.radiusKm <= 40 ? 9.5 : 8,
                interactionOptions: const InteractionOptions(flags: InteractiveFlag.none),
              ),
              children: [
                ...evTileLayers(),
                CircleLayer(circles: [
                  CircleMarker(
                    point: r.location,
                    radius: r.radiusKm * 1000.0,
                    useRadiusInMeter: true,
                    color: EvColors.bronze.withValues(alpha: 0.12),
                    borderColor: EvColors.bronze,
                    borderStrokeWidth: 1.5,
                  ),
                ]),
                MarkerLayer(markers: [
                  Marker(point: r.location, width: 36, height: 36, child: const Icon(LucideIcons.mapPin, size: 32, color: EvColors.forest, fill: 1)),
                ]),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text('${r.locationLabel} · alert radius ${r.radiusKm} km', style: EvType.caption),

        const SectionHeader('Requested by', padding: EdgeInsets.fromLTRB(0, EvSpace.x5, 0, EvSpace.x2)),
        _AdminPartyTile(biz: r.requester, context: context, note: 'about the urgent request for ${r.quantity} × ${r.itemDescription}'),

        const SectionHeader('Need', padding: EdgeInsets.fromLTRB(0, EvSpace.x5, 0, EvSpace.x2)),
        EvSurface(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${r.quantity} × ${r.itemDescription}', style: EvType.bodyStrong),
            const SizedBox(height: 4),
            Text('${EvDates.range(r.neededFrom, r.neededTo)}${r.neededByTime != null ? ' · by ${r.neededByTime!.substring(0, 5)}' : ''}', style: EvType.small),
            if (r.maxBudget != null) Text('Budget up to ${Money.zmw(r.maxBudget!)}', style: EvType.small),
            Text('Expires ${EvDates.dayTime(r.expiresAt)}', style: EvType.caption),
            if (r.notes.isNotEmpty) ...[const SizedBox(height: 6), Text('“${r.notes}”', style: EvType.small)],
          ]),
        ),

        AsyncView<AdminNowDetail>(
          value: detail,
          onRetry: () => ref.invalidate(_nowDetailProvider(r.id)),
          loading: const Padding(padding: EdgeInsets.all(EvSpace.x5), child: Center(child: CircularProgressIndicator())),
          data: (d) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SectionHeader('Suppliers alerted', count: d.recipients.length, padding: const EdgeInsets.fromLTRB(0, EvSpace.x5, 0, EvSpace.x2)),
            if (d.recipients.isEmpty)
              EvSurface(
                color: EvColors.warningTint,
                child: Text('No supplier matched: nobody in range had this category free on those dates.', style: EvType.small.copyWith(color: EvColors.warning)),
              )
            else
              EvSurface(
                padding: EdgeInsets.zero,
                child: Column(children: [
                  for (final (i, x) in d.recipients.indexed) ...[
                    if (i > 0) const EvDivider(indent: 60),
                    Builder(builder: (_) {
                      final offered = d.offers.any((o) => o.supplier.id == x.business.id);
                      final (label, tone) = offered
                          ? ('Offered', Tone.positive)
                          : x.declinedAt != null
                              ? ('Declined', Tone.neutral)
                              : x.seenAt != null
                                  ? ('Seen', Tone.progress)
                                  : ('Not opened', Tone.waiting);
                      return EvRow(
                        dense: true,
                        leading: BusinessAvatar(name: x.business.name, logoUrl: x.business.logoUrl, size: 34, verified: x.business.verified),
                        title: x.business.name,
                        subtitle: '${x.distanceKm.toStringAsFixed(1)} km · ${x.available >= 999 ? 'has capacity' : '${x.available} free'}',
                        trailing: StatusPill(label, tone: tone, dense: true),
                      );
                    }),
                  ],
                ]),
              ),
            SectionHeader('Offers', count: d.offers.length, padding: const EdgeInsets.fromLTRB(0, EvSpace.x5, 0, EvSpace.x2)),
            if (d.offers.isEmpty)
              Text('No offers.', style: EvType.small)
            else
              for (final o in d.offers)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: EvSurface(
                    padding: const EdgeInsets.all(12),
                    child: Row(children: [
                      BusinessAvatar(name: o.supplier.name, logoUrl: o.supplier.logoUrl, size: 34),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(o.supplier.name, style: EvType.smallStrong, maxLines: 1, overflow: TextOverflow.ellipsis),
                          Text('${o.quantity} × ${o.listingTitle} @ ${Money.k(o.unitPrice)}${o.canDeliver ? ' · delivers' : ''}', style: EvType.caption),
                        ]),
                      ),
                      Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                        Text(Money.k(o.total), style: EvType.money),
                        StatusPill(o.status.label, tone: o.status == NowOfferStatus.selected ? Tone.positive : Tone.neutral, dense: true),
                      ]),
                    ]),
                  ),
                ),
            SectionHeader('Timeline', count: d.history.length, padding: const EdgeInsets.fromLTRB(0, EvSpace.x5, 0, EvSpace.x2)),
            for (final (i, h) in d.history.reversed.indexed)
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Column(children: [
                  Container(width: 10, height: 10, margin: const EdgeInsets.only(top: 4), decoration: BoxDecoration(color: toneForNow(h.to).fg, shape: BoxShape.circle)),
                  if (i < d.history.length - 1) Container(width: 2, height: 34, color: EvColors.sand),
                ]),
                const SizedBox(width: 10),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(h.to.label, style: EvType.smallStrong),
                      Text([EvDates.dayTime(h.at), if (h.note != null && h.note!.isNotEmpty) h.note!].join(' · '), style: EvType.caption),
                    ]),
                  ),
                ),
              ]),
          ]),
        ),

        if (canClose) ...[
          const SizedBox(height: EvSpace.x4),
          EvSurface(
            color: EvColors.dangerTint,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                const Icon(LucideIcons.shieldAlert, size: 18, color: EvColors.danger),
                const SizedBox(width: 8),
                Text('Platform intervention', style: EvType.smallStrong.copyWith(color: EvColors.danger)),
              ]),
              const SizedBox(height: 6),
              Text('Closing stops this request, expires pending offers, tells the requester why and tells alerted suppliers it is closed.', style: EvType.small),
              const SizedBox(height: EvSpace.x3),
              EvButton('Close request as Evenda', kind: EvButtonKind.danger, icon: LucideIcons.octagonX, expand: true, onPressed: () async {
                final reason = await confirmWithReason(context,
                    title: 'Close this request?', body: 'The requester sees this reason. It is stored in the audit log.', confirm: 'Close request', destructive: true);
                if (reason == null || !context.mounted) return;
                final ok = await guard(context, () async {
                  await ref.read(backendProvider).admin.closeNowRequest(r.id, reason);
                  return true;
                }, success: 'Request closed and people notified');
                if (ok == true && context.mounted) {
                  onChanged();
                  Navigator.pop(context);
                }
              }),
            ]),
          ),
        ] else if (r.status == NowStatus.bookingConfirmed) ...[
          const SizedBox(height: EvSpace.x4),
          Text('This request ended in a booking. To intervene, cancel the booking in Bookings & payments.', style: EvType.caption),
        ],
      ]),
    );
  }
}

/// A business with call / WhatsApp / review shortcuts, for admin sheets.
class _AdminPartyTile extends StatelessWidget {
  const _AdminPartyTile({required this.biz, required this.context, required this.note});
  final BizRef biz;
  final BuildContext context;
  final String note;

  @override
  Widget build(BuildContext _) => EvSurface(
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          BusinessAvatar(name: biz.name, logoUrl: biz.logoUrl, size: 40, verified: biz.verified),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(biz.name, style: EvType.bodyStrong, maxLines: 1, overflow: TextOverflow.ellipsis),
              if (biz.neighbourhood != null) Text(biz.neighbourhood!, style: EvType.caption),
            ]),
          ),
          if (biz.phone != null) EvIconButton(LucideIcons.phone, tooltip: 'Call', onPressed: () => launchUrl(Uri.parse('tel:${biz.phone}'))),
          if (biz.whatsapp != null)
            EvIconButton(LucideIcons.messageCircle,
                tooltip: 'WhatsApp',
                onPressed: () => launchUrl(Uri.parse('https://wa.me/${ZambianPhone.waDigits(biz.whatsapp!)}?text=${Uri.encodeComponent('Hello from the Evenda team $note.')}'),
                    mode: LaunchMode.externalApplication)),
          EvIconButton(LucideIcons.store, tooltip: 'Review business', onPressed: () {
            Navigator.pop(context);
            context.push('/admin/business/${biz.id}');
          }),
        ]),
      );
}

enum _BookingFilter {
  all('All'),
  active('Active'),
  unpaid('Payment due'),
  disputed('Disputed'),
  completed('Completed'),
  cancelled('Cancelled');

  const _BookingFilter(this.label);
  final String label;

  bool matches(Booking b) => switch (this) {
        all => true,
        active => !{BookingStatus.completed, BookingStatus.cancelled, BookingStatus.disputed}.contains(b.status),
        unpaid => b.status != BookingStatus.cancelled && b.confirmedPaid < b.total,
        disputed => b.status == BookingStatus.disputed,
        completed => b.status == BookingStatus.completed,
        cancelled => b.status == BookingStatus.cancelled,
      };
}

/// Platform-wide booking oversight: money moving between vendors, what is
/// owed, what is contested, and the power to step in.
class _Bookings extends ConsumerStatefulWidget {
  const _Bookings({required this.showPayments});
  final bool showPayments;
  @override
  ConsumerState<_Bookings> createState() => _BookingsState();
}

class _BookingsState extends ConsumerState<_Bookings> {
  _BookingFilter _filter = _BookingFilter.all;

  @override
  Widget build(BuildContext context) => AsyncView(
        value: ref.watch(_bookingsProvider),
        onRetry: () => ref.invalidate(_bookingsProvider),
        isEmpty: (l) => l.isEmpty,
        empty: const EmptyState(mascot: Mascot.chair, title: 'No bookings yet', body: 'Bookings between vendors appear here with their payments.', compact: true),
        data: (all) {
          final live = all.where((b) => b.status != BookingStatus.cancelled).toList();
          final value = live.fold<double>(0, (s, b) => s + b.total);
          // Per booking, so an overpayment on one never hides money owed on another.
          final paid = live.fold<double>(0, (s, b) => s + (b.confirmedPaid < b.total ? b.confirmedPaid : b.total));
          final owed = live.fold<double>(0, (s, b) => s + (b.total - b.confirmedPaid).clamp(0, double.infinity));
          final overpaid = live.where((b) => b.confirmedPaid > b.total + 0.005).toList();
          final disputed = all.where((b) => b.status == BookingStatus.disputed).length;
          final unconfirmed = all.expand((b) => b.payments).where((p) => p.confirmedAt == null).length;
          final list = all.where(_filter.matches).toList();

          return ListView(padding: const EdgeInsets.only(bottom: EvSpace.x10), children: [
            // Money overview, the platform's ledger at a glance.
            Container(
              margin: const EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x2, EvSpace.gutter, 0),
              padding: const EdgeInsets.all(EvSpace.x4),
              decoration: BoxDecoration(color: EvColors.forest, borderRadius: EvRadius.lgAll),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('BOOKED VALUE ON EVENDA', style: EvType.overline.copyWith(color: EvColors.sand)),
                const SizedBox(height: 4),
                Text(Money.zmw(value), style: EvType.display.copyWith(color: EvColors.inkOnDark)),
                Text('${live.length} live booking${live.length == 1 ? '' : 's'} · cancelled excluded', style: EvType.caption.copyWith(color: EvColors.sand)),
                if (widget.showPayments) ...[
                  const SizedBox(height: EvSpace.x3),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: value == 0 ? 0 : paid / value,
                      minHeight: 8,
                      backgroundColor: EvColors.forestSoft,
                      color: const Color(0xFFC9A27A),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(children: [
                    Expanded(child: _MoneyFact('Confirmed paid', Money.k(paid), const Color(0xFFC9A27A))),
                    Expanded(child: _MoneyFact('Still owed', Money.k(owed), EvColors.inkOnDark)),
                  ]),
                  if (overpaid.isNotEmpty) ...[
                    const SizedBox(height: EvSpace.x3),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(color: EvColors.dangerTint, borderRadius: EvRadius.mdAll),
                      child: Row(children: [
                        const Icon(LucideIcons.triangleAlert, size: 18, color: EvColors.danger),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '${overpaid.length} booking${overpaid.length == 1 ? ' has' : 's have'} more confirmed than the booking total (${overpaid.map((b) => b.reference).join(', ')}). Check for a typing error.',
                            style: EvType.small.copyWith(color: EvColors.danger),
                          ),
                        ),
                      ]),
                    ),
                  ],
                ],
              ]),
            ),
            const SizedBox(height: EvSpace.x3),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: EvSpace.gutter),
              child: Row(children: [
                Expanded(child: _MiniStat('Disputed', '$disputed', tone: disputed > 0 ? Tone.critical : Tone.neutral)),
                const SizedBox(width: 8),
                Expanded(child: _MiniStat('Unconfirmed payments', '$unconfirmed', tone: unconfirmed > 0 ? Tone.waiting : Tone.neutral)),
              ]),
            ),
            const SizedBox(height: EvSpace.x3),
            EvSegmented<_BookingFilter>(
              value: _filter,
              onChanged: (v) => setState(() => _filter = v),
              segments: [for (final f in _BookingFilter.values) (f, '${f.label} ${all.where(f.matches).length}')],
            ),
            const SizedBox(height: EvSpace.x2),
            if (list.isEmpty)
              const EmptyState(title: 'Nothing here', body: 'No bookings match this filter.', compact: true)
            else
              for (final b in list)
                Padding(
                  padding: const EdgeInsets.fromLTRB(EvSpace.gutter, 0, EvSpace.gutter, 8),
                  child: _AdminBookingCard(booking: b, showPayments: widget.showPayments, onTap: () => _openBookingFile(context, ref, b, widget.showPayments)),
                ),
          ]);
        },
      );
}

class _MoneyFact extends StatelessWidget {
  const _MoneyFact(this.label, this.value, this.color);
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: EvType.caption.copyWith(color: EvColors.sand)),
        Text(value, style: EvType.money.copyWith(color: color, fontSize: 17)),
      ]);
}

class _AdminBookingCard extends StatelessWidget {
  const _AdminBookingCard({required this.booking, required this.showPayments, required this.onTap});
  final Booking booking;
  final bool showPayments;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final b = booking;
    final ratio = b.total == 0 ? 0.0 : (b.confirmedPaid / b.total).clamp(0.0, 1.0);
    final overpaid = b.confirmedPaid > b.total + 0.005;
    final alert = b.status == BookingStatus.disputed || overpaid;
    return EvSurface(
      onTap: onTap,
      padding: EdgeInsets.zero,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: EvRadius.lgAll,
          border: alert ? const Border(left: BorderSide(color: EvColors.danger, width: 4)) : null,
        ),
        padding: const EdgeInsets.all(EvSpace.x3),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(b.reference, style: EvType.smallStrong.copyWith(fontFamily: 'monospace', letterSpacing: 0.5, color: EvColors.ink2)),
            if (b.source == BookingSource.now) ...[
              const SizedBox(width: 6),
              const StatusPill('Evenda Now', tone: Tone.attention, dense: true, icon: LucideIcons.zap),
            ],
            const Spacer(),
            StatusPill(b.status.label, tone: toneForBooking(b.status), dense: true),
          ]),
          const SizedBox(height: EvSpace.x3),
          // Who supplies whom.
          Row(children: [
            Expanded(child: _Party(b.supplier, 'Supplier')),
            const Padding(padding: EdgeInsets.symmetric(horizontal: 6), child: Icon(LucideIcons.arrowRight, size: 16, color: EvColors.ink3)),
            Expanded(child: _Party(b.requester, 'Hired by')),
          ]),
          const SizedBox(height: EvSpace.x3),
          Row(children: [
            const Icon(LucideIcons.calendarDays, size: 14, color: EvColors.ink3),
            const SizedBox(width: 6),
            Expanded(child: Text(EvDates.range(b.startsOn, b.endsOn), style: EvType.small)),
            Text(Money.k(b.total), style: EvType.money),
          ]),
          if (showPayments) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: ratio,
                minHeight: 5,
                backgroundColor: EvColors.sand,
                color: overpaid ? EvColors.danger : (ratio >= 1 ? EvColors.success : EvColors.bronze),
              ),
            ),
            const SizedBox(height: 4),
            Row(children: [
              Text('${Money.k(b.confirmedPaid)} confirmed', style: EvType.caption.copyWith(color: overpaid ? EvColors.danger : null, fontWeight: overpaid ? FontWeight.w700 : null)),
              const Spacer(),
              overpaid
                  ? Text('Overpaid by ${Money.k(b.confirmedPaid - b.total)}', style: EvType.caption.copyWith(color: EvColors.danger, fontWeight: FontWeight.w700))
                  : Text(b.paymentStatus.label, style: EvType.caption.copyWith(color: toneForPayment(b.paymentStatus).fg, fontWeight: FontWeight.w700)),
            ]),
          ],
        ]),
      ),
    );
  }
}

class _Party extends StatelessWidget {
  const _Party(this.biz, this.role);
  final BizRef biz;
  final String role;

  @override
  Widget build(BuildContext context) => Row(children: [
        BusinessAvatar(name: biz.name, logoUrl: biz.logoUrl, size: 30, verified: biz.verified),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(role, style: EvType.caption),
            Text(biz.name, style: EvType.smallStrong, maxLines: 1, overflow: TextOverflow.ellipsis),
          ]),
        ),
      ]);
}

void _openBookingFile(BuildContext context, WidgetRef ref, Booking b, bool showPayments) {
  showEvSheet<void>(
    context,
    title: 'Booking ${b.reference}',
    subtitle: '${b.source == BookingSource.now ? 'Evenda Now' : b.source == BookingSource.quotation ? 'From a quotation' : 'Manual'} · created ${EvDates.day(b.createdAt)}',
    builder: (c) => _BookingFile(booking: b, showPayments: showPayments, onChanged: () => ref.invalidate(_bookingsProvider)),
  );
}

class _BookingFile extends ConsumerWidget {
  const _BookingFile({required this.booking, required this.showPayments, required this.onChanged});
  final Booking booking;
  final bool showPayments;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final b = booking;
    final role = ref.watch(adminSessionProvider).value?.role ?? ref.read(backendProvider).admin.current?.role;
    final canIntervene = (role?.can('dispute.manage') ?? false) && b.status != BookingStatus.completed && b.status != BookingStatus.cancelled;
    String who(String id) => id == b.supplier.id ? b.supplier.name : id == b.requester.id ? b.requester.name : 'Unknown';

    Widget party(BizRef p, String label) => EvSurface(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            BusinessAvatar(name: p.name, logoUrl: p.logoUrl, size: 40, verified: p.verified),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, style: EvType.caption),
                Text(p.name, style: EvType.bodyStrong, maxLines: 1, overflow: TextOverflow.ellipsis),
                if (p.neighbourhood != null) Text(p.neighbourhood!, style: EvType.caption),
              ]),
            ),
            if (p.phone != null) EvIconButton(LucideIcons.phone, tooltip: 'Call', onPressed: () => launchUrl(Uri.parse('tel:${p.phone}'))),
            if (p.whatsapp != null)
              EvIconButton(LucideIcons.messageCircle,
                  tooltip: 'WhatsApp',
                  onPressed: () => launchUrl(Uri.parse('https://wa.me/${ZambianPhone.waDigits(p.whatsapp!)}?text=${Uri.encodeComponent('Hello from the Evenda team about booking ${b.reference}.')}'),
                      mode: LaunchMode.externalApplication)),
            EvIconButton(LucideIcons.store, tooltip: 'Review business', onPressed: () {
              Navigator.pop(context);
              context.push('/admin/business/${p.id}');
            }),
          ]),
        );

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(EvSpace.gutter, 0, EvSpace.gutter, EvSpace.x8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: 6, runSpacing: 6, children: [
          StatusPill(b.status.label, tone: toneForBooking(b.status)),
          StatusPill(b.paymentStatus.label, tone: toneForPayment(b.paymentStatus), icon: LucideIcons.wallet),
          StatusPill(b.fulfilment.label, tone: Tone.neutral, icon: LucideIcons.truck),
        ]),
        const SizedBox(height: EvSpace.x3),
        party(b.supplier, 'Supplier'),
        const SizedBox(height: 8),
        party(b.requester, 'Hired by'),

        const SectionHeader('What was booked', padding: EdgeInsets.fromLTRB(0, EvSpace.x5, 0, EvSpace.x2)),
        EvSurface(
          child: Column(children: [
            for (final i in b.items)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(children: [
                  Expanded(child: Text('${i.quantity} × ${i.description}', style: EvType.body)),
                  Text(Money.k(i.lineTotal), style: EvType.money),
                ]),
              ),
            const EvDivider(),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: Text(EvDates.range(b.startsOn, b.endsOn), style: EvType.small)),
              Text('Total ${Money.zmw(b.total)}', style: EvType.money),
            ]),
            if (b.depositAmount > 0)
              Align(alignment: Alignment.centerRight, child: Text('Deposit ${Money.k(b.depositAmount)}', style: EvType.caption)),
          ]),
        ),

        SectionHeader('Payment ledger', count: showPayments ? b.payments.length : null, padding: const EdgeInsets.fromLTRB(0, EvSpace.x5, 0, EvSpace.x2)),
        if (!showPayments)
          Text('Payment records need the finance or super admin role.', style: EvType.small)
        else if (b.payments.isEmpty)
          EvSurface(color: EvColors.warningTint, child: Text('No payments recorded yet. Evenda records payments; it does not hold money.', style: EvType.small.copyWith(color: EvColors.warning)))
        else
          for (final p in b.payments)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: EvSurface(
                padding: const EdgeInsets.all(12),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(p.kind == 'refund' ? LucideIcons.undo2 : LucideIcons.banknote, size: 20, color: p.confirmedAt != null ? EvColors.success : EvColors.warning),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${p.kind[0].toUpperCase()}${p.kind.substring(1)} · ${p.methodLabel}', style: EvType.smallStrong),
                      Text('Recorded by ${who(p.recordedByBusinessId)} · ${EvDates.dayTime(p.createdAt)}', style: EvType.caption),
                      if (p.reference != null) Text('Ref ${p.reference}', style: EvType.caption.copyWith(fontFamily: 'monospace')),
                      const SizedBox(height: 4),
                      p.confirmedAt != null
                          ? StatusPill('Confirmed by the other party', tone: Tone.positive, dense: true, icon: LucideIcons.check)
                          : const StatusPill('Not confirmed', tone: Tone.waiting, dense: true),
                    ]),
                  ),
                  Text('${p.kind == 'refund' ? '−' : ''}${Money.k(p.amount)}', style: EvType.money),
                ]),
              ),
            ),

        SectionHeader('Timeline', count: b.history.length, padding: const EdgeInsets.fromLTRB(0, EvSpace.x5, 0, EvSpace.x2)),
        for (final (i, h) in b.history.reversed.indexed)
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Column(children: [
              Container(width: 10, height: 10, margin: const EdgeInsets.only(top: 4), decoration: BoxDecoration(color: toneForBooking(h.to).fg, shape: BoxShape.circle)),
              if (i < b.history.length - 1) Container(width: 2, height: 34, color: EvColors.sand),
            ]),
            const SizedBox(width: 10),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(h.to.label, style: EvType.smallStrong),
                  Text([EvDates.dayTime(h.at), if (h.note != null && h.note!.isNotEmpty) h.note!].join(' · '), style: EvType.caption),
                ]),
              ),
            ),
          ]),

        if (canIntervene) ...[
          const SizedBox(height: EvSpace.x4),
          EvSurface(
            color: EvColors.dangerTint,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                const Icon(LucideIcons.shieldAlert, size: 18, color: EvColors.danger),
                const SizedBox(width: 8),
                Text('Platform intervention', style: EvType.smallStrong.copyWith(color: EvColors.danger)),
              ]),
              const SizedBox(height: 6),
              Text('Cancelling releases the reserved stock and open tasks, and notifies both businesses with your reason.', style: EvType.small),
              const SizedBox(height: EvSpace.x3),
              EvButton('Cancel booking as Evenda', kind: EvButtonKind.danger, icon: LucideIcons.ban, expand: true, onPressed: () async {
                final reason = await confirmWithReason(context,
                    title: 'Cancel ${b.reference}?', body: 'Both businesses see this reason. It is stored in the audit log.', confirm: 'Cancel booking', destructive: true);
                if (reason == null || !context.mounted) return;
                final ok = await guard(context, () async {
                  await ref.read(backendProvider).admin.cancelBooking(b.id, reason);
                  return true;
                }, success: 'Booking cancelled and both parties notified');
                if (ok == true && context.mounted) {
                  onChanged();
                  Navigator.pop(context);
                }
              }),
            ]),
          ),
        ],
      ]),
    );
  }
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
