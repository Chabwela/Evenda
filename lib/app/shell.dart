import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/backend.dart';
import '../design/ev.dart';
import '../domain/models.dart';
import 'providers.dart';

/// Badge counts for the tabs: incoming requests needing a reply, overdue tasks.
final _tabBadgesProvider = FutureProvider<(int bookings, int work)>((ref) async {
  ref.watchDomains(const [DataDomain.bookings, DataDomain.work, DataDomain.now]);
  final biz = ref.watch(myBusinessProvider).value;
  if (biz == null) return (0, 0);
  final b = ref.watch(backendProvider);
  final reqs = await b.bookings.requests(biz.id);
  final incoming = reqs.where((q) => q.supplier.id == biz.id && q.status == QuoteRequestStatus.open).length;
  final tasks = await b.work.tasks(biz.id);
  return (incoming, tasks.where((t) => t.overdue).length);
});

class VendorShell extends ConsumerWidget {
  const VendorShell({super.key, required this.shell});
  final StatefulNavigationShell shell;

  static const _items = [
    (LucideIcons.house, 'Home'),
    (LucideIcons.search, 'Find suppliers'),
    (LucideIcons.handshake, 'Bookings'),
    (LucideIcons.listTodo, 'My Work'),
    (LucideIcons.store, 'Business'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final badges = ref.watch(_tabBadgesProvider).value ?? (0, 0);
    final counts = [0, 0, badges.$1, badges.$2, 0];
    final wide = MediaQuery.sizeOf(context).width >= EvBreakpoints.tablet;

    void go(int i) {
      HapticFeedback.selectionClick();
      shell.goBranch(i, initialLocation: i == shell.currentIndex);
    }

    final body = _IncomingBanner(child: shell);

    if (wide) {
      return Scaffold(
        body: Row(children: [
          NavigationRail(
            backgroundColor: EvColors.warmWhite,
            selectedIndex: shell.currentIndex,
            onDestinationSelected: go,
            labelType: NavigationRailLabelType.all,
            indicatorColor: EvColors.forestTint,
            leading: const Padding(padding: EdgeInsets.symmetric(vertical: EvSpace.x5), child: EvendaMark(size: 36)),
            selectedLabelTextStyle: EvType.caption.copyWith(color: EvColors.forest, fontWeight: FontWeight.w700),
            unselectedLabelTextStyle: EvType.caption,
            destinations: [
              for (var i = 0; i < _items.length; i++)
                NavigationRailDestination(
                  icon: Badge(isLabelVisible: counts[i] > 0, label: Text('${counts[i]}'), backgroundColor: EvColors.bronze, child: Icon(_items[i].$1, color: EvColors.ink2)),
                  selectedIcon: Icon(_items[i].$1, color: EvColors.forest),
                  label: Text(_items[i].$2),
                ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: Center(
              child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 820), child: body),
            ),
          ),
        ]),
      );
    }

    return Scaffold(
      body: body,
      bottomNavigationBar: _BottomNav(index: shell.currentIndex, counts: counts, onTap: go),
    );
  }
}

class _BottomNav extends StatelessWidget {
  const _BottomNav({required this.index, required this.counts, required this.onTap});
  final int index;
  final List<int> counts;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(color: EvColors.warmWhite, border: Border(top: BorderSide(color: EvColors.sand))),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 62,
          child: Row(children: [
            for (var i = 0; i < VendorShell._items.length; i++)
              Expanded(
                child: Semantics(
                  selected: i == index,
                  button: true,
                  label: VendorShell._items[i].$2,
                  child: InkWell(
                    onTap: () => onTap(i),
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Stack(clipBehavior: Clip.none, children: [
                        AnimatedContainer(
                          duration: EvMotion.of(context, EvMotion.fast),
                          curve: EvMotion.standard,
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                          decoration: BoxDecoration(
                            color: i == index ? EvColors.forestTint : Colors.transparent,
                            borderRadius: BorderRadius.circular(EvRadius.pill),
                          ),
                          child: Icon(VendorShell._items[i].$1, size: 21, color: i == index ? EvColors.forest : EvColors.ink3),
                        ),
                        if (counts[i] > 0)
                          Positioned(
                            right: 6,
                            top: -2,
                            child: Container(
                              constraints: const BoxConstraints(minWidth: 16),
                              height: 16,
                              padding: const EdgeInsets.symmetric(horizontal: 4),
                              alignment: Alignment.center,
                              decoration: BoxDecoration(color: EvColors.bronze, borderRadius: BorderRadius.circular(8), border: Border.all(color: EvColors.warmWhite, width: 1.5)),
                              child: Text('${counts[i]}', style: EvType.caption.copyWith(color: EvColors.inkOnDark, fontSize: 9.5, height: 1, fontWeight: FontWeight.w700)),
                            ),
                          ),
                      ]),
                      const SizedBox(height: 3),
                      Text(
                        i == 1 ? 'Find' : VendorShell._items[i].$2,
                        style: EvType.caption.copyWith(
                          fontSize: 11,
                          color: i == index ? EvColors.forest : EvColors.ink3,
                          fontWeight: i == index ? FontWeight.w700 : FontWeight.w500,
                        ),
                      ),
                    ]),
                  ),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}

/// Compact header for top-level tabs: title, demo marker, notifications.
/// Deliberately small so operational content starts high on the screen.
class TabHeader extends ConsumerWidget implements PreferredSizeWidget {
  const TabHeader({super.key, required this.title, this.actions = const [], this.bottom});
  final String title;
  final List<Widget> actions;
  final PreferredSizeWidget? bottom;

  @override
  Size get preferredSize => Size.fromHeight(56 + (bottom?.preferredSize.height ?? 0));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unread = ref.watch(unreadCountProvider).value ?? 0;
    return AppBar(
      title: Row(children: [
        Flexible(child: Text(title, overflow: TextOverflow.ellipsis)),
      ]),
      bottom: bottom,
      actions: [
        ...actions,
        EvIconButton(LucideIcons.bell, tooltip: 'Notifications', badge: unread, onPressed: () => context.push('/notifications')),
        const SizedBox(width: 8),
      ],
    );
  }
}

/// Slides a banner in from the top when a notification arrives while the
/// app is open. Tapping opens it; it leaves on its own after 5 s.
class _IncomingBanner extends ConsumerStatefulWidget {
  const _IncomingBanner({required this.child});
  final Widget child;

  @override
  ConsumerState<_IncomingBanner> createState() => _IncomingBannerState();
}

class _IncomingBannerState extends ConsumerState<_IncomingBanner> {
  StreamSubscription<AppNotification>? _sub;
  String? _subscribedFor;
  AppNotification? _current;
  Timer? _timer;

  void _subscribe(String bizId) {
    if (_subscribedFor == bizId) return;
    _sub?.cancel();
    _subscribedFor = bizId;
    _sub = ref.read(backendProvider).notifications.incoming(bizId).listen((n) {
      if (!mounted || n.digest) return;
      HapticFeedback.lightImpact();
      setState(() => _current = n);
      _timer?.cancel();
      _timer = Timer(const Duration(seconds: 5), () {
        if (mounted) setState(() => _current = null);
      });
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _timer?.cancel();
    super.dispose();
  }

  IconData _icon(NotificationCategory c) => switch (c) {
        NotificationCategory.inventory => LucideIcons.packagePlus,
        NotificationCategory.booking => LucideIcons.handshake,
        NotificationCategory.task => LucideIcons.alarmClock,
        NotificationCategory.now => LucideIcons.zap,
        NotificationCategory.system => LucideIcons.bell,
      };

  @override
  Widget build(BuildContext context) {
    final biz = ref.watch(myBusinessProvider).value;
    if (biz != null) _subscribe(biz.id);
    final n = _current;
    return Stack(children: [
      widget.child,
      Positioned(
        left: 12,
        right: 12,
        top: MediaQuery.paddingOf(context).top + 8,
        child: AnimatedSwitcher(
          duration: EvMotion.of(context, EvMotion.slow),
          switchInCurve: EvMotion.spring,
          switchOutCurve: EvMotion.accelerate,
          transitionBuilder: (child, a) => SlideTransition(
            position: Tween(begin: const Offset(0, -1.3), end: Offset.zero).animate(a),
            child: FadeTransition(opacity: a, child: child),
          ),
          child: n == null
              ? const SizedBox.shrink(key: ValueKey('none'))
              : Material(
                  key: ValueKey(n.id),
                  color: EvColors.ink,
                  borderRadius: EvRadius.mdAll,
                  elevation: 0,
                  child: InkWell(
                    borderRadius: EvRadius.mdAll,
                    onTap: () {
                      setState(() => _current = null);
                      ref.read(backendProvider).notifications.markRead(n.id);
                      if (n.route != null) context.push(n.route!);
                    },
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(borderRadius: EvRadius.mdAll, boxShadow: EvShadow.floating),
                      child: Row(children: [
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(color: n.category == NotificationCategory.now ? EvColors.bronze : EvColors.forestSoft, borderRadius: EvRadius.smAll),
                          child: Icon(_icon(n.category), size: 18, color: EvColors.inkOnDark),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                            Text(n.title, style: EvType.smallStrong.copyWith(color: EvColors.inkOnDark), maxLines: 2, overflow: TextOverflow.ellipsis),
                            if (n.body.isNotEmpty)
                              Text(n.body, style: EvType.caption.copyWith(color: EvColors.sand), maxLines: 1, overflow: TextOverflow.ellipsis),
                          ]),
                        ),
                        const Icon(LucideIcons.chevronRight, size: 18, color: EvColors.sand),
                      ]),
                    ),
                  ),
                ),
        ),
      ),
    ]);
  }
}
