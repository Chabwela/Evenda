import 'dart:async';

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
import '../shared/feed_cards.dart';

/// Exploratory supplier discovery. (Evenda Now is the time-critical path.)
class FindScreen extends ConsumerStatefulWidget {
  const FindScreen({super.key, this.initialCategory});
  final String? initialCategory;

  @override
  ConsumerState<FindScreen> createState() => _FindScreenState();
}

class _FindScreenState extends ConsumerState<FindScreen> {
  final _text = TextEditingController();
  late SearchQuery _q = SearchQuery(categoryId: widget.initialCategory);
  AsyncValue<List<SearchResult>> _results = const AsyncValue.data([]);
  bool _searching = false;
  Timer? _debounce;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    if (!_q.isEmpty) WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _text.dispose();
    super.dispose();
  }

  void _set(SearchQuery q, {bool debounce = false}) {
    setState(() => _q = q);
    _debounce?.cancel();
    if (debounce) {
      _debounce = Timer(const Duration(milliseconds: 350), _run);
    } else {
      _run();
    }
  }

  Future<void> _run() async {
    if (_q.isEmpty) {
      setState(() => _results = const AsyncValue.data([]));
      return;
    }
    final seq = ++_seq;
    // Previous results stay visible while the new search runs.
    setState(() => _searching = true);
    try {
      final biz = ref.read(bizIdProvider);
      final r = await ref.read(backendProvider).discovery.search(biz, _q);
      if (mounted && seq == _seq) setState(() => _results = AsyncValue.data(r));
    } catch (e, st) {
      if (mounted && seq == _seq) setState(() => _results = AsyncValue.error(e, st));
    } finally {
      if (mounted && seq == _seq) setState(() => _searching = false);
    }
  }

  Future<void> _pickDates() async {
    final range = await showDateRangePicker(
      context: context,
      firstDate: EvDates.today(),
      lastDate: EvDates.today().add(const Duration(days: 365)),
      initialDateRange: _q.from == null ? null : DateTimeRange(start: _q.from!, end: _q.to ?? _q.from!),
      helpText: 'When do you need it?',
    );
    if (range != null) _set(_q.copyWith(from: () => range.start, to: () => range.end));
  }

  Future<void> _pickQuantity() async {
    var v = _q.quantity ?? 50;
    final r = await showEvSheet<int>(
      context,
      title: 'How many do you need?',
      builder: (c) => StatefulBuilder(
        builder: (c, set) => Padding(
          padding: const EdgeInsets.fromLTRB(EvSpace.gutter, 0, EvSpace.gutter, EvSpace.x6),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            EvQuantityStepper(value: v, min: 1, step: 10, onChanged: (x) => set(() => v = x)),
            const SizedBox(height: EvSpace.x5),
            Row(children: [
              Expanded(child: EvButton('Clear', kind: EvButtonKind.quiet, onPressed: () => Navigator.pop(c, -1))),
              const SizedBox(width: 12),
              Expanded(child: EvButton('Apply', onPressed: () => Navigator.pop(c, v))),
            ]),
          ]),
        ),
      ),
    );
    if (r != null) _set(_q.copyWith(quantity: () => r < 0 ? null : r));
  }

  Future<void> _pickArea() async {
    final r = await pickFromSheet<String?>(context, title: 'Near', selected: _q.neighbourhood, options: [
      (null, 'Anywhere in Lusaka', 'Sorted by distance from your business'),
      for (final n in kNeighbourhoods) (n.name, n.name, null),
    ]);
    if (!mounted) return;
    _set(_q.copyWith(neighbourhood: () => r));
  }

  Future<void> _pickPrice() async {
    final r = await pickFromSheet<double?>(context, title: 'Maximum price', selected: _q.maxPrice, options: const [
      (null, 'Any price', null),
      (15.0, 'Up to K15', 'Per item'),
      (50.0, 'Up to K50', null),
      (500.0, 'Up to K500', null),
      (3000.0, 'Up to K3,000', null),
      (10000.0, 'Up to K10,000', null),
    ]);
    if (!mounted) return;
    _set(_q.copyWith(maxPrice: () => r));
  }

  Future<void> _pickCategory() async {
    final r = await pickFromSheet<String?>(context, title: 'Category', selected: _q.categoryId, icon: (id) => id == null ? LucideIcons.layoutGrid : categoryIcon(id), options: [
      (null, 'All categories', null),
      for (final c in kCategories) (c.id, c.name, c.kind == OfferingType.service ? 'Service' : 'Rental'),
    ]);
    if (!mounted) return;
    _set(_q.copyWith(categoryId: () => r));
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(revisionProvider.select((m) => m[DataDomain.discovery]), (_, _) => _run());
    final cat = _q.categoryId == null ? null : categoryById(_q.categoryId);

    return Scaffold(
      appBar: TabHeader(
        title: 'Find suppliers',
        actions: [
          TextButton.icon(
            onPressed: () => context.push('/now'),
            icon: const Icon(LucideIcons.zap, size: 16, color: EvColors.bronze),
            label: Text('Urgent', style: EvType.smallStrong.copyWith(color: EvColors.bronzeDeep)),
          ),
        ],
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x1, EvSpace.gutter, EvSpace.x3),
          child: TextField(
            controller: _text,
            textInputAction: TextInputAction.search,
            onChanged: (v) => _set(_q.copyWith(text: v), debounce: true),
            onSubmitted: (v) => _set(_q.copyWith(text: v)),
            decoration: InputDecoration(
              hintText: 'Chairs, marquees, PA systems, suppliers…',
              prefixIcon: const Icon(LucideIcons.search, size: 18, color: EvColors.ink3),
              suffixIcon: _text.text.isEmpty
                  ? null
                  : IconButton(icon: const Icon(LucideIcons.x, size: 18), onPressed: () {
                      _text.clear();
                      _set(_q.copyWith(text: ''));
                    }),
            ),
          ),
        ),
        SizedBox(
          height: 38,
          child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: EvSpace.gutter), children: [
            EvChip(label: cat?.name ?? 'Category', icon: cat == null ? LucideIcons.layoutGrid : categoryIcon(cat.id), trailing: LucideIcons.chevronDown, selected: cat != null, onTap: _pickCategory),
            const SizedBox(width: 6),
            EvChip(
              label: _q.from == null ? 'Dates' : EvDates.range(_q.from!, _q.to ?? _q.from!),
              icon: LucideIcons.calendarDays,
              selected: _q.from != null,
              onTap: _pickDates,
            ),
            const SizedBox(width: 6),
            EvChip(label: _q.quantity == null ? 'Quantity' : '${_q.quantity}+', icon: LucideIcons.hash, selected: _q.quantity != null, onTap: _pickQuantity),
            const SizedBox(width: 6),
            EvChip(label: _q.neighbourhood ?? 'Area', icon: LucideIcons.mapPin, selected: _q.neighbourhood != null, onTap: _pickArea),
            const SizedBox(width: 6),
            EvChip(label: _q.maxPrice == null ? 'Price' : '≤ ${Money.k(_q.maxPrice)}', icon: LucideIcons.banknote, selected: _q.maxPrice != null, onTap: _pickPrice),
            const SizedBox(width: 6),
            EvChip(label: 'Saved', icon: LucideIcons.bookmark, selected: _q.savedOnly, onTap: () => _set(_q.copyWith(savedOnly: !_q.savedOnly))),
          ]),
        ),
        if (_q.from != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x2, EvSpace.gutter, 0),
            child: Row(children: [
              const Icon(LucideIcons.info, size: 13, color: EvColors.ink3),
              const SizedBox(width: 6),
              Expanded(child: Text('Free quantities are live from each supplier’s calendar. Stock is held only when a quotation is accepted.', style: EvType.caption)),
            ]),
          ),
        const SizedBox(height: EvSpace.x2),
        if (_searching) const LinearProgressIndicator(minHeight: 2) else const SizedBox(height: 2),
        Expanded(child: _q.isEmpty ? _Browse(onCategory: (id) => _set(_q.copyWith(categoryId: () => id))) : _resultsList()),
      ]),
    );
  }

  Widget _resultsList() {
    return AsyncView(
      value: _results,
      onRetry: _run,
      isEmpty: (r) => r.isEmpty,
      empty: EmptyState(
        mascot: Mascot.crate,
        title: 'No matches yet',
        body: _q.from != null
            ? 'Nobody has that free for those dates. Try other dates, a smaller quantity, or ask nearby suppliers with Evenda Now.'
            : 'Try a broader search or another category.',
        action: _q.from != null ? 'Ask with Evenda Now' : null,
        onAction: () => context.push(
            '/now/new?${_q.categoryId != null ? 'category=${_q.categoryId}&' : ''}${_q.quantity != null ? 'qty=${_q.quantity}&' : ''}${_q.from != null ? 'date=${EvDates.iso(_q.from!)}' : ''}'),
      ),
      data: (r) => ListView.separated(
        padding: const EdgeInsets.only(bottom: EvSpace.x10),
        itemCount: r.length + 1,
        separatorBuilder: (_, i) => i == 0 ? const SizedBox.shrink() : const EvDivider(indent: 144),
        itemBuilder: (c, i) {
          if (i == 0) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x2, EvSpace.gutter, 0),
              child: Text('${plural(r.length, 'result')}${_q.neighbourhood != null ? ' near ${_q.neighbourhood}' : ''}', style: EvType.caption),
            );
          }
          final res = r[i - 1];
          return ListingResultCard(
            result: res,
            onTap: () {
              HapticFeedback.selectionClick();
              final params = [
                if (_q.from != null) 'from=${EvDates.iso(_q.from!)}',
                if (_q.to != null) 'to=${EvDates.iso(_q.to!)}',
                if (_q.quantity != null) 'qty=${_q.quantity}',
              ].join('&');
              context.push('/listing/${res.listing.id}${params.isEmpty ? '' : '?$params'}');
            },
          );
        },
      ),
    );
  }
}

class _Browse extends ConsumerWidget {
  const _Browse({required this.onCategory});
  final ValueChanged<String> onCategory;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rentals = kCategories.where((c) => c.kind == OfferingType.rental).toList();
    final services = kCategories.where((c) => c.kind == OfferingType.service).toList();
    Widget grid(List<Category> cats) => GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: EvSpace.gutter),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 200, mainAxisExtent: 56, crossAxisSpacing: 8, mainAxisSpacing: 8),
          itemCount: cats.length,
          itemBuilder: (c, i) => EvSurface(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            onTap: () => onCategory(cats[i].id),
            child: Row(children: [
              Icon(categoryIcon(cats[i].id), size: 18, color: EvColors.forest),
              const SizedBox(width: 10),
              Expanded(child: Text(cats[i].name, style: EvType.smallStrong, maxLines: 2, overflow: TextOverflow.ellipsis)),
            ]),
          ),
        );
    return ListView(padding: const EdgeInsets.only(bottom: EvSpace.x10), children: [
      const SectionHeader('Equipment & rentals', padding: EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x3, EvSpace.gutter, EvSpace.x2)),
      grid(rentals),
      const SectionHeader('Services'),
      grid(services),
      const SizedBox(height: EvSpace.x5),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: EvSpace.gutter),
        child: EvSurface(
          color: EvColors.forestWash,
          onTap: () => context.push('/now'),
          child: Row(children: [
            const MascotImage(Mascot.pin, size: 56),
            const SizedBox(width: EvSpace.x3),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Need it today or tomorrow?', style: EvType.bodyStrong),
                Text('Evenda Now asks nearby suppliers with free stock to reply with offers.', style: EvType.small),
              ]),
            ),
          ]),
        ),
      ),
    ]);
  }
}
