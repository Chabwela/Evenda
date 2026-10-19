import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../app/providers.dart';
import '../../core/format.dart';
import '../../data/backend.dart';
import '../../design/ev.dart';
import '../../domain/models.dart';

final _taskProvider = FutureProvider.autoDispose.family<(WorkTask, List<TaskReminder>), String>((ref, id) async {
  ref.watchDomains(const [DataDomain.work]);
  final w = ref.watch(backendProvider).work;
  final r = await Future.wait([w.task(id), w.reminders(id)]);
  return (r[0] as WorkTask, r[1] as List<TaskReminder>);
});

class TaskDetailScreen extends ConsumerWidget {
  const TaskDetailScreen({super.key, required this.id});
  final String id;

  Future<void> _snooze(BuildContext context, WidgetRef ref, WorkTask t) async {
    final now = DateTime.now();
    final tomorrow8 = DateTime(now.year, now.month, now.day + 1, 8);
    final choice = await pickFromSheet<String>(context, title: 'Remind me again', options: [
      ('1h', 'In 1 hour', EvDates.time(now.add(const Duration(hours: 1)))),
      ('3h', 'In 3 hours', EvDates.time(now.add(const Duration(hours: 3)))),
      ('tomorrow', 'Tomorrow morning', EvDates.dayTime(tomorrow8)),
      ('pick', 'Pick a time', null),
    ]);
    if (choice == null || !context.mounted) return;
    DateTime? until = switch (choice) {
      '1h' => now.add(const Duration(hours: 1)),
      '3h' => now.add(const Duration(hours: 3)),
      'tomorrow' => tomorrow8,
      _ => null,
    };
    if (choice == 'pick') {
      final d = await pickDate(context, initial: now);
      if (d == null || !context.mounted) return;
      final tm = await pickTime(context);
      if (tm == null) return;
      until = DateTime(d.year, d.month, d.day, tm.hour, tm.minute);
    }
    if (!context.mounted) return;
    await guard(context, () => ref.read(backendProvider).work.snoozeTask(t.id, until!), success: 'Reminder moved to ${EvDates.dayTime(until!)}');
  }

  Future<void> _reschedule(BuildContext context, WidgetRef ref, WorkTask t) async {
    final d = await pickDate(context, initial: t.dueAt.isBefore(DateTime.now()) ? EvDates.today() : t.dueAt);
    if (d == null || !context.mounted) return;
    final tm = await pickTime(context, initial: TimeOfDay.fromDateTime(t.dueAt));
    if (tm == null || !context.mounted) return;
    final due = DateTime(d.year, d.month, d.day, tm.hour, tm.minute);
    await guard(context, () => ref.read(backendProvider).work.updateTask(t.copyWith(dueAt: due)), success: 'Due ${EvDates.dayTime(due)} · reminders rescheduled');
  }

  Future<void> _edit(BuildContext context, WidgetRef ref, WorkTask t) async {
    final title = TextEditingController(text: t.title);
    final notes = TextEditingController(text: t.notes);
    var priority = t.priority;
    final ok = await showEvSheet<bool>(
      context,
      title: 'Edit task',
      builder: (c) => StatefulBuilder(
        builder: (c, set) => ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(EvSpace.gutter, 0, EvSpace.gutter, EvSpace.x6), children: [
          EvField(label: 'Task', controller: title),
          const SizedBox(height: EvSpace.x4),
          const EvFieldLabel('Priority'),
          Wrap(spacing: 8, children: [for (final p in TaskPriority.values) EvChip(label: p.label, selected: priority == p, onTap: () => set(() => priority = p))]),
          const SizedBox(height: EvSpace.x4),
          EvField(label: 'Notes', controller: notes, maxLines: 4, minLines: 2, optional: true),
          const SizedBox(height: EvSpace.x5),
          EvButton('Save', expand: true, onPressed: () => Navigator.pop(c, true)),
        ]),
      ),
    );
    if (ok != true || !context.mounted) return;
    await guard(context, () => ref.read(backendProvider).work.updateTask(t.copyWith(title: title.text.trim(), notes: notes.text.trim(), priority: priority)), success: 'Saved');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(_taskProvider(id));
    final work = ref.read(backendProvider).work;
    return Scaffold(
      appBar: AppBar(actions: [
        if (data.hasValue) EvIconButton(LucideIcons.squarePen, tooltip: 'Edit', onPressed: () => _edit(context, ref, data.value!.$1)),
        const SizedBox(width: 8),
      ]),
      body: AsyncView(
        value: data,
        onRetry: () => ref.invalidate(_taskProvider(id)),
        data: (r) {
          final (t, reminders) = r;
          final open = t.status.open;
          return ListView(padding: const EdgeInsets.fromLTRB(EvSpace.gutter, 0, EvSpace.gutter, EvSpace.x10), children: [
            Wrap(spacing: 8, runSpacing: 6, children: [
              StatusPill(t.status.label, tone: switch (t.status) { TaskStatus.done => Tone.positive, TaskStatus.cancelled => Tone.neutral, _ => t.overdue ? Tone.critical : Tone.waiting }),
              StatusPill('${t.priority.label} priority', tone: toneForPriority(t.priority)),
              if (t.generated) const StatusPill('Suggested by Evenda', tone: Tone.neutral, icon: LucideIcons.sparkles),
            ]),
            const SizedBox(height: EvSpace.x3),
            Text(t.title, style: EvType.display),
            const SizedBox(height: EvSpace.x4),
            EvSurface(
              child: Column(children: [
                KeyValue('Due', '${EvDates.dayTime(t.dueAt)}${t.overdue ? ' (overdue)' : ''}',
                    valueStyle: EvType.body.copyWith(color: t.overdue ? EvColors.danger : EvColors.ink)),
                if (t.eventName != null)
                  KeyValue('Event', t.eventName!, trailing: t.eventId == null ? null : InkWell(onTap: () => context.push('/work/event/${t.eventId}'), child: const Icon(LucideIcons.chevronRight, size: 18))),
                if (t.bookingId != null)
                  KeyValue('Booking', 'Linked booking', trailing: InkWell(onTap: () => context.push('/bookings/${t.bookingId}'), child: const Icon(LucideIcons.chevronRight, size: 18))),
                if (t.offsetMinutes != null)
                  KeyValue('Timing', 'Moves automatically if the event date changes'),
                if (t.notes.isNotEmpty) KeyValue('Notes', t.notes),
              ]),
            ),
            const SizedBox(height: EvSpace.x4),
            if (open) ...[
              EvButton('Mark done', icon: LucideIcons.circleCheck, expand: true,
                  onPressed: () => guard(context, () => work.setTaskStatus(t.id, TaskStatus.done), success: 'Done — reminders cancelled')),
              const SizedBox(height: EvSpace.x2),
              Row(children: [
                Expanded(child: EvButton('Snooze', kind: EvButtonKind.secondary, icon: LucideIcons.alarmClock, onPressed: () => _snooze(context, ref, t))),
                const SizedBox(width: 8),
                Expanded(child: EvButton('Reschedule', kind: EvButtonKind.secondary, icon: LucideIcons.calendarClock, onPressed: () => _reschedule(context, ref, t))),
              ]),
              const SizedBox(height: EvSpace.x2),
              EvButton('No longer needed', kind: EvButtonKind.quiet, expand: true,
                  onPressed: () => guard(context, () => work.setTaskStatus(t.id, TaskStatus.cancelled), success: 'Task cancelled · reminders stopped')),
            ] else
              EvButton('Reopen task', kind: EvButtonKind.secondary, expand: true, onPressed: () => guard(context, () => work.setTaskStatus(t.id, TaskStatus.todo))),
            SectionHeader('Reminders', padding: const EdgeInsets.fromLTRB(0, EvSpace.x6, 0, EvSpace.x2)),
            if (reminders.isEmpty)
              Text(t.priority == TaskPriority.low ? 'Low-priority tasks appear in your daily summary instead of separate reminders.' : 'No reminders scheduled.', style: EvType.small),
            for (final rm in reminders)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(children: [
                  Icon(
                    switch (rm.status) { 'sent' => LucideIcons.bellRing, 'cancelled' => LucideIcons.bellOff, _ => LucideIcons.bell },
                    size: 16,
                    color: rm.status == 'pending' ? EvColors.forest : EvColors.ink3,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '${switch (rm.kind) { 'deadline' => 'Deadline alert', 'snoozed' => 'Snoozed reminder', _ => 'Reminder' }} · ${EvDates.dayTime(rm.remindAt)}',
                      style: EvType.body.copyWith(
                        color: rm.status == 'cancelled' ? EvColors.ink3 : EvColors.ink,
                        decoration: rm.status == 'cancelled' ? TextDecoration.lineThrough : null,
                      ),
                    ),
                  ),
                  Text(switch (rm.status) { 'sent' => 'Sent', 'cancelled' => 'Cancelled', _ => 'Scheduled' }, style: EvType.caption),
                ]),
              ),
            const SizedBox(height: EvSpace.x2),
            Text('Reminders respect your quiet hours (critical tasks excepted) and stop as soon as the task is done.', style: EvType.caption),
          ]);
        },
      ),
    );
  }
}
