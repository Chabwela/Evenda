import 'package:evenda/core/errors.dart';
import 'package:evenda/data/supabase/supabase_backend.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

/// The production backend's error translation, exercised without a network:
/// the client points at an unreachable host and calls throw locally.
void main() {
  late SupabaseBackend backend;

  setUp(() {
    final client = sb.SupabaseClient('http://127.0.0.1:9', 'test-key', authOptions: const sb.AuthClientOptions(autoRefreshToken: false));
    backend = SupabaseBackend(client);
  });

  Future<EvError> failWith(Object error) async {
    try {
      await backend.call<void>(() async => throw error);
    } on EvError catch (e) {
      return e;
    }
    fail('expected an EvError');
  }

  test('Supabase auth codes map to specific app errors', () async {
    expect((await failWith(sb.AuthException('Invalid login credentials', code: 'invalid_credentials'))).code, 'invalid_credentials');
    expect((await failWith(sb.AuthException('User already registered', code: 'user_already_exists'))).code, 'email_taken');
    expect((await failWith(sb.AuthException('Token has expired or is invalid', code: 'otp_expired'))).code, 'invalid_otp');
    expect((await failWith(sb.AuthException('Email rate limit exceeded', code: 'over_email_send_rate_limit'))).code, 'rate_limited');
    expect((await failWith(sb.AuthException('Email not confirmed', code: 'email_not_confirmed'))).code, 'email_not_confirmed');
  });

  test('a request that never reached Supabase is "offline" (regression)', () async {
    expect((await failWith(sb.AuthRetryableFetchException(message: 'ClientException: Failed to fetch'))).code, 'offline');
  });

  test('server business-rule errors keep their code', () async {
    final e = await failWith(const sb.PostgrestException(message: 'insufficient_availability', details: '{"available": 3}'));
    expect(e.code, 'insufficient_availability');
    expect(e.userMessage, contains('3'));
  });

  test('RLS denial maps to forbidden', () async {
    expect((await failWith(const sb.PostgrestException(message: 'permission denied for table businesses', code: '42501'))).code, 'forbidden');
  });
}
