import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/connectivity.dart';
import '../motion.dart';
import '../theme.dart';
import '../tokens.dart';
import 'controls.dart';

/// Full-page offline states on screen; the strip steps aside while one shows,
/// so "No internet connection" appears once.
final _offlinePages = ValueNotifier<int>(0);

/// Full offline state, kept as plain as the big apps do it: one icon, a short
/// title, one sentence, "Try again". The screen reloads itself as soon as the
/// connection comes back, and keeps retrying quietly while it waits.
class OfflineState extends ConsumerStatefulWidget {
  const OfflineState({super.key, this.onRetry, this.compact = false});
  final VoidCallback? onRetry;
  final bool compact;

  @override
  ConsumerState<OfflineState> createState() => _OfflineStateState();
}

class _OfflineStateState extends ConsumerState<OfflineState> {
  Timer? _autoRetry;
  bool _trying = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _offlinePages.value++);
    // Connected but nothing gets through (no data bundle, captive Wi-Fi):
    // the radio never flips, so keep quietly retrying in the background.
    _autoRetry = Timer.periodic(const Duration(seconds: 15), (_) {
      if (ref.read(onlineProvider).value == true) widget.onRetry?.call();
    });
  }

  @override
  void dispose() {
    _autoRetry?.cancel();
    WidgetsBinding.instance.addPostFrameCallback((_) => _offlinePages.value--);
    super.dispose();
  }

  // A short spinner on the button, so a tap visibly does something.
  Future<void> _retry() async {
    setState(() => _trying = true);
    widget.onRetry?.call();
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    if (mounted) setState(() => _trying = false);
  }

  @override
  Widget build(BuildContext context) {
    // Back online: reload without making the vendor tap anything.
    ref.listen(onlineProvider, (prev, next) {
      if (prev?.value == false && next.value == true) widget.onRetry?.call();
    });
    final online = ref.watch(onlineProvider).value ?? false;

    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: EvSpace.x8,
          vertical: widget.compact ? EvSpace.x5 : EvSpace.x8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              online ? LucideIcons.cloudOff : LucideIcons.wifiOff,
              size: widget.compact ? 32 : 40,
              color: EvColors.ink3,
            ),
            const SizedBox(height: EvSpace.x4),
            Text(
              online ? 'Can’t reach Evenda' : 'No internet connection',
              style: EvType.headline,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: EvSpace.x2),
            Text(
              online
                  ? 'Your connection isn’t getting through. Check your data balance or Wi-Fi.'
                  : 'Turn on mobile data or Wi-Fi to continue.',
              style: EvType.small,
              textAlign: TextAlign.center,
            ),
            if (widget.onRetry != null) ...[
              const SizedBox(height: EvSpace.x5),
              EvButton(
                'Try again',
                onPressed: _trying ? null : _retry,
                loading: _trying,
                kind: EvButtonKind.secondary,
                compact: true,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// App-wide connection strip, the way the big apps do it: a slim full-width
/// bar at the top that pushes the screen down (nothing floats over content),
/// "No internet connection" while offline, then green "Back online" for 2 s.
class OfflineBanner extends ConsumerStatefulWidget {
  const OfflineBanner({super.key, required this.child, this.onReconnect});
  final Widget child;
  final VoidCallback? onReconnect;

  @override
  ConsumerState<OfflineBanner> createState() => _OfflineBannerState();
}

class _OfflineBannerState extends ConsumerState<OfflineBanner> {
  bool _showBack = false;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(onlineProvider, (prev, next) {
      if (prev?.value == false && next.value == true) {
        widget.onReconnect?.call();
        setState(() => _showBack = true);
        _timer?.cancel();
        _timer = Timer(const Duration(seconds: 2), () {
          if (mounted) setState(() => _showBack = false);
        });
      } else if (next.value == false) {
        _timer?.cancel();
        setState(() => _showBack = false);
      }
    });
    final offline = ref.watch(onlineProvider).value == false;
    return ValueListenableBuilder<int>(
      valueListenable: _offlinePages,
      builder: (context, pages, _) => _strip(context, offline, pages > 0),
    );
  }

  Widget _strip(BuildContext context, bool offline, bool pageSaysOffline) {
    final visible = (offline && !pageSaysOffline) || _showBack;
    final top = MediaQuery.paddingOf(context).top;
    final color = offline ? EvColors.ink : EvColors.success;

    final body = Column(
      children: [
        // The strip owns the status-bar area while it shows.
        AnimatedContainer(
          duration: EvMotion.of(context, EvMotion.base),
          curve: Curves.easeOut,
          height: visible ? top + 28 : 0,
          color: color,
          // Material gives the text its style: the strip sits above the app's screens.
          child: Material(
            type: MaterialType.transparency,
            child: ClipRect(
              child: Padding(
                padding: EdgeInsets.only(top: top),
                child: Semantics(
                  liveRegion: true,
                  child: Center(
                    child: Text(
                      offline ? 'No internet connection' : 'Back online',
                      style: EvType.caption.copyWith(
                        color: EvColors.inkOnDark,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeTop: visible,
            child: widget.child,
          ),
        ),
      ],
    );
    // Light status-bar icons on the dark strip, dark again afterwards (Android
    // keeps the last style). Screens with their own style still win: theirs is deeper.
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: visible && !EvColors.isDark ? SystemUiOverlayStyle.light : EvTheme.statusBar,
      child: body,
    );
  }
}
