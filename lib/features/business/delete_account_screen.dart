import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/config.dart';
import '../../app/providers.dart';
import '../../core/format.dart';
import '../../design/ev.dart';

final _checkProvider = FutureProvider.autoDispose((ref) => ref.watch(backendProvider).auth.deletionCheck());

/// Permanent account deletion (Google Play User Data policy). Says plainly
/// what goes and what stays before anything happens.
class DeleteAccountScreen extends ConsumerStatefulWidget {
  const DeleteAccountScreen({super.key});
  @override
  ConsumerState<DeleteAccountScreen> createState() => _DeleteAccountScreenState();
}

class _DeleteAccountScreenState extends ConsumerState<DeleteAccountScreen> {
  final _confirm = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _delete() async {
    setState(() => _busy = true);
    final ok = await guard(context, () async {
      await ref.read(backendProvider).auth.deleteAccount();
      return true;
    });
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok == true) {
      showToast(context, 'Your account has been deleted.', icon: LucideIcons.circleCheck);
      context.go('/welcome');
    }
  }

  @override
  Widget build(BuildContext context) {
    final check = ref.watch(_checkProvider);
    Widget point(IconData icon, String text, {Color? color}) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, size: 18, color: color ?? EvColors.ink2),
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: EvType.small)),
          ]),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('Delete account'), centerTitle: false),
      body: ListView(padding: const EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x2, EvSpace.gutter, EvSpace.x10), children: [
        Text('This permanently deletes your Evenda account.', style: EvType.title),
        const SizedBox(height: EvSpace.x2),
        Text('It cannot be undone. If you only want a break, sign out instead.', style: EvType.body.copyWith(color: EvColors.ink2)),

        const SectionHeader('Deleted', padding: EdgeInsets.fromLTRB(0, EvSpace.x5, 0, EvSpace.x2)),
        EvSurface(
          child: Column(children: [
            point(LucideIcons.userX, 'Your login, name, email and phone number', color: EvColors.danger),
            point(LucideIcons.store, 'Your business name, description, logo, contacts and map location', color: EvColors.danger),
            point(LucideIcons.images, 'Listing photos and verification documents (PACRA, TPIN, NRC)', color: EvColors.danger),
            point(LucideIcons.calendarDays, 'Your events, tasks, reminders, follows and notifications', color: EvColors.danger),
            point(LucideIcons.bellOff, 'Push notifications to your phones stop', color: EvColors.danger),
          ]),
        ),

        const SectionHeader('Kept, without your name', padding: EdgeInsets.fromLTRB(0, EvSpace.x5, 0, EvSpace.x2)),
        EvSurface(
          child: Column(children: [
            point(LucideIcons.receipt,
                'Past bookings, quotations and payment records stay in the other vendor’s history (items, dates, amounts) and show your business as “Deleted business”.'),
            point(LucideIcons.scrollText, 'Records of decisions Evenda staff took on your account, for security and dispute handling.'),
          ]),
        ),

        const SizedBox(height: EvSpace.x5),
        check.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ErrorState(error: e, compact: true, onRetry: () => ref.invalidate(_checkProvider)),
          data: (c) {
            final blockers = [
              if (c.isAdmin) 'This is an Evenda staff account. A super admin removes staff access.',
              if (c.teamMembers > 0) 'You have ${plural(c.teamMembers, 'team member')}. Remove them in Business → Team first.',
              if (c.activeBookings > 0) 'You have ${plural(c.activeBookings, 'active booking')}. Finish or cancel them first.',
            ];
            if (blockers.isNotEmpty) {
              return EvSurface(
                color: EvColors.warningTint,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Before you can delete', style: EvType.smallStrong.copyWith(color: EvColors.warning)),
                  const SizedBox(height: 6),
                  for (final b in blockers) point(LucideIcons.circleAlert, b, color: EvColors.warning),
                ]),
              );
            }
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              EvField(label: 'Type DELETE to confirm', controller: _confirm, textCapitalization: TextCapitalization.characters, onChanged: (_) => setState(() {})),
              const SizedBox(height: EvSpace.x4),
              EvButton('Delete my account permanently', kind: EvButtonKind.danger, icon: LucideIcons.trash2, expand: true, loading: _busy,
                  onPressed: _confirm.text.trim() == 'DELETE' ? _delete : null),
            ]);
          },
        ),
        if (AppConfig.privacyPolicyUrl.isNotEmpty) ...[
          const SizedBox(height: EvSpace.x4),
          Center(
            child: TextButton(
              onPressed: () => launchUrl(Uri.parse(AppConfig.privacyPolicyUrl), mode: LaunchMode.externalApplication),
              child: const Text('How Evenda handles your data'),
            ),
          ),
        ],
      ]),
    );
  }
}
