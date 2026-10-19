import 'package:flutter/material.dart';

/// Motion system. Motion in Evenda always communicates a state change:
/// something arrived, moved, completed or changed status. Nothing loops
/// decoratively; the Evenda Now broadcast ripple runs only while the
/// request is actually waiting for replies.
abstract final class EvMotion {
  static const instant = Duration(milliseconds: 90);
  static const fast = Duration(milliseconds: 160); // state toggles, pills
  static const base = Duration(milliseconds: 240); // page transitions, expand
  static const slow = Duration(milliseconds: 380); // sheets, list arrivals
  static const emphasis = Duration(milliseconds: 620); // success moments
  static const stagger = Duration(milliseconds: 70); // map marker reveal step

  static const standard = Cubic(0.2, 0.0, 0.0, 1.0);
  static const decelerate = Cubic(0.0, 0.0, 0.2, 1.0);
  static const accelerate = Cubic(0.4, 0.0, 1.0, 1.0);
  static const spring = Cubic(0.34, 1.36, 0.64, 1.0); // slight overshoot for arrivals

  /// True when the OS asks for reduced motion. Callers collapse durations to
  /// zero (or swap to a plain fade) when this is set.
  static bool reduced(BuildContext context) => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  static Duration of(BuildContext context, Duration d) => reduced(context) ? Duration.zero : d;
}

/// Page transition: a short fade-through with a 12 px rise. Reduced motion
/// gets a plain cross-fade.
class EvPageTransitionsBuilder extends PageTransitionsBuilder {
  const EvPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(PageRoute<T> route, BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation, Widget child) {
    return EvFadeThrough(animation: animation, secondary: secondaryAnimation, child: child);
  }
}

class EvFadeThrough extends StatelessWidget {
  const EvFadeThrough({super.key, required this.animation, required this.secondary, required this.child});
  final Animation<double> animation;
  final Animation<double> secondary;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (EvMotion.reduced(context)) {
      return FadeTransition(opacity: animation, child: child);
    }
    final enter = CurvedAnimation(parent: animation, curve: EvMotion.standard, reverseCurve: EvMotion.accelerate);
    final exit = CurvedAnimation(parent: secondary, curve: EvMotion.standard);
    return FadeTransition(
      opacity: Tween(begin: 1.0, end: 0.0).animate(CurvedAnimation(parent: exit, curve: const Interval(0, 0.5))),
      child: FadeTransition(
        opacity: CurvedAnimation(parent: enter, curve: const Interval(0.15, 1)),
        child: SlideTransition(
          position: Tween(begin: const Offset(0, 0.02), end: Offset.zero).animate(enter),
          child: child,
        ),
      ),
    );
  }
}

/// Animates an integer change (stock counts, totals) so the new value reads as an update.
class EvAnimatedCount extends StatelessWidget {
  const EvAnimatedCount({super.key, required this.value, this.style, this.format});
  final int value;
  final TextStyle? style;
  final String Function(int)? format;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(end: value.toDouble()),
      duration: EvMotion.of(context, EvMotion.slow),
      curve: EvMotion.standard,
      builder: (context, v, _) {
        final n = v.round();
        return Text(format?.call(n) ?? '$n', style: style);
      },
    );
  }
}

/// One-shot entrance for items that just arrived (new request, new offer).
class EvArrive extends StatefulWidget {
  const EvArrive({super.key, required this.child, this.delay = Duration.zero, this.offset = 16});
  final Widget child;
  final Duration delay;
  final double offset;

  @override
  State<EvArrive> createState() => _EvArriveState();
}

class _EvArriveState extends State<EvArrive> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: EvMotion.slow);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (EvMotion.reduced(context)) {
      _c.value = 1;
    } else if (_c.status == AnimationStatus.dismissed) {
      Future.delayed(widget.delay, () {
        if (mounted) _c.forward();
      });
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final a = CurvedAnimation(parent: _c, curve: EvMotion.standard);
    return AnimatedBuilder(
      animation: a,
      builder: (context, child) => Opacity(
        opacity: a.value,
        child: Transform.translate(offset: Offset(0, widget.offset * (1 - a.value)), child: child),
      ),
      child: widget.child,
    );
  }
}
