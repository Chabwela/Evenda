import 'dart:ui' show PathMetric;

import 'package:flutter/material.dart';

import '../motion.dart';
import '../theme.dart';
import '../tokens.dart';

/// The Evenda mark, drawn in code so it can animate. Geometry matches
/// assets/brand/evenda_mark.svg: a forest "e" whose tail turns bronze and
/// ends in a dot.
class EvendaMark extends StatefulWidget {
  const EvendaMark({super.key, this.size = 48, this.animate = false, this.onDark = false});
  final double size;
  final bool animate;
  final bool onDark;

  @override
  State<EvendaMark> createState() => _EvendaMarkState();
}

class _EvendaMarkState extends State<EvendaMark> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));

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
  Widget build(BuildContext context) => Semantics(
        label: 'Evenda',
        child: AnimatedBuilder(
          animation: _c,
          builder: (_, _) => CustomPaint(size: Size.square(widget.size), painter: _MarkPainter(_c.value, widget.onDark)),
        ),
      );
}

class _MarkPainter extends CustomPainter {
  _MarkPainter(this.t, this.onDark);
  final double t;
  final bool onDark;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 120;
    canvas.scale(s);
    final main = onDark ? EvColors.cream : EvColors.forest;
    final accent = onDark ? const Color(0xFFC9A27A) : EvColors.bronze;
    Paint stroke(Color c) => Paint()
      ..color = c
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final e = Path()
      ..moveTo(38, 56)
      ..lineTo(90, 56)
      ..arcToPoint(const Offset(56, 90), radius: const Radius.circular(34), largeArc: true, clockwise: false);
    final tail = Path()
      ..moveTo(56, 90)
      ..lineTo(70, 90)
      ..quadraticBezierTo(86, 90, 86, 74)
      ..lineTo(86, 70);

    final p1 = Curves.easeInOutCubic.transform((t / 0.7).clamp(0, 1));
    final p2 = Curves.easeOutCubic.transform(((t - 0.6) / 0.25).clamp(0, 1));
    final p3 = EvMotion.spring.transform(((t - 0.8) / 0.2).clamp(0, 1));

    void drawPartial(Path path, double frac, Paint paint) {
      for (final PathMetric m in path.computeMetrics()) {
        canvas.drawPath(m.extractPath(0, m.length * frac), paint);
      }
    }

    drawPartial(e, p1, stroke(main));
    if (p2 > 0) drawPartial(tail, p2, stroke(accent));
    if (p3 > 0) canvas.drawCircle(const Offset(101, 92), 6.5 * p3, Paint()..color = accent);
  }

  @override
  bool shouldRepaint(_MarkPainter old) => old.t != t || old.onDark != onDark;
}

/// Mark + wordmark. The "v" picks up the bronze accent.
class EvendaLogo extends StatelessWidget {
  const EvendaLogo({super.key, this.size = 28, this.onDark = false});
  final double size;
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final main = onDark ? EvColors.cream : EvColors.forest;
    final accent = onDark ? const Color(0xFFC9A27A) : EvColors.bronze;
    final style = EvType.title.copyWith(fontSize: size * 0.82, color: main, letterSpacing: 0.2, fontWeight: FontWeight.w600);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      EvendaMark(size: size, onDark: onDark),
      const SizedBox(width: 6),
      Text.rich(TextSpan(style: style, children: [
        const TextSpan(text: 'e'),
        TextSpan(text: 'v', style: TextStyle(color: accent)),
        const TextSpan(text: 'enda'),
      ])),
    ]);
  }
}
