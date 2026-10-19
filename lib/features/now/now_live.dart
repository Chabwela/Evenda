import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:uuid/uuid.dart';

import '../../app/providers.dart';
import '../../core/format.dart';
import '../../data/backend.dart';
import '../../data/demo/demo_backend.dart';
import '../../design/ev.dart';
import '../../domain/models.dart';
import '../shared/map_widgets.dart';

enum _Phase { loading, dropping, broadcasting, revealed }

/// Evenda Now live view. Every animation reflects a real state:
///  1. the request pin drops at the chosen location;
///  2. the radius ripples only while the broadcast RPC is running;
///  3. supplier markers appear, nearest first, from the server's eligible list;
///  4. markers and offer cards update as real offers arrive (realtime);
///  5. status changes (offer selected, booking confirmed) transition in place.
class NowLiveScreen extends ConsumerStatefulWidget {
  const NowLiveScreen({super.key, required this.id});
  final String id;

  @override
  ConsumerState<NowLiveScreen> createState() => _NowLiveScreenState();
}

class _NowLiveScreenState extends ConsumerState<NowLiveScreen> with TickerProviderStateMixin {
  final _map = MapController();
  late final _drop = AnimationController(vsync: this, duration: const Duration(milliseconds: 650));
  late final _ripple = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));
  late final _reveal = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
  AnimationController? _camera;

  _Phase _phase = _Phase.loading;
  NowRequest? _req;
  List<NowMapVendor> _vendors = const [];
  List<NowOffer> _offers = const [];
  final _fresh = <String>{}; // offer ids that just arrived
  final _selectKeys = <String, String>{};
  bool _sortByPrice = true;
  String? _busyOffer;
  int _rippleCyclesLeft = 0;
  Object? _error;
  Timer? _clock;
  bool _mapReady = false;
  bool _simulating = false;

  NowApi get _api => ref.read(backendProvider).now;

  @override
  void initState() {
    super.initState();
    _ripple.addStatusListener((s) {
      if (s == AnimationStatus.completed) {
        if (_phase == _Phase.broadcasting || _rippleCyclesLeft > 0) {
          if (_phase != _Phase.broadcasting) _rippleCyclesLeft--;
          _ripple.forward(from: 0);
        }
      }
    });
    _clock = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _clock?.cancel();
    _drop.dispose();
    _ripple.dispose();
    _reveal.dispose();
    _camera?.dispose();
    super.dispose();
  }

  bool get _reduced => EvMotion.reduced(context);

  Future<void> _start() async {
    try {
      final req = await _api.request(widget.id);
      if (!mounted) return;
      setState(() => _req = req);
      final shouldBroadcast = GoRouterState.of(context).uri.queryParameters['broadcast'] == '1' && req.status == NowStatus.draft;

      // 1. Pin drop.
      setState(() => _phase = _Phase.dropping);
      if (_reduced) {
        _drop.value = 1;
      } else {
        await _drop.forward();
      }
      if (!mounted) return;

      // 2. Broadcast (real RPC) with the ripple running only while it is in flight.
      if (shouldBroadcast) await _broadcast();
      await _reload(animateReveal: true);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _broadcast({int? radiusKm}) async {
    setState(() => _phase = _Phase.broadcasting);
    if (!_reduced) _ripple.forward(from: 0);
    HapticFeedback.mediumImpact();
    try {
      await _api.broadcast(widget.id, radiusKm: radiusKm);
    } finally {
      if (mounted) {
        _rippleCyclesLeft = 1; // let the current wave finish, then stop
        setState(() => _phase = _Phase.revealed);
      }
    }
  }

  Future<void> _reload({bool animateReveal = false}) async {
    final r = await Future.wait([_api.request(widget.id), _api.map(widget.id), _api.offers(widget.id)]);
    if (!mounted) return;
    final req = r[0] as NowRequest;
    final vendors = r[1] as List<NowMapVendor>;
    final offers = r[2] as List<NowOffer>;
    final known = _offers.map((o) => o.id).toSet();
    final arrived = offers.where((o) => !known.contains(o.id) && _offers.isNotEmpty || (!known.contains(o.id) && !animateReveal && _phase == _Phase.revealed)).map((o) => o.id).toSet();
    setState(() {
      _req = req;
      _vendors = vendors;
      _offers = offers;
      _phase = _Phase.revealed;
      _fresh.addAll(arrived);
    });
    if (arrived.isNotEmpty) {
      HapticFeedback.lightImpact();
      Future.delayed(const Duration(milliseconds: 1600), () {
        if (mounted) setState(() => _fresh.removeAll(arrived));
      });
    }
    if (animateReveal) {
      _reveal.duration = Duration(milliseconds: 420 + EvMotion.stagger.inMilliseconds * vendors.length);
      if (_reduced) {
        _reveal.value = 1;
      } else {
        _reveal.forward(from: 0);
      }
      _fitCamera();
    }
  }

  /// Smoothly frames the request and every notified supplier.
  void _fitCamera() {
    if (!_mapReady || _req == null) return;
    final pts = [_req!.location, ..._vendors.map((v) => v.location)];
    final target = pts.length == 1
        ? MapCamera(crs: const Epsg3857(), center: _req!.location, zoom: _zoomForRadius(_req!.radiusKm.toDouble()), rotation: 0, nonRotatedSize: _map.camera.nonRotatedSize)
        : CameraFit.bounds(bounds: LatLngBounds.fromPoints(pts), padding: const EdgeInsets.fromLTRB(60, 120, 60, 320), maxZoom: 15).fit(_map.camera);
    _animateCamera(target.center, target.zoom);
  }

  double _zoomForRadius(double km) => (14.6 - math.log(km / 1.5) / math.ln2).clamp(9, 15);

  void _animateCamera(LatLng to, double zoom) {
    if (_reduced) {
      _map.move(to, zoom);
      return;
    }
    final from = _map.camera.center;
    final fromZoom = _map.camera.zoom;
    _camera?.dispose();
    _camera = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
    final a = CurvedAnimation(parent: _camera!, curve: EvMotion.standard);
    a.addListener(() {
      final t = a.value;
      _map.move(LatLng(from.latitude + (to.latitude - from.latitude) * t, from.longitude + (to.longitude - from.longitude) * t), fromZoom + (zoom - fromZoom) * t);
    });
    _camera!.forward();
  }

  Future<void> _select(NowOffer o) async {
    final req = _req!;
    final ok = await showEvSheet<bool>(
      context,
      title: 'Book ${o.supplier.name}?',
      subtitle: 'Creates a confirmed booking and reserves ${o.quantity} for ${EvDates.day(req.neededFrom)}.',
      builder: (c) => Padding(
        padding: const EdgeInsets.fromLTRB(EvSpace.gutter, 0, EvSpace.gutter, EvSpace.x6),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          KeyValue('Item', o.listingTitle),
          KeyValue('Quantity', '${o.quantity} of ${req.quantity} needed'),
          KeyValue('Price', '${Money.k(o.unitPrice)} each · ${Money.k(o.total)} total'),
          KeyValue('Handover', o.canDeliver && req.fulfilment != Fulfilment.pickup ? 'Supplier delivers' : 'You collect'),
          if (o.distanceKm != null) KeyValue('Distance', '${o.distanceKm} km'),
          const SizedBox(height: EvSpace.x4),
          EvButton('Confirm booking', expand: true, onPressed: () => Navigator.pop(c, true)),
        ]),
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busyOffer = o.id);
    final key = _selectKeys.putIfAbsent(o.id, () => const Uuid().v4());
    final bookingId = await guard(context, () => _api.selectOffer(o.id, key));
    if (!mounted) return;
    setState(() => _busyOffer = null);
    if (bookingId != null) {
      HapticFeedback.heavyImpact();
      await _reload();
      if (mounted) {
        showToast(context, 'Booked ${o.quantity} from ${o.supplier.name}', icon: LucideIcons.circleCheck, action: 'View', onAction: () => context.push('/bookings/$bookingId'));
      }
    }
  }

  Future<void> _widen(int km) async {
    await guard(context, () async {
      _reveal.value = 0;
      await _broadcast(radiusKm: km);
      await _reload(animateReveal: true);
    });
  }

  Future<void> _simulate() async {
    final b = ref.read(backendProvider);
    if (b is! DemoBackend) return;
    setState(() => _simulating = true);
    await b.simulateSupplierReplies(widget.id);
    if (mounted) setState(() => _simulating = false);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(revisionProvider.select((m) => m[DataDomain.now]), (_, _) {
      if (_phase == _Phase.revealed) _reload();
    });
    final req = _req;
    if (_error != null) {
      return Scaffold(appBar: AppBar(), body: ErrorState(error: _error!, onRetry: () => setState(() {
      _error = null;
      _start();
    })));
    }
    if (req == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));

    final selectedIds = _offers.where((o) => o.status == NowOfferStatus.selected).map((o) => o.supplier.id).toSet();
    final offerBySupplier = {for (final o in _offers.where((o) => o.status == NowOfferStatus.pending || o.status == NowOfferStatus.selected)) o.supplier.id: o};

    return Scaffold(
      body: Stack(children: [
        FlutterMap(
          mapController: _map,
          options: MapOptions(
            initialCenter: req.location,
            initialZoom: _zoomForRadius(req.radiusKm.toDouble()) + 0.6,
            interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
            onMapReady: () {
              _mapReady = true;
              if (_phase == _Phase.revealed) _fitCamera();
            },
          ),
          children: [
            ...evTileLayers(),
            // Search radius and broadcast ripple.
            AnimatedBuilder(
              animation: Listenable.merge([_drop, _ripple]),
              builder: (_, _) {
                final r = req.radiusKm * 1000.0;
                final grow = Curves.easeOutCubic.transform(_drop.value);
                final circles = <CircleMarker>[
                  CircleMarker(
                    point: req.location,
                    radius: r * grow,
                    useRadiusInMeter: true,
                    color: EvColors.forest.withValues(alpha: 0.06),
                    borderColor: EvColors.forest.withValues(alpha: 0.35),
                    borderStrokeWidth: 1.5,
                  ),
                ];
                if (_ripple.isAnimating) {
                  for (final offset in const [0.0, 0.5]) {
                    final t = (_ripple.value + offset) % 1.0;
                    circles.add(CircleMarker(
                      point: req.location,
                      radius: r * Curves.easeOut.transform(t),
                      useRadiusInMeter: true,
                      color: EvColors.bronze.withValues(alpha: 0.10 * (1 - t)),
                      borderColor: EvColors.bronze.withValues(alpha: 0.55 * (1 - t)),
                      borderStrokeWidth: 2,
                    ));
                  }
                }
                return CircleLayer(circles: circles);
              },
            ),
            // Supplier markers, revealed nearest-first.
            AnimatedBuilder(
              animation: _reveal,
              builder: (_, _) => MarkerLayer(markers: [
                for (final (i, v) in _vendors.indexed)
                  Marker(
                    point: v.location,
                    width: 120,
                    height: 70,
                    alignment: Alignment.topCenter,
                    child: _revealed(i, _VendorMarker(
                      vendor: v,
                      offer: offerBySupplier[v.businessId],
                      selected: selectedIds.contains(v.businessId),
                      fresh: offerBySupplier[v.businessId] != null && _fresh.contains(offerBySupplier[v.businessId]!.id),
                      onTap: () => _showVendor(v, offerBySupplier[v.businessId]),
                    )),
                  ),
                Marker(
                  point: req.location,
                  width: 60,
                  height: 66,
                  alignment: Alignment.topCenter,
                  child: AnimatedBuilder(
                    animation: _drop,
                    builder: (_, child) {
                      final t = _drop.value;
                      final y = -40 * (1 - Curves.bounceOut.transform(t));
                      return Opacity(opacity: t.clamp(0, 1), child: Transform.translate(offset: Offset(0, y), child: child));
                    },
                    child: const _RequestPin(),
                  ),
                ),
              ]),
            ),
            evAttribution(),
          ],
        ),

        // Top bar
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(EvSpace.x3),
            child: Row(children: [
              _MapButton(icon: LucideIcons.arrowLeft, onTap: () => context.canPop() ? context.pop() : context.go('/home')),
              const SizedBox(width: 8),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(color: EvColors.warmWhite, borderRadius: EvRadius.mdAll, boxShadow: EvShadow.raised),
                  child: Row(children: [
                    const Icon(LucideIcons.zap, size: 16, color: EvColors.bronze),
                    const SizedBox(width: 8),
                    Expanded(child: Text('${req.quantity} × ${req.itemDescription}', style: EvType.smallStrong, maxLines: 1, overflow: TextOverflow.ellipsis)),
                  ]),
                ),
              ),
              const SizedBox(width: 8),
              _MapButton(icon: LucideIcons.scan, onTap: _fitCamera),
            ]),
          ),
        ),

        _sheet(req),
      ]),
    );
  }

  Widget _revealed(int i, Widget child) {
    final n = math.max(_vendors.length, 1);
    final total = _reveal.duration!.inMilliseconds;
    final start = (EvMotion.stagger.inMilliseconds * i / total).clamp(0.0, 0.95);
    final end = math.min(1.0, start + 420 / total);
    final t = Interval(start, end, curve: EvMotion.spring).transform(_reveal.value.clamp(0, 1));
    if (n == 0) return child;
    return Opacity(opacity: t.clamp(0, 1), child: Transform.scale(scale: 0.4 + 0.6 * t, alignment: Alignment.bottomCenter, child: child));
  }

  void _showVendor(NowMapVendor v, NowOffer? o) {
    showEvSheet<void>(
      context,
      title: v.name,
      subtitle: '${v.distanceKm} km away${v.approximate ? ' · approximate location' : ''}',
      builder: (c) => Padding(
        padding: const EdgeInsets.fromLTRB(EvSpace.gutter, 0, EvSpace.gutter, EvSpace.x6),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          KeyValue('Free on your date', v.available >= 999 ? 'Has capacity' : '${v.available}'),
          KeyValue('Status', o == null ? (v.declined ? 'Declined' : 'Notified, no offer yet') : (o.status == NowOfferStatus.selected ? 'Booked' : 'Offered ${o.quantity} at ${Money.k(o.unitPrice)}')),
          const SizedBox(height: EvSpace.x4),
          EvButton('View supplier profile', kind: EvButtonKind.secondary, expand: true, onPressed: () {
            Navigator.pop(c);
            context.push('/supplier/${v.businessId}');
          }),
          if (o != null && o.status == NowOfferStatus.pending) ...[
            const SizedBox(height: 8),
            EvButton('Book this offer', expand: true, onPressed: () {
              Navigator.pop(c);
              _select(o);
            }),
          ],
        ]),
      ),
    );
  }

  String _expiry(NowRequest r) {
    final left = r.expiresAt.difference(DateTime.now());
    if (left.isNegative) return 'Expired';
    if (left.inMinutes < 60) return 'Closes in ${left.inMinutes} min';
    return 'Closes in ${left.inHours} h ${left.inMinutes % 60} min';
  }

  Widget _sheet(NowRequest req) {
    final pending = _offers.where((o) => o.status == NowOfferStatus.pending).toList()
      ..sort((a, b) => _sortByPrice ? a.unitPrice.compareTo(b.unitPrice) : (a.distanceKm ?? 99).compareTo(b.distanceKm ?? 99));
    final selected = _offers.where((o) => o.status == NowOfferStatus.selected).toList();
    final covered = selected.fold(0, (s, o) => s + o.quantity);
    final noMatch = _phase == _Phase.revealed && req.status == NowStatus.draft && _vendors.isEmpty;
    final demo = ref.watch(backendProvider).isDemo;

    final statusLabel = switch (_phase) {
      _Phase.loading || _Phase.dropping => 'Preparing request',
      _Phase.broadcasting => 'Searching for suppliers',
      _Phase.revealed => noMatch ? 'No suppliers found' : req.status.label,
    };
    final statusTone = _phase == _Phase.broadcasting ? Tone.progress : (noMatch ? Tone.attention : toneForNow(req.status));

    return DraggableScrollableSheet(
      initialChildSize: 0.42,
      minChildSize: 0.2,
      maxChildSize: 0.88,
      snap: true,
      snapSizes: const [0.2, 0.42, 0.88],
      builder: (c, scroll) => Container(
        decoration: const BoxDecoration(
          color: EvColors.warmWhite,
          borderRadius: BorderRadius.vertical(top: Radius.circular(EvRadius.lg)),
          boxShadow: EvShadow.floating,
        ),
        child: ListView(controller: scroll, padding: EdgeInsets.zero, children: [
          Center(child: Container(margin: const EdgeInsets.symmetric(vertical: 10), width: 36, height: 4, decoration: BoxDecoration(color: EvColors.sandDeep, borderRadius: BorderRadius.circular(2)))),
          Padding(
            padding: const EdgeInsets.fromLTRB(EvSpace.gutter, 0, EvSpace.gutter, 0),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                StatusPill(statusLabel, tone: statusTone, icon: _phase == _Phase.broadcasting ? LucideIcons.radar : null),
                const Spacer(),
                if (req.status.live) Text(_expiry(req), style: EvType.caption),
              ]),
              const SizedBox(height: 10),
              Text('${req.quantity} × ${req.itemDescription}', style: EvType.title),
              const SizedBox(height: 2),
              Text(
                '${EvDates.relativeDay(req.neededFrom)}${req.neededByTime != null ? ' by ${req.neededByTime}' : ''} · ${req.fulfilment == Fulfilment.pickup ? 'You collect' : 'Delivery'} · within ${req.radiusKm} km',
                style: EvType.small,
              ),
              if (selected.isNotEmpty) ...[
                const SizedBox(height: EvSpace.x3),
                Row(children: [
                  Text('$covered of ${req.quantity} covered', style: EvType.smallStrong),
                  const Spacer(),
                  Text(Money.k(selected.fold<double>(0.0, (s, o) => s + o.total)), style: EvType.money),
                ]),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(end: (covered / req.quantity).clamp(0, 1)),
                    duration: EvMotion.of(context, EvMotion.slow),
                    curve: EvMotion.standard,
                    builder: (_, v, _) => LinearProgressIndicator(value: v, minHeight: 6),
                  ),
                ),
              ],
            ]),
          ),
          const SizedBox(height: EvSpace.x4),

          if (_phase == _Phase.broadcasting || _phase == _Phase.dropping || _phase == _Phase.loading)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: EvSpace.gutter),
              child: Row(children: [
                const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 12),
                Expanded(child: Text('Checking which suppliers within ${req.radiusKm} km have this free on ${EvDates.day(req.neededFrom)}…', style: EvType.small)),
              ]),
            )
          else if (noMatch)
            _NoMatch(radius: req.radiusKm, onWiden: _widen, onEdit: () => context.pushReplacement('/now/new?category=${req.categoryId}&qty=${req.quantity}&item=${Uri.encodeComponent(req.itemDescription)}&date=${EvDates.iso(req.neededFrom)}'))
          else ...[
            if (req.status == NowStatus.bookingConfirmed || req.status == NowStatus.completed)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: EvSpace.gutter),
                child: Row(children: [
                  const Celebration(size: 70),
                  Expanded(child: Text('Sorted. ${selected.length == 1 ? 'Your supplier has' : 'Your suppliers have'} been notified and the stock is reserved.', style: EvType.bodyStrong)),
                ]),
              ),
            if (selected.isNotEmpty) ...[
              const SectionHeader('Booked', padding: EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x2, EvSpace.gutter, EvSpace.x2)),
              for (final o in selected) _OfferCard(offer: o, request: req, busy: false, fresh: _fresh.contains(o.id), onSelect: null, onOpenBooking: () => context.push('/bookings/${o.bookingId}')),
            ],
            if (req.status.live) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x2, EvSpace.x2, 0),
                child: Row(children: [
                  Text(pending.isEmpty ? 'WAITING FOR OFFERS' : 'OFFERS', style: EvType.overline),
                  if (pending.isNotEmpty) Text('  ${pending.length}', style: EvType.overline.copyWith(color: EvColors.bronze)),
                  const Spacer(),
                  if (pending.length > 1)
                    TextButton(onPressed: () => setState(() => _sortByPrice = !_sortByPrice), child: Text(_sortByPrice ? 'Cheapest first' : 'Nearest first')),
                ]),
              ),
              if (pending.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x2, EvSpace.gutter, 0),
                  child: Text('${plural(_vendors.length, 'supplier')} with this free ${_vendors.length == 1 ? 'has' : 'have'} been alerted. Offers appear here as they reply — keep this open or come back from Home.',
                      style: EvType.small),
                ),
              for (final o in pending)
                _OfferCard(offer: o, request: req, busy: _busyOffer == o.id, fresh: _fresh.contains(o.id), onSelect: () => _select(o)),
              if (demo && pending.isEmpty && _vendors.any((v) => !v.hasOffer && !v.declined))
                Padding(
                  padding: const EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x4, EvSpace.gutter, 0),
                  child: EvSurface(
                    color: EvColors.bronzeTint,
                    padding: const EdgeInsets.all(EvSpace.x3),
                    child: Row(children: [
                      const Icon(LucideIcons.flaskConical, size: 16, color: EvColors.bronzeDeep),
                      const SizedBox(width: 8),
                      Expanded(child: Text('Demo control: let the notified demo suppliers reply using their real listings.', style: EvType.caption.copyWith(color: EvColors.bronzeDeep))),
                      EvButton('Simulate', compact: true, kind: EvButtonKind.quiet, loading: _simulating, onPressed: _simulate),
                    ]),
                  ),
                ),
              SectionHeader('Notified', count: _vendors.length, padding: const EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x6, EvSpace.gutter, EvSpace.x2)),
              for (final v in _vendors)
                EvRow(
                  dense: true,
                  leading: BusinessAvatar(name: v.name, logoUrl: v.logoUrl, size: 32),
                  title: v.name,
                  subtitle: '${v.distanceKm} km · ${v.available >= 999 ? 'has capacity' : '${v.available} free'}',
                  trailing: v.hasOffer
                      ? const StatusPill('Offered', tone: Tone.positive, dense: true)
                      : v.declined
                          ? const StatusPill('Declined', dense: true)
                          : Text('Notified', style: EvType.caption),
                  onTap: () => _showVendor(v, offerBySupplierOf(v)),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x5, EvSpace.gutter, 0),
                child: EvButton(selected.isEmpty ? 'Cancel request' : 'Close request — I have enough', kind: EvButtonKind.quiet, expand: true, onPressed: () async {
                  final to = selected.isEmpty ? NowStatus.cancelled : NowStatus.completed;
                  if (await confirmAction(context, title: selected.isEmpty ? 'Cancel this request?' : 'Close this request?', body: 'Suppliers with pending offers will be told it’s closed.', confirm: selected.isEmpty ? 'Cancel request' : 'Close')) {
                    if (mounted) await guard(context, () => _api.close(req.id, to));
                  }
                }),
              ),
            ],
            if (req.status == NowStatus.expired || req.status == NowStatus.cancelled)
              Padding(
                padding: const EdgeInsets.all(EvSpace.gutter),
                child: Column(children: [
                  Text(req.status == NowStatus.expired ? 'This request expired without a booking.' : 'You cancelled this request.', style: EvType.small),
                  const SizedBox(height: EvSpace.x3),
                  EvButton('Start a new request', kind: EvButtonKind.secondary, expand: true, onPressed: () => context.pushReplacement('/now/new?category=${req.categoryId}&qty=${req.quantity}&item=${Uri.encodeComponent(req.itemDescription)}')),
                ]),
              ),
          ],
          SizedBox(height: EvSpace.x8 + MediaQuery.paddingOf(context).bottom),
        ]),
      ),
    );
  }

  NowOffer? offerBySupplierOf(NowMapVendor v) => _offers.where((o) => o.supplier.id == v.businessId && o.status != NowOfferStatus.withdrawn).firstOrNull;
}

class _NoMatch extends StatelessWidget {
  const _NoMatch({required this.radius, required this.onWiden, required this.onEdit});
  final int radius;
  final ValueChanged<int> onWiden;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: EvSpace.gutter),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const MascotImage(Mascot.pin, size: 64),
            const SizedBox(width: EvSpace.x3),
            Expanded(
              child: Text('No supplier within $radius km has this free on that date. Nobody was alerted.', style: EvType.bodyStrong),
            ),
          ]),
          const SizedBox(height: EvSpace.x4),
          Text('Try a wider area', style: EvType.smallStrong),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [
            for (final km in [radius + 10, radius + 25, 60].where((k) => k > radius && k <= 100).toSet())
              EvChip(label: 'Within $km km', icon: LucideIcons.radar, selected: false, onTap: () => onWiden(km)),
          ]),
          const SizedBox(height: EvSpace.x4),
          EvButton('Change date, quantity or item', kind: EvButtonKind.secondary, icon: LucideIcons.squarePen, expand: true, onPressed: onEdit),
        ]),
      );
}

class _OfferCard extends StatelessWidget {
  const _OfferCard({required this.offer, required this.request, required this.busy, required this.fresh, required this.onSelect, this.onOpenBooking});
  final NowOffer offer;
  final NowRequest request;
  final bool busy;
  final bool fresh;
  final VoidCallback? onSelect;
  final VoidCallback? onOpenBooking;

  @override
  Widget build(BuildContext context) {
    final o = offer;
    final overBudget = request.maxBudget != null && o.total > request.maxBudget!;
    final selected = o.status == NowOfferStatus.selected;
    return EvArrive(
      child: AnimatedContainer(
        duration: EvMotion.of(context, EvMotion.slow),
        margin: const EdgeInsets.fromLTRB(EvSpace.gutter, 0, EvSpace.gutter, 10),
        padding: const EdgeInsets.all(EvSpace.x3),
        decoration: BoxDecoration(
          color: fresh ? EvColors.bronzeTint : (selected ? EvColors.successTint : EvColors.warmWhite),
          borderRadius: EvRadius.mdAll,
          border: Border.all(color: selected ? EvColors.success : (fresh ? EvColors.bronze : EvColors.sand), width: selected || fresh ? 1.5 : 1),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            BusinessAvatar(name: o.supplier.name, logoUrl: o.supplier.logoUrl, verified: o.supplier.verified, size: 36),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(o.supplier.name, style: EvType.bodyStrong, maxLines: 1, overflow: TextOverflow.ellipsis),
                Text([if (o.distanceKm != null) '${o.distanceKm} km', o.canDeliver ? 'Can deliver' : 'Collect', EvDates.ago(o.createdAt)].join(' · '), style: EvType.caption),
              ]),
            ),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(Money.k(o.total), style: EvType.money.copyWith(fontSize: 16, color: overBudget ? EvColors.warning : EvColors.ink)),
              Text('${Money.k(o.unitPrice)} each', style: EvType.caption),
            ]),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            StatusPill(o.quantity >= request.quantity ? 'Covers all ${request.quantity}' : '${o.quantity} of ${request.quantity}',
                tone: o.quantity >= request.quantity ? Tone.positive : Tone.progress, dense: true),
            if (overBudget) ...[const SizedBox(width: 6), const StatusPill('Over budget', tone: Tone.attention, dense: true)],
            const Spacer(),
            if (onSelect != null) EvButton('Book', compact: true, loading: busy, onPressed: onSelect),
            if (onOpenBooking != null) TextButton(onPressed: onOpenBooking, child: const Text('View booking')),
          ]),
          if (o.note.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text('“${o.note}”', style: EvType.small.copyWith(fontStyle: FontStyle.italic))),
        ]),
      ),
    );
  }
}

/// The requester's pin: forest teardrop with the bronze bolt.
class _RequestPin extends StatelessWidget {
  const _RequestPin();
  @override
  Widget build(BuildContext context) => Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(color: EvColors.forest, shape: BoxShape.circle, border: Border.all(color: EvColors.warmWhite, width: 3), boxShadow: EvShadow.floating),
          child: const Icon(LucideIcons.zap, color: EvColors.bronzeTint, size: 20),
        ),
        CustomPaint(size: const Size(14, 10), painter: _Pointer(EvColors.forest)),
        Container(width: 10, height: 4, decoration: BoxDecoration(color: EvColors.ink.withValues(alpha: 0.25), borderRadius: BorderRadius.circular(4))),
      ]);
}

class _VendorMarker extends StatelessWidget {
  const _VendorMarker({required this.vendor, required this.onTap, this.offer, this.selected = false, this.fresh = false});
  final NowMapVendor vendor;
  final NowOffer? offer;
  final bool selected;
  final bool fresh;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hasOffer = offer != null;
    final bg = selected ? EvColors.forest : (hasOffer ? EvColors.bronze : EvColors.warmWhite);
    final fg = selected || hasOffer ? EvColors.inkOnDark : EvColors.forest;
    final words = vendor.name.split(' ').where((w) => w.isNotEmpty && RegExp(r'[A-Za-z]').hasMatch(w[0])).toList();
    final initials = words.take(2).map((w) => w[0].toUpperCase()).join();
    return GestureDetector(
      onTap: onTap,
      child: Opacity(
        opacity: vendor.declined ? 0.45 : 1,
        child: AnimatedScale(
          scale: fresh ? 1.18 : 1,
          duration: EvMotion.of(context, EvMotion.base),
          curve: EvMotion.spring,
          alignment: Alignment.bottomCenter,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            AnimatedContainer(
              duration: EvMotion.of(context, EvMotion.base),
              padding: EdgeInsets.fromLTRB(4, 4, hasOffer ? 10 : 4, 4),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(EvRadius.pill),
                border: Border.all(color: selected ? EvColors.forest : (hasOffer ? EvColors.bronze : EvColors.forest), width: 1.5),
                boxShadow: EvShadow.raised,
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  width: 28,
                  height: 28,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: selected || hasOffer ? EvColors.warmWhite.withValues(alpha: 0.18) : EvColors.forestTint, shape: BoxShape.circle),
                  child: selected
                      ? const Icon(LucideIcons.check, size: 15, color: EvColors.inkOnDark)
                      : Text(initials, style: EvType.caption.copyWith(color: fg, fontWeight: FontWeight.w800, fontSize: 11)),
                ),
                if (hasOffer) ...[
                  const SizedBox(width: 6),
                  Text(Money.k(offer!.unitPrice), style: EvType.caption.copyWith(color: fg, fontWeight: FontWeight.w700)),
                ],
              ]),
            ),
            CustomPaint(size: const Size(12, 7), painter: _Pointer(selected ? EvColors.forest : (hasOffer ? EvColors.bronze : EvColors.forest))),
          ]),
        ),
      ),
    );
  }
}

class _Pointer extends CustomPainter {
  _Pointer(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final p = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width / 2, size.height)
      ..close();
    canvas.drawPath(p, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_Pointer old) => old.color != color;
}

class _MapButton extends StatelessWidget {
  const _MapButton({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Material(
        color: EvColors.warmWhite,
        shape: RoundedRectangleBorder(borderRadius: EvRadius.mdAll),
        elevation: 0,
        child: InkWell(
          borderRadius: EvRadius.mdAll,
          onTap: onTap,
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(borderRadius: EvRadius.mdAll, boxShadow: EvShadow.raised),
            child: Icon(icon, size: 20, color: EvColors.ink),
          ),
        ),
      );
}
