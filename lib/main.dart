import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

import 'app/app.dart';
import 'app/appearance.dart';
import 'design/ev.dart';
import 'app/config.dart';
import 'app/providers.dart';
import 'core/push.dart';
import 'data/backend.dart';
import 'data/supabase/supabase_backend.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('en_ZM');
  final view = PlatformDispatcher.instance.views.first;
  if (view.physicalSize.shortestSide / view.devicePixelRatio < 600) {
    await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  }
  await AppearanceNotifier.load();
  EvColors.apply(paletteFor(AppearanceNotifier.initial, PlatformDispatcher.instance.platformBrightness));
  SystemChrome.setSystemUIOverlayStyle(EvTheme.statusBar);

  // Production only: the app always runs against Supabase. A build without
  // the backend settings is a packaging mistake, so say so instead of
  // starting on fake data.
  if (!AppConfig.hasBackend) {
    runApp(const _MissingConfigApp());
    return;
  }
  await sb.Supabase.initialize(url: AppConfig.supabaseUrl, publishableKey: AppConfig.supabaseKey);
  final Backend backend = SupabaseBackend(sb.Supabase.instance.client);

  final container = ProviderContainer(overrides: [backendProvider.overrideWithValue(backend)]);
  // In the background: fetching a push token needs the network and must not
  // hold up the first frame. A tapped notification is routed when it arrives.
  if (AppConfig.firebaseEnabled) unawaited(PushService.init(backend));

  runApp(UncontrolledProviderScope(container: container, child: const EvendaApp()));
}

class _MissingConfigApp extends StatelessWidget {
  const _MissingConfigApp();

  @override
  Widget build(BuildContext context) => const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'This build of Evenda is missing its server settings.\n\n'
                'Build with --dart-define-from-file=env/prod.json.',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      );
}
