import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// True while the device has a network connection (Wi-Fi, mobile data,
/// ethernet). This is the radio state, not proof that Supabase is reachable;
/// failed requests are still reported through [EvError] as `offline`.
final onlineProvider = StreamProvider<bool>((ref) async* {
  final c = Connectivity();
  bool online(List<ConnectivityResult> r) => r.any((x) => x != ConnectivityResult.none);
  yield online(await c.checkConnectivity());
  yield* c.onConnectivityChanged.map(online).distinct();
});
