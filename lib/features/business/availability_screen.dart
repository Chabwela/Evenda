import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../app/providers.dart';
import '../../core/format.dart';
import '../../data/backend.dart';
import '../../design/ev.dart';
import '../../domain/models.dart';
import 'listings_screen.dart';

final _calendarProvider = FutureProvider.autoDispose.family<List<AvailabilityDay>, (String, DateTime)>((ref, key) async {
  ref.watchDomains(const [DataDomain.listings, DataDomain.bookings]);
  final (id, month) = key;
  final from = DateTime(month.year, month.month, 1);
  final to = DateTime(month.year, month.month + 1, 0);
  return ref.watch(backendProvider).listings.calendar(id, from, to);
});

final _blocksProvider = FutureProvider.autoDispose<(List<AvailabilityBlock>, List<Reservation>)>((ref) async {
  ref.watchDomains(const [DataDomain.listings]);
  final id = ref.watch(bizIdProvider);
  final l = ref.watch(backendProvider).listings;
  final r = await Future.wait([l.blocks(id), l.reservations(id)]);
  return (r[0] as List<AvailabilityBlock>, r[1] as List<Reservation>);
});

/// Date-aware availability per listing, closed dates, and jobs booked
/// outside Evenda (so the calendar stays truthful).
class AvailabilityScreen extends ConsumerStatefulWidget {
  const AvailabilityScreen({super.key, this.listingId});
  final String? listingId;
  @override
  ConsumerState<AvailabilityScreen> createState() => _AvailabilityScreenState();
}

class _AvailabilityScreenState extends ConsumerState<AvailabilityScreen> {
  String? _listingId;
  DateTime _month = DateTime(EvDates.today().year, EvDates.today().month);
  DateTime? _selected;

  Future<void> _recordJob(List<Listing> listings, Listing current) async {
    var listing = current;
    var qty = listing.isService ? 1 : 10;
    var from = _selected ?? EvDates.today();
    var to = from;
    final client = TextEditingController();
    final note = TextEditingController();
    final ok = await showEvSheet<bool>(
      context,
      title: 'Record a job',
      subtitle: 'For bookings you took by phone or in person. The quantity is held so nobody can book it twice.',
      builder: (c) => StatefulBuilder(
        builder: (c, set) => ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(EvSpace.gutter, 0, EvSpace.gutter, EvSpace.x6), children: [
          EvPickerField(label: 'Item', value: listing.title, onTap: () async {
            final id = await pickFromSheet<String>(c, title: 'Item', selected: listing.id, options: [for (final l in listings) (l.id, l.title, null)]);
            if (id != null) set(() => listing = listings.firstWhere((l) => l.id == id));
          }),
          const SizedBox(height: EvSpace.x4),
          EvPickerField(label: 'Dates', value: EvDates.range(from, to), icon: LucideIcons.calendarDays, onTap: () async {
            final r = await showDateRangePicker(context: c, firstDate: EvDates.today(), lastDate: EvDates.today().add(const Duration(days: 365)),
                initialDateRange: DateTimeRange(start: from, end: to));
            if (r != null) {
              set(() {
              from = r.start;
              to = r.end;
            });
            }
          }),
          const SizedBox(height: EvSpace.x4),
          EvQuantityStepper(label: listing.isService ? 'Jobs' : 'Quantity', value: qty, min: 1, step: qty >= 20 ? 10 : 1, onChanged: (v) => set(() => qty = v)),
          const SizedBox(height: EvSpace.x4),
          EvField(label: 'Client or event', controller: client, hint: 'e.g. Chanda family funeral', textCapitalization: TextCapitalization.words),
          const SizedBox(height: EvSpace.x4),
          EvField(label: 'Note', controller: note, optional: true),
          const SizedBox(height: EvSpace.x5),
          EvButton('Hold stock', expand: true, onPressed: () => Navigator.pop(c, client.text.trim().isNotEmpty)),
        ]),
      ),
    );
    if (ok != true || !mounted) return;
    await guard(context, () => ref.read(backendProvider).listings.recordManualReservation(listing.id, qty, from, to, client.text.trim(), note: note.text.trim().isEmpty ? null : note.text.trim()),
        success: 'Held $qty × ${listing.title} for ${EvDates.range(from, to)}');
  }

  Future<void> _closeDates(Listing? listing) async {
    final r = await showDateRangePicker(context: context, firstDate: EvDates.today(), lastDate: EvDates.today().add(const Duration(days: 365)), helpText: 'Dates you can’t take bookings');
    if (r == null || !mounted) return;
    final scope = await pickFromSheet<String>(context, title: 'Close for', options: [
      ('all', 'All listings', 'e.g. public holiday, family event'),
      if (listing != null) (listing.id, 'Only ${listing.title}', null),
    ]);
    if (scope == null || !mounted) return;
    await guard(context, () => ref.read(backendProvider).listings.addBlock(ref.read(bizIdProvider), r.start, r.end, listingId: scope == 'all' ? null : scope),
        success: 'Closed ${EvDates.range(r.start, r.end)}');
  }

  @override
  Widget build(BuildContext context) {
    final listingsAsync = ref.watch(myListingsProvider);
    final extra = ref.watch(_blocksProvider).value;
    return Scaffold(
      appBar: AppBar(title: const Text('Availability & jobs')),
      body: AsyncView(
        value: listingsAsync,
        onRetry: () => ref.invalidate(myListingsProvider),
        isEmpty: (l) => !l.any((x) => x.tracksStock && x.status != ListingStatus.archived),
        empty: EmptyState(mascot: Mascot.calendar, title: 'Nothing to schedule yet', body: 'Availability is tracked for listings with stock or a daily job limit.',
            action: 'New listing', onAction: () => context.push('/business/listings/new')),
        data: (all) {
          final listings = all.where((x) => x.tracksStock && x.status != ListingStatus.archived).toList();
          final current = listings.firstWhere((l) => l.id == (_listingId ?? widget.listingId), orElse: () => listings.first);
          final days = ref.watch(_calendarProvider((current.id, _month)));
          final blocks = extra?.$1 ?? const <AvailabilityBlock>[];
          final reservations = (extra?.$2 ?? const <Reservation>[]).where((r) => r.listingId == current.id).toList();
          final sel = _selected;

          return ListView(padding: const EdgeInsets.only(bottom: 120), children: [
            SizedBox(
              height: 40,
              child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: EvSpace.gutter), children: [
                for (final l in listings)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: EvChip(label: l.title, selected: l.id == current.id, onTap: () => setState(() {
                      _listingId = l.id;
                      _selected = null;
                    })),
                  ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x3, EvSpace.x2, 0),
              child: Row(children: [
                Text(EvDates.monthYear(_month), style: EvType.headline),
                const Spacer(),
                EvIconButton(LucideIcons.chevronLeft, tooltip: 'Previous', onPressed: _month.isAfter(DateTime(EvDates.today().year, EvDates.today().month))
                    ? () => setState(() => _month = DateTime(_month.year, _month.month - 1))
                    : null),
                EvIconButton(LucideIcons.chevronRight, tooltip: 'Next', onPressed: () => setState(() => _month = DateTime(_month.year, _month.month + 1))),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: EvSpace.x3),
              child: days.when(
                skipLoadingOnReload: true,
                loading: () => const SizedBox(height: 300, child: Center(child: CircularProgressIndicator(strokeWidth: 2))),
                error: (e, _) => ErrorState(error: e, compact: true, onRetry: () => ref.invalidate(_calendarProvider((current.id, _month)))),
                data: (list) => _Heatmap(
                  month: _month,
                  days: list,
                  selected: sel,
                  service: current.isService,
                  onTap: (d) => setState(() => _selected = d),
                ),
              ),
            ),
            if (sel != null) ...[
              SectionHeader(EvDates.dayLong(sel)),
              Builder(builder: (_) {
                final info = days.value?.where((d) => EvDates.sameDay(d.day, sel)).firstOrNull;
                final rs = reservations.where((r) => r.covers(sel)).toList();
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: EvSpace.gutter),
                  child: EvSurface(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      if (info != null)
                        Row(children: [
                          Text(info.blocked ? 'Closed' : '${info.available} free', style: EvType.title.copyWith(color: info.blocked ? EvColors.ink3 : EvColors.forest)),
                          const SizedBox(width: 8),
                          Text('of ${info.usable} usable · ${info.reserved} held', style: EvType.small),
                        ]),
                      if (rs.isEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text('Nothing booked.', style: EvType.small)),
                      for (final r in rs)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Row(children: [
                            IconTile(r.source == ReservationSource.manual ? LucideIcons.notebookPen : (r.source == ReservationSource.now ? LucideIcons.zap : LucideIcons.handshake), size: 30),
                            const SizedBox(width: 10),
                            Expanded(child: Text('${r.quantity} · ${r.clientLabel ?? 'Booking'}', style: EvType.body)),
                            if (r.source == ReservationSource.manual && r.status != ReservationStatus.dispatched)
                              TextButton(
                                onPressed: () async {
                                  if (await confirmAction(context, title: 'Release this hold?', body: '${r.quantity} will be available again.', confirm: 'Release', destructive: true) && context.mounted) {
                                    await guard(context, () => ref.read(backendProvider).listings.moveReservation(r.id, 'cancel'), success: 'Released');
                                  }
                                },
                                child: const Text('Release'),
                              ),
                          ]),
                        ),
                    ]),
                  ),
                );
              }),
            ],
            SectionHeader('Closed dates', count: blocks.length, action: 'Close dates', onAction: () => _closeDates(current)),
            if (blocks.isEmpty) Padding(padding: const EdgeInsets.symmetric(horizontal: EvSpace.gutter), child: Text('You’re open on all dates.', style: EvType.small)),
            for (final b in blocks)
              EvRow(
                dense: true,
                leading: const IconTile(LucideIcons.ban, size: 32),
                title: EvDates.range(b.startsOn, b.endsOn),
                subtitle: b.listingId == null ? 'All listings' : (all.where((l) => l.id == b.listingId).firstOrNull?.title ?? 'One listing'),
                trailing: TextButton(
                  onPressed: () => guard(context, () => ref.read(backendProvider).listings.removeBlock(b.id), success: 'Dates reopened — subscribers will be told'),
                  child: const Text('Reopen'),
                ),
              ),
          ]);
        },
      ),
      bottomSheet: listingsAsync.hasValue && listingsAsync.value!.any((x) => x.tracksStock)
          ? Container(
              color: EvColors.warmWhite,
              padding: EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x3, EvSpace.gutter, EvSpace.x3 + MediaQuery.paddingOf(context).bottom),
              child: EvButton('Record a job taken outside Evenda', icon: LucideIcons.notebookPen, expand: true, onPressed: () {
                final listings = listingsAsync.value!.where((x) => x.tracksStock && x.status != ListingStatus.archived).toList();
                final current = listings.firstWhere((l) => l.id == (_listingId ?? widget.listingId), orElse: () => listings.first);
                _recordJob(listings, current);
              }),
            )
          : null,
    );
  }
}

class _Heatmap extends StatelessWidget {
  const _Heatmap({required this.month, required this.days, required this.onTap, required this.service, this.selected});
  final DateTime month;
  final List<AvailabilityDay> days;
  final DateTime? selected;
  final bool service;
  final ValueChanged<DateTime> onTap;

  @override
  Widget build(BuildContext context) {
    final first = DateTime(month.year, month.month, 1);
    final lead = first.weekday - 1;
    final byDay = {for (final d in days) d.day.day: d};
    final count = DateTime(month.year, month.month + 1, 0).day;
    final today = EvDates.today();
    return Column(children: [
      Row(children: [
        for (final d in const ['M', 'T', 'W', 'T', 'F', 'S', 'S'])
          Expanded(child: Center(child: Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Text(d, style: EvType.caption)))),
      ]),
      GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 7, mainAxisExtent: 54),
        itemCount: lead + count,
        itemBuilder: (c, i) {
          if (i < lead) return const SizedBox.shrink();
          final dayNum = i - lead + 1;
          final date = DateTime(month.year, month.month, dayNum);
          final info = byDay[dayNum];
          final past = date.isBefore(today);
          final frac = info == null || info.usable == 0 ? 0.0 : info.available / info.usable;
          final bg = info == null || past
              ? Colors.transparent
              : info.blocked
                  ? EvColors.neutralTint
                  : frac == 0
                      ? EvColors.dangerTint
                      : frac < 0.34
                          ? EvColors.warningTint
                          : Color.lerp(EvColors.forestWash, EvColors.forestTint, 1 - frac)!;
          final isSel = selected != null && EvDates.sameDay(selected!, date);
          return GestureDetector(
            onTap: past ? null : () => onTap(date),
            child: AnimatedContainer(
              duration: EvMotion.of(context, EvMotion.fast),
              margin: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: EvRadius.smAll,
                border: Border.all(color: isSel ? EvColors.forest : (EvDates.sameDay(date, today) ? EvColors.bronze : Colors.transparent), width: isSel ? 2 : 1.2),
              ),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Text('$dayNum', style: EvType.caption.copyWith(color: past ? EvColors.ink3.withValues(alpha: 0.5) : EvColors.ink2)),
                if (info != null && !past)
                  Text(
                    info.blocked ? '—' : (service ? (info.available > 0 ? '${info.available}' : 'Full') : '${info.available}'),
                    style: EvType.smallStrong.copyWith(
                      color: info.blocked ? EvColors.ink3 : (frac == 0 ? EvColors.danger : EvColors.forest),
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
              ]),
            ),
          );
        },
      ),
      const SizedBox(height: 6),
      Text('Numbers show how many are free each day. Tap a day for details.', style: EvType.caption),
    ]);
  }
}
