import 'package:flutter/services.dart';

/// Android side of the call-style Evenda Now alert (MainActivity "evenda/alert").
///
/// - ring/stop: the open app's ringing (follows the ringer mode, stops after
///   30 s); ring also silences a ringing notification the app took over from.
/// - routes: screens the closed-app alert asked to open ("Make an offer",
///   or the incoming screen over the lock screen).
/// - Android 14+ full-screen permission and battery settings, so people can
///   let Evenda ring like a call when it's closed.
/// Everything is a quiet no-op where the native side isn't there (tests, web).
abstract final class AlertTone {
  static const _channel = MethodChannel('evenda/alert');

  static Future<T?> _call<T>(String method) async {
    try {
      return await _channel.invokeMethod<T>(method);
    } catch (_) {
      return null;
    }
  }

  static Future<void> ring() => _call<void>('ring');
  static Future<void> stop() => _call<void>('stop');

  /// The route the app was launched with from the alert, once.
  static Future<String?> launchRoute() => _call<String>('launchRoute');

  /// Routes from the alert while the app is already running.
  static void onOpen(void Function(String route) open) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'open' && call.arguments is String) open(call.arguments as String);
    });
  }

  /// False on Android 14+ until the user allows full-screen alerts for Evenda.
  static Future<bool> fullScreenAllowed() async => await _call<bool>('fullScreenAllowed') ?? true;
  static Future<void> openFullScreenSettings() => _call<void>('openFullScreenSettings');
  static Future<void> openBatterySettings() => _call<void>('openBatterySettings');
}
