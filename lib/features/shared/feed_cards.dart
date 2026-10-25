import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/format.dart';
import '../../design/ev.dart';
import '../../domain/models.dart';

IconData notificationIcon(NotificationCategory c) => switch (c) {
      NotificationCategory.inventory => LucideIcons.packagePlus,
      NotificationCategory.booking => LucideIcons.handshake,
      NotificationCategory.task => LucideIcons.alarmClock,
      NotificationCategory.now => LucideIcons.zap,
      NotificationCategory.system => LucideIcons.bell,
    };

String priceLabel(Listing l) {
  if (l.priceUnit == PriceUnit.onQuote || l.priceAmount == null) return 'Price on quotation';
  return '${Money.k(l.priceAmount)} ${l.priceUnit.short}';
}

/// Broadcast card: photo-led, with the supplier, what changed and an explicit
/// reminder that availability is only confirmed by quotation.
class InventoryUpdateCard extends StatelessWidget {
  const InventoryUpdateCard({super.key, required this.update, this.width = 220});
  final InventoryUpdate update;
  final double width;

  @override
  Widget build(BuildContext context) {
    final l = update.listing;
    return SizedBox(
      width: width,
      child: InkWell(
        borderRadius: EvRadius.mdAll,
        onTap: l == null ? null : () => context.push('/listing/${l.id}'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Stack(children: [
            EvPhoto(l?.coverPhoto, width: width, height: 130),
            Positioned(
              left: 8,
              top: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(color: EvColors.warmWhite, borderRadius: BorderRadius.circular(EvRadius.pill)),
                child: Text(update.headline, style: EvType.caption.copyWith(color: EvColors.forest, fontWeight: FontWeight.w700)),
              ),
            ),
          ]),
          const SizedBox(height: 8),
          Text(l?.title ?? 'Availability update', style: EvType.bodyStrong, maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 2),
          Row(children: [
            Flexible(child: Text(update.supplier.name, style: EvType.small, maxLines: 1, overflow: TextOverflow.ellipsis)),
            if (update.supplier.verified) ...[const SizedBox(width: 4), Icon(LucideIcons.badgeCheck, size: 13, color: EvColors.forest)],
          ]),
          const SizedBox(height: 2),
          Text(
            [
              if (update.supplier.neighbourhood != null) update.supplier.neighbourhood!,
              if (update.type == 'availability_opened' && update.payload['from'] != null) 'from ${EvDates.dayShort(DateTime.parse(update.payload['from']))}',
              EvDates.ago(update.createdAt),
            ].join(' · '),
            style: EvType.caption,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ]),
      ),
    );
  }
}

/// Search result: editorial row with a generous photo, business identity,
/// price basis, date-aware availability (when the search has dates) and distance.
class ListingResultCard extends StatelessWidget {
  const ListingResultCard({super.key, required this.result, this.onTap});
  final SearchResult result;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l = result.listing;
    final biz = l.business;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: EvSpace.gutter, vertical: EvSpace.x3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          EvPhoto(l.coverPhoto, width: 112, height: 112, icon: categoryIcon(l.categoryId)),
          const SizedBox(width: EvSpace.x3),
          // At least as tall as the photo, but free to grow: a two-line title
          // or a large phone text size overflowed the old fixed 112 px.
          Expanded(
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 112),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(categoryById(l.categoryId).name, style: EvType.caption.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(l.title, style: EvType.headline.copyWith(fontSize: 16), maxLines: 2, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 4),
                if (biz != null)
                  Row(children: [
                    Flexible(child: Text(biz.name, style: EvType.small, maxLines: 1, overflow: TextOverflow.ellipsis)),
                    if (biz.verified) ...[const SizedBox(width: 4), Icon(LucideIcons.badgeCheck, size: 13, color: EvColors.forest)],
                  ]),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(child: Text(priceLabel(l), style: EvType.money.copyWith(fontSize: 14), maxLines: 1, overflow: TextOverflow.ellipsis)),
                  const SizedBox(width: 6),
                  if (result.available != null)
                    StatusPill('${result.available} free', tone: Tone.positive, dense: true)
                  else if (l.tracksStock && l.kind != OfferingType.service)
                    Text('${l.offeredQuantity} available', style: EvType.caption),
                ]),
                const SizedBox(height: 2),
                Text(
                  [
                    if (biz?.neighbourhood != null) biz!.neighbourhood!,
                    if (result.distanceKm != null) '${result.distanceKm!.toStringAsFixed(1)} km',
                  ].join(' · '),
                  style: EvType.caption,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}
