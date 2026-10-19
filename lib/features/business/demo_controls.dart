import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../app/providers.dart';
import '../../data/demo/demo_backend.dart';
import '../../design/ev.dart';

/// Demo-only tools. Switching vendor lets one person play both sides of a
/// transaction (request as one vendor, quote as another, accept as the first).
class DemoControlsScreen extends ConsumerWidget {
  const DemoControlsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final backend = ref.watch(backendProvider);
    if (backend is! DemoBackend) {
      return Scaffold(appBar: AppBar(), body: const EmptyState(title: 'Not available', body: 'Demo controls exist only in demo mode.'));
    }
    final current = ref.watch(sessionProvider).value?.userId;
    return Scaffold(
      appBar: AppBar(title: const Text('Demo controls')),
      body: ListView(children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: EvSpace.gutter),
          child: EvSurface(
            color: EvColors.bronzeTint,
            child: Text(
              'Everything here is fictional demo data held in memory on this device. It resets when the app restarts. '
              'Connect Supabase to run Evenda with real accounts.',
              style: EvType.small.copyWith(color: EvColors.bronzeDeep),
            ),
          ),
        ),
        const SectionHeader('Act as'),
        for (final p in backend.personas)
          EvRow(
            leading: BusinessAvatar(name: backend.db.businesses[p.businessId]!.name, verified: backend.db.businesses[p.businessId]!.verified),
            title: backend.db.businesses[p.businessId]!.name,
            subtitle: '${p.person} · ${p.role}',
            trailing: p.userId == current ? const StatusPill('Current', tone: Tone.positive, dense: true) : null,
            onTap: p.userId == current
                ? null
                : () {
                    backend.enterAs(p.userId);
                    context.go('/home');
                    showToast(context, 'Now acting as ${backend.db.businesses[p.businessId]!.name}', icon: LucideIcons.repeat);
                  },
          ),
        const SectionHeader('Tools'),
        EvRow(
          leading: const IconTile(LucideIcons.shieldCheck, tone: Tone.progress),
          title: 'Open admin console',
          subtitle: 'Sign in with a demo admin role',
          onTap: () => context.push('/admin/login'),
        ),
        EvRow(
          leading: const IconTile(LucideIcons.rotateCcw, tone: Tone.critical),
          title: 'Reset demo data',
          subtitle: 'Restore the original vendors, listings and bookings',
          onTap: () async {
            if (await confirmAction(context, title: 'Reset demo data?', body: 'All changes you made in this session will be lost.', confirm: 'Reset', destructive: true)) {
              backend.reset();
              if (context.mounted) showToast(context, 'Demo data reset', icon: LucideIcons.rotateCcw);
            }
          },
        ),
      ]),
    );
  }
}
