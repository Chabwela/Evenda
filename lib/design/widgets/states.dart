import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/errors.dart';
import '../motion.dart';
import '../theme.dart';
import '../tokens.dart';
import 'controls.dart';
import 'offline.dart';

/// The Evenda character family. Each has one job:
///  coordinator — onboarding and welcome
///  crate       — equipment and listings (and generic empty states)
///  calendar    — scheduling and tasks
///  chair       — celebration after a completed booking or setup
///  pin         — Evenda Now and location
enum Mascot {
  coordinator,
  crate,
  calendar,
  chair,
  pin;

  String get asset => 'assets/illustrations/$name.svg';
}

class MascotImage extends StatefulWidget {
  const MascotImage(this.mascot, {super.key, this.size = 120, this.animate = true});
  final Mascot mascot;
  final double size;
  final bool animate;

  @override
  State<MascotImage> createState() => _MascotImageState();
}

class _MascotImageState extends State<MascotImage> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: EvMotion.emphasis);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!widget.animate || EvMotion.reduced(context)) {
      _c.value = 1;
    } else if (_c.status == AnimationStatus.dismissed) {
      _c.forward();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final a = CurvedAnimation(parent: _c, curve: EvMotion.spring);
    return ExcludeSemantics(
      child: AnimatedBuilder(
        animation: a,
        builder: (_, child) => Opacity(
          opacity: _c.value.clamp(0, 1),
          child: Transform.translate(offset: Offset(0, 10 * (1 - a.value)), child: Transform.scale(scale: 0.92 + 0.08 * a.value, child: child)),
        ),
        child: SvgPicture.asset(widget.mascot.asset, width: widget.size, height: widget.size),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.title, this.body, this.mascot = Mascot.crate, this.action, this.onAction, this.compact = false});
  final String title;
  final String? body;
  final Mascot mascot;
  final String? action;
  final VoidCallback? onAction;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: EvSpace.x8, vertical: compact ? EvSpace.x6 : EvSpace.x10),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          MascotImage(mascot, size: compact ? 84 : 120),
          const SizedBox(height: EvSpace.x4),
          Text(title, style: compact ? EvType.headline : EvType.displaySm, textAlign: TextAlign.center),
          if (body != null) ...[
            const SizedBox(height: EvSpace.x2),
            Text(body!, style: EvType.small, textAlign: TextAlign.center),
          ],
          if (action != null) ...[
            const SizedBox(height: EvSpace.x5),
            EvButton(action!, onPressed: onAction, kind: EvButtonKind.secondary),
          ],
        ]),
      ),
    );
  }
}

/// Error with a recovery action. Offline errors get their own wording.
class ErrorState extends StatelessWidget {
  const ErrorState({super.key, required this.error, this.onRetry, this.compact = false});
  final Object error;
  final VoidCallback? onRetry;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final e = EvError.from(error);
    if (e.isOffline || e.code == 'timeout') return OfflineState(onRetry: onRetry, compact: compact);
    return Center(
      child: Padding(
        padding: EdgeInsets.all(compact ? EvSpace.x5 : EvSpace.x8),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 52,
            height: 52,
            decoration: const BoxDecoration(color: EvColors.dangerTint, shape: BoxShape.circle),
            child: const Icon(LucideIcons.circleAlert, color: EvColors.danger),
          ),
          const SizedBox(height: EvSpace.x3),
          Text(e.isForbidden ? 'Not allowed' : 'Couldn’t load this', style: EvType.headline),
          const SizedBox(height: EvSpace.x1),
          Text(e.userMessage, style: EvType.small, textAlign: TextAlign.center),
          if (onRetry != null) ...[
            const SizedBox(height: EvSpace.x4),
            EvButton('Try again', onPressed: onRetry, kind: EvButtonKind.secondary, icon: LucideIcons.refreshCw, compact: true),
          ],
        ]),
      ),
    );
  }
}

/// Skeleton blocks. A single gentle opacity pulse; static under reduced motion.
class Skeleton extends StatefulWidget {
  const Skeleton({super.key, this.rows = 4, this.media = false});
  final int rows;
  final bool media;

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (EvMotion.reduced(context)) {
      _c.value = 0.5;
    } else if (!_c.isAnimating) {
      _c.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget block(double w, double h, {double r = 6}) =>
        Container(width: w, height: h, decoration: BoxDecoration(color: EvColors.sand, borderRadius: BorderRadius.circular(r)));
    return Semantics(
      label: 'Loading',
      child: FadeTransition(
        opacity: Tween(begin: 0.55, end: 1.0).animate(_c),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: EvSpace.gutter, vertical: EvSpace.x4),
          child: Column(children: [
            for (var i = 0; i < widget.rows; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: EvSpace.x5),
                child: Row(children: [
                  block(widget.media ? 72 : 36, widget.media ? 72 : 36, r: widget.media ? 10 : 8),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      block(double.infinity, 13),
                      const SizedBox(height: 8),
                      FractionallySizedBox(widthFactor: 0.6, child: block(double.infinity, 11)),
                    ]),
                  ),
                ]),
              ),
          ]),
        ),
      ),
    );
  }
}

/// Uniform loading / error / empty / data handling for AsyncValue.
class AsyncView<T> extends StatelessWidget {
  const AsyncView({
    super.key,
    required this.value,
    required this.data,
    this.onRetry,
    this.isEmpty,
    this.empty,
    this.loading,
    this.sliver = false,
  });

  final AsyncValue<T> value;
  final Widget Function(T data) data;
  final VoidCallback? onRetry;
  final bool Function(T data)? isEmpty;
  final Widget? empty;
  final Widget? loading;
  final bool sliver;

  @override
  Widget build(BuildContext context) {
    Widget wrap(Widget w) => sliver ? SliverToBoxAdapter(child: w) : w;
    // Keep showing previous data while refreshing, so revalidation never flashes.
    if (value.hasValue) {
      final v = value.requireValue;
      if (isEmpty != null && isEmpty!(v) && empty != null) return wrap(empty!);
      return data(v);
    }
    if (value.hasError) return wrap(ErrorState(error: value.error!, onRetry: onRetry));
    return wrap(loading ?? const Skeleton());
  }
}

// ---------------------------------------------------------------------------
// Feedback
// ---------------------------------------------------------------------------

void showToast(BuildContext context, String message, {IconData? icon, String? action, VoidCallback? onAction}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Row(children: [
        if (icon != null) ...[Icon(icon, size: 18, color: EvColors.bronzeTint), const SizedBox(width: 10)],
        Expanded(child: Text(message)),
      ]),
      action: action == null ? null : SnackBarAction(label: action, onPressed: onAction ?? () {}),
      // Give people time to read and reach the button when there is one.
      duration: Duration(seconds: action == null ? 4 : 8),
    ));
}

void showError(BuildContext context, Object e) {
  final err = EvError.from(e);
  if (err.isOffline || err.code == 'timeout') {
    // Say plainly that nothing went through, so vendors don't wonder whether
    // a quote or booking was half-sent.
    showToast(
      context,
      err.code == 'timeout'
          ? 'The connection is too slow right now. Nothing was saved — try again in a moment.'
          : 'No internet, so nothing was sent. Turn on data or Wi-Fi and try again.',
      icon: LucideIcons.wifiOff,
    );
    return;
  }
  showToast(context, err.userMessage, icon: LucideIcons.circleAlert);
}

/// Runs an action with standard error toast; returns the result or null.
Future<T?> guard<T>(BuildContext context, Future<T> Function() action, {String? success}) async {
  try {
    final r = await action();
    if (success != null && context.mounted) showToast(context, success, icon: LucideIcons.circleCheck);
    return r;
  } catch (e) {
    if (context.mounted) showError(context, e);
    return null;
  }
}

Future<bool> confirmAction(BuildContext context, {required String title, required String body, String confirm = 'Confirm', bool destructive = false}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        TextButton(
          onPressed: () => Navigator.pop(c, true),
          style: TextButton.styleFrom(foregroundColor: destructive ? EvColors.danger : EvColors.forest),
          child: Text(confirm),
        ),
      ],
    ),
  );
  return r ?? false;
}

/// Confirmation that requires a recorded reason (admin and other sensitive actions).
Future<String?> confirmWithReason(BuildContext context, {required String title, required String body, String confirm = 'Confirm', bool required = true, bool destructive = false}) {
  final c = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) {
        final ok = !required || c.text.trim().length >= 5;
        return AlertDialog(
          title: Text(title),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(body),
            const SizedBox(height: EvSpace.x4),
            TextField(
              controller: c,
              autofocus: true,
              maxLines: 3,
              minLines: 2,
              onChanged: (_) => set(() {}),
              decoration: InputDecoration(hintText: required ? 'Reason (recorded in the audit log)' : 'Note (optional)'),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            TextButton(
              onPressed: ok ? () => Navigator.pop(ctx, c.text.trim()) : null,
              style: TextButton.styleFrom(foregroundColor: destructive ? EvColors.danger : EvColors.forest),
              child: Text(confirm),
            ),
          ],
        );
      },
    ),
  );
}

// ---------------------------------------------------------------------------
// Success moment
// ---------------------------------------------------------------------------

/// One-shot celebration: the chair mascot rises and a short confetti burst
/// plays once (about 1 s). Under reduced motion only the static image shows.
class Celebration extends StatefulWidget {
  const Celebration({super.key, this.size = 150});
  final double size;

  @override
  State<Celebration> createState() => _CelebrationState();
}

class _CelebrationState extends State<Celebration> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));
  final _rand = math.Random(7);
  late final _bits = List.generate(22, (i) => (_rand.nextDouble() * 2 * math.pi, 0.55 + _rand.nextDouble() * 0.45, i % 4));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (EvMotion.reduced(context)) {
      _c.value = 1;
    } else if (_c.status == AnimationStatus.dismissed) {
      _c.forward();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size * 1.6,
      height: widget.size * 1.3,
      child: Stack(alignment: Alignment.center, children: [
        if (!EvMotion.reduced(context))
          AnimatedBuilder(
            animation: _c,
            builder: (_, _) => CustomPaint(size: Size(widget.size * 1.6, widget.size * 1.3), painter: _ConfettiPainter(_c.value, _bits)),
          ),
        MascotImage(Mascot.chair, size: widget.size),
      ]),
    );
  }
}

class _ConfettiPainter extends CustomPainter {
  _ConfettiPainter(this.t, this.bits);
  final double t;
  final List<(double angle, double reach, int colour)> bits;
  static const _colours = [EvColors.forest, EvColors.bronze, EvColors.forestSoft, Color(0xFFC9A27A)];

  @override
  void paint(Canvas canvas, Size size) {
    if (t == 0 || t == 1) return;
    final c = size.center(Offset.zero);
    final e = Curves.easeOutCubic.transform(t);
    final fade = t < 0.7 ? 1.0 : (1 - (t - 0.7) / 0.3);
    for (final (a, reach, ci) in bits) {
      final r = size.shortestSide * 0.55 * reach * e;
      final p = c + Offset(math.cos(a) * r, math.sin(a) * r + 30 * t * t);
      final paint = Paint()..color = _colours[ci].withValues(alpha: fade);
      canvas.save();
      canvas.translate(p.dx, p.dy);
      canvas.rotate(a + t * 6);
      canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(-4, -2, 8, 4), const Radius.circular(1)), paint);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_ConfettiPainter old) => old.t != t;
}
