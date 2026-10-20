import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/config.dart';
import '../../app/providers.dart';
import '../../design/ev.dart';

/// Account & privacy. Account deletion lives here, at the bottom of its own
/// page, so it can never be hit by mistake while signing out.
class AccountScreen extends ConsumerWidget {
  const AccountScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider).value;
    final biz = ref.watch(myBusinessProvider).value;

    Widget fact(IconData icon, String title, String body) => Padding(
          padding: const EdgeInsets.only(bottom: EvSpace.x3),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, size: 18, color: EvColors.forest),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: EvType.smallStrong),
                Text(body, style: EvType.small),
              ]),
            ),
          ]),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('Account & privacy'), centerTitle: false),
      body: ListView(padding: const EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x2, EvSpace.gutter, EvSpace.x10), children: [
        EvSurface(
          child: Row(children: [
            const IconTile(LucideIcons.userRound),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(session?.fullName.isNotEmpty == true ? session!.fullName : 'Your account', style: EvType.bodyStrong),
                if (biz != null) Text('Owner of ${biz.name}', style: EvType.small),
              ]),
            ),
          ]),
        ),

        const SectionHeader('Your data on Evenda', padding: EdgeInsets.fromLTRB(0, EvSpace.x5, 0, EvSpace.x2)),
        EvSurface(
          child: Column(children: [
            fact(LucideIcons.eye, 'Other vendors see', 'Your business profile, live listings and photos, and your location as exact or approximate (your choice in Business profile).'),
            fact(LucideIcons.lock, 'Only your business sees', 'Your exact pin, stock counts, jobs, events, tasks and verification documents.'),
            fact(LucideIcons.shieldCheck, 'Evenda staff', 'See what their role needs (for example verification or support). Every decision is recorded.'),
            fact(LucideIcons.wallet, 'Payments', 'Evenda records payments between vendors. It never holds money or asks for mobile-money PINs.'),
          ]),
        ),
        const SizedBox(height: EvSpace.x3),
        EvSurface(
          padding: EdgeInsets.zero,
          child: Column(children: [
            if (AppConfig.privacyPolicyUrl.isNotEmpty) ...[
              EvRow(
                leading: const IconTile(LucideIcons.fileText),
                title: 'Privacy policy',
                subtitle: 'The full details',
                trailing: const Icon(LucideIcons.externalLink, size: 18, color: EvColors.ink3),
                onTap: () => launchUrl(Uri.parse(AppConfig.privacyPolicyUrl), mode: LaunchMode.externalApplication),
              ),
              const EvDivider(indent: 64),
            ],
            EvRow(
              leading: const IconTile(LucideIcons.mapPin),
              title: 'Location privacy',
              subtitle: 'Exact or approximate pin for other vendors',
              trailing: const Icon(LucideIcons.chevronRight, size: 18, color: EvColors.ink3),
              onTap: () => context.push('/business/profile'),
            ),
            const EvDivider(indent: 64),
            EvRow(
              leading: const IconTile(LucideIcons.bellRing),
              title: 'Notifications',
              subtitle: 'Choose what reaches your phone',
              trailing: const Icon(LucideIcons.chevronRight, size: 18, color: EvColors.ink3),
              onTap: () => context.push('/business/notifications'),
            ),
          ]),
        ),

        // Kept apart and at the end, with its own explanation.
        const SectionHeader('Leaving Evenda', padding: EdgeInsets.fromLTRB(0, EvSpace.x8, 0, EvSpace.x2)),
        Container(
          padding: const EdgeInsets.all(EvSpace.x4),
          decoration: BoxDecoration(borderRadius: EvRadius.mdAll, border: Border.all(color: EvColors.danger.withValues(alpha: 0.35))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Delete your account', style: EvType.bodyStrong),
            const SizedBox(height: 4),
            Text('Permanently removes your login, business profile, photos and documents. Past bookings stay in the other vendor’s records without your name.',
                style: EvType.small),
            const SizedBox(height: EvSpace.x3),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => context.push('/business/delete-account'),
                icon: const Icon(LucideIcons.trash2, size: 16, color: EvColors.danger),
                label: Text('Delete account…', style: EvType.smallStrong.copyWith(color: EvColors.danger)),
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}
