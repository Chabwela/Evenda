import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../data/backend.dart';
import 'alert_tone.dart';

/// Firebase Cloud Messaging integration boundary.
///
/// Requires google-services.json (Android) / GoogleService-Info.plist (iOS)
/// and FIREBASE_ENABLED=true. Server-side delivery is done by the
/// `send-push` Edge Function; this class only registers the device token and
/// routes taps on notifications.
abstract final class PushService {
  /// Route from a tapped push notification, waiting to be opened by the
  /// router once the vendor's session and business have loaded.
  static final tapRoutes = ValueNotifier<String?>(null);

  static Future<void> init(Backend backend) async {
    // The call-style Evenda Now alert (Android) opens screens the same way.
    AlertTone.onOpen((route) => tapRoutes.value = route);
    final launched = await AlertTone.launchRoute();
    if (launched != null && launched.startsWith('/')) tapRoutes.value = launched;
    try {
      await Firebase.initializeApp();
      final fm = FirebaseMessaging.instance;
      Future<void> register(String? token) async {
        if (token == null || backend.auth.current == null) return;
        // Ask only once someone has signed in, so the first thing a new
        // visitor sees is Evenda, not a system permission dialog.
        await fm.requestPermission(alert: true, badge: true, sound: true);
        final platform = kIsWeb ? 'web' : (defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android');
        await backend.notifications.registerDevice(token, platform);
      }

      // FCM registration tokens are what the send-push Edge Function targets
      // (HTTP v1 `message.token`). The newer register()/onRegistered API yields
      // installation IDs for direct send; move to it together with the function.
      // ignore: deprecated_member_use
      await register(await fm.getToken());
      // ignore: deprecated_member_use
      fm.onTokenRefresh.listen(register);
      backend.auth.sessions.listen((s) async {
        // ignore: deprecated_member_use
        if (s != null) await register(await fm.getToken());
      });

      void open(RemoteMessage m) {
        final route = m.data['route'];
        if (route is String && route.startsWith('/')) tapRoutes.value = route;
      }

      // In the foreground, Supabase Realtime shows the in-app banner instead.
      FirebaseMessaging.onMessageOpenedApp.listen(open);
      final initial = await fm.getInitialMessage();
      if (initial != null) open(initial);
    } catch (e) {
      // Push is optional: the in-app notification centre still works.
      debugPrint('Push not available: $e');
    }
  }
}
