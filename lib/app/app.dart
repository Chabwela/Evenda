import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ev.dart';
import 'incoming_banner.dart';
import 'providers.dart';
import 'router.dart';

class EvendaApp extends ConsumerWidget {
  const EvendaApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
