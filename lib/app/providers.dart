import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/errors.dart';
import '../data/backend.dart';
import '../domain/models.dart';

/// The active backend (Supabase or Demo). Overridden in main().
final backendProvider = Provider<Backend>((ref) => throw UnimplementedError('backendProvider must be overridden'));

/// Per-domain revision counters. Providers that read a domain watch its
/// counter, so a mutation or realtime event refetches exactly what changed.
class RevisionNotifier extends Notifier<Map<DataDomain, int>> {
  StreamSubscription<Set<DataDomain>>? _sub;

  @override
  Map<DataDomain, int> build() {
    _sub?.cancel();
    _sub = ref.watch(backendProvider).changes.listen((domains) {
      state = {...state, for (final d in domains) d: (state[d] ?? 0) + 1};
    });
    ref.onDispose(() => _sub?.cancel());
    return {for (final d in DataDomain.values) d: 0};
  }

  /// Refetch everything, e.g. when the connection comes back.
  void bumpAll() => state = {for (final d in DataDomain.values) d: (state[d] ?? 0) + 1};
}

final revisionProvider = NotifierProvider<RevisionNotifier, Map<DataDomain, int>>(RevisionNotifier.new);

extension DomainWatch on Ref {
  /// Re-run this provider whenever any of [domains] changes.
  void watchDomains(Iterable<DataDomain> domains) {
    for (final d in domains) {
      watch(revisionProvider.select((m) => m[d]));
    }
  }
}

final sessionProvider = StreamProvider<Session?>((ref) async* {
  final auth = ref.watch(backendProvider).auth;
  yield auth.current;
  yield* auth.sessions;
});

/// The signed-in user's business, or null while onboarding has not started.
final myBusinessProvider = FutureProvider<Business?>((ref) async {
  ref.watchDomains(const [DataDomain.business, DataDomain.session]);
  final session = ref.watch(sessionProvider).value;
  if (session == null) return null;
  return ref.watch(backendProvider).business.mine();
});

/// Non-null business id for screens inside the vendor shell.
final bizIdProvider = Provider<String>((ref) {
  final b = ref.watch(myBusinessProvider).value;
  if (b == null) throw const EvError('not_authenticated');
  return b.id;
});

/// True while the onboarding finish screen is showing, so the router does not
/// bounce a just-completed business straight to Home.
class OnboardingCelebration extends Notifier<bool> {
  @override
  bool build() => false;
  void set(bool v) => state = v;
}

final onboardingCelebrationProvider = NotifierProvider<OnboardingCelebration, bool>(OnboardingCelebration.new);

final unreadCountProvider = FutureProvider<int>((ref) async {
  ref.watchDomains(const [DataDomain.notifications]);
  final biz = ref.watch(myBusinessProvider).value;
  if (biz == null) return 0;
  return ref.watch(backendProvider).notifications.unreadCount(biz.id);
});
