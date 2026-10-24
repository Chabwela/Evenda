import 'package:flutter/services.dart';

/// Call-style ringing for an incoming Evenda Now request while the app is open
/// (Android: MainActivity "evenda/alert"). Follows the phone's ringer mode and
/// stops by itself after 30 s. A no-op where it isn't available.
abstract final class AlertTone {
  static const _channel = MethodChannel('evenda/alert');

  static Future<void> ring() async {
    try {
      await _channel.invokeMethod<void>('ring');
    } catch (_) {}
  }

  static Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {}
  }
}
