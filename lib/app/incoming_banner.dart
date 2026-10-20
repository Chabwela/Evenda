import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../design/ev.dart';
import '../domain/models.dart';
import 'providers.dart';
import 'router.dart';

/// Slides a banner in from the top when a notification arrives while the app
/// is open (in the background, the phone's own notification does this).
///
/// It sits above every route, so it also shows over full-screen pages such as
/// an Evenda Now request, where offers arrive. Evenda Now banners stay longer,
/// vibrate harder and offer "View"; others leave after 5 s. Tapping opens it.
class IncomingBanner extends ConsumerStatefulWidget {
  const IncomingBanner({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<IncomingBanner> createState() => _IncomingBannerState();
}

class _IncomingBannerState extends ConsumerState<IncomingBanner> {
  StreamSubscription<AppNotification>? _sub;
  String? _subscribedFor;
  AppNotification? _current;
  Timer? _timer;

  void _subscribe(String? bizId) {
    if (_subscribedFor == bizId) return;
    _sub?.cancel();
    _sub = null;
    _subscribedFor = bizId;
    if (bizId == null) return;
    _sub = ref.read(backendProvider).notifications.incoming(bizId).listen((n) {
      if (!mounted || n.digest) return;
      final urgent = n.category == NotificationCategory.now;
      urgent ? HapticFeedback.heavyImpact() : HapticFeedback.lightImpact();
      setState(() => _current = n);
      _timer?.cancel();
      _timer = Timer(Duration(seconds: urgent ? 10 : 5), _dismiss);
    });
  }

  void _dismiss() {
    if (mounted) setState(() => _current = null);
  }

  void _open(AppNotification n) {
    _timer?.cancel();
    setState(() => _current = null);
    ref.read(backendProvider).notifications.markRead(n.id);
    if (n.route != null) ref.read(routerProvider).push(n.route!);
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
    // Vendors only: staff accounts have no business, so nothing subscribes.
    _subscribe(ref.watch(myBusinessProvider).value?.id);
    final n = _current;
    final urgent = n?.category == NotificationCategory.now;
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
              : Dismissible(
                  key: ValueKey(n.id),
                  direction: DismissDirection.up,
                  onDismissed: (_) => setState(() => _current = null),
                  child: Material(
                    color: EvColors.ink,
                    borderRadius: EvRadius.mdAll,
                    child: InkWell(
                      borderRadius: EvRadius.mdAll,
                      onTap: () => _open(n),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(borderRadius: EvRadius.mdAll, boxShadow: EvShadow.floating),
                        child: Row(children: [
                          Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(color: urgent ? EvColors.bronze : EvColors.forestSoft, borderRadius: EvRadius.smAll),
                            child: Icon(_icon(n.category), size: 18, color: EvColors.inkOnDark),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                              if (urgent)
                                Text('EVENDA NOW', style: EvType.caption.copyWith(color: EvColors.sand, fontWeight: FontWeight.w700, letterSpacing: 1)),
                              Text(n.title, style: EvType.smallStrong.copyWith(color: EvColors.inkOnDark), maxLines: 2, overflow: TextOverflow.ellipsis),
                              if (n.body.isNotEmpty)
                                Text(n.body, style: EvType.caption.copyWith(color: EvColors.sand), maxLines: 1, overflow: TextOverflow.ellipsis),
                            ]),
                          ),
                          const SizedBox(width: 8),
                          if (urgent && n.route != null)
                            FilledButton(
                              onPressed: () => _open(n),
                              style: FilledButton.styleFrom(
                                backgroundColor: EvColors.bronze,
                                foregroundColor: EvColors.inkOnDark,
                                visualDensity: VisualDensity.compact,
                                padding: const EdgeInsets.symmetric(horizontal: 14),
                              ),
                              child: const Text('View'),
                            )
                          else
                            const Icon(LucideIcons.chevronRight, size: 18, color: EvColors.sand),
                        ]),
                      ),
                    ),
                  ),
                ),
        ),
      ),
    ]);
  }
}
