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

class _HomeData {
  _HomeData({
    required this.business,
    required this.tasks,
    required this.requests,
    required this.events,
    required this.feed,
    required this.conflicts,
    required this.nowInbox,
    required this.nowMine,
    required this.activity,
    required this.bookings,
  });
  final Business business;
  final List<WorkTask> tasks;
  final List<QuoteRequest> requests;
  final List<EventPlan> events;
  final List<InventoryUpdate> feed;
  final List<InventoryConflict> conflicts;
  final List<NowInboxItem> nowInbox;
  final List<NowRequest> nowMine;
  final List<AppNotification> activity;
  final List<Booking> bookings;
}

final _homeProvider = FutureProvider.autoDispose<_HomeData>((ref) async {
  ref.watchDomains(DataDomain.values);
  final biz = (await ref.watch(myBusinessProvider.future))!;
  final b = ref.watch(backendProvider);
  final r = await Future.wait([
    b.work.tasks(biz.id),
    b.bookings.requests(biz.id),
    b.work.events(biz.id),
    b.discovery.inventoryFeed(biz.id, limit: 8),
    biz.rents ? b.listings.conflicts(biz.id) : Future.value(<InventoryConflict>[]),
    b.now.inbox(biz.id),
    b.now.mine(biz.id),
    b.notifications.list(biz.id),
    b.bookings.bookings(biz.id),
  ]);
  return _HomeData(
    business: biz,
    tasks: r[0] as List<WorkTask>,
    requests: r[1] as List<QuoteRequest>,
    events: r[2] as List<EventPlan>,
    feed: r[3] as List<InventoryUpdate>,
    conflicts: r[4] as List<InventoryConflict>,
    nowInbox: r[5] as List<NowInboxItem>,
    nowMine: r[6] as List<NowRequest>,
    activity: r[7] as List<AppNotification>,
    bookings: r[8] as List<Booking>,
  );
});

/// A row in "Needs you": one prioritised list instead of a wall of widgets.
class _Priority {
  _Priority(this.rank, this.icon, this.tone, this.title, this.subtitle, this.route, {this.cta});
  final int rank;
  final IconData icon;
  final Tone tone;
  final String title;
  final String subtitle;
  final String route;
  final String? cta;
}

List<_Priority> _priorities(_HomeData d) {
  final out = <_Priority>[];
  final id = d.business.id;
  for (final n in d.nowInbox.where((i) => i.request.status.live && i.myOffer == null && !i.declined)) {
    out.add(_Priority(0, LucideIcons.zap, Tone.waiting, 'Urgent: ${n.request.quantity} × ${n.request.itemDescription}',
        '${n.request.requester.name} · ${EvDates.relativeDay(n.request.neededFrom)} · ${n.distanceKm} km away', '/now/respond/${n.request.id}', cta: 'Respond'));
  }
  for (final t in d.tasks.where((t) => t.overdue)) {
    out.add(_Priority(1, LucideIcons.alarmClock, Tone.critical, t.title, 'Overdue · was due ${EvDates.dayTime(t.dueAt)}', '/work/task/${t.id}'));
  }
  for (final q in d.requests.where((q) => q.supplier.id == id && q.status == QuoteRequestStatus.open)) {
    out.add(_Priority(2, LucideIcons.inbox, Tone.waiting, 'Quote request from ${q.requester.name}',
        '${q.items.map((i) => '${i.quantity} × ${i.description}').join(', ')} · ${EvDates.day(q.neededFrom)}', '/bookings/request/${q.id}', cta: 'Quote'));
  }
  final seen = <String>{};
  for (final c in d.conflicts) {
    if (!seen.add(c.listingId)) continue;
    out.add(_Priority(3, LucideIcons.triangleAlert, Tone.attention, '${c.title}: ${c.shortfall} short on ${EvDates.day(c.day)}',
        '${c.committed} committed, ${c.usable} usable. Repair, restock or source the difference.', '/business/inventory?listing=${c.listingId}'));
  }
  for (final q in d.requests.where((q) => q.requester.id == id && q.openQuotation != null)) {
    out.add(_Priority(4, LucideIcons.fileText, Tone.progress, '${q.supplier.name} sent a quotation',
        '${Money.k(q.openQuotation!.total)} · valid until ${EvDates.dayShort(q.openQuotation!.validUntil)}', '/bookings/request/${q.id}', cta: 'Review'));
  }
  for (final p in d.bookings.where((b) => b.payments.any((p) => p.confirmedAt == null && p.recordedByBusinessId != id))) {
    out.add(_Priority(5, LucideIcons.handCoins, Tone.waiting, 'Confirm payment on ${p.reference}', 'Recorded by ${p.counterparty(id).name}', '/bookings/${p.id}'));
  }
  for (final t in d.tasks.where((t) => !t.overdue && EvDates.sameDay(t.dueAt, DateTime.now()))) {
    out.add(_Priority(6, LucideIcons.circleDot, toneForPriority(t.priority), t.title, 'Today · ${EvDates.time(t.dueAt)}', '/work/task/${t.id}'));
  }
  out.sort((a, b) => a.rank.compareTo(b.rank));
  return out;
}

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(_homeProvider);
    return Scaffold(
      body: RefreshIndicator(
        color: EvColors.forest,
        onRefresh: () => ref.refresh(_homeProvider.future),
        child: AsyncView(
          value: data,
          onRetry: () => ref.invalidate(_homeProvider),
          loading: const SafeArea(child: Skeleton(rows: 7)),
          data: (d) => _HomeBody(d: d),
        ),
      ),
    );
  }
}

class _HomeBody extends ConsumerWidget {
  const _HomeBody({required this.d});
  final _HomeData d;

  String _greeting() {
    final h = EvDates.nowLusaka().hour;
    return h < 12 ? 'Good morning' : (h < 17 ? 'Good afternoon' : 'Good evening');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider).value;
    final unread = ref.watch(unreadCountProvider).value ?? 0;
    final first = (session?.fullName ?? '').split(' ').first;
    final priorities = _priorities(d);
    final upcoming = d.events.where((e) => e.status != EventStatus.cancelled && e.endsAt.isAfter(DateTime.now())).take(6).toList();
    final waiting = d.requests.where((q) => q.requester.id == d.business.id && q.status == QuoteRequestStatus.open).toList();
    final liveNow = d.nowMine.where((r) => r.status.live).toList();

    return CustomScrollView(slivers: [
      SliverSafeArea(
        bottom: false,
        sliver: SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x3, EvSpace.x2, 0),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Flexible(child: Text(d.business.name, style: EvType.smallStrong.copyWith(color: EvColors.ink2), overflow: TextOverflow.ellipsis)),
                  ]),
                  const SizedBox(height: 4),
                  Text(first.isEmpty ? _greeting() : '${_greeting()}, $first', style: EvType.display),
                  const SizedBox(height: 2),
                  Text(EvDates.dayLong(DateTime.now()), style: EvType.small),
                ]),
              ),
              EvIconButton(LucideIcons.bell, tooltip: 'Notifications', badge: unread, onPressed: () => context.push('/notifications')),
            ]),
          ),
        ),
      ),

      // Needs you
      SliverToBoxAdapter(child: SectionHeader('Needs you', count: priorities.length, action: 'All tasks', onAction: () => context.go('/work'))),
      SliverToBoxAdapter(
        child: priorities.isEmpty
            ? Padding(
                padding: const EdgeInsets.symmetric(horizontal: EvSpace.gutter),
                child: EvSurface(
                  child: Row(children: [
                    const MascotImage(Mascot.calendar, size: 56),
                    const SizedBox(width: EvSpace.x4),
                    Expanded(child: Text('Nothing urgent. You’re on top of today.', style: EvType.bodyStrong)),
                  ]),
                ),
              )
            : Padding(
                padding: const EdgeInsets.symmetric(horizontal: EvSpace.gutter),
                child: EvSurface(
                  padding: EdgeInsets.zero,
                  child: Column(children: [
                    for (final (i, p) in priorities.take(6).indexed) ...[
                      if (i > 0) const EvDivider(indent: 64),
                      EvArrive(
                        delay: EvMotion.stagger * i,
                        child: EvRow(
                          padding: const EdgeInsets.symmetric(horizontal: EvSpace.x4, vertical: 12),
                          leading: IconTile(p.icon, tone: p.tone),
                          title: p.title,
                          subtitle: p.subtitle,
                          trailing: p.cta == null ? null : Text(p.cta!, style: EvType.smallStrong.copyWith(color: EvColors.forest)),
                          onTap: () => context.push(p.route),
                        ),
                      ),
                    ],
                    if (priorities.length > 6)
                      TextButton(onPressed: () => context.go('/work'), child: Text('${priorities.length - 6} more')),
                  ]),
                ),
              ),
      ),

      // Evenda Now
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x4, EvSpace.gutter, 0),
          child: _NowBanner(live: liveNow),
        ),
      ),

      // Quick actions
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x4, EvSpace.gutter, 0),
          child: Row(children: [
            _Quick(LucideIcons.packagePlus, 'New listing', () => context.push('/business/listings/new')),
            if (d.business.rents) _Quick(LucideIcons.notebookPen, 'Record a job', () => context.push('/business/availability')),
            _Quick(LucideIcons.calendarPlus, 'New event', () => context.push('/work/event/new')),
            _Quick(LucideIcons.search, 'Find stock', () => context.go('/find')),
          ]),
        ),
      ),

      // Upcoming events
      SliverToBoxAdapter(child: SectionHeader('Upcoming events', action: 'Calendar', onAction: () => context.go('/work?tab=calendar'))),
      SliverToBoxAdapter(
        child: upcoming.isEmpty
            ? Padding(
                padding: const EdgeInsets.symmetric(horizontal: EvSpace.gutter),
                child: EvSurface(
                  onTap: () => context.push('/work/event/new'),
                  child: Row(children: [
                    const Icon(LucideIcons.calendarPlus, color: EvColors.forest),
                    const SizedBox(width: 12),
                    Expanded(child: Text('No upcoming events. Add one to plan tasks and reminders.', style: EvType.body)),
                  ]),
                ),
              )
            : SizedBox(
                height: 132,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: EvSpace.gutter),
                  itemCount: upcoming.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 10),
                  itemBuilder: (c, i) => _EventCard(event: upcoming[i], tasks: d.tasks.where((t) => t.eventId == upcoming[i].id).toList()),
                ),
              ),
      ),

      // Supplier updates
      if (d.feed.isNotEmpty) ...[
        SliverToBoxAdapter(child: SectionHeader('Supplier updates', action: 'Settings', onAction: () => context.push('/business/notifications'))),
        SliverToBoxAdapter(
          child: SizedBox(
            height: 246,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: EvSpace.gutter),
              itemCount: d.feed.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (c, i) => EvArrive(delay: EvMotion.stagger * i, child: InventoryUpdateCard(update: d.feed[i])),
            ),
          ),
        ),
      ],

      // Waiting on suppliers
      if (waiting.isNotEmpty) ...[
        SliverToBoxAdapter(child: SectionHeader('Waiting on suppliers', count: waiting.length)),
        SliverList.separated(
          itemCount: waiting.length,
          separatorBuilder: (_, _) => const EvDivider(indent: 72),
          itemBuilder: (c, i) {
            final q = waiting[i];
            return EvRow(
              leading: BusinessAvatar(name: q.supplier.name, logoUrl: q.supplier.logoUrl, size: 40),
              title: q.supplier.name,
              subtitle: '${q.items.map((i) => '${i.quantity} × ${i.description}').join(', ')} · sent ${EvDates.ago(q.createdAt)}',
              trailing: StatusPill(q.status.label, tone: toneForRequest(q.status), dense: true),
              onTap: () => context.push('/bookings/request/${q.id}'),
            );
          },
        ),
      ],

      // Recent activity
      SliverToBoxAdapter(child: SectionHeader('Recent activity', action: 'All', onAction: () => context.push('/notifications'))),
      SliverList.separated(
        itemCount: d.activity.take(4).length,
        separatorBuilder: (_, _) => const EvDivider(indent: 64),
        itemBuilder: (c, i) {
          final n = d.activity[i];
          return EvRow(
            dense: true,
            leading: IconTile(notificationIcon(n.category), tone: n.unread ? Tone.positive : Tone.neutral, size: 32),
            title: n.title,
            titleStyle: n.unread ? EvType.smallStrong : EvType.small.copyWith(color: EvColors.ink),
            subtitle: EvDates.ago(n.createdAt),
            trailing: const SizedBox.shrink(),
            onTap: n.route == null ? null : () => context.push(n.route!),
          );
        },
      ),
      const SliverToBoxAdapter(child: SizedBox(height: EvSpace.x10)),
    ]);
  }
}

class _Quick extends StatelessWidget {
  const _Quick(this.icon, this.label, this.onTap);
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Expanded(
        child: InkWell(
          onTap: onTap,
          borderRadius: EvRadius.mdAll,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(color: EvColors.warmWhite, borderRadius: EvRadius.mdAll, border: Border.all(color: EvColors.sand)),
                child: Icon(icon, size: 21, color: EvColors.forest),
              ),
              const SizedBox(height: 6),
              Text(label, style: EvType.caption.copyWith(color: EvColors.ink, fontWeight: FontWeight.w600), textAlign: TextAlign.center, maxLines: 1),
            ]),
          ),
        ),
      );
}

class _NowBanner extends StatelessWidget {
  const _NowBanner({required this.live});
  final List<NowRequest> live;

  @override
  Widget build(BuildContext context) {
    final r = live.firstOrNull;
    return Material(
      color: EvColors.forest,
      borderRadius: EvRadius.mdAll,
      child: InkWell(
        borderRadius: EvRadius.mdAll,
        onTap: () => context.push(r == null ? '/now' : '/now/${r.id}'),
        child: Padding(
          padding: const EdgeInsets.all(EvSpace.x4),
          child: Row(children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(color: EvColors.bronze, borderRadius: EvRadius.smAll),
              child: const Icon(LucideIcons.zap, color: EvColors.inkOnDark, size: 22),
            ),
            const SizedBox(width: EvSpace.x3),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(r == null ? 'Short on stock?' : 'Evenda Now · ${r.status.label}', style: EvType.bodyStrong.copyWith(color: EvColors.inkOnDark)),
                const SizedBox(height: 2),
                Text(
                  r == null ? 'Evenda Now asks nearby suppliers who have it free.' : '${r.quantity} × ${r.itemDescription} · ${plural(r.recipientsCount, 'supplier')} notified',
                  style: EvType.small.copyWith(color: EvColors.sand),
                ),
              ]),
            ),
            const Icon(LucideIcons.arrowRight, color: EvColors.inkOnDark, size: 20),
          ]),
        ),
      ),
    );
  }
}

class _EventCard extends StatelessWidget {
  const _EventCard({required this.event, required this.tasks});
  final EventPlan event;
  final List<WorkTask> tasks;

  @override
  Widget build(BuildContext context) {
    final open = tasks.where((t) => t.status.open).length;
    final overdue = tasks.where((t) => t.overdue).length;
    return SizedBox(
      width: 250,
      child: EvSurface(
        onTap: () => context.push('/work/event/${event.id}'),
        padding: const EdgeInsets.all(EvSpace.x3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 52,
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(color: EvColors.forestWash, borderRadius: EvRadius.smAll),
            child: Column(children: [
              Text(EvDates.day(event.startsAt).split(' ').first.toUpperCase(), style: EvType.overline.copyWith(color: EvColors.forest)),
              Text('${event.startsAt.day}', style: EvType.number.copyWith(color: EvColors.forest)),
            ]),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(event.name, style: EvType.bodyStrong, maxLines: 2, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Text(event.venueName ?? event.type.label, style: EvType.caption, maxLines: 1, overflow: TextOverflow.ellipsis),
              const Spacer(),
              Row(children: [
                Icon(overdue > 0 ? LucideIcons.alarmClock : LucideIcons.listChecks, size: 14, color: overdue > 0 ? EvColors.danger : EvColors.ink3),
                const SizedBox(width: 4),
                Text(overdue > 0 ? '$overdue overdue' : (open == 0 ? 'All tasks done' : '$open open tasks'),
                    style: EvType.caption.copyWith(color: overdue > 0 ? EvColors.danger : EvColors.ink2, fontWeight: FontWeight.w600)),
              ]),
            ]),
          ),
        ]),
      ),
    );
  }
}
