import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../design/ev.dart';

/// The welcome hero: a small live map of Lusaka where event vendors lend
/// stock to each other. Arcs draw between neighbourhoods and an item chip
/// travels along each one, ending in a pulse at the vendor who needed it.
/// That is Evenda in one picture: the stock you're short of is nearby.
class WelcomeHero extends StatefulWidget {
  const WelcomeHero({super.key, this.height = 300});
  final double height;

  @override
  State<WelcomeHero> createState() => _WelcomeHeroState();
}

class _Node {
  const _Node(this.area, this.trade, this.icon, this.at);
  final String area;
  final String trade;
  final IconData icon;
  final Offset at; // 0..1 within the map
}

class _Transfer {
  const _Transfer(this.from, this.to, this.item, this.distance);
  final int from;
  final int to;
  final String item;
  final String distance;
}

const _nodes = [
  // Pins stay inside y 0.14–0.68 so labels clear the "live" tag at the bottom.
  _Node('Kabwata', 'Décor', LucideIcons.sparkles, Offset(0.17, 0.24)),
  _Node('Woodlands', 'Chairs', LucideIcons.armchair, Offset(0.80, 0.16)),
  _Node('Roma', 'Sound', LucideIcons.speaker, Offset(0.84, 0.60)),
  _Node('Chelston', 'Tents', LucideIcons.tent, Offset(0.30, 0.66)),
  _Node('Kabulonga', 'Lighting', LucideIcons.lightbulb, Offset(0.56, 0.40)),
];

const _transfers = [
  _Transfer(1, 0, '80 chairs', '4 km'),
  _Transfer(3, 4, 'Marquee 10×20', '6 km'),
  _Transfer(2, 0, 'PA system', '7 km'),
  _Transfer(4, 3, 'Fairy lights', '5 km'),
];

class _WelcomeHeroState extends State<WelcomeHero> with SingleTickerProviderStateMixin {
  // One full loop = every transfer once.
  late final _c = AnimationController(vsync: this, duration: Duration(milliseconds: 3200 * _transfers.length));
  bool _reduced = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = EvMotion.reduced(context);
    if (_reduced) {
      _c.value = 0.55 / _transfers.length; // a chip mid-route, frozen
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Animation: event vendors across Lusaka lending chairs, tents, sound and lighting to each other.',
      child: SizedBox(
        height: widget.height,
        child: LayoutBuilder(builder: (context, box) {
          final size = Size(box.maxWidth, widget.height);
          Offset px(int i) => Offset(_nodes[i].at.dx * size.width, _nodes[i].at.dy * size.height);

          return ClipRRect(
            borderRadius: EvRadius.lgAll,
            child: AnimatedBuilder(
              animation: _c,
              builder: (context, _) {
                final loop = _c.value * _transfers.length;
                final idx = loop.floor() % _transfers.length;
                final t = loop - loop.floor(); // 0..1 within the current transfer
                final tr = _transfers[idx];
                final a = px(tr.from), b = px(tr.to);
                final ctrl = _control(a, b);

                // Phases of one transfer.
                final draw = Curves.easeInOutCubic.transform(_seg(t, 0.0, 0.32));
                final travel = Curves.easeInOutCubic.transform(_seg(t, 0.22, 0.78));
                final chipIn = _seg(t, 0.18, 0.28);
                final chipOut = 1 - _seg(t, 0.84, 0.94);
                final arrive = _seg(t, 0.74, 1.0);
                final fade = 1 - _seg(t, 0.86, 1.0);
                final raw = _bezier(a, ctrl, b, travel);
                // The chip sits above its point; keep it inside the map edges.
                final chipPos = Offset(raw.dx.clamp(80.0, size.width - 80.0), math.max(raw.dy, 40.0));

                return Stack(clipBehavior: Clip.none, children: [
                  // Map paper.
                  Positioned.fill(child: CustomPaint(painter: _MapPainter())),
                  // Past routes stay as faint traces; the live one draws in bronze.
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _RoutesPainter(
                        points: [for (var i = 0; i < _nodes.length; i++) px(i)],
                        current: idx,
                        draw: draw,
                        fade: fade,
                      ),
                    ),
                  ),
                  // Vendors.
                  for (var i = 0; i < _nodes.length; i++)
                    _VendorPin(
                      node: _nodes[i],
                      at: px(i),
                      source: i == tr.from && t < 0.8,
                      ping: i == tr.to ? arrive : 0,
                      breathe: _reduced ? 0 : math.sin((_c.value * _transfers.length * 2 + i * 0.7) * math.pi),
                    ),
                  // The item on its way.
                  Positioned(
                    left: chipPos.dx,
                    top: chipPos.dy,
                    child: FractionalTranslation(
                      translation: const Offset(-0.5, -1.35),
                      child: Opacity(
                        opacity: (chipIn * chipOut).clamp(0.0, 1.0),
                        child: Transform.scale(scale: 0.85 + 0.15 * chipIn, child: _ItemChip(item: tr.item, distance: tr.distance)),
                      ),
                    ),
                  ),
                  // A quiet "live" tag in the corner.
                  Positioned(left: 12, bottom: 12, child: _LiveTag(pulse: _reduced ? 1 : (math.sin(_c.value * math.pi * 2 * _transfers.length * 2) + 1) / 2)),
                ]);
              },
            ),
          );
        }),
      ),
    );
  }
}

double _seg(double t, double a, double b) => ((t - a) / (b - a)).clamp(0.0, 1.0);

/// Arc control point: bow each route sideways so lines don't overlap pins.
Offset _control(Offset a, Offset b) {
  final mid = (a + b) / 2;
  final d = b - a;
  final normal = Offset(-d.dy, d.dx) / (d.distance == 0 ? 1 : d.distance);
  return mid + normal * (d.distance * 0.28);
}

Offset _bezier(Offset a, Offset c, Offset b, double t) {
  final u = 1 - t;
  return a * (u * u) + c * (2 * u * t) + b * (t * t);
}

class _MapPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final r = Offset.zero & size;
    canvas.drawRect(r, Paint()..color = EvColors.forestWash);
    // Street grid, slightly skewed so it reads as a map, not graph paper.
    final grid = Paint()
      ..color = EvColors.forestTint
      ..strokeWidth = 1;
    for (var x = -size.height; x < size.width + size.height; x += 34) {
      canvas.drawLine(Offset(x, 0), Offset(x + size.height * 0.18, size.height), grid);
    }
    for (var y = 0.0; y < size.height; y += 34) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y - size.width * 0.06), grid);
    }
    // Two main roads (Great East and Kafue roads, loosely).
    final road = Paint()
      ..color = EvColors.warmWhite
      ..style = PaintingStyle.stroke
      ..strokeWidth = 9
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(
        Path()
          ..moveTo(-10, size.height * 0.62)
          ..cubicTo(size.width * 0.3, size.height * 0.5, size.width * 0.55, size.height * 0.62, size.width + 10, size.height * 0.38),
        road);
    canvas.drawPath(
        Path()
          ..moveTo(size.width * 0.34, -10)
          ..cubicTo(size.width * 0.4, size.height * 0.35, size.width * 0.3, size.height * 0.7, size.width * 0.38, size.height + 10),
        road);
  }

  @override
  bool shouldRepaint(_MapPainter old) => false;
}

class _RoutesPainter extends CustomPainter {
  _RoutesPainter({required this.points, required this.current, required this.draw, required this.fade});
  final List<Offset> points;
  final int current;
  final double draw;
  final double fade;

  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < _transfers.length; i++) {
      final tr = _transfers[i];
      final a = points[tr.from], b = points[tr.to];
      final c = _control(a, b);
      final path = Path()
        ..moveTo(a.dx, a.dy)
        ..quadraticBezierTo(c.dx, c.dy, b.dx, b.dy);
      if (i != current) {
        canvas.drawPath(path, Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..color = EvColors.forestSoft.withValues(alpha: 0.18));
        continue;
      }
      // Live route: dashed bronze, drawn progressively.
      for (final m in path.computeMetrics()) {
        final end = m.length * draw;
        const dash = 7.0, gap = 5.0;
        for (var d = 0.0; d < end; d += dash + gap) {
          canvas.drawPath(
            m.extractPath(d, math.min(d + dash, end)),
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2.4
              ..strokeCap = StrokeCap.round
              ..color = EvColors.bronze.withValues(alpha: 0.9 * fade),
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(_RoutesPainter old) => old.draw != draw || old.current != current || old.fade != fade;
}

class _VendorPin extends StatelessWidget {
  const _VendorPin({required this.node, required this.at, required this.source, required this.ping, required this.breathe});
  final _Node node;
  final Offset at;
  final bool source;
  final double ping; // 0..1 arrival pulse
  final double breathe; // -1..1 idle motion

  @override
  Widget build(BuildContext context) {
    const d = 40.0;
    final ring = ping > 0 && ping < 1;
    final pop = ping > 0 ? 1 + 0.18 * math.sin(ping * math.pi) : 1.0;
    return Positioned(
      left: at.dx - 60,
      top: at.dy - d / 2,
      width: 120,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        SizedBox.square(
          dimension: d,
          child: Stack(clipBehavior: Clip.none, alignment: Alignment.center, children: [
            if (ring)
              Container(
                width: d + 34 * ping,
                height: d + 34 * ping,
                decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: EvColors.bronze.withValues(alpha: 1 - ping), width: 2)),
              ),
            Transform.translate(
              offset: Offset(0, 1.5 * breathe),
              child: Transform.scale(
                scale: pop,
                child: Container(
                  width: d,
                  height: d,
                  decoration: BoxDecoration(
                    color: ping > 0.3 ? EvColors.forest : EvColors.warmWhite,
                    shape: BoxShape.circle,
                    border: Border.all(color: source ? EvColors.bronze : EvColors.sand, width: source ? 2 : 1.2),
                    boxShadow: EvShadow.raised,
                  ),
                  child: Icon(node.icon, size: 18, color: ping > 0.3 ? EvColors.inkOnDark : EvColors.forest),
                ),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(color: EvColors.warmWhite.withValues(alpha: 0.92), borderRadius: BorderRadius.circular(EvRadius.pill)),
          child: Text(node.area, style: EvType.caption.copyWith(color: EvColors.ink2, fontSize: 10.5), maxLines: 1),
        ),
      ]),
    );
  }
}

class _ItemChip extends StatelessWidget {
  const _ItemChip({required this.item, required this.distance});
  final String item;
  final String distance;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(8, 5, 10, 5),
        decoration: BoxDecoration(color: EvColors.forest, borderRadius: BorderRadius.circular(EvRadius.pill), boxShadow: EvShadow.floating),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(LucideIcons.package, size: 13, color: Color(0xFFC9A27A)),
          const SizedBox(width: 5),
          Text(item, style: EvType.smallStrong.copyWith(color: EvColors.inkOnDark, fontSize: 12)),
          Text('  ·  $distance', style: EvType.caption.copyWith(color: const Color(0xFFC9A27A), fontSize: 11)),
        ]),
      );
}

class _LiveTag extends StatelessWidget {
  const _LiveTag({required this.pulse});
  final double pulse;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(color: EvColors.warmWhite, borderRadius: BorderRadius.circular(EvRadius.pill), border: Border.all(color: EvColors.hairline)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: Color.lerp(EvColors.forestSoft, EvColors.success, pulse), shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text('Vendors sharing stock in Lusaka', style: EvType.caption.copyWith(color: EvColors.ink2, fontSize: 11)),
        ]),
      );
}

/// Headline promise that cycles through what Evenda does for a vendor.
class RotatingPromise extends StatefulWidget {
  const RotatingPromise({super.key});

  @override
  State<RotatingPromise> createState() => _RotatingPromiseState();
}

class _RotatingPromiseState extends State<RotatingPromise> {
  static const _lines = [
    ('Short on chairs tonight?', 'Find them a few kilometres away.'),
    ('Got stock sitting idle?', 'Rent it to vendors who need it.'),
    ('Quoting another vendor?', 'Send it, accept it, book it — in one place.'),
    ('Big weekend coming?', 'Every event’s tasks, on time.'),
  ];
  var _i = 0;
  Timer? _timer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _timer ??= EvMotion.reduced(context)
        ? null
        : Timer.periodic(const Duration(milliseconds: 3400), (_) {
            if (mounted) setState(() => _i = (_i + 1) % _lines.length);
          });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget lineFor(int i) {
      final (q, a) = _lines[i];
      return Column(
        key: ValueKey(i),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(q, style: EvType.display),
          const SizedBox(height: 2),
          Text(a, style: EvType.display.copyWith(color: EvColors.bronze)),
        ],
      );
    }

    final (q, a) = _lines[_i];
    return Semantics(
      label: '$q $a',
      child: ExcludeSemantics(
        // Invisible copies of every line reserve the height of the tallest
        // one at this width and text size, so nothing overflows or jumps.
        child: Stack(alignment: Alignment.topLeft, children: [
          for (var i = 0; i < _lines.length; i++)
            Visibility(visible: false, maintainSize: true, maintainAnimation: true, maintainState: true, child: lineFor(i)),
          Positioned.fill(
            child: AnimatedSwitcher(
              duration: EvMotion.of(context, EvMotion.slow),
              switchInCurve: EvMotion.decelerate,
              switchOutCurve: EvMotion.accelerate,
              transitionBuilder: (child, anim) => FadeTransition(
                opacity: anim,
                child: SlideTransition(position: Tween(begin: const Offset(0, 0.25), end: Offset.zero).animate(anim), child: child),
              ),
              layoutBuilder: (current, previous) => Stack(alignment: Alignment.topLeft, children: [...previous, ?current]),
              child: lineFor(_i),
            ),
          ),
        ]),
      ),
    );
  }
}
