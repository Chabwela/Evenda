import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../app/config.dart';
import '../../design/ev.dart';
import '../../domain/models.dart';

/// Map tiles from OpenStreetMap data. The URL is configurable; attribution is always shown.
List<Widget> evTileLayers() => [
      TileLayer(
        urlTemplate: AppConfig.mapTileUrl,
        userAgentPackageName: AppConfig.userAgentPackage,
        maxZoom: 19,
        tileProvider: NetworkTileProvider(),
      ),
    ];

Widget evAttribution() => RichAttributionWidget(
      alignment: AttributionAlignment.bottomLeft,
      showFlutterMapAttribution: false,
      attributions: [TextSourceAttribution(AppConfig.mapAttribution)],
    );

Neighbourhood nearestNeighbourhood(LatLng p) {
  const d = Distance();
  return kNeighbourhoods.reduce((a, b) => d.as(LengthUnit.Meter, p, a.point) <= d.as(LengthUnit.Meter, p, b.point) ? a : b);
}

/// What the vendor can do about a location problem.
enum LocationFix {
  none,
  turnOnLocation, // phone-wide Location switch is off
  allowPermission; // Evenda was blocked in app settings

  String? get action => switch (this) { turnOnLocation => 'Turn on', allowPermission => 'Settings', none => null };

  Future<bool> open() => switch (this) {
        turnOnLocation => Geolocator.openLocationSettings(),
        allowPermission => Geolocator.openAppSettings(),
        none => Future.value(false),
      };
}

/// A GPS fix and how far off it may be, in metres.
typedef GpsFix = ({LatLng point, double accuracyM});

/// Device location, with permission handling. Returns null (and explains
/// via [onMessage]) when unavailable; callers fall back to manual pinning.
///
/// Asks for the best fix the phone can give and keeps listening for up to
/// [settle] while accuracy improves, because the first GPS reading is often
/// a coarse network position hundreds of metres off.
Future<GpsFix?> currentFix({
  void Function(String message, {LocationFix fix})? onMessage,
  void Function(GpsFix rough)? onRough,
  Duration settle = const Duration(seconds: 10),
  double goodEnoughM = 20,
}) async {
  try {
    if (!await Geolocator.isLocationServiceEnabled()) {
      onMessage?.call('Location is off on this phone. Turn it on to find your business, or move the map yourself.', fix: LocationFix.turnOnLocation);
      return null;
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.deniedForever) {
      onMessage?.call('Evenda isn’t allowed to use your location. Allow it in Settings, or move the map yourself.', fix: LocationFix.allowPermission);
      return null;
    }
    if (perm == LocationPermission.denied) {
      onMessage?.call('Location permission was not given. Move the map to place the pin.');
      return null;
    }

    GpsFix fix(Position p) => (point: LatLng(p.latitude, p.longitude), accuracyM: p.accuracy);
    GpsFix? best;
    // A quick last-known position so the map jumps somewhere sensible at once.
    final last = await Geolocator.getLastKnownPosition();
    if (last != null) onRough?.call(fix(last));

    final stream = Geolocator.getPositionStream(
      locationSettings: defaultTargetPlatform == TargetPlatform.android
          ? AndroidSettings(accuracy: LocationAccuracy.best, distanceFilter: 0, intervalDuration: const Duration(milliseconds: 800))
          : const LocationSettings(accuracy: LocationAccuracy.best, distanceFilter: 0),
    );
    final deadline = DateTime.now().add(settle);
    await for (final p in stream.timeout(settle, onTimeout: (sink) => sink.close())) {
      if (best == null || p.accuracy < best.accuracyM) {
        best = fix(p);
        onRough?.call(best);
      }
      if (best.accuracyM <= goodEnoughM || DateTime.now().isAfter(deadline)) break;
    }
    best ??= last == null ? null : fix(last);
    if (best == null) onMessage?.call('Couldn’t get a GPS fix. Move the map to place the pin.');
    return best;
  } catch (_) {
    onMessage?.call('Couldn’t get your location. Move the map to place the pin.');
    return null;
  }
}

/// Simple point lookup for screens that only need a centre (Evenda Now, Find).
Future<LatLng?> currentLocation({void Function(String)? onMessage}) async =>
    (await currentFix(onMessage: onMessage == null ? null : (m, {fix = LocationFix.none}) => onMessage(m), settle: const Duration(seconds: 6), goodEnoughM: 60))?.point;

/// Pick a point by moving the map under a fixed centre pin (Uber/Yango
/// pattern: the pin stays put, the city moves). Reports the point and the
/// nearest Lusaka neighbourhood as the map settles.
class LocationPicker extends StatefulWidget {
  const LocationPicker({
    super.key,
    required this.initial,
    required this.onChanged,
    this.height = 280,
    this.radiusKm,
    this.pinLabel,
    this.autoLocate = false,
    this.showPrecision = false,
  });
  final LatLng initial;
  final void Function(LatLng point, Neighbourhood nearest) onChanged;
  final double height;
  final double? radiusKm;
  final String? pinLabel;

  /// Find the device position as soon as the picker opens (first-time setup).
  final bool autoLocate;

  /// Show the coordinates and GPS accuracy under the map.
  final bool showPrecision;

  @override
  State<LocationPicker> createState() => _LocationPickerState();
}

class _LocationPickerState extends State<LocationPicker> with WidgetsBindingObserver {
  final _map = MapController();
  late LatLng _centre = widget.initial;
  bool _moving = false;
  bool _locating = false;
  GpsFix? _fix; // last GPS reading, drawn as an accuracy ring
  bool _adjusted = false; // moved by hand since the GPS fix
  bool _sentToSettings = false; // retry when the vendor comes back from Settings

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.autoLocate) WidgetsBinding.instance.addPostFrameCallback((_) => _locate());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _sentToSettings) {
      _sentToSettings = false;
      _locate();
    }
  }

  double _zoomFor(double accuracyM) => accuracyM <= 25 ? 18.5 : accuracyM <= 80 ? 17.5 : accuracyM <= 300 ? 16 : 14.5;

  Future<void> _locate() async {
    if (_locating) return;
    setState(() => _locating = true);
    final fix = await currentFix(
      onMessage: (m, {fix = LocationFix.none}) {
        if (!mounted) return;
        showToast(context, m, icon: LucideIcons.mapPin, action: fix.action, onAction: () {
          _sentToSettings = true;
          fix.open();
        });
      },
      // Follow the fix as it sharpens, so the vendor sees it working.
      onRough: (f) {
        if (!mounted) return;
        setState(() => _fix = f);
        _map.move(f.point, _zoomFor(f.accuracyM));
        _settle(f.point, byGps: true);
      },
    );
    if (!mounted) return;
    setState(() => _locating = false);
    if (fix == null) return;
    setState(() => _fix = fix);
    _map.move(fix.point, _zoomFor(fix.accuracyM));
    _settle(fix.point, byGps: true);
    if (fix.accuracyM > 50) {
      showToast(context, 'GPS is rough here (±${fix.accuracyM.round()} m). Drag the map so the pin sits exactly on your gate.', icon: LucideIcons.move);
    }
  }

  void _settle(LatLng p, {bool byGps = false}) {
    _centre = p;
    if (!byGps && _fix != null) _adjusted = true;
    if (byGps) _adjusted = false;
    widget.onChanged(p, nearestNeighbourhood(p));
  }

  @override
  Widget build(BuildContext context) {
    final map = SizedBox(
      height: widget.height,
      child: ClipRRect(
        borderRadius: EvRadius.mdAll,
        child: Stack(children: [
          FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: widget.initial,
              initialZoom: 16,
              minZoom: 6,
              maxZoom: 19,
              interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
              onPositionChanged: (camera, gesture) {
                if (gesture && !_moving) setState(() => _moving = true);
                _centre = camera.center;
              },
              onMapEvent: (e) {
                if (e is MapEventMoveEnd || e is MapEventFlingAnimationEnd || e is MapEventDoubleTapZoomEnd || e is MapEventScrollWheelZoom) {
                  final byHand = _moving;
                  if (_moving) setState(() => _moving = false);
                  if (byHand) _settle(_centre);
                }
              },
            ),
            children: [
              ...evTileLayers(),
              if (widget.radiusKm != null)
                CircleLayer(circles: [
                  CircleMarker(
                    point: _centre,
                    radius: widget.radiusKm! * 1000,
                    useRadiusInMeter: true,
                    color: EvColors.forest.withValues(alpha: 0.07),
                    borderColor: EvColors.forest.withValues(alpha: 0.35),
                    borderStrokeWidth: 1.5,
                  ),
                ]),
              // Where the phone thinks it is, and how sure it is.
              if (_fix != null) ...[
                CircleLayer(circles: [
                  CircleMarker(
                    point: _fix!.point,
                    radius: _fix!.accuracyM,
                    useRadiusInMeter: true,
                    color: EvColors.info.withValues(alpha: 0.12),
                    borderColor: EvColors.info.withValues(alpha: 0.45),
                    borderStrokeWidth: 1,
                  ),
                ]),
                MarkerLayer(markers: [
                  Marker(
                    point: _fix!.point,
                    width: 16,
                    height: 16,
                    child: Container(decoration: BoxDecoration(color: EvColors.info, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 2.5))),
                  ),
                ]),
              ],
              evAttribution(),
            ],
          ),
          // Fixed centre pin; lifts while the map moves.
          IgnorePointer(
            child: Center(
              child: AnimatedSlide(
                duration: EvMotion.of(context, EvMotion.fast),
                offset: Offset(0, _moving ? -0.62 : -0.5),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  if (widget.pinLabel != null)
                    Container(
                      margin: const EdgeInsets.only(bottom: 4),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(color: EvColors.ink, borderRadius: EvRadius.smAll),
                      child: Text(widget.pinLabel!, style: EvType.caption.copyWith(color: EvColors.inkOnDark)),
                    ),
                  Icon(LucideIcons.mapPin, size: 40, color: EvColors.forest, fill: 1),
                ]),
              ),
            ),
          ),
          IgnorePointer(
            child: Center(
              child: AnimatedContainer(
                duration: EvMotion.of(context, EvMotion.fast),
                width: _moving ? 6 : 10,
                height: _moving ? 3 : 5,
                decoration: BoxDecoration(color: EvColors.ink.withValues(alpha: 0.25), borderRadius: BorderRadius.circular(5)),
              ),
            ),
          ),
          Positioned(
            right: 10,
            bottom: 10,
            child: Material(
              color: EvColors.warmWhite,
              shape: const StadiumBorder(),
              elevation: 2,
              child: InkWell(
                customBorder: const StadiumBorder(),
                onTap: _locating ? null : _locate,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    _locating
                        ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : Icon(LucideIcons.locateFixed, size: 18, color: EvColors.forest),
                    const SizedBox(width: 8),
                    Text(_locating ? 'Finding you…' : 'Use my location', style: EvType.smallStrong.copyWith(color: EvColors.forest)),
                  ]),
                ),
              ),
            ),
          ),
        ]),
      ),
    );

    if (!widget.showPrecision) return map;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      map,
      const SizedBox(height: 8),
      _PrecisionLine(point: _centre, fix: _fix, adjusted: _adjusted, locating: _locating),
    ]);
  }
}

/// "Pin -15.41672, 28.28330 · GPS ±8 m" — tells the vendor how exact the pin is.
class _PrecisionLine extends StatelessWidget {
  const _PrecisionLine({required this.point, required this.fix, required this.adjusted, required this.locating});
  final LatLng point;
  final GpsFix? fix;
  final bool adjusted;
  final bool locating;

  @override
  Widget build(BuildContext context) {
    final (String text, Color tone) = switch (fix) {
      _ when locating => ('Getting a precise GPS fix…', EvColors.ink3),
      null => ('Placed by hand · zoom in to place it exactly', EvColors.ink3),
      _ when adjusted => ('Adjusted by hand from GPS', EvColors.success),
      final f when f.accuracyM <= 25 => ('GPS accurate to ±${f.accuracyM.round()} m', EvColors.success),
      final f when f.accuracyM <= 80 => ('GPS ±${f.accuracyM.round()} m · check the pin is on your gate', EvColors.warning),
      final f => ('Rough GPS (±${f.accuracyM.round()} m) · drag the map to fix the pin', EvColors.warning),
    };
    return Row(children: [
      Icon(LucideIcons.crosshair, size: 14, color: tone),
      const SizedBox(width: 6),
      Expanded(child: Text(text, style: EvType.caption.copyWith(color: tone))),
      Text('${point.latitude.toStringAsFixed(5)}, ${point.longitude.toStringAsFixed(5)}',
          style: EvType.caption.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
    ]);
  }
}
