import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/push.dart';
import '../design/ev.dart';
import '../features/admin/admin_console.dart';
import '../features/admin/admin_business_review.dart';
import '../features/admin/admin_dispute_case.dart';
import '../features/admin/admin_login.dart';
import '../features/auth/auth_screens.dart';
import '../features/bookings/booking_detail.dart';
import '../features/bookings/bookings_screen.dart';
import '../features/bookings/quotation_composer.dart';
import '../features/bookings/request_detail.dart';
import '../features/business/availability_screen.dart';
import '../features/business/account_screen.dart';
import '../features/business/business_screen.dart';
import '../features/business/delete_account_screen.dart';
import '../features/business/inventory_screen.dart';
import '../features/business/listing_editor.dart';
import '../features/business/listings_screen.dart';
import '../features/business/notification_settings.dart';
import '../features/business/profile_screen.dart';
import '../features/business/team_screen.dart';
import '../features/find/find_screen.dart';
import '../features/find/listing_detail.dart';
import '../features/find/quote_request_screen.dart';
import '../features/find/supplier_screen.dart';
import '../features/home/home_screen.dart';
import '../features/notifications/notifications_screen.dart';
import '../features/now/incoming_request.dart';
import '../features/now/now_create.dart';
import '../features/now/now_home.dart';
import '../features/now/now_live.dart';
import '../features/now/now_respond.dart';
import '../features/onboarding/onboarding_screen.dart';
import '../features/work/event_detail.dart';
import '../features/work/event_editor.dart';
import '../features/work/task_detail.dart';
import '../features/work/work_screen.dart';
import 'providers.dart';
import 'shell.dart';

/// Re-evaluates redirects whenever the session or business changes.
class _RouterRefresh extends ChangeNotifier {
  _RouterRefresh(Ref ref) {
    ref.listen(sessionProvider, (_, _) => notifyListeners());
    ref.listen(myBusinessProvider, (_, _) => notifyListeners());
    ref.listen(adminSessionProvider, (_, _) => notifyListeners());
    ref.listen(onboardingCelebrationProvider, (_, _) => notifyListeners());
    ref.listen(launchIntroDoneProvider, (_, _) => notifyListeners());
  }
}

final _rootKey = GlobalKey<NavigatorState>();

CustomTransitionPage<void> _page(GoRouterState s, Widget child) => CustomTransitionPage(
      key: s.pageKey,
      child: child,
      transitionDuration: EvMotion.base,
      reverseTransitionDuration: EvMotion.fast,
      transitionsBuilder: (context, a, sa, child) => EvFadeThrough(animation: a, secondary: sa, child: child),
    );

GoRoute _r(String path, Widget Function(GoRouterState s) build) =>
    GoRoute(path: path, parentNavigatorKey: _rootKey, pageBuilder: (c, s) => _page(s, build(s)));

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = _RouterRefresh(ref);
  final router = GoRouter(
    navigatorKey: _rootKey,
    initialLocation: '/launch',
    refreshListenable: refresh,
    redirect: (context, state) {
      final loc = state.matchedLocation;
      if (loc.startsWith('/admin')) return null; // the console checks its own access
      if (loc == '/launch' && !ref.read(launchIntroDoneProvider)) return null; // let the mark finish
      final session = ref.read(sessionProvider);
      final business = ref.read(myBusinessProvider);
      final open = loc == '/welcome' || loc.startsWith('/auth');

      if (session.isLoading && !session.hasValue) return loc == '/launch' ? null : '/launch';
      if (session.value == null) return open ? null : '/welcome';
      // Staff accounts belong in the console, never in vendor onboarding.
      final admin = ref.read(adminSessionProvider);
      if (admin.isLoading && !admin.hasValue) return loc == '/launch' ? null : '/launch';
      if (admin.value != null) return '/admin';
      // Signed-in screens that live under /auth: name capture and the last
      // step of a password reset (the recovery code signs the user in).
      if (loc == '/auth/profile' || loc == '/auth/new-password') return null;
      // A refetch after sign-in can briefly hold the previous (null) value;
      // treat that as loading rather than "no business yet".
      if (business.isLoading && business.value == null) return loc == '/launch' ? null : '/launch';
      if (business.hasError && !business.hasValue) return loc == '/launch' ? null : '/launch';
      final b = business.value;
      if (b == null || !b.onboardingCompleted) {
        if ((session.value!.fullName).isEmpty && b == null) return '/auth/profile';
        return loc == '/onboarding' ? null : '/onboarding';
      }
      if (loc == '/onboarding' && ref.read(onboardingCelebrationProvider)) return null;
      if (open || loc == '/launch' || loc == '/onboarding') return '/home';
      return null;
    },
    routes: [
      _r('/launch', (_) => const LaunchScreen()),
      _r('/welcome', (_) => const WelcomeScreen()),
      _r('/auth/phone', (_) => const PhoneScreen()),
      _r('/auth/email', (_) => const EmailPasswordScreen()),
      _r('/auth/otp', (s) => OtpScreen(phone: s.uri.queryParameters['phone'] ?? '')),
      _r('/auth/signup', (_) => const SignUpScreen()),
      _r('/auth/forgot', (s) => ForgotPasswordScreen(email: s.uri.queryParameters['email'] ?? '')),
      _r('/auth/code', (s) => EmailCodeScreen(email: s.uri.queryParameters['email'] ?? '', recovery: s.uri.queryParameters['purpose'] == 'recovery')),
      _r('/auth/new-password', (_) => const NewPasswordScreen()),
      _r('/auth/profile', (_) => const ProfileNameScreen()),
      _r('/onboarding', (_) => const OnboardingScreen()),
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => VendorShell(shell: shell),
        branches: [
          StatefulShellBranch(routes: [GoRoute(path: '/home', pageBuilder: (c, s) => NoTransitionPage(child: const HomeScreen()))]),
          StatefulShellBranch(routes: [GoRoute(path: '/find', pageBuilder: (c, s) => NoTransitionPage(child: FindScreen(initialCategory: s.uri.queryParameters['category'])))]),
          StatefulShellBranch(routes: [GoRoute(path: '/bookings', pageBuilder: (c, s) => NoTransitionPage(child: BookingsScreen(initialTab: s.uri.queryParameters['tab'])))]),
          StatefulShellBranch(routes: [GoRoute(path: '/work', pageBuilder: (c, s) => NoTransitionPage(child: WorkScreen(initialTab: s.uri.queryParameters['tab'])))]),
          StatefulShellBranch(routes: [GoRoute(path: '/business', pageBuilder: (c, s) => const NoTransitionPage(child: BusinessScreen()))]),
        ],
      ),
      _r('/notifications', (_) => const NotificationsScreen()),
      _r('/listing/:id', (s) => ListingDetailScreen(id: s.pathParameters['id']!)),
      _r('/supplier/:id', (s) => SupplierScreen(id: s.pathParameters['id']!)),
      _r('/quote/new', (s) => QuoteRequestScreen(supplierId: s.uri.queryParameters['supplier']!, listingId: s.uri.queryParameters['listing'],
          from: s.uri.queryParameters['from'], quantity: int.tryParse(s.uri.queryParameters['qty'] ?? ''))),
      _r('/bookings/request/:id', (s) => RequestDetailScreen(id: s.pathParameters['id']!)),
      _r('/bookings/request/:id/quote', (s) => QuotationComposerScreen(requestId: s.pathParameters['id']!)),
      _r('/bookings/:id', (s) => BookingDetailScreen(id: s.pathParameters['id']!)),
      _r('/work/event/new', (s) => EventEditorScreen(fromBooking: s.uri.queryParameters['booking'])),
      _r('/work/event/:id', (s) => EventDetailScreen(id: s.pathParameters['id']!)),
      _r('/work/event/:id/edit', (s) => EventEditorScreen(id: s.pathParameters['id'])),
      _r('/work/task/:id', (s) => TaskDetailScreen(id: s.pathParameters['id']!)),
      _r('/business/account', (_) => const AccountScreen()),
      _r('/business/delete-account', (_) => const DeleteAccountScreen()),
      _r('/business/profile', (_) => const BusinessProfileScreen()),
      _r('/business/stock/new', (_) => const ListingEditorScreen(kind: 'rental', mode: ListingEditorMode.item)),
      _r('/business/stock/:id', (s) => ListingEditorScreen(id: s.pathParameters['id'], mode: ListingEditorMode.item)),
      _r('/business/listings', (_) => const ListingsScreen()),
      _r('/business/listings/new', (s) => ListingEditorScreen(kind: s.uri.queryParameters['kind'])),
      _r('/business/listings/:id', (s) => ListingEditorScreen(id: s.pathParameters['id'])),
      _r('/business/inventory', (s) => InventoryScreen(focusListingId: s.uri.queryParameters['listing'])),
      _r('/business/availability', (s) => AvailabilityScreen(listingId: s.uri.queryParameters['listing'])),
      _r('/business/team', (_) => const TeamScreen()),
      _r('/business/notifications', (_) => const NotificationSettingsScreen()),
      _r('/now', (_) => const NowHomeScreen()),
      _r('/now/new', (s) => NowCreateScreen(categoryId: s.uri.queryParameters['category'], quantity: int.tryParse(s.uri.queryParameters['qty'] ?? ''),
          item: s.uri.queryParameters['item'], date: s.uri.queryParameters['date'])),
      _r('/now/respond/:id', (s) => NowRespondScreen(id: s.pathParameters['id']!)),
      _r('/now/incoming/:id', (s) => IncomingRequestScreen(id: s.pathParameters['id']!)),
      _r('/now/:id', (s) => NowLiveScreen(id: s.pathParameters['id']!)),
      _r('/admin/business/:id', (s) => AdminBusinessReviewScreen(id: s.pathParameters['id']!)),
      _r('/admin/dispute/:id', (s) => AdminDisputeCaseScreen(id: s.pathParameters['id']!)),
      _r('/admin', (_) => const AdminConsoleScreen()),
      _r('/admin/login', (_) => const AdminLoginScreen()),
    ],
    errorPageBuilder: (c, s) => _page(s, Scaffold(
          appBar: AppBar(),
          body: EmptyState(title: 'Page not found', body: 'This link may be out of date.', action: 'Go home', onAction: () => c.go('/home')),
        )),
  );

  ref.onDispose(refresh.dispose);
  // Open the screen a tapped push notification points to, once the vendor
  // is signed in with a finished business (cold starts wait for that).
  void openTapped() {
    final route = PushService.tapRoutes.value;
    final b = ref.read(myBusinessProvider).value;
    if (route == null || ref.read(sessionProvider).value == null || b == null || !b.onboardingCompleted) return;
    if (!ref.read(launchIntroDoneProvider)) return; // after the splash, or the launch redirect would replace it
    PushService.tapRoutes.value = null;
    // Let the launch redirect to /home settle first, so Back returns there.
    Future.delayed(const Duration(milliseconds: 350), () => router.push(route));
  }

  PushService.tapRoutes.addListener(openTapped);
  ref.listen(myBusinessProvider, (_, _) => openTapped());
  ref.listen(launchIntroDoneProvider, (_, _) => openTapped());
  ref.onDispose(() => PushService.tapRoutes.removeListener(openTapped));
  return router;
});
