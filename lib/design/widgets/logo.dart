import 'package:flutter/material.dart';

import '../motion.dart';
import '../theme.dart';
import '../tokens.dart';

/// The Evenda mark, drawn in code so it can animate. Same geometry as the app
/// icon (tool/icon/evenda_icon.mjs, assets/brand/evenda_mark.svg): an "e" cut
/// out of a disc, forest above the aperture and bronze below it.
class EvendaMark extends StatefulWidget {
  const EvendaMark({super.key, this.size = 48, this.animate = false, this.onDark});
  final double size;
  final bool animate;
  /// Cream and light bronze, for dark grounds. Defaults to dark mode.
  final bool? onDark;

  /// Length of the launch animation (the launch screen waits for it).
  static const introDuration = Duration(milliseconds: 1300);

  @override
  State<EvendaMark> createState() => _EvendaMarkState();
}

class _EvendaMarkState extends State<EvendaMark> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: EvendaMark.introDuration);

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
          builder: (_, _) => CustomPaint(size: Size.square(widget.size), painter: _MarkPainter(_c.value, widget.onDark ?? EvColors.isDark)),
        ),
      );
}

class _MarkPainter extends CustomPainter {
  _MarkPainter(this.t, this.onDark);
  final double t;
  final bool onDark;

  // Icon geometry (1024 canvas: R 270, counter 134, crossbar 62, aperture 62
  // starting 44 left of centre) scaled so the disc fills the 120 box.
  static const _k = 59 / 270;
  static const _r = 270 * _k, _ri = 134 * _k, _y1 = 31 * _k, _slot = 62 * _k, _xs = -44 * _k;

  /// The mark at a point of the intro: [counter] and [slot] run 0..1 as the
  /// "e" is carved out of the disc (both 1 = the finished mark).
  static Path _shape(double counter, double slot) {
    const c = Offset(60, 60);
    var p = Path()..addOval(Rect.fromCircle(center: c, radius: _r));
    if (counter > 0) {
      final ri = _ri * counter;
      final cut = Path()
        ..moveTo(c.dx - ri, c.dy - _y1)
        ..arcToPoint(Offset(c.dx + ri, c.dy - _y1), radius: Radius.circular(ri))
        ..close();
      p = Path.combine(PathOperation.difference, p, cut);
    }
    if (slot > 0) {
      // Slides in from beyond the right edge until it reaches its start point.
      const end = 130.0, start = 60 + _xs;
      final left = end - (end - start) * slot;
      final cut = Path()..addRRect(RRect.fromLTRBR(left, c.dy + _y1, end + _slot, c.dy + _y1 + _slot, const Radius.circular(_slot / 2)));
      p = Path.combine(PathOperation.difference, p, cut);
    }
    return p;
  }

  static final Path _final = _shape(1, 1);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 120);
    final main = onDark ? EvBrand.cream : EvBrand.forest;
    final accent = onDark ? EvBrand.bronzeLight : EvBrand.bronze;
    const split = 60 + _y1 + _slot; // bronze below the aperture

    // Starts as the plain disc the native splash shows, so the hand-off is
    // seamless; then bronze rises, the counter opens, the aperture slides in.
    double phase(double from, double to, Curve curve) => curve.transform(((t - from) / (to - from)).clamp(0.0, 1.0));
    final rise = phase(0.0, 0.45, Curves.easeOutCubic);
    final counter = phase(0.3, 0.7, Curves.easeOutBack);
    final slot = phase(0.55, 0.95, Curves.easeOutCubic);

    canvas.clipPath(t >= 1 ? _final : _shape(counter.clamp(0.0, 1.08), slot));
    canvas.drawRect(const Rect.fromLTRB(0, 0, 120, 120), Paint()..color = main);
    final top = 120 - (120 - split) * rise;
    canvas.drawRect(Rect.fromLTRB(0, top, 120, 120), Paint()..color = accent);
  }

  @override
  bool shouldRepaint(_MarkPainter old) => old.t != t || old.onDark != onDark;
}

/// Mark + wordmark. The wordmark stays one colour; the mark carries the bronze.
class EvendaLogo extends StatelessWidget {
  const EvendaLogo({super.key, this.size = 28, this.onDark});
  final double size;
  final bool? onDark;

  @override
  Widget build(BuildContext context) {
    final dark = onDark ?? EvColors.isDark;
    final main = dark ? EvBrand.cream : EvBrand.forest;
    final style = EvType.title.copyWith(fontSize: size * 0.82, color: main, letterSpacing: 0.2, fontWeight: FontWeight.w600);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      EvendaMark(size: size, onDark: dark),
      SizedBox(width: size * 0.3),
      Text('evenda', style: style),
    ]);
  }
}
