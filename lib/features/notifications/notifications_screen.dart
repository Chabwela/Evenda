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

final _notificationsProvider = FutureProvider.autoDispose<List<AppNotification>>((ref) async {
  ref.watchDomains(const [DataDomain.notifications]);
  return ref.watch(backendProvider).notifications.list(ref.watch(bizIdProvider));
});

/// While quiet hours are on, pushes (except Evenda Now and critical deadlines)
/// wait until they end; the list still fills. Say so, so a missing pop-up
/// isn't a mystery. Returns when quiet hours end, or null outside them.
final _quietUntilProvider = FutureProvider.autoDispose<DateTime?>((ref) async {
  ref.watchDomains(const [DataDomain.notifications]);
  final p = await ref.watch(backendProvider).notifications.prefs(ref.watch(bizIdProvider));
  final now = DateTime.now();
  final midnight = DateTime(now.year, now.month, now.day);
  final t = now.difference(midnight);
  final start = p.quietStart, end = p.quietEnd;
  if (start == end) return null;
  final inQuiet = start > end ? (t >= start || t < end) : (t >= start && t < end);
  if (!inQuiet) return null;
  final endToday = midnight.add(end);
  return endToday.isAfter(now) ? endToday : endToday.add(const Duration(days: 1));
});

enum _Filter { all, inventory, bookings, tasks }

class NotificationsScreen extends ConsumerStatefulWidget {
  const NotificationsScreen({super.key});
  @override
  ConsumerState<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends ConsumerState<NotificationsScreen> {
  _Filter _f = _Filter.all;
  bool _digestOpen = false;

  bool _match(AppNotification n) => switch (_f) {
        _Filter.all => true,
        _Filter.inventory => n.category == NotificationCategory.inventory,
        _Filter.bookings => n.category == NotificationCategory.booking || n.category == NotificationCategory.now,
        _Filter.tasks => n.category == NotificationCategory.task,
      };

  void _open(AppNotification n) {
    ref.read(backendProvider).notifications.markRead(n.id);
    if (n.route != null && n.route != '/notifications') context.push(n.route!);
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(_notificationsProvider);
    final all = data.value ?? const <AppNotification>[];
    int unread(bool Function(AppNotification) f) => all.where((n) => n.unread && f(n)).length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: [
          if (all.any((n) => n.unread))
            IconButton(tooltip: 'Mark all read', icon: const Icon(LucideIcons.checkCheck), onPressed: () => ref.read(backendProvider).notifications.markAllRead(ref.read(bizIdProvider))),
          EvIconButton(LucideIcons.settings, tooltip: 'Settings', onPressed: () => context.push('/business/notifications')),
          const SizedBox(width: 4),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(50),
          child: Padding(
            padding: const EdgeInsets.only(bottom: EvSpace.x2),
            child: EvSegmented<_Filter>(
              value: _f,
              onChanged: (f) => setState(() => _f = f),
              counts: {
                _Filter.all: unread((_) => true),
                _Filter.inventory: unread((n) => n.category == NotificationCategory.inventory),
                _Filter.bookings: unread((n) => n.category == NotificationCategory.booking || n.category == NotificationCategory.now),
                _Filter.tasks: unread((n) => n.category == NotificationCategory.task),
              },
              segments: const [(_Filter.all, 'All'), (_Filter.inventory, 'Inventory updates'), (_Filter.bookings, 'Booking activity'), (_Filter.tasks, 'Tasks')],
            ),
          ),
        ),
      ),
      body: RefreshIndicator(
        color: EvColors.forest,
        onRefresh: () => ref.refresh(_notificationsProvider.future),
        child: AsyncView(
          value: data,
          onRetry: () => ref.invalidate(_notificationsProvider),
          data: (list) {
            final shown = list.where(_match).toList();
            final immediate = shown.where((n) => !n.digest).toList();
            final digest = shown.where((n) => n.digest).toList();
            if (shown.isEmpty) {
              return ListView(children: [
                EmptyState(
                  mascot: _f == _Filter.tasks ? Mascot.calendar : Mascot.crate,
                  title: 'All caught up',
                  body: _f == _Filter.inventory ? 'Follow suppliers or categories to hear when stock you use becomes available.' : 'New activity will appear here.',
                ),
              ]);
            }
            final groups = <String, List<AppNotification>>{};
            for (final n in immediate) {
              final k = EvDates.sameDay(n.createdAt, DateTime.now())
                  ? 'Today'
                  : EvDates.sameDay(n.createdAt, DateTime.now().subtract(const Duration(days: 1)))
                      ? 'Yesterday'
                      : 'Earlier';
              groups.putIfAbsent(k, () => []).add(n);
            }
            return ListView(padding: const EdgeInsets.only(bottom: EvSpace.x10), children: [
              const _QuietHoursLine(),
              for (final e in groups.entries) ...[
                SectionHeader(e.key),
                for (final (i, n) in e.value.indexed) ...[
                  if (i > 0) const EvDivider(indent: 72),
                  _NotificationRow(n: n, onTap: () => _open(n)),
                ],
              ],
              if (digest.isNotEmpty) ...[
                SectionHeader('Daily digest', count: digest.length, action: _digestOpen ? 'Hide' : 'Show', onAction: () => setState(() => _digestOpen = !_digestOpen)),
                if (!_digestOpen)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: EvSpace.gutter),
                    child: Text('Routine supplier updates are grouped here instead of interrupting you.', style: EvType.small),
                  ),
                AnimatedSize(
                  duration: EvMotion.of(context, EvMotion.base),
                  child: _digestOpen
                      ? Column(children: [for (final n in digest) _NotificationRow(n: n, onTap: () => _open(n))])
                      : const SizedBox(width: double.infinity),
                ),
              ],
            ]);
          },
        ),
      ),
    );
  }
}

class _NotificationRow extends StatelessWidget {
  const _NotificationRow({required this.n, required this.onTap});
  final AppNotification n;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tone = switch (n.category) {
      NotificationCategory.now => Tone.waiting,
      NotificationCategory.task => n.title.startsWith('Overdue') || n.title.startsWith('Due soon') ? Tone.critical : Tone.neutral,
      NotificationCategory.booking => Tone.progress,
      NotificationCategory.inventory => Tone.positive,
      NotificationCategory.system => Tone.neutral,
    };
    return InkWell(
      onTap: onTap,
      child: Container(
        color: n.unread ? EvColors.forestWash.withValues(alpha: 0.6) : null,
        padding: const EdgeInsets.symmetric(horizontal: EvSpace.gutter, vertical: 12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (n.category == NotificationCategory.inventory && n.imageUrl != null)
            EvPhoto(n.imageUrl, width: 40, height: 40, radius: EvRadius.sm)
          else
            IconTile(notificationIcon(n.category), tone: tone, size: 40),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(n.title, style: n.unread ? EvType.bodyStrong : EvType.body, maxLines: 2, overflow: TextOverflow.ellipsis),
              if (n.body.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 2), child: Text(n.body, style: EvType.small, maxLines: 2, overflow: TextOverflow.ellipsis)),
              const SizedBox(height: 4),
              Text('${n.category.label} · ${EvDates.ago(n.createdAt)}', style: EvType.caption),
            ]),
          ),
          if (n.unread) Container(margin: const EdgeInsets.only(top: 6, left: 8), width: 8, height: 8, decoration: BoxDecoration(color: EvColors.bronze, shape: BoxShape.circle)),
        ]),
      ),
    );
  }
}


class _QuietHoursLine extends ConsumerWidget {
  const _QuietHoursLine();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final until = ref.watch(_quietUntilProvider).value;
    if (until == null) return const SizedBox.shrink();
    return InkWell(
      onTap: () => context.push('/business/notifications'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x3, EvSpace.gutter, 0),
        child: Row(children: [
          Icon(LucideIcons.moon, size: 16, color: EvColors.ink3),
          const SizedBox(width: 8),
          Expanded(
            child: Text('Quiet hours: pop-ups are paused until ${EvDates.time(until)}. Evenda Now still alerts you.',
                style: EvType.small),
          ),
          Text('Change', style: EvType.smallStrong.copyWith(color: EvColors.forest)),
        ]),
      ),
    );
  }
}
