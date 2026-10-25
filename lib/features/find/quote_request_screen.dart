import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:uuid/uuid.dart';

import '../../app/providers.dart';
import '../../core/format.dart';
import '../../design/ev.dart';
import '../../domain/models.dart';
import '../shared/feed_cards.dart';

final _supplierListingsProvider = FutureProvider.autoDispose.family<(Business, List<Listing>, List<EventPlan>), String>((ref, supplierId) async {
  final b = ref.watch(backendProvider);
  final r = await Future.wait([
    b.discovery.supplier(supplierId),
    b.discovery.supplierListings(supplierId),
    b.work.events(ref.watch(bizIdProvider)),
  ]);
  return (r[0] as Business, r[1] as List<Listing>, (r[2] as List<EventPlan>).where((e) => e.endsAt.isAfter(DateTime.now())).toList());
});

class _Line {
  _Line({this.listing, required this.description, required this.quantity});
  final Listing? listing;
  String description;
  int quantity;
}

/// Ask another vendor for a quotation. One idempotency key per form, so a
/// double tap or a retry after a timeout never creates two requests.
class QuoteRequestScreen extends ConsumerStatefulWidget {
  const QuoteRequestScreen({super.key, required this.supplierId, this.listingId, this.from, this.quantity});
  final String supplierId;
  final String? listingId;
  final String? from;
  final int? quantity;

  @override
  ConsumerState<QuoteRequestScreen> createState() => _QuoteRequestScreenState();
}

class _QuoteRequestScreenState extends ConsumerState<QuoteRequestScreen> {
  final _key = const Uuid().v4();
  final _lines = <_Line>[];
  late DateTime _from = widget.from != null ? DateTime.parse(widget.from!) : EvDates.today().add(const Duration(days: 7));
  late DateTime _to = _from;
  Fulfilment _fulfilment = Fulfilment.pickup;
  final _venue = TextEditingController();
  final _message = TextEditingController();
  String? _eventId;
  bool _busy = false;
  bool _seeded = false;

  void _seed(List<Listing> listings) {
    if (_seeded) return;
    _seeded = true;
    final l = listings.where((x) => x.id == widget.listingId).firstOrNull;
    if (l != null) _lines.add(_Line(listing: l, description: l.title, quantity: widget.quantity ?? 1));
  }

  Future<void> _addLine(List<Listing> listings) async {
    final available = listings.where((l) => !_lines.any((x) => x.listing?.id == l.id)).toList();
    final pick = await pickFromSheet<String>(context, title: 'Add an item', options: [
      for (final l in available) (l.id, l.title, priceLabel(l)),
      ('__custom', 'Something else', 'Describe it in your own words'),
    ]);
    if (pick == null || !mounted) return;
    if (pick == '__custom') {
      final c = TextEditingController();
      final text = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Describe the item'),
          content: TextField(controller: c, autofocus: true, decoration: const InputDecoration(hintText: 'e.g. Gold charger plates')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Add')),
          ],
        ),
      );
      if (text != null && text.isNotEmpty) setState(() => _lines.add(_Line(description: text, quantity: 1)));
    } else {
      final l = listings.firstWhere((x) => x.id == pick);
      setState(() => _lines.add(_Line(listing: l, description: l.title, quantity: l.isService ? 1 : 10)));
    }
  }

  Future<void> _submit(Business supplier) async {
    if (_lines.isEmpty) {
      showToast(context, 'Add at least one item.', icon: LucideIcons.circleAlert);
      return;
    }
    setState(() => _busy = true);
    final id = await guard(
      context,
      () => ref.read(backendProvider).bookings.createRequest(QuoteRequestDraft(
            requesterId: ref.read(bizIdProvider),
            supplierId: supplier.id,
            neededFrom: _from,
            neededTo: _to,
            items: [for (final l in _lines) QuoteRequestItem(listingId: l.listing?.id, description: l.description, quantity: l.quantity)],
            idempotencyKey: _key,
            eventId: _eventId,
            fulfilment: _fulfilment,
            venue: _venue.text.trim().isEmpty ? null : _venue.text.trim(),
            message: _message.text.trim(),
          )),
      success: 'Request sent to ${supplier.name}',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (id != null) context.pushReplacement('/bookings/request/$id');
  }

  /// What the listed prices come to for these quantities and dates, and
  /// whether some lines have no usable price (custom items, hourly, on quote).
  (double, bool) _estimate() {
    final days = _to.difference(_from).inDays + 1;
    var total = 0.0;
    var partial = false;
    for (final l in _lines) {
      final x = l.listing;
      final price = x?.priceAmount;
      if (x == null || price == null) {
        partial = true;
        continue;
      }
      switch (x.priceUnit) {
        case PriceUnit.perItemPerDay:
          total += price * l.quantity * days;
        case PriceUnit.perItemPerEvent || PriceUnit.perEvent || PriceUnit.perPackage:
          total += price * l.quantity;
        case PriceUnit.perHour || PriceUnit.onQuote:
          partial = true;
      }
    }
    return (total, partial);
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(_supplierListingsProvider(widget.supplierId));
    const section = EdgeInsets.fromLTRB(0, EvSpace.x6, 0, EvSpace.x2);
    // Add the item they came from before working out the estimate.
    if (data.value case final r?) _seed(r.$2);
    final (estimate, partial) = _estimate();

    return Scaffold(
      appBar: AppBar(title: const Text('Request a quotation')),
      body: AsyncView(
        value: data,
        onRetry: () => ref.invalidate(_supplierListingsProvider(widget.supplierId)),
        data: (r) {
          final (supplier, listings, events) = r;
          _seed(listings);
          return ListView(padding: const EdgeInsets.fromLTRB(EvSpace.gutter, 0, EvSpace.gutter, 160), children: [
            // Who you're asking.
            Row(children: [
              BusinessAvatar(name: supplier.name, logoUrl: supplier.logoUrl, verified: supplier.verified, size: 44),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(supplier.name, style: EvType.bodyStrong, maxLines: 2, overflow: TextOverflow.ellipsis),
                  Text('They reply with a quotation you can accept, query or decline.', style: EvType.small),
                ]),
              ),
            ]),

            // What you need: one row per item, name on its own line.
            SectionHeader('Items', count: _lines.isEmpty ? null : _lines.length, padding: section),
            if (_lines.isNotEmpty)
              EvSurface(
                padding: EdgeInsets.zero,
                child: Column(children: [
                  for (final (i, line) in _lines.indexed) ...[
                    if (i > 0) const EvDivider(indent: EvSpace.x4),
                    _ItemRow(
                      line: line,
                      onQuantity: (v) => setState(() => line.quantity = v),
                      onRemove: () => setState(() => _lines.removeAt(i)),
                    ),
                  ],
                ]),
              )
            else
              Text('Add what you need from ${supplier.name}.', style: EvType.small),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(onPressed: () => _addLine(listings), icon: const Icon(LucideIcons.plus, size: 18), label: const Text('Add item')),
            ),

            // When and where.
            const SectionHeader('When and where', padding: section),
            EvPickerField(
              label: 'Dates needed',
              value: EvDates.range(_from, _to),
              icon: LucideIcons.calendarDays,
              onTap: () async {
                final r = await showDateRangePicker(
                  context: context,
                  firstDate: EvDates.today(),
                  lastDate: EvDates.today().add(const Duration(days: 365)),
                  initialDateRange: DateTimeRange(start: _from, end: _to),
                );
                if (r != null) {
                  setState(() {
                    _from = r.start;
                    _to = r.end;
                  });
                }
              },
            ),
            const SizedBox(height: EvSpace.x4),
            const EvFieldLabel('Delivery'),
            EvSurface(
              padding: EdgeInsets.zero,
              child: Column(children: [
                for (final (i, f) in Fulfilment.values.indexed) ...[
                  if (i > 0) const EvDivider(indent: EvSpace.x4),
                  _ChoiceRow(
                    title: switch (f) {
                      Fulfilment.pickup => 'I’ll collect',
                      Fulfilment.supplierDelivers => 'They deliver',
                      Fulfilment.supplierSetsUp => 'They deliver and set up',
                    },
                    selected: _fulfilment == f,
                    onTap: () => setState(() => _fulfilment = f),
                  ),
                ],
              ]),
            ),
            if (_fulfilment != Fulfilment.pickup) ...[
              const SizedBox(height: EvSpace.x4),
              EvField(label: 'Venue or delivery address', controller: _venue, hint: 'e.g. Garden venue, Leopards Hill Road'),
            ],

            // Anything else.
            const SectionHeader('Anything else', padding: section),
            if (events.isNotEmpty) ...[
              EvPickerField(
                label: 'For which event?',
                optional: true,
                value: events.where((e) => e.id == _eventId).firstOrNull?.name,
                placeholder: 'Not linked',
                onTap: () async {
                  final id = await pickFromSheet<String?>(context, title: 'Link to an event', selected: _eventId, options: [
                    (null, 'Not linked', null),
                    for (final e in events) (e.id, e.name, EvDates.day(e.startsAt)),
                  ]);
                  if (mounted) setState(() => _eventId = id);
                },
              ),
              const SizedBox(height: EvSpace.x4),
            ],
            EvField(label: 'Message', controller: _message, hint: 'Colours, setup times, anything they should know', maxLines: 4, minLines: 3, optional: true),
          ]);
        },
      ),
      bottomSheet: data.hasValue
          ? Container(
              decoration: BoxDecoration(color: EvColors.cream, border: Border(top: BorderSide(color: EvColors.hairline))),
              padding: EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x3, EvSpace.gutter, EvSpace.x3 + MediaQuery.paddingOf(context).bottom),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                // A rough idea of cost; the quotation sets the real price.
                if (estimate > 0)
                  Padding(
                    padding: const EdgeInsets.only(bottom: EvSpace.x2),
                    child: Row(children: [
                      Expanded(
                        child: Text(partial ? 'Listed prices, some items on quotation' : 'At listed prices', style: EvType.small),
                      ),
                      Text('about ${Money.k(estimate)}', style: EvType.bodyStrong),
                    ]),
                  ),
                EvButton('Send request', expand: true, loading: _busy, icon: LucideIcons.send, onPressed: () => _submit(data.value!.$1)),
              ]),
            )
          : null,
    );
  }
}

/// One item: photo and name on the first line, price and quantity below,
/// so long names and prices never squeeze into a column.
class _ItemRow extends StatelessWidget {
  const _ItemRow({required this.line, required this.onQuantity, required this.onRemove});
  final _Line line;
  final ValueChanged<int> onQuantity;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final l = line.listing;
    return Padding(
      padding: const EdgeInsets.fromLTRB(EvSpace.x4, EvSpace.x3, EvSpace.x2, EvSpace.x3),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          if (l != null) ...[EvPhoto(l.coverPhoto, width: 44, height: 44, radius: EvRadius.sm), const SizedBox(width: 12)],
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(line.description, style: EvType.bodyStrong, maxLines: 2, overflow: TextOverflow.ellipsis),
              Text(l == null ? 'Your own description' : priceLabel(l), style: EvType.caption),
            ]),
          ),
          IconButton(tooltip: 'Remove', icon: Icon(LucideIcons.x, size: 18, color: EvColors.ink3), onPressed: onRemove),
        ]),
        const SizedBox(height: EvSpace.x2),
        Row(children: [
          Text('Quantity', style: EvType.small),
          const Spacer(),
          SizedBox(
            width: 150,
            child: EvQuantityStepper(value: line.quantity, min: 1, step: line.quantity >= 20 ? 10 : 1, onChanged: onQuantity),
          ),
          const SizedBox(width: EvSpace.x2),
        ]),
      ]),
    );
  }
}

/// A plain radio row inside a grouped list.
class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({required this.title, required this.selected, required this.onTap});
  final String title;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: EvSpace.x4, vertical: 14),
          child: Row(children: [
            Expanded(child: Text(title, style: EvType.body)),
            Icon(selected ? LucideIcons.circleCheck : LucideIcons.circle, size: 22, color: selected ? EvColors.forest : EvColors.sandDeep),
          ]),
        ),
      );
}
