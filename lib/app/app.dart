import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ev.dart';
import 'incoming_banner.dart';
import 'providers.dart';
import 'router.dart';

class EvendaApp extends ConsumerStatefulWidget {
  const EvendaApp({super.key});

  @override
  ConsumerState<EvendaApp> createState() => _EvendaAppState();
}

class _EvendaAppState extends ConsumerState<EvendaApp> with WidgetsBindingObserver {
  DateTime? _backgroundSince;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Android drops the live connection while Evenda is in the background, so
  /// notifications, quotes and bookings that arrived meanwhile were missing
  /// (and the bell didn't count them) until a restart. Coming back after more
  /// than a few seconds reconnects and refreshes everything.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _backgroundSince ??= DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final since = _backgroundSince;
      _backgroundSince = null;
      if (since != null && DateTime.now().difference(since) > const Duration(seconds: 5)) {
        ref.read(backendProvider).reconnect();
        ref.read(revisionProvider.notifier).bumpAll();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild once the live category catalogue arrives, so pickers show it.
    ref.watch(categoryCatalogProvider);
    return MaterialApp.router(
      title: 'Evenda',
      debugShowCheckedModeBanner: false,
      theme: EvTheme.light(),
      routerConfig: ref.watch(routerProvider),
      builder: (context, child) {
        // Respect the user's text size up to 1.3×, beyond which dense
        // operational layouts break; larger sizes still scale, just capped.
        final mq = MediaQuery.of(context);
        return MediaQuery(
          data: mq.copyWith(textScaler: mq.textScaler.clamp(maxScaleFactor: 1.3)),
          child: OfflineBanner(
            onReconnect: () {
              ref.read(backendProvider).reconnect();
              ref.read(revisionProvider.notifier).bumpAll();
              ref.invalidate(myBusinessProvider);
            },
            child: IncomingBanner(child: child!),
          ),
        );
      },
    );
  }
}
