import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../app/providers.dart';
import '../../app/shell.dart';
import '../../core/format.dart';
import '../../data/backend.dart';
import '../../design/ev.dart';
import '../../domain/models.dart';

final bookingsOverviewProvider = FutureProvider.autoDispose<(List<QuoteRequest>, List<Booking>)>((ref) async {
  ref.watchDomains(const [DataDomain.bookings]);
  final id = ref.watch(bizIdProvider);
  final b = ref.watch(backendProvider).bookings;
  final r = await Future.wait([b.requests(id), b.bookings(id)]);
  return (r[0] as List<QuoteRequest>, r[1] as List<Booking>);
});

enum _Tab { incoming, sent, quotes, confirmed, past }

class BookingsScreen extends ConsumerStatefulWidget {
  const BookingsScreen({super.key, this.initialTab});
  final String? initialTab;

  @override
  ConsumerState<BookingsScreen> createState() => _BookingsScreenState();
}

class _BookingsScreenState extends ConsumerState<BookingsScreen> {
  late _Tab _tab = _Tab.values.where((t) => t.name == widget.initialTab).firstOrNull ?? _Tab.incoming;

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(bookingsOverviewProvider);
    final me = ref.watch(bizIdProvider);
    final (reqs, bookings) = data.value ?? (const <QuoteRequest>[], const <Booking>[]);

    final incoming = reqs.where((q) => q.supplier.id == me && q.status == QuoteRequestStatus.open).toList();
    final sent = reqs.where((q) => q.requester.id == me && q.status == QuoteRequestStatus.open).toList();
    final quotes = reqs.where((q) => q.status == QuoteRequestStatus.quoted).toList();
    final confirmed = bookings.where((b) => b.status.isActive).toList()..sort((a, b) => a.startsOn.compareTo(b.startsOn));
    final past = [
      ...bookings.where((b) => !b.status.isActive),
    ]..sort((a, b) => b.startsOn.compareTo(a.startsOn));
    final closedRequests = reqs.where((q) => q.status == QuoteRequestStatus.declined || q.status == QuoteRequestStatus.cancelled || q.status == QuoteRequestStatus.expired).toList();

    return Scaffold(
      appBar: TabHeader(
        title: 'Bookings',
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(50),
          child: Padding(
            padding: const EdgeInsets.only(bottom: EvSpace.x2),
            child: EvSegmented<_Tab>(
              value: _tab,
              onChanged: (t) => setState(() => _tab = t),
              counts: {_Tab.incoming: incoming.length, _Tab.quotes: quotes.length},
              segments: const [
                (_Tab.incoming, 'Incoming'),
                (_Tab.sent, 'Sent'),
                (_Tab.quotes, 'Quotations'),
                (_Tab.confirmed, 'Confirmed'),
                (_Tab.past, 'Past'),
              ],
            ),
          ),
        ),
      ),
      body: RefreshIndicator(
        color: EvColors.forest,
        onRefresh: () => ref.refresh(bookingsOverviewProvider.future),
        child: AsyncView(
          value: data,
          onRetry: () => ref.invalidate(bookingsOverviewProvider),
          data: (_) => AnimatedSwitcher(
            duration: EvMotion.of(context, EvMotion.fast),
            child: KeyedSubtree(
              key: ValueKey(_tab),
              child: switch (_tab) {
                _Tab.incoming => _RequestList(
                    items: incoming,
                    me: me,
                    empty: const EmptyState(
                      mascot: Mascot.crate,
                      title: 'No requests waiting',
                      body: 'When another vendor asks you for a quotation it appears here. Published listings are how they find you.',
                    ),
                  ),
                _Tab.sent => _RequestList(
                    items: sent,
                    me: me,
                    empty: EmptyState(
                      mascot: Mascot.crate,
                      title: 'No open requests',
                      body: 'Ask a supplier for a quotation when you need extra stock or a service.',
                      action: 'Find suppliers',
                      onAction: () => context.go('/find'),
                    ),
                  ),
                _Tab.quotes => _RequestList(
                    items: quotes,
                    me: me,
                    empty: const EmptyState(mascot: Mascot.crate, title: 'No open quotations', body: 'Quotations you send or receive appear here until they are accepted or closed.'),
                  ),
                _Tab.confirmed => _BookingList(
                    items: confirmed,
                    me: me,
                    empty: const EmptyState(mascot: Mascot.calendar, title: 'No confirmed bookings', body: 'Accepted quotations and Evenda Now selections become bookings here.'),
                  ),
                _Tab.past => _PastList(bookings: past, requests: closedRequests, me: me),
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _RequestList extends StatelessWidget {
  const _RequestList({required this.items, required this.me, required this.empty});
  final List<QuoteRequest> items;
  final String me;
  final Widget empty;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return ListView(children: [empty]);
    return ListView.separated(
      padding: const EdgeInsets.only(top: EvSpace.x2, bottom: EvSpace.x10),
      itemCount: items.length,
      separatorBuilder: (_, _) => const EvDivider(indent: 72),
      itemBuilder: (c, i) => RequestRow(request: items[i], me: me),
    );
  }
}

class RequestRow extends StatelessWidget {
  const RequestRow({super.key, required this.request, required this.me});
  final QuoteRequest request;
  final String me;

  @override
  Widget build(BuildContext context) {
    final q = request;
    final incoming = q.supplier.id == me;
    final other = incoming ? q.requester : q.supplier;
    final quote = q.openQuotation ?? q.latestQuotation;
    final waitingOnMe = (incoming && q.status == QuoteRequestStatus.open) || (!incoming && q.openQuotation != null);
    return EvRow(
      leading: BusinessAvatar(name: other.name, logoUrl: other.logoUrl, verified: other.verified),
      title: other.name,
      subtitle: q.items.map((i) => '${i.quantity} × ${i.description}').join(', '),
      // Wraps instead of overflowing: next to the status pill there is
      // little room for direction, dates and "Your move" on one line.
      meta: Wrap(spacing: 8, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(incoming ? LucideIcons.arrowDownLeft : LucideIcons.arrowUpRight, size: 13, color: EvColors.ink3),
          const SizedBox(width: 4),
          // Flexible: at large text sizes the line shortens instead of overflowing.
          Flexible(child: Text('${incoming ? 'To you' : 'You asked'} · ${EvDates.range(q.neededFrom, q.neededTo)}', style: EvType.caption, maxLines: 1, overflow: TextOverflow.ellipsis)),
        ]),
        if (waitingOnMe) Text('Your move', style: EvType.caption.copyWith(color: EvColors.bronzeDeep, fontWeight: FontWeight.w700)),
      ]),
      trailing: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
        StatusPill(q.status.label, tone: toneForRequest(q.status), dense: true),
        if (quote != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(Money.k(quote.total), style: EvType.money.copyWith(fontSize: 13))),
      ]),
      onTap: () => context.push('/bookings/request/${q.id}'),
    );
  }
}

class _BookingList extends StatelessWidget {
  const _BookingList({required this.items, required this.me, required this.empty});
  final List<Booking> items;
  final String me;
  final Widget empty;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return ListView(children: [empty]);
    final today = EvDates.today();
    final weekEnd = today.add(const Duration(days: 7));
    final groups = <String, List<Booking>>{};
    for (final b in items) {
      final k = b.endsOn.isBefore(today) ? 'Awaiting completion' : (b.startsOn.isBefore(weekEnd) ? 'Next 7 days' : 'Later');
      groups.putIfAbsent(k, () => []).add(b);
    }
    return ListView(padding: const EdgeInsets.only(bottom: EvSpace.x10), children: [
      for (final e in groups.entries) ...[
        SectionHeader(e.key, count: e.value.length),
        for (final (i, b) in e.value.indexed) ...[
          if (i > 0) const EvDivider(indent: 84),
          BookingRow(booking: b, me: me),
        ],
      ],
    ]);
  }
}

class BookingRow extends StatelessWidget {
  const BookingRow({super.key, required this.booking, required this.me});
  final Booking booking;
  final String me;

  @override
  Widget build(BuildContext context) {
    final b = booking;
    final supplier = b.isSupplier(me);
    return InkWell(
      onTap: () => context.push('/bookings/${b.id}'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: EvSpace.gutter, vertical: 12),
        child: Row(children: [
          SizedBox(
            width: 52,
            child: Column(children: [
              Text(EvDates.day(b.startsOn).split(' ').first.toUpperCase(), style: EvType.overline),
              Text('${b.startsOn.day}', style: EvType.number),
              Text(EvDates.dayShort(b.startsOn).split(' ').last, style: EvType.caption),
            ]),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(child: Text(b.counterparty(me).name, style: EvType.bodyStrong, overflow: TextOverflow.ellipsis)),
                const SizedBox(width: 6),
                if (b.source == BookingSource.now) const Icon(LucideIcons.zap, size: 13, color: EvColors.bronze),
              ]),
              Text(b.items.map((i) => '${i.quantity} × ${i.description}').join(', '), style: EvType.small, maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 4, children: [
                StatusPill(b.status.label, tone: toneForBooking(b.status), dense: true),
                StatusPill(b.paymentStatus.label, tone: toneForPayment(b.paymentStatus), dense: true, icon: LucideIcons.wallet),
              ]),
            ]),
          ),
          const SizedBox(width: 8),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(Money.k(b.total), style: EvType.money),
            Text(supplier ? 'You supply' : 'You hired', style: EvType.caption),
          ]),
        ]),
      ),
    );
  }
}

class _PastList extends StatelessWidget {
  const _PastList({required this.bookings, required this.requests, required this.me});
  final List<Booking> bookings;
  final List<QuoteRequest> requests;
  final String me;

  @override
  Widget build(BuildContext context) {
    if (bookings.isEmpty && requests.isEmpty) {
      return ListView(children: const [EmptyState(mascot: Mascot.calendar, title: 'Nothing here yet', body: 'Completed and cancelled work is kept here for your records.')]);
    }
    return ListView(padding: const EdgeInsets.only(bottom: EvSpace.x10), children: [
      if (bookings.isNotEmpty) ...[
        SectionHeader('Completed & cancelled bookings', count: bookings.length),
        for (final (i, b) in bookings.indexed) ...[if (i > 0) const EvDivider(indent: 84), BookingRow(booking: b, me: me)],
      ],
      if (requests.isNotEmpty) ...[
        SectionHeader('Closed requests', count: requests.length),
        for (final (i, q) in requests.indexed) ...[if (i > 0) const EvDivider(indent: 72), RequestRow(request: q, me: me)],
      ],
    ]);
  }
}
