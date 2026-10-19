import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:uuid/uuid.dart';

import '../../app/providers.dart';
import '../../core/format.dart';
import '../../design/ev.dart';
import '../../domain/models.dart';
import '../shared/map_widgets.dart';

/// Step 1 of Evenda Now: what, how many, when, and where (confirmed on the map).
class NowCreateScreen extends ConsumerStatefulWidget {
  const NowCreateScreen({super.key, this.categoryId, this.quantity, this.item, this.date});
  final String? categoryId;
  final int? quantity;
  final String? item;
  final String? date;

  @override
  ConsumerState<NowCreateScreen> createState() => _NowCreateScreenState();
}

class _NowCreateScreenState extends ConsumerState<NowCreateScreen> {
  late final NowRequestDraft _d;
  final _item = TextEditingController();
  final _budget = TextEditingController();
  final _notes = TextEditingController();
  final _label = TextEditingController();
  bool _busy = false;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    final biz = ref.read(myBusinessProvider).value!;
    final tomorrow = EvDates.today().add(const Duration(days: 1));
    _d = NowRequestDraft(
      requesterId: biz.id,
      idempotencyKey: const Uuid().v4(),
      categoryId: widget.categoryId,
      quantity: widget.quantity ?? 20,
      neededFrom: widget.date != null ? DateTime.parse(widget.date!) : tomorrow,
      neededByTime: '09:00',
      location: biz.location ?? kLusakaCentre,
      locationLabel: biz.neighbourhood != null ? '${biz.neighbourhood} · ${biz.name}' : biz.name,
    );
    _item.text = widget.item ?? '';
    _label.text = _d.locationLabel;
    _ready = biz.location != null;
  }

  Future<void> _submit() async {
    if (_d.categoryId == null) return _warn('Choose what you need.');
    if (_item.text.trim().length < 2) return _warn('Describe the item, e.g. “White chair covers”.');
    if (!_ready) return _warn('Confirm the location on the map.');
    _d
      ..itemDescription = _item.text.trim()
      ..maxBudget = double.tryParse(_budget.text)
      ..notes = _notes.text.trim()
      ..locationLabel = _label.text.trim().isEmpty ? 'Pinned location' : _label.text.trim();
    setState(() => _busy = true);
    final id = await guard(context, () => ref.read(backendProvider).now.create(_d));
    if (!mounted) return;
    setState(() => _busy = false);
    if (id != null) context.pushReplacement('/now/$id?broadcast=1');
  }

  void _warn(String m) => showToast(context, m, icon: LucideIcons.circleAlert);

  @override
  Widget build(BuildContext context) {
    final today = EvDates.today();
    final tomorrow = today.add(const Duration(days: 1));
    final rentalCats = kCategories.where((c) => c.kind == OfferingType.rental).toList();
    final serviceCats = kCategories.where((c) => c.kind == OfferingType.service).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Urgent request')),
      body: ListView(padding: const EdgeInsets.fromLTRB(EvSpace.gutter, 0, EvSpace.gutter, 140), children: [
        const EvFieldLabel('What do you need?'),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final c in [...rentalCats, ...serviceCats])
            EvChip(label: c.name, icon: categoryIcon(c.id), selected: _d.categoryId == c.id, onTap: () => setState(() => _d.categoryId = c.id)),
        ]),
        const SizedBox(height: EvSpace.x4),
        EvField(label: 'Describe it', controller: _item, hint: 'e.g. White chair covers with sashes', textCapitalization: TextCapitalization.sentences),
        const SizedBox(height: EvSpace.x4),
        EvQuantityStepper(label: 'How many', value: _d.quantity, min: 1, step: _d.quantity >= 20 ? 10 : 1, onChanged: (v) => setState(() => _d.quantity = v),
            helper: 'Several suppliers can each cover part of it.'),
        const SizedBox(height: EvSpace.x5),
        const EvFieldLabel('When'),
        Wrap(spacing: 8, runSpacing: 8, children: [
          EvChip(label: 'Today', selected: EvDates.sameDay(_d.neededFrom, today), onTap: () => setState(() => _d.neededFrom = today)),
          EvChip(label: 'Tomorrow', selected: EvDates.sameDay(_d.neededFrom, tomorrow), onTap: () => setState(() => _d.neededFrom = tomorrow)),
          EvChip(
            label: !EvDates.sameDay(_d.neededFrom, today) && !EvDates.sameDay(_d.neededFrom, tomorrow) ? EvDates.day(_d.neededFrom) : 'Other date',
            icon: LucideIcons.calendarDays,
            selected: !EvDates.sameDay(_d.neededFrom, today) && !EvDates.sameDay(_d.neededFrom, tomorrow),
            onTap: () async {
              final d = await pickDate(context, initial: _d.neededFrom, last: today.add(const Duration(days: 30)));
              if (d != null) setState(() => _d.neededFrom = d);
            },
          ),
          EvChip(
            label: 'By ${_d.neededByTime ?? '—'}',
            icon: LucideIcons.clock,
            selected: _d.neededByTime != null,
            onTap: () async {
              final t = await pickTime(context, initial: const TimeOfDay(hour: 9, minute: 0));
              if (t != null) setState(() => _d.neededByTime = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}');
            },
          ),
        ]),
        const SizedBox(height: EvSpace.x5),
        const EvFieldLabel('Handover'),
        Row(children: [
          Expanded(child: EvOptionTile(title: 'I’ll collect', selected: _d.fulfilment == Fulfilment.pickup, onTap: () => setState(() => _d.fulfilment = Fulfilment.pickup))),
          const SizedBox(width: 8),
          Expanded(child: EvOptionTile(title: 'Deliver to me', selected: _d.fulfilment == Fulfilment.supplierDelivers, onTap: () => setState(() => _d.fulfilment = Fulfilment.supplierDelivers))),
        ]),
        const SizedBox(height: EvSpace.x5),
        EvFieldLabel(_d.fulfilment == Fulfilment.pickup ? 'Search around' : 'Deliver to'),
        LocationPicker(
          initial: _d.location ?? kLusakaCentre,
          height: 260,
          radiusKm: _d.radiusKm.toDouble(),
          pinLabel: 'Request location',
          onChanged: (p, n) => setState(() {
            _d.location = p;
            _ready = true;
            if (_label.text.isEmpty || kNeighbourhoods.any((x) => _label.text.startsWith(x.name))) _label.text = n.name;
          }),
        ),
        const SizedBox(height: EvSpace.x3),
        EvField(label: 'Location note', controller: _label, hint: 'e.g. Kabulonga, near the studio', optional: true),
        const SizedBox(height: EvSpace.x4),
        EvFieldLabel('Ask suppliers within ${_d.radiusKm} km'),
        Slider(value: _d.radiusKm.toDouble(), min: 3, max: 50, divisions: 47, label: '${_d.radiusKm} km', onChanged: (v) => setState(() => _d.radiusKm = v.round())),
        const SizedBox(height: EvSpace.x3),
        EvField(label: 'Maximum budget', controller: _budget, prefixText: 'K ', optional: true, keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly], helper: 'Total for the whole quantity. Shown to suppliers.'),
        const SizedBox(height: EvSpace.x4),
        EvField(label: 'Anything else', controller: _notes, hint: 'Colour, condition, setup needed…', maxLines: 3, minLines: 2, optional: true),
        const SizedBox(height: EvSpace.x3),
        Row(children: [
          const Icon(LucideIcons.shieldCheck, size: 14, color: EvColors.ink3),
          const SizedBox(width: 6),
          Expanded(
            child: Text('Only suppliers with this free on your date are alerted. They see your location note and distance, not your exact address.', style: EvType.caption),
          ),
        ]),
      ]),
      bottomSheet: Container(
        color: EvColors.warmWhite,
        padding: EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x3, EvSpace.gutter, EvSpace.x3 + MediaQuery.paddingOf(context).bottom),
        child: EvButton('Alert nearby suppliers', icon: LucideIcons.radar, expand: true, loading: _busy, onPressed: _submit),
      ),
    );
  }
}
