import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../app/providers.dart';
import '../../app/shell.dart';
import '../../core/format.dart';
import '../../data/backend.dart';
import '../../design/ev.dart';
import '../../domain/models.dart';

final workTasksProvider = FutureProvider.autoDispose<List<WorkTask>>((ref) async {
  ref.watchDomains(const [DataDomain.work]);
  return ref.watch(backendProvider).work.tasks(ref.watch(bizIdProvider));
});

final workEventsProvider = FutureProvider.autoDispose<List<EventPlan>>((ref) async {
  ref.watchDomains(const [DataDomain.work]);
  return ref.watch(backendProvider).work.events(ref.watch(bizIdProvider));
});

final workloadProvider = FutureProvider.autoDispose.family<List<WorkloadDay>, DateTime>((ref, month) async {
  ref.watchDomains(const [DataDomain.work]);
  final from = DateTime(month.year, month.month, 1).subtract(Duration(days: DateTime(month.year, month.month, 1).weekday - 1));
  return ref.watch(backendProvider).work.workload(ref.watch(bizIdProvider), from, from.add(const Duration(days: 41)));
});

enum _Tab { agenda, calendar, events }

class WorkScreen extends ConsumerStatefulWidget {
  const WorkScreen({super.key, this.initialTab});
  final String? initialTab;
  @override
  ConsumerState<WorkScreen> createState() => _WorkScreenState();
}

class _WorkScreenState extends ConsumerState<WorkScreen> {
  late _Tab _tab = _Tab.values.where((t) => t.name == widget.initialTab).firstOrNull ?? _Tab.agenda;

  Future<void> _add() async {
    final r = await pickFromSheet<String>(context, title: 'Add', icon: (v) => v == 'event' ? LucideIcons.calendarPlus : LucideIcons.listPlus, options: const [
      ('task', 'Task', 'A to-do with a deadline and reminders'),
      ('event', 'Event', 'A job you’re working, with responsibilities and generated tasks'),
    ]);
    if (!mounted || r == null) return;
    if (r == 'event') {
      context.push('/work/event/new');
    } else {
      await showNewTaskSheet(context, ref);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tasks = ref.watch(workTasksProvider);
    final overdue = tasks.value?.where((t) => t.overdue).length ?? 0;
    return Scaffold(
      appBar: TabHeader(
        title: 'My Work',
        actions: [EvIconButton(LucideIcons.plus, tooltip: 'Add task or event', onPressed: _add)],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(50),
          child: Padding(
            padding: const EdgeInsets.only(bottom: EvSpace.x2),
            child: EvSegmented<_Tab>(
              value: _tab,
              onChanged: (t) => setState(() => _tab = t),
              counts: {_Tab.agenda: overdue},
              segments: const [(_Tab.agenda, 'Agenda'), (_Tab.calendar, 'Calendar'), (_Tab.events, 'Events')],
            ),
          ),
        ),
      ),
      body: AnimatedSwitcher(
        duration: EvMotion.of(context, EvMotion.fast),
        child: KeyedSubtree(
          key: ValueKey(_tab),
          child: switch (_tab) {
            _Tab.agenda => const _Agenda(),
            _Tab.calendar => const _Calendar(),
            _Tab.events => const _Events(),
          },
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Agenda
// ---------------------------------------------------------------------------

class _Agenda extends ConsumerWidget {
  const _Agenda();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(workTasksProvider);
    return RefreshIndicator(
      color: EvColors.forest,
      onRefresh: () => ref.refresh(workTasksProvider.future),
      child: AsyncView(
        value: tasks,
        onRetry: () => ref.invalidate(workTasksProvider),
        isEmpty: (t) => t.isEmpty,
        empty: ListView(children: [
          EmptyState(
            mascot: Mascot.calendar,
            title: 'All clear',
            body: 'No open tasks. Create an event and Evenda will suggest the tasks you’re responsible for.',
            action: 'New event',
            onAction: () => context.push('/work/event/new'),
          ),
        ]),
        data: (list) {
          final today = EvDates.today();
          final groups = <(String, IconData?, Tone), List<WorkTask>>{};
          for (final t in list) {
            final d = EvDates.dateOnly(t.dueAt).difference(today).inDays;
            final key = t.overdue
                ? ('Overdue', LucideIcons.alarmClock, Tone.critical)
                : d == 0
                    ? ('Today', null, Tone.neutral)
                    : d == 1
                        ? ('Tomorrow', null, Tone.neutral)
                        : d < 7
                            ? ('This week', null, Tone.neutral)
                            : ('Later', null, Tone.neutral);
            groups.putIfAbsent(key, () => []).add(t);
          }
          return ListView(padding: const EdgeInsets.only(bottom: EvSpace.x10), children: [
            const _WeekLoad(),
            for (final e in groups.entries) _TaskGroup(title: e.key.$1, icon: e.key.$2, tone: e.key.$3, tasks: e.value, initiallyOpen: e.key.$1 != 'Later'),
          ]);
        },
      ),
    );
  }
}

/// Seven-day workload strip: events weigh more than tasks; overlapping
/// events are flagged so double-booking is visible before it bites.
class _WeekLoad extends ConsumerWidget {
  const _WeekLoad();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final today = EvDates.today();
    final data = ref.watch(workloadProvider(DateTime(today.year, today.month)));
    final days = (data.value ?? const <WorkloadDay>[]).where((d) => !d.day.isBefore(today)).take(7).toList();
    if (days.isEmpty) return const SizedBox(height: EvSpace.x2);
    final maxLoad = math.max(6, days.map((d) => d.load).fold(0, math.max));
    return Padding(
      padding: const EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x3, EvSpace.gutter, 0),
      child: EvSurface(
        padding: const EdgeInsets.fromLTRB(EvSpace.x4, EvSpace.x3, EvSpace.x4, EvSpace.x3),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text('Next 7 days', style: EvType.smallStrong),
            const Spacer(),
            if (days.any((d) => d.overlapping))
              const StatusPill('Overlapping events', tone: Tone.attention, dense: true, icon: LucideIcons.triangleAlert),
          ]),
          const SizedBox(height: 10),
          SizedBox(
            height: 64,
            child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              for (final d in days)
                Expanded(
                  child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                    TweenAnimationBuilder<double>(
                      tween: Tween(end: d.load / maxLoad),
                      duration: EvMotion.of(context, EvMotion.slow),
                      curve: EvMotion.standard,
                      builder: (_, v, _) => Container(
                        width: 18,
                        height: math.max(4, 40 * v),
                        decoration: BoxDecoration(
                          color: d.overlapping ? EvColors.warning : (d.events > 0 ? EvColors.forest : EvColors.forestSoft.withValues(alpha: 0.45)),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(EvDates.sameDay(d.day, today) ? 'Today' : EvDates.day(d.day).substring(0, 3),
                        style: EvType.caption.copyWith(fontSize: 10.5, fontWeight: EvDates.sameDay(d.day, today) ? FontWeight.w700 : FontWeight.w500)),
                  ]),
                ),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _TaskGroup extends StatefulWidget {
  const _TaskGroup({required this.title, required this.tasks, required this.tone, this.icon, this.initiallyOpen = true});
  final String title;
  final IconData? icon;
  final Tone tone;
  final List<WorkTask> tasks;
  final bool initiallyOpen;

  @override
  State<_TaskGroup> createState() => _TaskGroupState();
}

class _TaskGroupState extends State<_TaskGroup> {
  late bool _open = widget.initiallyOpen;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      InkWell(
        onTap: () => setState(() => _open = !_open),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x5, EvSpace.x4, EvSpace.x2),
          child: Row(children: [
            if (widget.icon != null) ...[Icon(widget.icon, size: 14, color: widget.tone.fg), const SizedBox(width: 6)],
            Text(widget.title.toUpperCase(), style: EvType.overline.copyWith(color: widget.tone == Tone.critical ? EvColors.danger : EvColors.ink3)),
            const SizedBox(width: 6),
            Text('${widget.tasks.length}', style: EvType.overline.copyWith(color: EvColors.bronze)),
            const Spacer(),
            AnimatedRotation(
              turns: _open ? 0 : -0.25,
              duration: EvMotion.of(context, EvMotion.fast),
              child: Icon(LucideIcons.chevronDown, size: 18, color: EvColors.ink3),
            ),
          ]),
        ),
      ),
      AnimatedSize(
        duration: EvMotion.of(context, EvMotion.base),
        curve: EvMotion.standard,
        alignment: Alignment.topCenter,
        child: _open
            ? Column(children: [
                for (final (i, t) in widget.tasks.indexed) ...[
                  if (i > 0) const EvDivider(indent: 60),
                  TaskRow(task: t),
                ],
              ])
            : const SizedBox(width: double.infinity),
      ),
    ]);
  }
}

/// Task row with an animated completion: the check draws, the title strikes
/// through and the row leaves. Completion is saved before the row leaves.
class TaskRow extends ConsumerStatefulWidget {
  const TaskRow({super.key, required this.task, this.showEvent = true});
  final WorkTask task;
  final bool showEvent;

  @override
  ConsumerState<TaskRow> createState() => _TaskRowState();
}

class _TaskRowState extends ConsumerState<TaskRow> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: EvMotion.emphasis);
  bool _done = false;

  @override
  void didUpdateWidget(TaskRow old) {
    super.didUpdateWidget(old);
    if (old.task.id != widget.task.id) {
      _done = false;
      _c.value = 0;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _complete() async {
    HapticFeedback.mediumImpact();
    setState(() => _done = true);
    // Animate first: saving refreshes the list, which would remove the row
    // mid-animation. If the save fails the row comes back with an error.
    if (!EvMotion.reduced(context)) await _c.forward();
    if (!mounted) return;
    final ok = await guard(context, () async {
      await ref.read(backendProvider).work.setTaskStatus(widget.task.id, TaskStatus.done);
      return true;
    });
    if (!mounted) return;
    if (ok != true) {
      _c.value = 0;
      setState(() => _done = false);
      return;
    }
    if (mounted) {
      showToast(context, 'Done — reminders cancelled', icon: LucideIcons.circleCheck, action: 'Undo', onAction: () {
        ref.read(backendProvider).work.setTaskStatus(widget.task.id, TaskStatus.todo);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.task;
    final a = CurvedAnimation(parent: _c, curve: const Interval(0.45, 1, curve: Curves.easeIn));
    final meta = [
      if (t.overdue) 'Overdue ${EvDates.ago(t.dueAt).toLowerCase()}' else EvDates.sameDay(t.dueAt, DateTime.now()) ? EvDates.time(t.dueAt) : EvDates.dayTime(t.dueAt),
      if (widget.showEvent && t.eventName != null) t.eventName!,
    ].join(' · ');
    return SizeTransition(
      sizeFactor: ReverseAnimation(a),
      child: FadeTransition(
        opacity: ReverseAnimation(a),
        child: InkWell(
          onTap: () => context.push('/work/task/${t.id}'),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(EvSpace.x3, 6, EvSpace.gutter, 6),
            child: Row(children: [
              _CheckCircle(checked: _done, priority: t.priority, onTap: _done ? null : _complete),
              const SizedBox(width: 6),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  AnimatedDefaultTextStyle(
                    duration: EvMotion.of(context, EvMotion.fast),
                    style: EvType.body.copyWith(
                      color: _done ? EvColors.ink3 : EvColors.ink,
                      decoration: _done ? TextDecoration.lineThrough : null,
                      fontWeight: FontWeight.w500,
                    ),
                    child: Text(t.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                  ),
                  const SizedBox(height: 2),
                  Row(children: [
                    if (t.generated) ...[Icon(LucideIcons.sparkles, size: 11, color: EvColors.bronze), const SizedBox(width: 4)],
                    Flexible(
                      child: Text(meta, style: EvType.caption.copyWith(color: t.overdue ? EvColors.danger : EvColors.ink3), maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                  ]),
                ]),
              ),
              if (t.priority == TaskPriority.high || t.priority == TaskPriority.critical)
                StatusPill(t.priority.label, tone: toneForPriority(t.priority), dense: true),
            ]),
          ),
        ),
      ),
    );
  }
}

class _CheckCircle extends StatelessWidget {
  const _CheckCircle({required this.checked, required this.priority, this.onTap});
  final bool checked;
  final TaskPriority priority;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ring = priority == TaskPriority.critical ? EvColors.danger : (priority == TaskPriority.high ? EvColors.warning : EvColors.sandDeep);
    return Semantics(
      checked: checked,
      button: true,
      label: 'Mark done',
      child: InkResponse(
        onTap: onTap,
        radius: 22,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Center(
            child: AnimatedContainer(
              duration: EvMotion.of(context, EvMotion.fast),
              curve: EvMotion.spring,
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: checked ? EvColors.forest : Colors.transparent,
                border: Border.all(color: checked ? EvColors.forest : ring, width: 1.8),
              ),
              child: AnimatedScale(
                scale: checked ? 1 : 0,
                duration: EvMotion.of(context, EvMotion.base),
                curve: EvMotion.spring,
                child: Icon(LucideIcons.check, size: 14, color: EvColors.inkOnDark),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> showNewTaskSheet(BuildContext context, WidgetRef ref, {String? eventId}) async {
  final title = TextEditingController();
  var due = DateTime.now().add(const Duration(days: 1));
  due = DateTime(due.year, due.month, due.day, 9);
  var priority = TaskPriority.normal;
  final ok = await showEvSheet<bool>(
    context,
    title: 'New task',
    builder: (c) => StatefulBuilder(
      builder: (c, set) => ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(EvSpace.gutter, 0, EvSpace.gutter, EvSpace.x6), children: [
        EvField(label: 'Task', controller: title, hint: 'e.g. Wash and count chair covers', autofocus: true),
        const SizedBox(height: EvSpace.x4),
        Row(children: [
          Expanded(
            child: EvPickerField(label: 'Due date', value: EvDates.day(due), icon: LucideIcons.calendarDays, onTap: () async {
              final d = await pickDate(c, initial: due);
              if (d != null) set(() => due = DateTime(d.year, d.month, d.day, due.hour, due.minute));
            }),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: EvPickerField(label: 'Time', value: EvDates.time(due), icon: LucideIcons.clock, onTap: () async {
              final t = await pickTime(c, initial: TimeOfDay.fromDateTime(due));
              if (t != null) set(() => due = DateTime(due.year, due.month, due.day, t.hour, t.minute));
            }),
          ),
        ]),
        const SizedBox(height: EvSpace.x4),
        const EvFieldLabel('Priority'),
        Wrap(spacing: 8, children: [for (final p in TaskPriority.values) EvChip(label: p.label, selected: priority == p, onTap: () => set(() => priority = p))]),
        const SizedBox(height: EvSpace.x2),
        Text(switch (priority) {
          TaskPriority.low => 'Included in your daily summary only.',
          TaskPriority.normal => 'Reminder 24 hours before.',
          _ => 'Reminders 24 hours and 2 hours before${priority == TaskPriority.critical ? ', even during quiet hours' : ''}.',
        }, style: EvType.caption),
        const SizedBox(height: EvSpace.x5),
        EvButton('Add task', expand: true, onPressed: () => Navigator.pop(c, title.text.trim().length >= 2)),
      ]),
    ),
  );
  if (ok != true || !context.mounted) return;
  await guard(context, () => ref.read(backendProvider).work.createTask(ref.read(bizIdProvider), title: title.text, dueAt: due, priority: priority, eventId: eventId), success: 'Task added');
}

// ---------------------------------------------------------------------------
// Calendar
// ---------------------------------------------------------------------------

class _Calendar extends ConsumerStatefulWidget {
  const _Calendar();
  @override
  ConsumerState<_Calendar> createState() => _CalendarState();
}

class _CalendarState extends ConsumerState<_Calendar> {
  DateTime _month = DateTime(EvDates.today().year, EvDates.today().month);
  DateTime _selected = EvDates.today();

  @override
  Widget build(BuildContext context) {
    final load = ref.watch(workloadProvider(_month));
    final events = ref.watch(workEventsProvider).value ?? const [];
    final tasks = ref.watch(workTasksProvider).value ?? const [];
    final first = DateTime(_month.year, _month.month, 1);
    final start = first.subtract(Duration(days: first.weekday - 1));
    final byDay = {for (final d in load.value ?? const <WorkloadDay>[]) EvDates.iso(d.day): d};
    final dayEvents = events.where((e) => !EvDates.dateOnly(e.startsAt).isAfter(_selected) && !EvDates.dateOnly(e.endsAt).isBefore(_selected)).toList();
    final dayTasks = tasks.where((t) => EvDates.sameDay(t.dueAt, _selected)).toList();

    return ListView(padding: const EdgeInsets.only(bottom: EvSpace.x10), children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x2, EvSpace.x2, 0),
        child: Row(children: [
          Text(EvDates.monthYear(_month), style: EvType.headline),
          const Spacer(),
          EvIconButton(LucideIcons.chevronLeft, tooltip: 'Previous month', onPressed: () => setState(() => _month = DateTime(_month.year, _month.month - 1))),
          EvIconButton(LucideIcons.chevronRight, tooltip: 'Next month', onPressed: () => setState(() => _month = DateTime(_month.year, _month.month + 1))),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: EvSpace.x3),
        child: Column(children: [
          Row(children: [
            for (final d in const ['M', 'T', 'W', 'T', 'F', 'S', 'S'])
              Expanded(child: Center(child: Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(d, style: EvType.caption)))),
          ]),
          for (var w = 0; w < 6; w++)
            Row(children: [
              for (var i = 0; i < 7; i++)
                Expanded(
                  child: Builder(builder: (context) {
                    final day = start.add(Duration(days: w * 7 + i));
                    final info = byDay[EvDates.iso(day)];
                    return _DayCell(
                      day: day,
                      inMonth: day.month == _month.month,
                      selected: EvDates.sameDay(day, _selected),
                      today: EvDates.sameDay(day, EvDates.today()),
                      info: info,
                      onTap: () => setState(() => _selected = day),
                    );
                  }),
                ),
            ]),
        ]),
      ),
      const SizedBox(height: EvSpace.x2),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: EvSpace.gutter),
        child: Row(children: [
          _legend(EvColors.forest, 'Event'),
          const SizedBox(width: 14),
          _legend(EvColors.forestSoft.withValues(alpha: 0.5), 'Tasks'),
          const SizedBox(width: 14),
          _legend(EvColors.warning, 'Overlap'),
        ]),
      ),
      SectionHeader(EvDates.dayLong(_selected)),
      if (dayEvents.isEmpty && dayTasks.isEmpty)
        Padding(padding: const EdgeInsets.symmetric(horizontal: EvSpace.gutter), child: Text('Nothing scheduled.', style: EvType.small)),
      for (final e in dayEvents)
        EvRow(
          leading: const IconTile(LucideIcons.calendarCheck, tone: Tone.positive),
          title: e.name,
          subtitle: '${EvDates.time(e.startsAt)}–${EvDates.time(e.endsAt)}${e.venueName != null ? ' · ${e.venueName}' : ''}',
          onTap: () => context.push('/work/event/${e.id}'),
        ),
      for (final t in dayTasks) TaskRow(task: t),
    ]);
  }

  Widget _legend(Color c, String l) => Row(children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
        const SizedBox(width: 5),
        Text(l, style: EvType.caption),
      ]);
}

class _DayCell extends StatelessWidget {
  const _DayCell({required this.day, required this.inMonth, required this.selected, required this.today, required this.onTap, this.info});
  final DateTime day;
  final bool inMonth;
  final bool selected;
  final bool today;
  final WorkloadDay? info;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final i = info;
    return InkWell(
      onTap: onTap,
      borderRadius: EvRadius.smAll,
      child: AnimatedContainer(
        duration: EvMotion.of(context, EvMotion.fast),
        height: 52,
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: selected ? EvColors.forest : (i != null && i.events > 0 ? EvColors.forestWash : Colors.transparent),
          borderRadius: EvRadius.smAll,
          border: today && !selected ? Border.all(color: EvColors.bronze, width: 1.4) : null,
        ),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Text('${day.day}',
              style: EvType.smallStrong.copyWith(
                color: selected ? EvColors.inkOnDark : (inMonth ? EvColors.ink : EvColors.ink3.withValues(alpha: 0.5)),
              )),
          const SizedBox(height: 4),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            if (i != null && i.events > 0) _dot(selected ? EvColors.inkOnDark : (i.overlapping ? EvColors.warning : EvColors.forest)),
            if (i != null && i.tasksDue > 0) _dot(selected ? EvColors.sand : (i.overdue > 0 ? EvColors.danger : EvColors.forestSoft.withValues(alpha: 0.5))),
          ]),
        ]),
      ),
    );
  }

  Widget _dot(Color c) => Container(width: 5, height: 5, margin: const EdgeInsets.symmetric(horizontal: 1.5), decoration: BoxDecoration(color: c, shape: BoxShape.circle));
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

class _Events extends ConsumerWidget {
  const _Events();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final events = ref.watch(workEventsProvider);
    final tasks = ref.watch(workTasksProvider).value ?? const [];
    return AsyncView(
      value: events,
      onRetry: () => ref.invalidate(workEventsProvider),
      isEmpty: (e) => e.isEmpty,
      empty: EmptyState(
        mascot: Mascot.calendar,
        title: 'No events yet',
        body: 'Add the weddings, parties and functions you’re working. Evenda builds the task list from what you’re responsible for.',
        action: 'New event',
        onAction: () => context.push('/work/event/new'),
      ),
      data: (list) {
        final now = DateTime.now();
        final upcoming = list.where((e) => e.endsAt.isAfter(now) && e.status != EventStatus.cancelled).toList();
        final past = list.where((e) => !e.endsAt.isAfter(now) || e.status == EventStatus.cancelled).toList().reversed.toList();
        Widget row(EventPlan e) {
          final ts = tasks.where((t) => t.eventId == e.id).toList();
          return EvRow(
            leading: Container(
              width: 48,
              padding: const EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(color: EvColors.forestWash, borderRadius: EvRadius.smAll),
              child: Column(children: [
                Text(EvDates.dayShort(e.startsAt).split(' ').last.toUpperCase(), style: EvType.overline.copyWith(color: EvColors.forest, fontSize: 9.5)),
                Text('${e.startsAt.day}', style: EvType.headline.copyWith(color: EvColors.forest)),
              ]),
            ),
            title: e.name,
            subtitle: [e.type.label, if (e.venueName != null) e.venueName!].join(' · '),
            meta: Row(children: [
              StatusPill(e.status.label, tone: e.status == EventStatus.cancelled ? Tone.neutral : (e.status == EventStatus.confirmed ? Tone.positive : Tone.waiting), dense: true),
              const SizedBox(width: 8),
              if (ts.isNotEmpty) Text('${ts.length} open task${ts.length == 1 ? '' : 's'}', style: EvType.caption),
            ]),
            onTap: () => context.push('/work/event/${e.id}'),
          );
        }

        return ListView(padding: const EdgeInsets.only(bottom: EvSpace.x10), children: [
          if (upcoming.isNotEmpty) SectionHeader('Upcoming', count: upcoming.length),
          for (final (i, e) in upcoming.indexed) ...[if (i > 0) const EvDivider(indent: 80), row(e)],
          if (past.isNotEmpty) SectionHeader('Past & cancelled', count: past.length),
          for (final (i, e) in past.indexed) ...[if (i > 0) const EvDivider(indent: 80), Opacity(opacity: 0.7, child: row(e))],
        ]);
      },
    );
  }
}
