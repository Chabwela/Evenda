import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../app/providers.dart';
import '../../core/alert_tone.dart';
import '../../core/format.dart';
import '../../design/ev.dart';
import '../../domain/models.dart';

final _incomingProvider = FutureProvider.autoDispose
    .family<NowInboxItem, String>((ref, id) {
      return ref
          .watch(backendProvider)
          .now
          .inboxItem(id, ref.watch(bizIdProvider));
    });

/// Shown like an incoming call when an Evenda Now request reaches a supplier
/// while the app is open: rings and vibrates (following the phone's ringer
/// mode), shows what is needed, and offers "Make an offer" or "Not now".
/// Leaves by itself after 45 s; the request stays in Evenda Now either way.
class IncomingRequestScreen extends ConsumerStatefulWidget {
  const IncomingRequestScreen({super.key, required this.id});
  final String id;

  @override
  ConsumerState<IncomingRequestScreen> createState() =>
      _IncomingRequestScreenState();
}

class _IncomingRequestScreenState extends ConsumerState<IncomingRequestScreen>
    with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  );
  Timer? _leave;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    AlertTone.ring();
    HapticFeedback.heavyImpact();
    _leave = Timer(const Duration(seconds: 45), _notNow);
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    EvMotion.reduced(context) ? _pulse.stop() : _pulse.repeat();
  }

  @override
  void dispose() {
    AlertTone.stop();
    _leave?.cancel();
    _tick?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  void _notNow() {
    if (!mounted) return;
    AlertTone.stop();
    context.canPop() ? context.pop() : context.go('/now');
  }

  void _offer() {
    AlertTone.stop();
    context.pushReplacement('/now/respond/${widget.id}');
  }

  static String _left(DateTime until) {
    final d = until.difference(DateTime.now());
    if (d.isNegative) return 'Closed';
    if (d.inMinutes < 60) return 'Closes in ${d.inMinutes} min';
    return 'Closes in ${d.inHours} h ${d.inMinutes % 60} min';
  }

  @override
  Widget build(BuildContext context) {
    final item = ref.watch(_incomingProvider(widget.id));
    final v = item.value;
    final r = v?.request;
    final cream = EvBrand.cream;
    const soft = Color(0xFFC9A27A); // light bronze on forest

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: EvBrand.forest,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              EvSpace.gutter,
              EvSpace.x3,
              EvSpace.gutter,
              EvSpace.x6,
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    const Icon(LucideIcons.zap, size: 16, color: soft),
                    const SizedBox(width: 6),
                    Text(
                      'EVENDA NOW',
                      style: EvType.caption.copyWith(
                        color: soft,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.4,
                      ),
                    ),
                    const Spacer(),
                    if (r != null)
                      Text(
                        _left(r.expiresAt),
                        style: EvType.caption.copyWith(
                          color: cream.withValues(alpha: .8),
                        ),
                      ),
                  ],
                ),
                const Spacer(),

                // The caller: the requesting business inside rippling rings.
                SizedBox(
                  width: 220,
                  height: 220,
                  child: AnimatedBuilder(
                    animation: _pulse,
                    builder: (_, child) => CustomPaint(
                      painter: _Ripples(_pulse.value),
                      child: child,
                    ),
                    child: Center(
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Container(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(color: cream, width: 3),
                            ),
                            child: ClipOval(
                              child: BusinessAvatar(
                                name: r?.requester.name ?? '…',
                                logoUrl: r?.requester.logoUrl,
                                size: 92,
                              ),
                            ),
                          ),
                          Positioned(
                            right: -2,
                            bottom: -2,
                            child: Container(
                              padding: const EdgeInsets.all(7),
                              decoration: BoxDecoration(
                                color: EvBrand.bronze,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: EvBrand.forest,
                                  width: 3,
                                ),
                              ),
                              child: Icon(
                                LucideIcons.zap,
                                size: 16,
                                color: cream,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: EvSpace.x4),
                Text(
                  r?.requester.name ?? 'Urgent request',
                  style: EvType.title.copyWith(color: cream),
                  textAlign: TextAlign.center,
                ),
                if (v != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    '${v.distanceKm.toStringAsFixed(1)} km away · needs it urgently',
                    style: EvType.small.copyWith(
                      color: cream.withValues(alpha: .75),
                    ),
                  ),
                ],
                const SizedBox(height: EvSpace.x6),
                if (r != null) ...[
                  Text(
                    '${r.quantity} × ${r.itemDescription}',
                    style: EvType.display.copyWith(color: cream, height: 1.15),
                    textAlign: TextAlign.center,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: EvSpace.x3),
                  Text(
                    [
                      '${EvDates.relativeDay(r.neededFrom)}${r.neededByTime != null ? ' by ${r.neededByTime}' : ''}',
                      switch (r.fulfilment) {
                        Fulfilment.pickup => 'They collect',
                        Fulfilment.supplierDelivers => 'You deliver',
                        Fulfilment.supplierSetsUp => 'You deliver and set up',
                      },
                      if (r.maxBudget != null)
                        'Budget ${Money.k(r.maxBudget!)}',
                    ].join(' · '),
                    style: EvType.body.copyWith(
                      color: cream.withValues(alpha: .85),
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: EvSpace.x4),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: cream.withValues(alpha: .12),
                      borderRadius: BorderRadius.circular(99),
                    ),
                    child: Text(
                      v!.availableQuantity >= r.quantity
                          ? 'You have ${v.availableQuantity} free that day'
                          : v.availableQuantity > 0
                          ? 'You have ${v.availableQuantity} of ${r.quantity} free that day'
                          : 'Check your stock for that day',
                      style: EvType.smallStrong.copyWith(color: soft),
                    ),
                  ),
                ] else if (item.isLoading)
                  SizedBox(
                    height: 24,
                    width: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: cream,
                    ),
                  )
                else
                  Text(
                    'This request is no longer open.',
                    style: EvType.body.copyWith(color: cream),
                  ),
                const Spacer(flex: 2),

                // Answer like a call.
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _RoundAction(
                      label: 'Not now',
                      icon: LucideIcons.x,
                      fill: Colors.transparent,
                      ink: cream,
                      outline: cream.withValues(alpha: .6),
                      onTap: _notNow,
                    ),
                    _RoundAction(
                      label: 'Make an offer',
                      icon: LucideIcons.zap,
                      fill: EvBrand.bronze,
                      ink: cream,
                      onTap: r == null ? null : _offer,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RoundAction extends StatelessWidget {
  const _RoundAction({
    required this.label,
    required this.icon,
    required this.fill,
    required this.ink,
    required this.onTap,
    this.outline,
  });
  final String label;
  final IconData icon;
  final Color fill;
  final Color ink;
  final Color? outline;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    // The label is part of the button: people tap the words too.
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Material(
            color: fill,
            shape: CircleBorder(
              side: outline == null
                  ? BorderSide.none
                  : BorderSide(color: outline!, width: 2),
            ),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: SizedBox(
                width: 74,
                height: 74,
                child: Icon(
                  icon,
                  size: 30,
                  color: onTap == null ? ink.withValues(alpha: .4) : ink,
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(label, style: EvType.smallStrong.copyWith(color: ink)),
        ],
      ),
    ),
  );
}

/// Three rings expanding from the centre and fading, like a phone ringing.
class _Ripples extends CustomPainter {
  _Ripples(this.t);
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final maxR = size.shortestSide / 2;
    for (var i = 0; i < 3; i++) {
      final p = (t + i / 3) % 1.0;
      final r = 50 + (maxR - 50) * Curves.easeOut.transform(p);
      final a = (1 - p) * .35;
      canvas.drawCircle(
        c,
        r,
        Paint()..color = EvBrand.cream.withValues(alpha: math.max(0, a)),
      );
    }
  }

  @override
  bool shouldRepaint(_Ripples old) => old.t != t;
}
