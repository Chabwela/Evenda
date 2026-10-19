import 'dart:async';

import 'package:evenda/core/errors.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('EvError.from', () {
    test('network failures become "offline" (regression: raw ClientException URL was shown to users)', () {
      for (final raw in [
        'ClientException: Failed to fetch, uri=https://x.supabase.co/auth/v1/recover',
        'SocketException: Failed host lookup: x.supabase.co',
        'ClientException with SocketException: Connection refused',
      ]) {
        final e = EvError.from(Exception(raw));
        expect(e.code, 'offline', reason: raw);
        expect(e.userMessage, isNot(contains('supabase.co')));
      }
    });

    test('timeouts are reported as timeouts', () {
      expect(EvError.from(TimeoutException('slow')).code, 'timeout');
    });

    test('unknown errors keep a generic message, never the raw text', () {
      final e = EvError.from(StateError('boom at /internal/path'));
      expect(e.code, 'unknown');
      expect(e.userMessage, isNot(contains('/internal/path')));
    });

    test('EvError passes through unchanged', () {
      const e = EvError('forbidden');
      expect(identical(EvError.from(e), e), isTrue);
      expect(e.isForbidden, isTrue);
    });
  });

  test('every auth code used by the app has a human message', () {
    for (final code in ['invalid_credentials', 'email_taken', 'weak_password', 'invalid_otp', 'rate_limited', 'offline', 'timeout']) {
      expect(EvError(code).userMessage, isNot('Something went wrong. Please try again.'), reason: code);
    }
  });
}
