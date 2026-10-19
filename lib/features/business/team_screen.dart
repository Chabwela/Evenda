import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../app/providers.dart';
import '../../core/format.dart';
import '../../data/backend.dart';
import '../../design/ev.dart';
import '../../domain/models.dart';

final _teamProvider = FutureProvider.autoDispose<List<TeamMember>>((ref) async {
  ref.watchDomains(const [DataDomain.business]);
  return ref.watch(backendProvider).business.team(ref.watch(bizIdProvider));
});

/// Roles are enforced by the database (is_member / can_manage):
///  owner   — everything, including team and verification
///  manager — listings, stock, quotations, bookings, payments
///  staff   — tasks, events and viewing bookings; cannot quote or change stock
class TeamScreen extends ConsumerWidget {
  const TeamScreen({super.key});

  static String roleHint(MemberRole r) => switch (r) {
        MemberRole.owner => 'Full control, including team and verification',
        MemberRole.manager => 'Listings, stock, quotations, bookings and payments',
        MemberRole.staff => 'Tasks and events; can view bookings but not quote or change stock',
      };

  Future<void> _invite(BuildContext context, WidgetRef ref) async {
    final name = TextEditingController();
    final email = TextEditingController();
    final form = GlobalKey<FormState>();
    var role = MemberRole.staff;
    final ok = await showEvSheet<bool>(
      context,
      title: 'Add a team member',
      subtitle: 'They join when they sign in to Evenda with this email.',
      builder: (c) => StatefulBuilder(
        builder: (c, set) => Form(
          key: form,
          child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(EvSpace.gutter, 0, EvSpace.gutter, EvSpace.x6), children: [
            EvField(label: 'Name', controller: name, textCapitalization: TextCapitalization.words, validator: (v) => (v ?? '').trim().length < 2 ? 'Required' : null),
            const SizedBox(height: EvSpace.x4),
            EvField(
              label: 'Work email',
              controller: email,
              keyboardType: TextInputType.emailAddress,
              textCapitalization: TextCapitalization.none,
              prefixIcon: LucideIcons.mail,
              validator: (v) => (v == null || v.trim().isEmpty || !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(v.trim())) ? 'Enter a valid email' : null,
            ),
            const SizedBox(height: EvSpace.x4),
            const EvFieldLabel('Role'),
            for (final r in const [MemberRole.manager, MemberRole.staff]) ...[
              EvOptionTile(title: r.label, subtitle: roleHint(r), selected: role == r, onTap: () => set(() => role = r)),
              const SizedBox(height: 6),
            ],
            const SizedBox(height: EvSpace.x4),
            EvButton('Add member', expand: true, onPressed: () {
              if (form.currentState!.validate()) Navigator.pop(c, true);
            }),
          ]),
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    await guard(context, () => ref.read(backendProvider).business.inviteMember(ref.read(bizIdProvider), email.text.trim(), name.text.trim(), role),
        success: '${name.text.trim()} added');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final team = ref.watch(_teamProvider);
    final api = ref.read(backendProvider).business;
    return Scaffold(
      appBar: AppBar(title: const Text('Team'), actions: [EvIconButton(LucideIcons.userPlus, tooltip: 'Add member', onPressed: () => _invite(context, ref)), const SizedBox(width: 8)]),
      body: AsyncView(
        value: team,
        onRetry: () => ref.invalidate(_teamProvider),
        data: (members) => ListView(children: [
          for (final (i, m) in members.indexed) ...[
            if (i > 0) const EvDivider(indent: 72),
            EvRow(
              leading: BusinessAvatar(name: m.displayName, size: 40),
              title: m.displayName,
              subtitle: '${m.role.label}${m.invited ? ' · invited' : ''}${m.email != null ? ' · ${m.email}' : ''}${m.phone != null && m.email == null ? ' · ${ZambianPhone.display(m.phone)}' : ''}',
              trailing: m.role == MemberRole.owner
                  ? const StatusPill('Owner', tone: Tone.positive, dense: true)
                  : PopupMenuButton<String>(
                      icon: const Icon(LucideIcons.ellipsisVertical, size: 18),
                      onSelected: (v) async {
                        if (v == 'remove') {
                          if (await confirmAction(context, title: 'Remove ${m.displayName}?', body: 'They lose access to this business immediately.', confirm: 'Remove', destructive: true) &&
                              context.mounted) {
                            await guard(context, () => api.removeMember(m.id), success: 'Removed');
                          }
                        } else {
                          await guard(context, () => api.setMemberRole(m.id, v == 'manager' ? MemberRole.manager : MemberRole.staff), success: 'Role updated');
                        }
                      },
                      itemBuilder: (_) => [
                        if (m.role != MemberRole.manager) const PopupMenuItem(value: 'manager', child: Text('Make manager')),
                        if (m.role != MemberRole.staff) const PopupMenuItem(value: 'staff', child: Text('Make staff')),
                        const PopupMenuItem(value: 'remove', child: Text('Remove')),
                      ],
                    ),
            ),
          ],
          const SectionHeader('What each role can do'),
          for (final r in MemberRole.values)
            EvRow(dense: true, leading: IconTile(r == MemberRole.owner ? LucideIcons.keyRound : (r == MemberRole.manager ? LucideIcons.briefcase : LucideIcons.user), size: 32), title: r.label, subtitle: roleHint(r)),
        ]),
      ),
    );
  }
}
