import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/providers.dart';
import '../../core/format.dart';
import '../../data/backend.dart';
import '../../design/ev.dart';
import '../../domain/models.dart';

final listingProvider = FutureProvider.autoDispose.family<Listing, String>((ref, id) async {
  ref.watchDomains(const [DataDomain.listings, DataDomain.discovery]);
  return ref.watch(backendProvider).listings.get(id);
});

final followsProvider = FutureProvider.autoDispose<List<SupplierFollow>>((ref) async {
  ref.watchDomains(const [DataDomain.discovery]);
  return ref.watch(backendProvider).discovery.follows(ref.watch(bizIdProvider));
});

class ListingDetailScreen extends ConsumerWidget {
  const ListingDetailScreen({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final listing = ref.watch(listingProvider(id));
    final q = GoRouterState.of(context).uri.queryParameters;
    return Scaffold(
      body: AsyncView(
        value: listing,
        onRetry: () => ref.invalidate(listingProvider(id)),
        loading: const SafeArea(child: Skeleton(rows: 5, media: true)),
        data: (l) => _Body(
          listing: l,
          from: q['from'] == null ? null : DateTime.parse(q['from']!),
          to: q['to'] == null ? null : DateTime.parse(q['to']!),
          qty: int.tryParse(q['qty'] ?? ''),
        ),
      ),
    );
  }
}

class _Body extends ConsumerStatefulWidget {
  const _Body({required this.listing, this.from, this.to, this.qty});
  final Listing listing;
  final DateTime? from;
  final DateTime? to;
  final int? qty;

  @override
  ConsumerState<_Body> createState() => _BodyState();
}

class _BodyState extends ConsumerState<_Body> {
  final _page = PageController();
  final _scroll = ScrollController();
  int _photo = 0;
  bool _collapsed = false; // photo scrolled away: title in the bar, dark status icons
  late DateTime? _from = widget.from;
  late DateTime? _to = widget.to;
  late final int _qty = widget.qty ?? (widget.listing.tracksStock && !widget.listing.isService ? 50 : 1);
  int? _available;
  bool _checking = false;

  @override
  void dispose() {
    _page.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _openViewer(List<String?> photos, int index) {
    if (photos.every((p) => p == null)) return;
    Navigator.of(context).push(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _PhotoViewer(photos: photos, initial: index, title: widget.listing.title, heroPrefix: 'listing-photo-${widget.listing.id}'),
    ));
  }

  @override
  void initState() {
    super.initState();
    if (_from != null) WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  Future<void> _check() async {
    if (_from == null) return;
    setState(() => _checking = true);
    final a = await guard(context, () => ref.read(backendProvider).listings.availableQuantity(widget.listing.id, _from!, _to ?? _from!));
    if (mounted) {
      setState(() {
      _available = a;
      _checking = false;
    });
    }
  }

  Future<void> _pickDates() async {
    final r = await showDateRangePicker(
      context: context,
      firstDate: EvDates.today(),
      lastDate: EvDates.today().add(const Duration(days: 365)),
      initialDateRange: _from == null ? null : DateTimeRange(start: _from!, end: _to ?? _from!),
    );
    if (r == null) return;
    setState(() {
      _from = r.start;
      _to = r.end;
      _available = null;
    });
    _check();
  }

  @override
  Widget build(BuildContext context) {
    final l = widget.listing;
    final biz = l.business!;
    final myId = ref.watch(bizIdProvider);
    final mine = l.businessId == myId;
    final follows = ref.watch(followsProvider).value ?? const [];
    final following = follows.any((f) => f.supplier.id == biz.id);
    final photos = l.photos.isEmpty ? <String?>[null] : l.photos;
    final width = MediaQuery.sizeOf(context).width;
    final expanded = (width * 0.78).clamp(240.0, 420.0);
    final collapseAt = expanded - kToolbarHeight - MediaQuery.paddingOf(context).top;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      // Light status icons over the photo, dark once the bar turns cream.
      value: _collapsed ? EvTheme.statusBar : SystemUiOverlayStyle.light,
      child: Stack(children: [
      NotificationListener<ScrollNotification>(
        onNotification: (n) {
          final c = n.metrics.axis == Axis.vertical && n.metrics.pixels > collapseAt;
          if (c != _collapsed) setState(() => _collapsed = c);
          return false;
        },
        child: CustomScrollView(controller: _scroll, slivers: [
        SliverAppBar(
          expandedHeight: expanded,
          pinned: true,
          backgroundColor: EvColors.cream,
          surfaceTintColor: Colors.transparent,
          // The bar sets the status-bar style itself: light over the photo.
          systemOverlayStyle: _collapsed ? EvTheme.statusBar : SystemUiOverlayStyle.light,
          // The listing's name appears in the bar once the photo has scrolled away.
          title: AnimatedOpacity(
            opacity: _collapsed ? 1 : 0,
            duration: EvMotion.of(context, EvMotion.fast),
            child: Text(l.title, style: EvType.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          leading: Padding(
            padding: const EdgeInsets.all(6),
            child: _collapsed
                ? IconButton(icon: Icon(LucideIcons.arrowLeft, color: EvColors.ink), onPressed: () => context.pop())
                : CircleAvatar(
                    backgroundColor: EvColors.warmWhite.withValues(alpha: 0.92),
                    child: IconButton(icon: Icon(LucideIcons.arrowLeft, size: 20, color: EvColors.ink), onPressed: () => context.pop()),
                  ),
          ),
          flexibleSpace: FlexibleSpaceBar(
            background: Stack(fit: StackFit.expand, children: [
              PageView.builder(
                controller: _page,
                itemCount: photos.length,
                onPageChanged: (i) => setState(() => _photo = i),
                itemBuilder: (c, i) => GestureDetector(
                  onTap: () => _openViewer(photos, i),
                  child: Hero(tag: 'listing-photo-${l.id}-$i', child: EvPhoto(photos[i], radius: 0, icon: categoryIcon(l.categoryId))),
                ),
              ),
              // A soft fade at the top keeps the status bar and back button readable.
              const IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment(0, -0.25),
                      colors: [Color(0x8C000000), Color(0x00000000)],
                    ),
                  ),
                ),
              ),
              if (photos.length > 1)
                Positioned(
                  right: EvSpace.gutter,
                  bottom: 14,
                  child: IgnorePointer(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(color: const Color(0x99171A18), borderRadius: BorderRadius.circular(99)),
                      child: Text('${_photo + 1} / ${photos.length}',
                          style: EvType.caption.copyWith(color: EvColors.inkOnDark, fontWeight: FontWeight.w600, fontFeatures: const [FontFeature.tabularFigures()])),
                    ),
                  ),
                ),
            ]),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x5, EvSpace.gutter, 0),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text(categoryById(l.categoryId).name, style: EvType.smallStrong.copyWith(color: EvColors.ink2)),
                if (l.condition != null) ...[const SizedBox(width: 8), Text('· ${l.condition![0].toUpperCase()}${l.condition!.substring(1)} condition', style: EvType.caption)],
                if (mine) ...[const Spacer(), StatusPill(l.status.label, tone: toneForListing(l.status), dense: true)],
              ]),
              const SizedBox(height: 6),
              Text(l.title, style: EvType.display),
              const SizedBox(height: EvSpace.x3),
              Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
                Text(l.priceAmount == null ? 'Price on quotation' : Money.k(l.priceAmount), style: EvType.title.copyWith(color: EvColors.forest)),
                if (l.priceAmount != null) ...[const SizedBox(width: 6), Text(l.priceUnit.short, style: EvType.small)],
              ]),
              if (l.depositAmount != null)
                Padding(padding: const EdgeInsets.only(top: 4), child: Text('Refundable deposit ${Money.k(l.depositAmount)}${l.depositNote != null ? ' · ${l.depositNote}' : ''}', style: EvType.small)),
            ]),
          ),
        ),

        // Supplier
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x5, EvSpace.gutter, 0),
            child: EvSurface(
              padding: const EdgeInsets.all(EvSpace.x3),
              onTap: () => context.push('/supplier/${biz.id}'),
              child: Row(children: [
                BusinessAvatar(name: biz.name, logoUrl: biz.logoUrl, verified: biz.verified, size: 44),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(biz.name, style: EvType.bodyStrong),
                    Text([if (biz.verified) 'Verified', if (biz.neighbourhood != null) biz.neighbourhood!].join(' · '), style: EvType.small),
                  ]),
                ),
                if (!mine)
                  EvButton(following ? 'Following' : 'Follow',
                      kind: following ? EvButtonKind.quiet : EvButtonKind.secondary,
                      compact: true,
                      icon: following ? LucideIcons.check : LucideIcons.bookmark,
                      onPressed: () => guard(
                          context,
                          () => following
                              ? ref.read(backendProvider).discovery.unfollow(myId, biz.id)
                              : ref.read(backendProvider).discovery.follow(myId, biz.id),
                          success: following ? 'Unfollowed ${biz.name}' : 'You’ll get updates when ${biz.name} adds stock')),
              ]),
            ),
          ),
        ),

        // Availability check
        if (!mine)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x5, EvSpace.gutter, 0),
              child: EvSurface(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Check availability', style: EvType.headline),
                  const SizedBox(height: EvSpace.x3),
                  EvPickerField(
                    label: 'Dates',
                    value: _from == null ? null : EvDates.range(_from!, _to ?? _from!),
                    placeholder: 'Choose dates',
                    icon: LucideIcons.calendarDays,
                    onTap: _pickDates,
                  ),
                  const SizedBox(height: EvSpace.x3),
                  AnimatedSize(
                    duration: EvMotion.of(context, EvMotion.base),
                    child: _from == null
                        ? Text(l.tracksStock && !l.isService ? 'Up to ${l.offeredQuantity} available.' : 'Choose a date to see if they’re free.', style: EvType.small)
                        : _checking
                            ? const LinearProgressIndicator(minHeight: 2)
                            : _available == null
                                ? const SizedBox.shrink()
                                : _AvailabilityResult(available: _available!, wanted: _qty, service: l.isService || !l.tracksStock),
                  ),
                ]),
              ),
            ),
          ),

        if (l.description.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x6, EvSpace.gutter, 0),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('About', style: EvType.headline.copyWith(fontSize: 16)),
                const SizedBox(height: 8),
                Text(l.description, style: EvType.body.copyWith(height: 1.55)),
              ]),
            ),
          ),
        if (l.packageItems.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x5, EvSpace.gutter, 0),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Included', style: EvType.headline.copyWith(fontSize: 16)),
                for (final p in l.packageItems)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(children: [Icon(LucideIcons.check, size: 16, color: EvColors.forest), const SizedBox(width: 8), Expanded(child: Text(p))]),
                  ),
              ]),
            ),
          ),
        if (l.terms.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x5, EvSpace.gutter, 0),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Hire terms', style: EvType.headline.copyWith(fontSize: 16)),
                const SizedBox(height: 8),
                Text(l.terms, style: EvType.small.copyWith(height: 1.5)),
              ]),
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 120)),
      ]),
      ),

      // Sticky action bar
      Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: Container(
          padding: EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x3, EvSpace.gutter, EvSpace.x3 + MediaQuery.paddingOf(context).bottom),
          decoration: BoxDecoration(color: EvColors.warmWhite, border: Border(top: BorderSide(color: EvColors.sand))),
          child: mine
              ? EvButton('Edit listing', icon: LucideIcons.squarePen, expand: true, onPressed: () => context.push('/business/listings/${l.id}'))
              : Row(children: [
                  if (biz.whatsapp != null) ...[
                    EvButton('',
                        kind: EvButtonKind.secondary,
                        icon: LucideIcons.messageCircle,
                        onPressed: () => launchUrl(
                            Uri.parse('https://wa.me/${ZambianPhone.waDigits(biz.whatsapp!)}?text=${Uri.encodeComponent('Hello ${biz.name}, I saw "${l.title}" on Evenda.')}'),
                            mode: LaunchMode.externalApplication)),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: EvButton('Request a quotation', expand: true, onPressed: () {
                      final p = [
                        'supplier=${biz.id}',
                        'listing=${l.id}',
                        if (_from != null) 'from=${EvDates.iso(_from!)}',
                        'qty=$_qty',
                      ].join('&');
                      context.push('/quote/new?$p');
                    }),
                  ),
                ]),
        ),
      ),
    ]),
    );
  }
}

class _AvailabilityResult extends StatelessWidget {
  const _AvailabilityResult({required this.available, required this.wanted, required this.service});
  final int available;
  final int wanted;
  final bool service;

  @override
  Widget build(BuildContext context) {
    final ok = service ? available > 0 : available >= wanted;
    final none = available == 0;
    final tone = none ? Tone.critical : (ok ? Tone.positive : Tone.attention);
    final text = service
        ? (none ? 'Fully booked on those dates.' : 'Has capacity on those dates.')
        : (none ? 'None free on those dates.' : '${available > 9999 ? 'Available' : '$available free'} for every day you chose.');
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: tone.bg, borderRadius: EvRadius.smAll),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(none ? LucideIcons.circleX : (ok ? LucideIcons.circleCheck : LucideIcons.triangleAlert), size: 18, color: tone.fg),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(text, style: EvType.smallStrong.copyWith(color: tone.fg)),
            const SizedBox(height: 2),
            Text('Not reserved until the supplier quotes and you accept.', style: EvType.caption.copyWith(color: tone.fg)),
          ]),
        ),
      ]),
    );
  }
}



/// Full-screen photos, as big apps do it: black, swipe between photos, pinch to
/// zoom, a "2 / 5" counter and a close button.
class _PhotoViewer extends StatefulWidget {
  const _PhotoViewer({required this.photos, required this.initial, required this.title, required this.heroPrefix});
  final String heroPrefix;
  final List<String?> photos;
  final int initial;
  final String title;

  @override
  State<_PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<_PhotoViewer> {
  late final _page = PageController(initialPage: widget.initial);
  late int _index = widget.initial;

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(children: [
            PageView.builder(
              controller: _page,
              itemCount: widget.photos.length,
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (_, i) => InteractiveViewer(
                maxScale: 4,
                child: Center(
                  child: Hero(
                    tag: '${widget.heroPrefix}-$i',
                    child: EvPhoto(widget.photos[i], radius: 0, fit: BoxFit.contain),
                  ),
                ),
              ),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Row(children: [
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(LucideIcons.x, color: Colors.white),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  Expanded(
                    child: Text(widget.title, style: EvType.bodyStrong.copyWith(color: Colors.white), maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                  if (widget.photos.length > 1)
                    Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: Text('${_index + 1} / ${widget.photos.length}', style: EvType.small.copyWith(color: Colors.white70)),
                    ),
                ]),
              ),
            ),
          ]),
        ),
      );
}
