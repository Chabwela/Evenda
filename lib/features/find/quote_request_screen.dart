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

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(_supplierListingsProvider(widget.supplierId));
    return Scaffold(
      appBar: AppBar(title: const Text('Request a quotation')),
      body: AsyncView(
        value: data,
        onRetry: () => ref.invalidate(_supplierListingsProvider(widget.supplierId)),
        data: (r) {
          final (supplier, listings, events) = r;
          _seed(listings);
          return ListView(padding: const EdgeInsets.fromLTRB(EvSpace.gutter, 0, EvSpace.gutter, 140), children: [
            Row(children: [
              BusinessAvatar(name: supplier.name, logoUrl: supplier.logoUrl, verified: supplier.verified),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(supplier.name, style: EvType.bodyStrong),
                  Text('Replies with a quotation you can accept, query or decline', style: EvType.small),
                ]),
              ),
            ]),
            const SizedBox(height: EvSpace.x6),
            Text('ITEMS', style: EvType.overline),
            const SizedBox(height: EvSpace.x2),
            for (final (i, line) in _lines.indexed)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: EvSurface(
                  padding: const EdgeInsets.all(EvSpace.x3),
                  child: Row(children: [
                    if (line.listing != null) ...[EvPhoto(line.listing!.coverPhoto, width: 52, height: 52, radius: EvRadius.sm), const SizedBox(width: 12)],
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(line.description, style: EvType.bodyStrong, maxLines: 2, overflow: TextOverflow.ellipsis),
                        if (line.listing != null) Text(priceLabel(line.listing!), style: EvType.caption),
                      ]),
                    ),
                    SizedBox(
                      width: 150,
                      child: EvQuantityStepper(value: line.quantity, min: 1, step: line.quantity >= 20 ? 10 : 1, onChanged: (v) => setState(() => line.quantity = v)),
                    ),
                    IconButton(icon: const Icon(LucideIcons.x, size: 18, color: EvColors.ink3), onPressed: () => setState(() => _lines.removeAt(i))),
                  ]),
                ),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(onPressed: () => _addLine(listings), icon: const Icon(LucideIcons.plus, size: 18), label: const Text('Add item')),
            ),
            const SizedBox(height: EvSpace.x4),
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
            const SizedBox(height: EvSpace.x5),
            const EvFieldLabel('Delivery arrangement'),
            for (final f in Fulfilment.values) ...[
              EvOptionTile(title: f.label, selected: _fulfilment == f, onTap: () => setState(() => _fulfilment = f)),
              const SizedBox(height: 6),
            ],
            Text('Evenda records what you agree; it doesn’t arrange transport.', style: EvType.caption),
            const SizedBox(height: EvSpace.x5),
            EvField(label: 'Venue or delivery address', controller: _venue, hint: 'e.g. Garden venue, Leopards Hill Road', optional: _fulfilment == Fulfilment.pickup),
            const SizedBox(height: EvSpace.x5),
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
              const SizedBox(height: EvSpace.x5),
            ],
            EvField(label: 'Message', controller: _message, hint: 'Colours, setup times, anything the supplier should know', maxLines: 4, minLines: 3, optional: true),
          ]);
        },
      ),
      bottomSheet: data.hasValue
          ? Container(
              color: EvColors.warmWhite,
              padding: EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x3, EvSpace.gutter, EvSpace.x3 + MediaQuery.paddingOf(context).bottom),
              child: EvButton('Send request', expand: true, loading: _busy, icon: LucideIcons.send, onPressed: () => _submit(data.value!.$1)),
            )
          : null,
    );
  }
}
