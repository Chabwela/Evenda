import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/connectivity.dart';
import '../motion.dart';
import '../theme.dart';
import '../tokens.dart';
import 'controls.dart';
import 'logo.dart';

/// Full offline state: the Evenda mark sends out signal arcs while it waits,
/// and the screen reloads itself as soon as the connection comes back.
class OfflineState extends ConsumerStatefulWidget {
  const OfflineState({super.key, this.onRetry, this.compact = false});
  final VoidCallback? onRetry;
  final bool compact;

  @override
  ConsumerState<OfflineState> createState() => _OfflineStateState();
}

class _OfflineStateState extends ConsumerState<OfflineState> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400));
  Timer? _autoRetry;

  @override
  void initState() {
    super.initState();
    // Connected but nothing gets through (no data bundle, captive Wi-Fi):
    // the radio never flips, so keep quietly retrying in the background.
    _autoRetry = Timer.periodic(const Duration(seconds: 15), (_) {
      if (ref.read(onlineProvider).value == true) widget.onRetry?.call();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (EvMotion.reduced(context)) {
      _c.value = 0.5;
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _autoRetry?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Back online: reload without making the vendor tap anything.
    ref.listen(onlineProvider, (prev, next) {
      if (prev?.value == false && next.value == true) widget.onRetry?.call();
    });
    final online = ref.watch(onlineProvider).value ?? false;
    final art = widget.compact ? 120.0 : 168.0;

    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: EvSpace.x8, vertical: widget.compact ? EvSpace.x5 : EvSpace.x8),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ExcludeSemantics(
            child: SizedBox.square(
              dimension: art,
              child: AnimatedBuilder(
                animation: _c,
                builder: (_, child) => CustomPaint(painter: _SignalPainter(_c.value), child: child),
                child: Align(
                  alignment: const Alignment(0, 0.55),
                  child: Container(
                    width: art * 0.46,
                    height: art * 0.46,
                    decoration: BoxDecoration(color: EvColors.warmWhite, shape: BoxShape.circle, border: Border.all(color: EvColors.sand, width: 1.5), boxShadow: EvShadow.raised),
                    child: Center(child: EvendaMark(size: art * 0.3)),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: EvSpace.x4),
          Text(online ? 'Evenda can’t be reached' : 'You’re offline', style: widget.compact ? EvType.headline : EvType.displaySm, textAlign: TextAlign.center),
          const SizedBox(height: EvSpace.x2),
          Text(
            online
                ? 'Your phone is connected, but the internet isn’t getting through. Check your data balance or Wi-Fi, then try again.'
                : 'Turn on mobile data or Wi-Fi. Evenda needs internet to show live stock, quotes and bookings.',
            style: EvType.small,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: EvSpace.x4),
          _WaitingLine(controller: _c, online: online),
          if (widget.onRetry != null) ...[
            const SizedBox(height: EvSpace.x4),
            EvButton('Try again', onPressed: widget.onRetry, kind: EvButtonKind.secondary, icon: LucideIcons.refreshCw, compact: true),
          ],
        ]),
      ),
    );
  }
}

class _WaitingLine extends StatelessWidget {
  const _WaitingLine({required this.controller, required this.online});
  final AnimationController controller;
  final bool online;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: controller,
        builder: (_, _) {
          final dots = '.' * (1 + (controller.value * 3).floor() % 3);
          return Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 7, height: 7, decoration: BoxDecoration(color: online ? EvColors.warning : EvColors.ink3, shape: BoxShape.circle)),
            const SizedBox(width: 8),
            SizedBox(
              width: 220,
              child: Text(
                online ? 'Reconnecting$dots' : 'Waiting for a connection$dots',
                style: EvType.caption,
                textAlign: TextAlign.left,
              ),
            ),
          ]);
        },
      );
}

/// Three arcs above the mark, rising and fading one after another like a
/// signal searching for a tower. A small bronze slash crosses the outer arc.
class _SignalPainter extends CustomPainter {
  _SignalPainter(this.t);
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height * 0.775);
    final base = size.width * 0.3;
    for (var i = 0; i < 3; i++) {
      final phase = (t - i * 0.18) % 1.0;
      final glow = math.sin(phase * math.pi).clamp(0.0, 1.0);
      final r = base + i * size.width * 0.12;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = size.width * 0.035
        ..color = Color.lerp(EvColors.sand, EvColors.forestSoft, glow * 0.85)!;
      canvas.drawArc(Rect.fromCircle(center: c, radius: r), math.pi * 1.22, math.pi * 0.56, false, paint);
    }
    // The "no signal" slash, gently breathing.
    final outer = base + 2 * size.width * 0.12;
    final s = 0.85 + 0.15 * math.sin(t * math.pi * 2);
    final a = Offset(c.dx + outer * 0.5 * s, c.dy - outer * 1.02 * s);
    final b = Offset(c.dx + outer * 0.86 * s, c.dy - outer * 0.62 * s);
    canvas.drawLine(a, b, Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = size.width * 0.035
      ..color = EvColors.bronze);
  }

  @override
  bool shouldRepaint(_SignalPainter old) => old.t != t;
}

/// App-wide strip that slides in under the status bar when the connection
/// drops, and briefly says "Back online" when it returns.
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
        _timer = Timer(const Duration(milliseconds: 2600), () {
          if (mounted) setState(() => _showBack = false);
        });
      } else if (next.value == false) {
        _timer?.cancel();
        setState(() => _showBack = false);
      }
    });
    final offline = ref.watch(onlineProvider).value == false;
    final visible = offline || _showBack;
    final top = MediaQuery.paddingOf(context).top;

    return Stack(children: [
      widget.child,
      Positioned(
        left: 0,
        right: 0,
        top: 0,
        child: IgnorePointer(
          child: AnimatedSlide(
            offset: visible ? Offset.zero : const Offset(0, -1.2),
            duration: EvMotion.of(context, EvMotion.slow),
            curve: visible ? EvMotion.spring : EvMotion.accelerate,
            child: AnimatedOpacity(
              opacity: visible ? 1 : 0,
              duration: EvMotion.of(context, EvMotion.base),
              child: Padding(
                padding: EdgeInsets.fromLTRB(EvSpace.gutter, top + 6, EvSpace.gutter, 0),
                child: Center(
                  child: Semantics(
                    liveRegion: true,
                    child: _BannerPill(back: !offline && _showBack),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ]);
  }
}

class _BannerPill extends StatefulWidget {
  const _BannerPill({required this.back});
  final bool back;

  @override
  State<_BannerPill> createState() => _BannerPillState();
}

class _BannerPillState extends State<_BannerPill> with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (EvMotion.reduced(context)) {
      _pulse.value = 1;
    } else if (!_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final back = widget.back;
    return Material(
      color: Colors.transparent,
      child: AnimatedContainer(
        duration: EvMotion.of(context, EvMotion.base),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: back ? EvColors.success : EvColors.forest,
          borderRadius: BorderRadius.circular(999),
          boxShadow: EvShadow.raised,
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (back)
            const Icon(LucideIcons.wifi, size: 16, color: EvColors.inkOnDark)
          else
            FadeTransition(
              opacity: Tween(begin: 0.35, end: 1.0).animate(_pulse),
              child: const Icon(LucideIcons.wifiOff, size: 16, color: Color(0xFFC9A27A)),
            ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              back ? 'Back online — refreshing' : 'No internet · Evenda will reconnect automatically',
              style: EvType.smallStrong.copyWith(color: EvColors.inkOnDark),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ]),
      ),
    );
  }
}
