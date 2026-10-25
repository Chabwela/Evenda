import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../app/providers.dart';
import '../../core/format.dart';
import '../../design/ev.dart';
import '../../domain/models.dart';
import 'event_detail.dart';

/// Create or edit an event and its requirements. Each requirement says who
/// supplies it; Evenda only generates operational tasks for "My business".
class EventEditorScreen extends ConsumerStatefulWidget {
  const EventEditorScreen({super.key, this.id, this.fromBooking});
  final String? id;
  final String? fromBooking;

  @override
  ConsumerState<EventEditorScreen> createState() => _EventEditorScreenState();
}

class _EventEditorScreenState extends ConsumerState<EventEditorScreen> {
  final _form = GlobalKey<FormState>();
  EventDraft? _d;
  DateTime? _originalStart;
  int _linkedTasks = 0;
  bool _busy = false;
  final _name = TextEditingController();
  final _venue = TextEditingController();
  final _client = TextEditingController();
  final _guests = TextEditingController();
  final _notes = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final biz = ref.read(bizIdProvider);
    if (widget.id == null) {
      final start = EvDates.today().add(const Duration(days: 14));
      setState(() => _d = EventDraft(businessId: biz, startsAt: start.add(const Duration(hours: 14)), endsAt: start.add(const Duration(hours: 22))));
      return;
    }
    final (e, tasks) = await ref.read(eventDetailProvider(widget.id!).future);
    _name.text = e.name;
    _venue.text = e.venueName ?? '';
    _client.text = e.clientName ?? '';
    _guests.text = e.guestCount?.toString() ?? '';
    _notes.text = e.notes;
    setState(() {
      _d = EventDraft.from(e);
      _originalStart = e.startsAt;
      _linkedTasks = tasks.where((t) => t.status.open && t.offsetMinutes != null).length;
    });
  }

  Future<void> _pickStart() async {
    final d = _d!;
    final day = await pickDate(context, initial: d.startsAt, first: widget.id != null ? DateTime(2020) : null);
    if (day == null || !mounted) return;
    final t = await pickTime(context, initial: TimeOfDay.fromDateTime(d.startsAt));
    if (t == null) return;
    final dur = d.endsAt.difference(d.startsAt);
    setState(() {
      d.startsAt = DateTime(day.year, day.month, day.day, t.hour, t.minute);
      d.endsAt = d.startsAt.add(dur);
    });
  }

  Future<void> _pickEnd() async {
    final d = _d!;
    final t = await pickTime(context, initial: TimeOfDay.fromDateTime(d.endsAt));
    if (t == null) return;
    setState(() {
      var end = DateTime(d.startsAt.year, d.startsAt.month, d.startsAt.day, t.hour, t.minute);
      if (!end.isAfter(d.startsAt)) end = end.add(const Duration(days: 1));
      d.endsAt = end;
    });
  }

  Future<void> _editRequirement([int? index]) async {
    final existing = index == null ? null : _d!.requirements[index];
    final label = TextEditingController(text: existing?.label ?? '');
    final qty = TextEditingController(text: existing?.quantity?.toString() ?? '');
    final supplier = TextEditingController(text: existing?.supplierName ?? '');
    var resp = existing?.responsibility ?? Responsibility.self;
    var cat = existing?.categoryId;
    final r = await showEvSheet<Requirement>(
      context,
      title: existing == null ? 'Add requirement' : 'Edit requirement',
      subtitle: 'Who handles it decides which tasks you get.',
      builder: (c) => StatefulBuilder(
        builder: (c, set) => ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(EvSpace.gutter, 0, EvSpace.gutter, EvSpace.x6), children: [
          EvField(label: 'What', controller: label, hint: 'e.g. Chairs, Backdrop, Generator', autofocus: existing == null),
          const SizedBox(height: EvSpace.x4),
          Row(children: [
            Expanded(
              child: EvPickerField(
                label: 'Category',
                optional: true,
                value: cat == null ? null : categoryById(cat).name,
                placeholder: 'None',
                onTap: () async {
                  final v = await pickFromSheet<String?>(c, title: 'Category', selected: cat, options: [
                    (null, 'None', null),
                    for (final k in kCategories) (k.id, k.name, null),
                  ]);
                  set(() => cat = v);
                },
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(width: 110, child: EvField(label: 'Quantity', controller: qty, keyboardType: TextInputType.number, optional: true)),
          ]),
          const SizedBox(height: EvSpace.x4),
          const EvFieldLabel('Who supplies it?'),
          for (final x in Responsibility.values) ...[
            EvOptionTile(
              title: x.label,
              icon: responsibilityIcon(x),
              subtitle: switch (x) {
                Responsibility.self => 'You get prepare, load and setup tasks',
                Responsibility.venue => 'One light confirmation task only',
                Responsibility.client => 'One light confirmation task only',
                Responsibility.otherVendor => 'Hire it from another vendor',
                Responsibility.unassigned => 'You get a task to decide',
              },
              selected: resp == x,
              onTap: () => set(() => resp = x),
            ),
            const SizedBox(height: 6),
          ],
          if (resp == Responsibility.otherVendor) ...[
            const SizedBox(height: EvSpace.x2),
            EvField(label: 'Vendor name', controller: supplier, hint: 'e.g. Woodlands Sound & Light', optional: true),
          ],
          const SizedBox(height: EvSpace.x5),
          EvButton('Save', expand: true, onPressed: () {
            if (label.text.trim().isEmpty) return;
            Navigator.pop(
              c,
              Requirement(
                id: existing?.id ?? '',
                label: label.text.trim(),
                responsibility: resp,
                categoryId: cat,
                quantity: int.tryParse(qty.text),
                supplierName: resp == Responsibility.otherVendor && supplier.text.trim().isNotEmpty ? supplier.text.trim() : null,
                bookingId: existing?.bookingId,
              ),
            );
          }),
        ]),
      ),
    );
    if (r == null) return;
    setState(() => index == null ? _d!.requirements.add(r) : _d!.requirements[index] = r);
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final d = _d!
      ..name = _name.text.trim()
      ..venueName = _venue.text.trim().isEmpty ? null : _venue.text.trim()
      ..clientName = _client.text.trim().isEmpty ? null : _client.text.trim()
      ..guestCount = int.tryParse(_guests.text)
      ..notes = _notes.text.trim();
    setState(() => _busy = true);
    final w = ref.read(backendProvider).work;
    final id = await guard(context, () async {
      if (widget.id == null) return w.createEvent(d);
      await w.updateEvent(widget.id!, d);
      return widget.id!;
    }, success: widget.id == null ? 'Event created with suggested tasks' : 'Event updated');
    if (!mounted) return;
    setState(() => _busy = false);
    if (id != null) widget.id == null ? context.pushReplacement('/work/event/$id') : context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    final moved = d != null && _originalStart != null && d.startsAt != _originalStart;
    return Scaffold(
      appBar: AppBar(title: Text(widget.id == null ? 'New event' : 'Edit event')),
      body: d == null
          ? const Skeleton()
          : Form(
              key: _form,
              child: ListView(padding: const EdgeInsets.fromLTRB(EvSpace.gutter, 0, EvSpace.gutter, 120), children: [
                EvField(
                  label: 'Event name',
                  controller: _name,
                  hint: 'e.g. Mwansa & Bwalya wedding',
                  textCapitalization: TextCapitalization.words,
                  validator: (v) => (v == null || v.trim().length < 2) ? 'Name the event' : null,
                ),
                const SizedBox(height: EvSpace.x4),
                const EvFieldLabel('Type'),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final t in EventType.values) EvChip(label: t.label, selected: d.type == t, onTap: () => setState(() => d.type = t)),
                ]),
                const SizedBox(height: EvSpace.x4),
                Row(children: [
                  Expanded(flex: 3, child: EvPickerField(label: 'Starts', value: EvDates.dayTime(d.startsAt), icon: LucideIcons.calendarDays, onTap: _pickStart)),
                  const SizedBox(width: 12),
                  Expanded(flex: 2, child: EvPickerField(label: 'Ends', value: EvDates.time(d.endsAt), icon: LucideIcons.clock, onTap: _pickEnd)),
                ]),
                AnimatedSize(
                  duration: EvMotion.of(context, EvMotion.base),
                  child: moved && _linkedTasks > 0
                      ? Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(color: EvColors.infoTint, borderRadius: EvRadius.smAll),
                            child: Row(children: [
                              Icon(LucideIcons.calendarClock, size: 16, color: EvColors.info),
                              const SizedBox(width: 8),
                              Expanded(child: Text('$_linkedTasks tasks and their reminders will move with the new date.', style: EvType.small.copyWith(color: EvColors.info))),
                            ]),
                          ),
                        )
                      : const SizedBox(width: double.infinity),
                ),
                const SizedBox(height: EvSpace.x4),
                EvField(label: 'Venue', controller: _venue, hint: 'e.g. Garden venue, Leopards Hill Road', optional: true),
                const SizedBox(height: EvSpace.x4),
                Row(children: [
                  Expanded(flex: 3, child: EvField(label: 'Client', controller: _client, optional: true, textCapitalization: TextCapitalization.words)),
                  const SizedBox(width: 12),
                  Expanded(flex: 2, child: EvField(label: 'Guests', controller: _guests, keyboardType: TextInputType.number, optional: true)),
                ]),
                const SizedBox(height: EvSpace.x6),
                Row(children: [
                  Text('WHO SUPPLIES WHAT', style: EvType.overline),
                  const Spacer(),
                  TextButton.icon(onPressed: _editRequirement, icon: const Icon(LucideIcons.plus, size: 16), label: const Text('Add')),
                ]),
                if (d.requirements.isEmpty)
                  Text('E.g. chairs from the venue, décor by you, sound by another vendor.', style: EvType.small),
                for (final (i, q) in d.requirements.indexed)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: EvSurface(
                      padding: EdgeInsets.zero,
                      child: EvRow(
                        dense: true,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        leading: IconTile(responsibilityIcon(q.responsibility), tone: responsibilityTone(q.responsibility), size: 32),
                        title: '${q.label}${q.quantity != null ? ' · ${q.quantity}' : ''}',
                        subtitle: q.supplierName ?? q.responsibility.label,
                        trailing: IconButton(icon: const Icon(LucideIcons.x, size: 16), onPressed: () => setState(() => d.requirements.removeAt(i))),
                        onTap: () => _editRequirement(i),
                      ),
                    ),
                  ),
                const SizedBox(height: EvSpace.x4),
                EvField(label: 'Notes', controller: _notes, maxLines: 4, minLines: 2, optional: true),
                if (widget.id != null) ...[
                  const SizedBox(height: EvSpace.x4),
                  const EvFieldLabel('Status'),
                  Wrap(spacing: 8, children: [for (final s in EventStatus.values) EvChip(label: s.label, selected: d.status == s, onTap: () => setState(() => d.status = s))]),
                ],
              ]),
            ),
      bottomSheet: d == null
          ? null
          : Container(
              color: EvColors.warmWhite,
              padding: EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x3, EvSpace.gutter, EvSpace.x3 + MediaQuery.paddingOf(context).bottom),
              child: EvButton(widget.id == null ? 'Create event' : 'Save changes', expand: true, loading: _busy, onPressed: _save),
            ),
    );
  }
}
