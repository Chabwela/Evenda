import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../app/providers.dart';
import '../../core/format.dart';
import '../../data/backend.dart';
import '../../design/ev.dart';
import '../../domain/models.dart';
import 'work_screen.dart';

final eventDetailProvider = FutureProvider.autoDispose.family<(EventPlan, List<WorkTask>), String>((ref, id) async {
  ref.watchDomains(const [DataDomain.work]);
  final w = ref.watch(backendProvider).work;
  final e = await w.event(id);
  final t = await w.tasks(e.businessId, eventId: id, includeDone: true);
  return (e, t);
});

IconData responsibilityIcon(Responsibility r) => switch (r) {
      Responsibility.self => LucideIcons.store,
      Responsibility.venue => LucideIcons.building2,
      Responsibility.client => LucideIcons.userRound,
      Responsibility.otherVendor => LucideIcons.handshake,
      Responsibility.unassigned => LucideIcons.circleHelp,
    };

Tone responsibilityTone(Responsibility r) => switch (r) {
      Responsibility.self => Tone.positive,
      Responsibility.unassigned => Tone.attention,
      Responsibility.otherVendor => Tone.progress,
      _ => Tone.neutral,
    };

class EventDetailScreen extends ConsumerWidget {
  const EventDetailScreen({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(eventDetailProvider(id));
    return Scaffold(
      appBar: AppBar(actions: [
        EvIconButton(LucideIcons.squarePen, tooltip: 'Edit event', onPressed: () => context.push('/work/event/$id/edit')),
        const SizedBox(width: 8),
      ]),
      body: AsyncView(
        value: data,
        onRetry: () => ref.invalidate(eventDetailProvider(id)),
        data: (r) {
          final (e, tasks) = r;
          final open = tasks.where((t) => t.status.open).toList();
          final done = tasks.where((t) => t.status == TaskStatus.done).length;
          final total = tasks.where((t) => t.status != TaskStatus.cancelled).length;
          return ListView(padding: const EdgeInsets.only(bottom: EvSpace.x10), children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: EvSpace.gutter),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(e.type.label.toUpperCase(), style: EvType.overline),
                const SizedBox(height: 4),
                Text(e.name, style: EvType.display),
                const SizedBox(height: EvSpace.x3),
                Wrap(spacing: 14, runSpacing: 6, children: [
                  _Meta(LucideIcons.calendarDays, EvDates.sameDay(e.startsAt, e.endsAt) ? '${EvDates.day(e.startsAt)}, ${EvDates.time(e.startsAt)}–${EvDates.time(e.endsAt)}' : EvDates.range(e.startsAt, e.endsAt)),
                  if (e.venueName != null) _Meta(LucideIcons.mapPin, e.venueName!),
                  if (e.clientName != null) _Meta(LucideIcons.userRound, e.clientName!),
                  if (e.guestCount != null) _Meta(LucideIcons.users, '${e.guestCount} guests'),
                ]),
                const SizedBox(height: EvSpace.x4),
                if (total > 0) ...[
                  Row(children: [
                    Text('$done of $total tasks done', style: EvType.smallStrong),
                    const Spacer(),
                    Text(EvDates.relativeDay(e.startsAt), style: EvType.small),
                  ]),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: TweenAnimationBuilder<double>(
                      tween: Tween(end: total == 0 ? 0 : done / total),
                      duration: EvMotion.of(context, EvMotion.slow),
                      curve: EvMotion.standard,
                      builder: (_, v, _) => LinearProgressIndicator(value: v, minHeight: 6),
                    ),
                  ),
                ],
              ]),
            ),

            SectionHeader('Who supplies what', count: e.requirements.length, action: 'Edit', onAction: () => context.push('/work/event/$id/edit')),
            if (e.requirements.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: EvSpace.gutter),
                child: Text('Add requirements (chairs, décor, sound…) and say who provides each. Tasks are generated only for what your business handles.',
                    style: EvType.small),
              ),
            for (final (i, q) in e.requirements.indexed) ...[
              if (i > 0) const EvDivider(indent: 68),
              EvRow(
                leading: IconTile(responsibilityIcon(q.responsibility), tone: responsibilityTone(q.responsibility)),
                title: '${q.label}${q.quantity != null ? ' · ${q.quantity}' : ''}',
                subtitle: q.responsibility == Responsibility.otherVendor && q.supplierName != null
                    ? q.supplierName!
                    : q.responsibility == Responsibility.self
                        ? (q.bookingId != null ? 'Your business · arranged' : 'Your business · to arrange')
                        : q.responsibility.label,
                trailing: (q.responsibility == Responsibility.self && q.bookingId == null) || q.responsibility == Responsibility.unassigned
                    ? TextButton(
                        onPressed: () => context.push('/find${q.categoryId != null ? '?category=${q.categoryId}' : ''}'),
                        child: const Text('Find supplier'),
                      )
                    : const SizedBox.shrink(),
              ),
            ],

            SectionHeader('Tasks', count: open.length, action: 'Add task', onAction: () => showNewTaskSheet(context, ref, eventId: e.id)),
            if (tasks.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: EvSpace.gutter),
                child: EvButton('Suggest tasks', kind: EvButtonKind.secondary, icon: LucideIcons.sparkles, onPressed: () async {
                  final n = await guard(context, () => ref.read(backendProvider).work.generateTasks(e.id));
                  if (n != null && context.mounted) showToast(context, n == 0 ? 'No new tasks to add' : 'Added $n tasks');
                }),
              ),
            for (final (i, t) in open.indexed) ...[if (i > 0) const EvDivider(indent: 60), TaskRow(task: t, showEvent: false)],
            if (done > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x3, EvSpace.gutter, 0),
                child: Text('$done completed', style: EvType.caption),
              ),
            if (tasks.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(EvSpace.x3, EvSpace.x3, EvSpace.gutter, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: const Icon(LucideIcons.sparkles, size: 16),
                    label: const Text('Check for missing tasks'),
                    onPressed: () async {
                      final n = await guard(context, () => ref.read(backendProvider).work.generateTasks(e.id));
                      if (n != null && context.mounted) showToast(context, n == 0 ? 'Nothing missing — no duplicates added' : 'Added $n tasks');
                    },
                  ),
                ),
              ),
            if (e.notes.isNotEmpty) ...[
              const SectionHeader('Notes'),
              Padding(padding: const EdgeInsets.symmetric(horizontal: EvSpace.gutter), child: Text(e.notes, style: EvType.body)),
            ],
          ]);
        },
      ),
    );
  }
}

class _Meta extends StatelessWidget {
  const _Meta(this.icon, this.text);
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 14, color: EvColors.ink3),
        const SizedBox(width: 5),
        Text(text, style: EvType.small),
      ]);
}
