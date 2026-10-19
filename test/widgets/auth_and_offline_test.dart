import 'package:evenda/app/providers.dart';
import 'package:evenda/core/connectivity.dart';
import 'package:evenda/data/demo/demo_backend.dart';
import 'package:evenda/design/ev.dart';
import 'package:evenda/features/auth/auth_screens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// Hosts one screen with a router (the auth screens use context.canPop/push).
/// DemoBackend stands in for the server; these tests cover the UI only.
late DemoBackend _backend;

Widget host(Widget screen, {bool online = true}) {
  _backend = DemoBackend();
  final router = GoRouter(routes: [GoRoute(path: '/', builder: (_, _) => screen)]);
  return ProviderScope(
    overrides: [
      backendProvider.overrideWithValue(_backend),
      onlineProvider.overrideWith((ref) => Stream.value(online)),
    ],
    child: MaterialApp.router(theme: EvTheme.light(), routerConfig: router),
  );
}

/// A typical Android phone in portrait: 360 × 800 logical pixels.
void phone(WidgetTester t) {
  t.view.physicalSize = const Size(1080, 2400);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
}

Future<void> tapButton(WidgetTester t, String label) async {
  final b = find.text(label).last;
  await t.ensureVisible(b);
  await t.pump();
  await t.tap(b);
}

Future<void> settle(WidgetTester t) async {
  // Screens have looping animations, so pump for a fixed time instead of pumpAndSettle.
  for (var i = 0; i < 10; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  // Each test ends with _backend.dispose(): DemoBackend runs a periodic clock
  // that must stop before flutter_test checks for pending timers.
  group('Create account form', () {
    testWidgets('blocks an empty submission with field-level messages', (t) async {
      phone(t);
      await t.pumpWidget(host(const SignUpScreen()));
      await settle(t);
      await tapButton(t, 'Create account');
      await settle(t);
      expect(find.text('Enter your name'), findsOneWidget);
      expect(find.text('Enter a valid email'), findsOneWidget);
      expect(find.text('Use at least 8 characters'), findsOneWidget);
      _backend.dispose();
    });

    testWidgets('requires letters and numbers in the password', (t) async {
      phone(t);
      await t.pumpWidget(host(const SignUpScreen()));
      await settle(t);
      final fields = find.byType(TextFormField);
      await t.enterText(fields.at(0), 'Mutale Banda');
      await t.enterText(fields.at(1), 'qa-vendor@example.com');
      await t.enterText(fields.at(2), 'onlyletters');
      await tapButton(t, 'Create account');
      await settle(t);
      expect(find.text('Use both letters and numbers'), findsOneWidget);
      _backend.dispose();
    });

    testWidgets('shows the server error instead of failing silently', (t) async {
      phone(t);
      await t.pumpWidget(host(const SignUpScreen()));
      await settle(t);
      final fields = find.byType(TextFormField);
      await t.enterText(fields.at(0), 'Mutale Banda');
      await t.enterText(fields.at(1), 'qa-vendor@example.com');
      await t.enterText(fields.at(2), 'chairs2026');
      await tapButton(t, 'Create account');
      await settle(t);
      // DemoBackend refuses sign-up; the message must reach the user.
      expect(find.text('Accounts need the live backend.'), findsOneWidget);
      _backend.dispose();
    });
  });

  group('Offline state', () {
    testWidgets('explains no connection when the radio is off', (t) async {
      phone(t);
      await t.pumpWidget(host(Scaffold(body: OfflineState(onRetry: () {})), online: false));
      await settle(t);
      expect(find.text('You’re offline'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      _backend.dispose();
    });

    testWidgets('explains a connection that does not reach the internet', (t) async {
      phone(t);
      await t.pumpWidget(host(Scaffold(body: OfflineState(onRetry: () {}))));
      await settle(t);
      expect(find.text('Evenda can’t be reached'), findsOneWidget);
      expect(find.textContaining('data balance'), findsOneWidget);
      _backend.dispose();
    });

    testWidgets('ErrorState routes offline errors to the offline screen', (t) async {
      phone(t);
      await t.pumpWidget(host(Scaffold(body: ErrorState(error: Exception('SocketException: Failed host lookup'), onRetry: () {})), online: false));
      await settle(t);
      expect(find.text('You’re offline'), findsOneWidget);
      expect(find.text('Couldn’t load this'), findsNothing);
      _backend.dispose();
    });
  });
}
