import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../app/providers.dart';
import '../../design/ev.dart';
import '../../domain/models.dart';

/// One form for rental, service and package listings. Fields adapt to the
/// kind: services describe capacity and portfolio, never stock counts.
/// Editing a quantity here is recorded as a stock correction; it never
/// reserves or releases anything.
class ListingEditorScreen extends ConsumerStatefulWidget {
  const ListingEditorScreen({super.key, this.id, this.kind});
  final String? id;
  final String? kind;

  @override
  ConsumerState<ListingEditorScreen> createState() => _ListingEditorScreenState();
}

class _ListingEditorScreenState extends ConsumerState<ListingEditorScreen> {
  final _form = GlobalKey<FormState>();
  ListingDraft? _d;
  Listing? _original;
  bool _busy = false;
  bool _uploading = false;
  final _title = TextEditingController();
  final _desc = TextEditingController();
  final _price = TextEditingController();
  final _deposit = TextEditingController();
  final _terms = TextEditingController();
  final _pkg = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final biz = ref.read(myBusinessProvider).value!;
    if (widget.id == null) {
      final kind = OfferingType.parse(widget.kind ?? (biz.rents ? 'rental' : 'service'));
      setState(() => _d = ListingDraft(
            businessId: biz.id,
            kind: kind,
            tracksStock: kind == OfferingType.rental,
            totalQuantity: kind == OfferingType.rental ? 0 : 1,
            priceUnit: kind == OfferingType.rental ? PriceUnit.perItemPerDay : (kind == OfferingType.package ? PriceUnit.perPackage : PriceUnit.perEvent),
            categoryId: biz.primaryCategory != null && categoryById(biz.primaryCategory).kind == (kind == OfferingType.package ? OfferingType.service : kind) ? biz.primaryCategory : null,
          ));
      return;
    }
    final l = await ref.read(backendProvider).listings.get(widget.id!);
    _title.text = l.title;
    _desc.text = l.description;
    _price.text = l.priceAmount?.toStringAsFixed(l.priceAmount! % 1 == 0 ? 0 : 2) ?? '';
    _deposit.text = l.depositAmount?.toStringAsFixed(0) ?? '';
    _terms.text = l.terms;
    _pkg.text = l.packageItems.join('\n');
    setState(() {
      _original = l;
      _d = ListingDraft.from(l);
    });
  }

  bool get _isService => _d!.kind != OfferingType.rental;

  Future<void> _addPhotos() async {
    final backend = ref.read(backendProvider);
    final files = await ImagePicker().pickMultiImage(maxWidth: 1600, imageQuality: 82, limit: 8);
    if (files.isEmpty || !mounted) return;
    setState(() => _uploading = true);
    final list = <(Uint8List, String)>[];
    for (final f in files) {
      list.add((await f.readAsBytes(), f.name.split('.').last.toLowerCase()));
    }
    if (!mounted) return;
    final urls = await guard(context, () => backend.listings.uploadPhotos(_d!.businessId, list));
    if (mounted) {
      setState(() {
      _uploading = false;
      if (urls != null) _d!.photos = [..._d!.photos, ...urls];
    });
    }
  }

  Future<void> _save(ListingStatus status) async {
    if (status == ListingStatus.published && !_form.currentState!.validate()) return;
    final d = _d!
      ..title = _title.text
      ..description = _desc.text
      ..priceAmount = double.tryParse(_price.text)
      ..depositAmount = double.tryParse(_deposit.text)
      ..terms = _terms.text
      ..packageItems = _pkg.text.split('\n').map((s) => s.trim()).where((s) => s.isNotEmpty).toList()
      ..status = status;
    if (d.categoryId == null) {
      showToast(context, 'Choose a category.', icon: LucideIcons.circleAlert);
      return;
    }
    if (d.title.trim().length < 2) {
      showToast(context, 'Give the listing a name.', icon: LucideIcons.circleAlert);
      return;
    }
    if (_original != null && _original!.tracksStock && d.totalQuantity != _original!.totalQuantity) {
      final delta = d.totalQuantity - _original!.totalQuantity;
      final ok = await confirmAction(context,
          title: delta > 0 ? 'Add $delta to stock?' : 'Remove ${-delta} from stock?',
          body: 'This is recorded in your stock history as a correction. It doesn’t reserve or release any bookings.',
          confirm: 'Update stock');
      if (!ok) return;
    }
    if (!mounted) return;
    setState(() => _busy = true);
    final api = ref.read(backendProvider).listings;
    final id = await guard(context, () async {
      if (widget.id == null) return api.create(d);
      await api.update(widget.id!, d, basedOn: _original);
      return widget.id!;
    }, success: status == ListingStatus.published
        ? (_original?.status == ListingStatus.published ? 'Listing updated' : 'Published — vendors following this category will be told')
        : 'Saved as ${status.label.toLowerCase()}');
    if (!mounted) return;
    setState(() => _busy = false);
    if (id != null) context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    if (d == null) return Scaffold(appBar: AppBar(), body: const Skeleton(rows: 6));
    final cats = kCategories.where((c) => d.kind == OfferingType.rental ? c.kind == OfferingType.rental : true).toList();
    final unitOptions = d.kind == OfferingType.rental
        ? const [PriceUnit.perItemPerDay, PriceUnit.perItemPerEvent, PriceUnit.perEvent, PriceUnit.onQuote]
        : const [PriceUnit.perEvent, PriceUnit.perHour, PriceUnit.perItemPerEvent, PriceUnit.perPackage, PriceUnit.onQuote];
    const gap = SizedBox(height: EvSpace.x5);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.id == null ? 'New ${d.kind == OfferingType.rental ? 'rental' : d.kind.name} listing' : 'Edit listing'),
        actions: [
          if (_original != null) Padding(padding: const EdgeInsets.only(right: 12), child: StatusPill(_original!.status.label, tone: toneForListing(_original!.status), dense: true)),
        ],
      ),
      body: Form(
        key: _form,
        child: ListView(padding: const EdgeInsets.fromLTRB(EvSpace.gutter, 0, EvSpace.gutter, 140), children: [
          if (_original?.moderation != null && _original!.moderation != ModerationStatus.ok)
            Padding(
              padding: const EdgeInsets.only(bottom: EvSpace.x4),
              child: EvSurface(
                color: EvColors.dangerTint,
                child: Text('This listing was ${_original!.moderation.name} by Evenda moderation: ${_original!.moderationReason ?? ''}',
                    style: EvType.small.copyWith(color: EvColors.danger)),
              ),
            ),
          // Photos
          Text(_isService ? 'PORTFOLIO' : 'PHOTOS', style: EvType.overline),
          const SizedBox(height: EvSpace.x2),
          SizedBox(
            height: 96,
            child: ReorderableListView(
              scrollDirection: Axis.horizontal,
              buildDefaultDragHandles: false,
              onReorderItem: (a, b) => setState(() {
                final p = [...d.photos];
                p.insert(b, p.removeAt(a));
                d.photos = p;
              }),
              footer: Padding(
                padding: const EdgeInsets.only(left: 8),
                child: InkWell(
                  onTap: _uploading ? null : _addPhotos,
                  borderRadius: EvRadius.mdAll,
                  child: Container(
                    width: 96,
                    height: 96,
                    decoration: BoxDecoration(color: EvColors.warmWhite, borderRadius: EvRadius.mdAll, border: Border.all(color: EvColors.sandDeep)),
                    child: _uploading
                        ? const Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))
                        : Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                            const Icon(LucideIcons.imagePlus, color: EvColors.forest),
                            const SizedBox(height: 4),
                            Text('Add', style: EvType.caption.copyWith(color: EvColors.forest)),
                          ]),
                  ),
                ),
              ),
              children: [
                for (final (i, p) in d.photos.indexed)
                  ReorderableDelayedDragStartListener(
                    key: ValueKey('$p$i'),
                    index: i,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Stack(children: [
                        EvPhoto(p, width: 96, height: 96),
                        if (i == 0)
                          Positioned(
                            left: 6,
                            bottom: 6,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(color: EvColors.ink.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(4)),
                              child: Text('Cover', style: EvType.caption.copyWith(color: EvColors.inkOnDark, fontSize: 10)),
                            ),
                          ),
                        Positioned(
                          right: 2,
                          top: 2,
                          child: InkWell(
                            onTap: () => setState(() => d.photos = [...d.photos]..removeAt(i)),
                            child: Container(
                              padding: const EdgeInsets.all(3),
                              decoration: const BoxDecoration(color: EvColors.warmWhite, shape: BoxShape.circle),
                              child: const Icon(LucideIcons.x, size: 13),
                            ),
                          ),
                        ),
                      ]),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text('Real photos of your own stock get far more requests. Long-press to reorder.', style: EvType.caption),
          gap,
          EvField(
            label: _isService ? 'Service name' : 'Item name',
            controller: _title,
            hint: _isService ? 'e.g. Full wedding styling' : 'e.g. Gold Chiavari chairs',
            textCapitalization: TextCapitalization.words,
            validator: (v) => (v == null || v.trim().length < 2) ? 'Required' : null,
          ),
          gap,
          EvPickerField(
            label: 'Category',
            value: d.categoryId == null ? null : categoryById(d.categoryId).name,
            onTap: () async {
              final c = await pickFromSheet<String>(context, title: 'Category', selected: d.categoryId, icon: categoryIcon, options: [for (final c in cats) (c.id, c.name, null)]);
              if (c != null) setState(() => d.categoryId = c);
            },
          ),
          gap,
          EvField(label: 'Description', controller: _desc, maxLines: 5, minLines: 3, maxLength: 2000, optional: true,
              hint: _isService ? 'What’s included, team size, the events you do best' : 'Material, colour, dimensions, what’s included'),
          if (d.kind == OfferingType.package) ...[
            gap,
            EvField(label: 'Included in the package', controller: _pkg, maxLines: 6, minLines: 3, hint: 'One item per line, e.g.\n100 Chiavari chairs\n10 round tables with linen'),
          ],

          // Pricing
          const SectionHeader('Pricing', padding: EdgeInsets.fromLTRB(0, EvSpace.x6, 0, EvSpace.x2)),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final u in unitOptions) EvChip(label: u.label, selected: d.priceUnit == u, onTap: () => setState(() => d.priceUnit = u)),
          ]),
          if (d.priceUnit != PriceUnit.onQuote) ...[
            const SizedBox(height: EvSpace.x4),
            EvField(
              label: 'Price (ZMW)',
              controller: _price,
              prefixText: 'K ',
              suffixText: d.priceUnit.short,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
              validator: (v) => d.priceUnit != PriceUnit.onQuote && double.tryParse(v ?? '') == null ? 'Enter a price, or choose price on quotation' : null,
            ),
          ],
          const SizedBox(height: EvSpace.x4),
          EvField(label: 'Deposit', controller: _deposit, prefixText: 'K ', optional: true, keyboardType: TextInputType.number, inputFormatters: [FilteringTextInputFormatter.digitsOnly]),

          // Quantity / capacity
          SectionHeader(_isService ? 'Capacity' : 'Stock', padding: const EdgeInsets.fromLTRB(0, EvSpace.x6, 0, EvSpace.x2)),
          if (!_isService) ...[
            EvQuantityStepper(
              value: d.totalQuantity,
              min: _original == null ? 0 : _original!.damagedQuantity + _original!.inspectionQuantity,
              step: d.totalQuantity >= 50 ? 10 : 1,
              label: 'Total you own',
              helper: _original == null
                  ? 'Availability for any date is this total minus damaged items and what’s already booked.'
                  : 'Changing this records a stock correction. Use Inventory for damage and returns.',
              onChanged: (v) => setState(() => d.totalQuantity = v),
            ),
            const SizedBox(height: EvSpace.x4),
            const EvFieldLabel('Condition', optional: true),
            Wrap(spacing: 8, children: [
              for (final c in const ['new', 'excellent', 'good', 'fair'])
                EvChip(label: '${c[0].toUpperCase()}${c.substring(1)}', selected: d.condition == c, onTap: () => setState(() => d.condition = d.condition == c ? null : c)),
            ]),
          ] else ...[
            EvSwitchRow(
              title: 'Limit jobs per day',
              subtitle: 'Prevents double-booking your team on the same date',
              value: d.tracksStock,
              onChanged: (v) => setState(() {
                d.tracksStock = v;
                if (v && d.totalQuantity < 1) d.totalQuantity = 1;
              }),
            ),
            if (d.tracksStock) EvQuantityStepper(value: d.totalQuantity, min: 1, max: 20, label: 'Jobs you can take on one day', onChanged: (v) => setState(() => d.totalQuantity = v)),
          ],

          const SectionHeader('Terms', padding: EdgeInsets.fromLTRB(0, EvSpace.x6, 0, EvSpace.x2)),
          EvField(label: 'Hire / service terms', controller: _terms, maxLines: 5, minLines: 3, optional: true,
              hint: 'Collection and return times, breakages, cancellation, deposits'),
        ]),
      ),
      bottomSheet: Container(
        decoration: const BoxDecoration(color: EvColors.warmWhite, border: Border(top: BorderSide(color: EvColors.sand))),
        padding: EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x3, EvSpace.gutter, EvSpace.x3 + MediaQuery.paddingOf(context).bottom),
        child: Row(children: [
          if (_original == null || _original!.status != ListingStatus.published) ...[
            Expanded(child: EvButton('Save draft', kind: EvButtonKind.secondary, onPressed: _busy ? null : () => _save(ListingStatus.draft))),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: EvButton(_original?.status == ListingStatus.published ? 'Save changes' : 'Publish', expand: true, loading: _busy, icon: LucideIcons.send,
                onPressed: () => _save(ListingStatus.published)),
          ),
        ]),
      ),
    );
  }
}
