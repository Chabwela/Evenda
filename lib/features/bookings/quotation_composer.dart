import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../app/providers.dart';
import '../../core/format.dart';
import '../../design/ev.dart';
import '../../domain/models.dart';
import 'request_detail.dart';

class _Line {
  _Line({this.listingId, required this.description, required this.quantity, required this.unitPrice, required this.days, this.categoryId});
  final String? listingId;
  String? categoryId;
  String description;
  int quantity;
  double unitPrice;
  int days;
  int? available;
  double get total => quantity * unitPrice * days;
}

class QuotationComposerScreen extends ConsumerStatefulWidget {
  const QuotationComposerScreen({super.key, required this.requestId});
  final String requestId;

  @override
  ConsumerState<QuotationComposerScreen> createState() => _QuotationComposerScreenState();
}

class _QuotationComposerScreenState extends ConsumerState<QuotationComposerScreen> {
  final _lines = <_Line>[];
  final _charges = <(TextEditingController, TextEditingController)>[];
  final _deposit = TextEditingController();
  final _depositTerms = TextEditingController();
  final _payment = TextEditingController(text: 'Deposit to confirm, balance on collection.');
  final _conditions = TextEditingController();
  DateTime _valid = EvDates.today().add(const Duration(days: 5));
  bool _seeded = false;
  bool _busy = false;

  Future<void> _seed(QuoteRequest q) async {
    if (_seeded) return;
    _seeded = true;
    final b = ref.read(backendProvider);
    final mine = await b.listings.mine(q.supplier.id);
    final prev = q.latestQuotation;
    if (prev != null) {
      for (final i in prev.items) {
        _lines.add(_Line(listingId: i.listingId, description: i.description, quantity: i.quantity, unitPrice: i.unitPrice, days: i.days));
      }
      for (final c in prev.charges) {
        _charges.add((TextEditingController(text: c.label), TextEditingController(text: c.amount.toStringAsFixed(0))));
      }
      if (prev.depositAmount > 0) _deposit.text = prev.depositAmount.toStringAsFixed(0);
      _depositTerms.text = prev.depositTerms ?? '';
      _payment.text = prev.paymentTerms;
      _conditions.text = prev.conditions;
    } else {
      for (final i in q.items) {
        final l = mine.where((x) => x.id == i.listingId).firstOrNull;
        final perDay = l?.priceUnit == PriceUnit.perItemPerDay;
        _lines.add(_Line(listingId: i.listingId, description: i.description, quantity: i.quantity, unitPrice: l?.priceAmount ?? 0, days: perDay ? q.days : 1, categoryId: l?.categoryId));
        if (l?.depositAmount != null && _deposit.text.isEmpty) _deposit.text = l!.depositAmount!.toStringAsFixed(0);
        if (l != null && l.terms.isNotEmpty && _conditions.text.isEmpty) _conditions.text = l.terms;
      }
      if (q.fulfilment != Fulfilment.pickup) {
        _charges.add((TextEditingController(text: q.fulfilment == Fulfilment.supplierSetsUp ? 'Delivery & setup' : 'Delivery'), TextEditingController(text: '')));
      }
    }
    // Your own free stock for the requested dates (authoritative backend check).
    for (final line in _lines.where((l) => l.listingId != null)) {
      final l = mine.where((x) => x.id == line.listingId).firstOrNull;
      line.categoryId ??= l?.categoryId;
      if (l != null && l.tracksStock && !l.isService) {
        line.available = await b.listings.availableQuantity(line.listingId!, q.neededFrom, q.neededTo);
      }
    }
    if (mounted) setState(() {});
  }

  double get _chargesTotal => _charges.fold(0, (s, c) => s + (double.tryParse(c.$2.text) ?? 0));
  double get _total => _lines.fold(0.0, (s, l) => s + l.total) + _chargesTotal;

  Future<void> _send(QuoteRequest q) async {
    if (_lines.isEmpty || _lines.any((l) => l.quantity <= 0)) {
      showToast(context, 'Every line needs a quantity.', icon: LucideIcons.circleAlert);
      return;
    }
    setState(() => _busy = true);
    final id = await guard(
      context,
      () => ref.read(backendProvider).bookings.sendQuotation(QuotationDraft(
            requestId: q.id,
            items: [for (final l in _lines) QuotationItem(listingId: l.listingId, description: l.description, quantity: l.quantity, unitPrice: l.unitPrice, days: l.days)],
            charges: [
              for (final c in _charges)
                if (c.$1.text.trim().isNotEmpty && (double.tryParse(c.$2.text) ?? 0) > 0) Charge(c.$1.text.trim(), double.parse(c.$2.text)),
            ],
            depositAmount: double.tryParse(_deposit.text) ?? 0,
            depositTerms: _depositTerms.text.trim().isEmpty ? null : _depositTerms.text.trim(),
            paymentTerms: _payment.text.trim(),
            validUntil: _valid,
            conditions: _conditions.text.trim(),
          )),
      success: q.quotations.isEmpty ? 'Quotation sent to ${q.requester.name}' : 'Revised quotation sent',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (id != null) context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(requestProvider(widget.requestId));
    return Scaffold(
      appBar: AppBar(title: Text(data.value?.quotations.isNotEmpty == true ? 'Revise quotation' : 'New quotation')),
      body: AsyncView(
        value: data,
        onRetry: () => ref.invalidate(requestProvider(widget.requestId)),
        data: (q) {
          _seed(q);
          if (!_seeded || (_lines.isEmpty && q.items.isNotEmpty)) return const Skeleton();
          return ListView(padding: const EdgeInsets.fromLTRB(EvSpace.gutter, 0, EvSpace.gutter, 160), children: [
            Text('For ${q.requester.name} · ${EvDates.range(q.neededFrom, q.neededTo)}', style: EvType.small),
            const SizedBox(height: EvSpace.x4),
            Text('LINE ITEMS', style: EvType.overline),
            const SizedBox(height: EvSpace.x2),
            for (final (i, line) in _lines.indexed) ...[
              _LineEditor(
                line: line,
                onChanged: () => setState(() {}),
                onRemove: _lines.length > 1 ? () => setState(() => _lines.removeAt(i)) : null,
                onSource: line.available != null && line.available! < line.quantity
                    ? () => context.push('/now/new?item=${Uri.encodeComponent(line.description)}&qty=${line.quantity - line.available!}'
                        '&date=${EvDates.iso(q.neededFrom)}${line.categoryId != null ? '&category=${line.categoryId}' : ''}')
                    : null,
              ),
              const SizedBox(height: 10),
            ],
            const SizedBox(height: EvSpace.x3),
            Row(children: [
              Text('EXTRA CHARGES', style: EvType.overline),
              const Spacer(),
              TextButton.icon(
                onPressed: () => setState(() => _charges.add((TextEditingController(), TextEditingController()))),
                icon: const Icon(LucideIcons.plus, size: 16),
                label: const Text('Add'),
              ),
            ]),
            for (final (i, c) in _charges.indexed)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(children: [
                  Expanded(flex: 3, child: TextField(controller: c.$1, decoration: const InputDecoration(hintText: 'e.g. Delivery'), onChanged: (_) => setState(() {}))),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 2,
                    child: TextField(
                      controller: c.$2,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                      decoration: const InputDecoration(prefixText: 'K '),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  IconButton(icon: const Icon(LucideIcons.x, size: 18), onPressed: () => setState(() => _charges.removeAt(i))),
                ]),
              ),
            const SizedBox(height: EvSpace.x4),
            Row(children: [
              Expanded(
                child: EvField(
                  label: 'Deposit',
                  controller: _deposit,
                  prefixText: 'K ',
                  optional: true,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: EvPickerField(
                  label: 'Valid until',
                  value: EvDates.day(_valid),
                  icon: LucideIcons.calendarClock,
                  onTap: () async {
                    final d = await pickDate(context, initial: _valid, last: q.neededFrom.isAfter(EvDates.today()) ? q.neededFrom : null);
                    if (d != null) setState(() => _valid = d);
                  },
                ),
              ),
            ]),
            const SizedBox(height: EvSpace.x4),
            EvField(label: 'Deposit terms', controller: _depositTerms, hint: 'e.g. Mobile money to 097…, refundable after inspection', optional: true),
            const SizedBox(height: EvSpace.x4),
            EvField(label: 'Payment terms', controller: _payment, maxLines: 2),
            const SizedBox(height: EvSpace.x4),
            EvField(label: 'Conditions', controller: _conditions, hint: 'Breakages, return times, overtime…', maxLines: 4, minLines: 2, optional: true),
          ]);
        },
      ),
      bottomSheet: data.hasValue
          ? Container(
              decoration: BoxDecoration(color: EvColors.warmWhite, border: Border(top: BorderSide(color: EvColors.sand))),
              padding: EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x3, EvSpace.gutter, EvSpace.x3 + MediaQuery.paddingOf(context).bottom),
              child: Row(children: [
                Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text('Total', style: EvType.caption),
                  EvAnimatedCount(value: _total.round(), format: (n) => Money.k(n), style: EvType.title.copyWith(color: EvColors.forest)),
                ]),
                const SizedBox(width: EvSpace.x4),
                Expanded(child: EvButton('Send quotation', icon: LucideIcons.send, loading: _busy, expand: true, onPressed: () => _send(data.value!))),
              ]),
            )
          : null,
    );
  }
}

class _LineEditor extends StatelessWidget {
  const _LineEditor({required this.line, required this.onChanged, this.onRemove, this.onSource});
  final _Line line;
  final VoidCallback onChanged;
  final VoidCallback? onRemove;
  final VoidCallback? onSource;

  @override
  Widget build(BuildContext context) {
    final short = line.available != null && line.available! < line.quantity;
    return EvSurface(
      padding: const EdgeInsets.all(EvSpace.x3),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: TextFormField(
              initialValue: line.description,
              style: EvType.bodyStrong,
              decoration: const InputDecoration(isDense: true, border: InputBorder.none, enabledBorder: InputBorder.none, focusedBorder: InputBorder.none, filled: false, contentPadding: EdgeInsets.zero),
              onChanged: (v) {
                line.description = v;
                onChanged();
              },
            ),
          ),
          if (onRemove != null) IconButton(icon: Icon(LucideIcons.x, size: 18, color: EvColors.ink3), onPressed: onRemove, visualDensity: VisualDensity.compact),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: _num('Qty', '${line.quantity}', (v) => line.quantity = int.tryParse(v) ?? 0)),
          const SizedBox(width: 8),
          Expanded(child: _num('Unit (K)', line.unitPrice.toStringAsFixed(line.unitPrice % 1 == 0 ? 0 : 2), (v) => line.unitPrice = double.tryParse(v) ?? 0, decimal: true)),
          const SizedBox(width: 8),
          Expanded(child: _num('Days', '${line.days}', (v) => line.days = (int.tryParse(v) ?? 1).clamp(1, 60))),
          const SizedBox(width: 12),
          SizedBox(width: 82, child: Text(Money.k(line.total), style: EvType.money, textAlign: TextAlign.right)),
        ]),
        if (line.available != null) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: short ? EvColors.warningTint : EvColors.successTint, borderRadius: EvRadius.smAll),
            child: Row(children: [
              Icon(short ? LucideIcons.triangleAlert : LucideIcons.circleCheck, size: 16, color: short ? EvColors.warning : EvColors.success),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  short
                      ? 'You have ${line.available} free on these dates — ${line.quantity - line.available!} short.'
                      : 'You have ${line.available} free on these dates.',
                  style: EvType.small.copyWith(color: short ? EvColors.warning : EvColors.success, fontWeight: FontWeight.w600),
                ),
              ),
              if (onSource != null)
                TextButton(onPressed: onSource, style: TextButton.styleFrom(visualDensity: VisualDensity.compact), child: const Text('Source the rest')),
            ]),
          ),
        ],
      ]),
    );
  }

  Widget _num(String label, String initial, void Function(String) set, {bool decimal = false}) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: EvType.caption),
        const SizedBox(height: 4),
        TextFormField(
          initialValue: initial,
          keyboardType: TextInputType.numberWithOptions(decimal: decimal),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(decimal ? r'[0-9.]' : r'[0-9]'))],
          style: EvType.money,
          decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10)),
          onChanged: (v) {
            set(v);
            onChanged();
          },
        ),
      ]);
}
