import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../domain/models.dart';
import '../motion.dart';
import '../theme.dart';
import '../tokens.dart';

// ---------------------------------------------------------------------------
// Status
// ---------------------------------------------------------------------------

/// Semantic tones. Every status in the product maps to exactly one tone, so
/// the same colour always means the same thing.
enum Tone {
  neutral(EvColors.neutralTint, EvColors.ink2),
  waiting(EvColors.bronzeTint, EvColors.bronzeDeep), // awaiting someone's action
  progress(EvColors.infoTint, EvColors.info), // underway
  positive(EvColors.successTint, EvColors.success), // confirmed / done
  attention(EvColors.warningTint, EvColors.warning), // needs your attention
  critical(EvColors.dangerTint, EvColors.danger); // failed / cancelled / overdue

  const Tone(this.bg, this.fg);
  final Color bg;
  final Color fg;
}

Tone toneForBooking(BookingStatus s) => switch (s) {
      BookingStatus.confirmed => Tone.positive,
      BookingStatus.preparing || BookingStatus.dispatched || BookingStatus.inProgress => Tone.progress,
      BookingStatus.returned => Tone.attention,
      BookingStatus.completed => Tone.neutral,
      BookingStatus.cancelled => Tone.critical,
      BookingStatus.disputed => Tone.critical,
    };

Tone toneForPayment(PaymentStatus s) => switch (s) {
      PaymentStatus.unpaid => Tone.waiting,
      PaymentStatus.depositRecorded || PaymentStatus.partiallyPaid => Tone.progress,
      PaymentStatus.paid => Tone.positive,
      PaymentStatus.refunded => Tone.neutral,
    };

Tone toneForRequest(QuoteRequestStatus s) => switch (s) {
      QuoteRequestStatus.open => Tone.waiting,
      QuoteRequestStatus.quoted => Tone.progress,
      QuoteRequestStatus.accepted => Tone.positive,
      _ => Tone.neutral,
    };

Tone toneForListing(ListingStatus s) => switch (s) {
      ListingStatus.published => Tone.positive,
      ListingStatus.draft => Tone.neutral,
      ListingStatus.paused => Tone.attention,
      ListingStatus.archived => Tone.neutral,
    };

Tone toneForNow(NowStatus s) => switch (s) {
      NowStatus.draft => Tone.neutral,
      NowStatus.broadcasting || NowStatus.receivingOffers => Tone.progress,
      NowStatus.offerSelected => Tone.waiting,
      NowStatus.bookingConfirmed || NowStatus.completed => Tone.positive,
      NowStatus.cancelled || NowStatus.expired => Tone.neutral,
    };

Tone toneForPriority(TaskPriority p) => switch (p) {
      TaskPriority.low => Tone.neutral,
      TaskPriority.normal => Tone.neutral,
      TaskPriority.high => Tone.attention,
      TaskPriority.critical => Tone.critical,
    };

Tone toneForVerification(VerificationStatus v) => switch (v) {
      VerificationStatus.verified => Tone.positive,
      VerificationStatus.pending => Tone.waiting,
      VerificationStatus.rejected => Tone.critical,
      VerificationStatus.unverified => Tone.neutral,
    };

/// Status pill. Cross-fades and scales when the status changes so the
/// change itself is noticed.
class StatusPill extends StatelessWidget {
  const StatusPill(this.label, {super.key, this.tone = Tone.neutral, this.icon, this.dense = false});
  final String label;
  final Tone tone;
  final IconData? icon;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: EvMotion.of(context, EvMotion.base),
      switchInCurve: EvMotion.spring,
      transitionBuilder: (child, a) => FadeTransition(opacity: a, child: ScaleTransition(scale: Tween(begin: 0.85, end: 1.0).animate(a), child: child)),
      child: Container(
        key: ValueKey('$label$tone'),
        padding: EdgeInsets.symmetric(horizontal: dense ? 7 : 9, vertical: dense ? 2 : 4),
        decoration: BoxDecoration(color: tone.bg, borderRadius: BorderRadius.circular(EvRadius.pill)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[Icon(icon, size: dense ? 11 : 13, color: tone.fg), const SizedBox(width: 4)],
          Text(label, style: (dense ? EvType.caption : EvType.smallStrong.copyWith(fontSize: 12)).copyWith(color: tone.fg, fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }
}

/// "Demo data" marker. Shown wherever demo content appears so it is never
/// mistaken for live data.
class DemoBadge extends StatelessWidget {
  const DemoBadge({super.key, this.label = 'Demo data'});
  final String label;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: EvColors.bronzeTint,
          borderRadius: BorderRadius.circular(EvRadius.pill),
          border: Border.all(color: EvColors.bronze.withValues(alpha: 0.35)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(LucideIcons.flaskConical, size: 12, color: EvColors.bronzeDeep),
          const SizedBox(width: 4),
          Text(label, style: EvType.caption.copyWith(color: EvColors.bronzeDeep, fontWeight: FontWeight.w700)),
        ]),
      );
}

// ---------------------------------------------------------------------------
// Layout primitives
// ---------------------------------------------------------------------------

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.action, this.onAction, this.count, this.padding});
  final String title;
  final String? action;
  final VoidCallback? onAction;
  final int? count;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) => Padding(
        padding: padding ?? const EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x6, EvSpace.x2, EvSpace.x2),
        child: Row(children: [
          Text(title.toUpperCase(), style: EvType.overline),
          if (count != null) ...[const SizedBox(width: 6), Text('$count', style: EvType.overline.copyWith(color: EvColors.bronze))],
          const Spacer(),
          if (action != null)
            TextButton(
              onPressed: onAction,
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact, textStyle: EvType.smallStrong),
              child: Text(action!),
            ),
        ]),
      );
}

/// Warm-white surface. Uses a hairline border rather than a shadow, except
/// for floating elements.
class EvSurface extends StatelessWidget {
  const EvSurface({super.key, required this.child, this.padding = const EdgeInsets.all(EvSpace.x4), this.onTap, this.margin, this.color, this.radius});
  final Widget child;
  final EdgeInsets padding;
  final EdgeInsets? margin;
  final VoidCallback? onTap;
  final Color? color;
  final double? radius;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(radius ?? EvRadius.md);
    return Padding(
      padding: margin ?? EdgeInsets.zero,
      child: Material(
        color: color ?? EvColors.warmWhite,
        shape: RoundedRectangleBorder(borderRadius: r, side: const BorderSide(color: EvColors.sand)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(onTap: onTap, child: Padding(padding: padding, child: child)),
      ),
    );
  }
}

/// Dense operational row: leading, title, meta line, trailing. Used for
/// tasks, bookings, requests, team members, settings.
class EvRow extends StatelessWidget {
  const EvRow({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.meta,
    this.dense = false,
    this.titleStyle,
    this.padding,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final Widget? meta;
  final VoidCallback? onTap;
  final bool dense;
  final TextStyle? titleStyle;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: padding ?? EdgeInsets.symmetric(horizontal: EvSpace.gutter, vertical: dense ? 10 : 13),
        child: Row(children: [
          if (leading != null) ...[leading!, const SizedBox(width: 12)],
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: titleStyle ?? EvType.bodyStrong, maxLines: 2, overflow: TextOverflow.ellipsis),
              if (subtitle != null) Padding(padding: const EdgeInsets.only(top: 2), child: Text(subtitle!, style: EvType.small, maxLines: 2, overflow: TextOverflow.ellipsis)),
              if (meta != null) Padding(padding: const EdgeInsets.only(top: 6), child: meta!),
            ]),
          ),
          if (trailing != null) ...[const SizedBox(width: 10), trailing!],
          if (trailing == null && onTap != null) const Icon(LucideIcons.chevronRight, size: 18, color: EvColors.ink3),
        ]),
      ),
    );
  }
}

class EvDivider extends StatelessWidget {
  const EvDivider({super.key, this.indent = EvSpace.gutter});
  final double indent;
  @override
  Widget build(BuildContext context) => Divider(indent: indent, endIndent: 0, height: 1);
}

/// Label/value line used in detail views.
class KeyValue extends StatelessWidget {
  const KeyValue(this.label, this.value, {super.key, this.valueStyle, this.trailing});
  final String label;
  final String value;
  final TextStyle? valueStyle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 120, child: Text(label, style: EvType.small)),
          Expanded(child: Text(value, style: valueStyle ?? EvType.body)),
          ?trailing,
        ]),
      );
}

/// Small leading icon tile, tinted by tone.
class IconTile extends StatelessWidget {
  const IconTile(this.icon, {super.key, this.tone = Tone.neutral, this.size = 36});
  final IconData icon;
  final Tone tone;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: tone.bg, borderRadius: EvRadius.smAll),
        child: Icon(icon, size: size * 0.5, color: tone.fg),
      );
}

// ---------------------------------------------------------------------------
// Media & identity
// ---------------------------------------------------------------------------

/// Displays `asset:` demo photos and network photos with a quiet placeholder.
class EvPhoto extends StatelessWidget {
  const EvPhoto(this.src, {super.key, this.width, this.height, this.radius = EvRadius.md, this.fit = BoxFit.cover, this.icon = LucideIcons.image});
  final String? src;
  final double? width;
  final double? height;
  final double radius;
  final BoxFit fit;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final placeholder = Container(
      width: width,
      height: height,
      color: EvColors.sand,
      alignment: Alignment.center,
      child: Icon(icon, color: EvColors.sandDeep, size: 26),
    );
    Widget img;
    if (src == null || src!.isEmpty) {
      img = placeholder;
    } else if (src!.startsWith('asset:')) {
      img = Image.asset(src!.substring(6), width: width, height: height, fit: fit, errorBuilder: (_, _, _) => placeholder);
    } else {
      img = CachedNetworkImage(
        imageUrl: src!,
        width: width,
        height: height,
        fit: fit,
        fadeInDuration: EvMotion.base,
        placeholder: (_, _) => placeholder,
        errorWidget: (_, _, _) => placeholder,
      );
    }
    return ClipRRect(borderRadius: BorderRadius.circular(radius), child: img);
  }
}

/// Business identity: logo if present, otherwise a monogram on a tint
/// derived from the name (stable per business, palette-only colours).
class BusinessAvatar extends StatelessWidget {
  const BusinessAvatar({super.key, required this.name, this.logoUrl, this.size = 40, this.verified = false});
  final String name;
  final String? logoUrl;
  final double size;
  final bool verified;

  static const _tints = [
    (EvColors.forestTint, EvColors.forest),
    (EvColors.bronzeTint, EvColors.bronzeDeep),
    (EvColors.infoTint, EvColors.info),
    (EvColors.neutralTint, EvColors.ink2),
  ];

  @override
  Widget build(BuildContext context) {
    final words = name.replaceAll(RegExp(r'[^A-Za-z ]'), '').split(' ').where((w) => w.isNotEmpty).toList();
    final initials = words.isEmpty ? '?' : (words.length == 1 ? words[0][0] : '${words[0][0]}${words[1][0]}').toUpperCase();
    final (bg, fg) = _tints[name.hashCode.abs() % _tints.length];
    final core = logoUrl != null
        ? EvPhoto(logoUrl, width: size, height: size, radius: size * 0.28)
        : Container(
            width: size,
            height: size,
            decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(size * 0.28)),
            alignment: Alignment.center,
            child: Text(initials, style: EvType.smallStrong.copyWith(color: fg, fontSize: size * 0.36, height: 1)),
          );
    if (!verified) return core;
    return Stack(clipBehavior: Clip.none, children: [
      core,
      Positioned(
        right: -3,
        bottom: -3,
        child: Container(
          padding: const EdgeInsets.all(1.5),
          decoration: const BoxDecoration(color: EvColors.cream, shape: BoxShape.circle),
          child: Icon(LucideIcons.badgeCheck, size: size * 0.36, color: EvColors.forest),
        ),
      ),
    ]);
  }
}

/// Inventory breakdown bar: available / reserved / dispatched / inspection / damaged.
class StockBar extends StatelessWidget {
  const StockBar({super.key, required this.segments, this.height = 10});
  final List<(int value, Color color)> segments;
  final double height;

  @override
  Widget build(BuildContext context) {
    final total = segments.fold(0, (s, e) => s + e.$1);
    if (total == 0) {
      return Container(height: height, decoration: BoxDecoration(color: EvColors.sand, borderRadius: BorderRadius.circular(height)));
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(height),
      child: SizedBox(
        height: height,
        child: Row(children: [
          for (final (v, c) in segments)
            if (v > 0)
              Expanded(
                flex: v,
                child: TweenAnimationBuilder<Color?>(
                  tween: ColorTween(end: c),
                  duration: EvMotion.of(context, EvMotion.slow),
                  builder: (_, col, _) => Container(color: col, margin: const EdgeInsets.only(right: 1.5)),
                ),
              ),
        ]),
      ),
    );
  }
}

class LegendDot extends StatelessWidget {
  const LegendDot(this.color, this.label, this.value, {super.key});
  final Color color;
  final String label;
  final int value;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 6),
        Text(label, style: EvType.small),
        const SizedBox(width: 4),
        EvAnimatedCount(value: value, style: EvType.smallStrong),
      ]);
}

// ---------------------------------------------------------------------------
// Sheets
// ---------------------------------------------------------------------------

Future<T?> showEvSheet<T>(BuildContext context, {required String title, required Widget Function(BuildContext) builder, bool scroll = true, String? subtitle}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (c) {
      final body = Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(c).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(EvSpace.gutter, 0, EvSpace.gutter, EvSpace.x3),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: EvType.title),
                if (subtitle != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(subtitle, style: EvType.small)),
              ]),
            ),
            Flexible(child: builder(c)),
          ],
        ),
      );
      return ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(c).height * 0.9),
        child: scroll ? body : body,
      );
    },
  );
}

/// Pick one option from a list in a sheet.
Future<T?> pickFromSheet<T>(BuildContext context, {required String title, required List<(T value, String label, String? subtitle)> options, T? selected, IconData? Function(T)? icon}) {
  return showEvSheet<T>(
    context,
    title: title,
    builder: (c) => ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.only(bottom: EvSpace.x6),
      children: [
        for (final (v, label, sub) in options)
          EvRow(
            title: label,
            subtitle: sub,
            leading: icon?.call(v) == null ? null : IconTile(icon!(v)!, tone: v == selected ? Tone.positive : Tone.neutral),
            trailing: v == selected ? const Icon(LucideIcons.check, color: EvColors.forest, size: 20) : const SizedBox(width: 20),
            onTap: () => Navigator.pop(c, v),
          ),
      ],
    ),
  );
}

IconData categoryIcon(String? categoryId) => iconForCategoryKey(categoryById(categoryId).icon);

/// Icon keys admins can choose for a category (mirrors the server check in
/// admin_upsert_category).
const kCategoryIconKeys = [
  'tent', 'armchair', 'table', 'shirt', 'sparkles', 'flower', 'speaker', 'lightbulb', 'layers', 'cooking_pot',
  'palette', 'utensils', 'flower_2', 'camera', 'music', 'clipboard_list', 'cake', 'car', 'mic', 'baby', 'gift',
  'video', 'scissors', 'paintbrush', 'package',
];

IconData iconForCategoryKey(String key) => switch (key) {
      'tent' => LucideIcons.tent,
      'armchair' => LucideIcons.armchair,
      'table' => LucideIcons.table,
      'shirt' => LucideIcons.shirt,
      'sparkles' => LucideIcons.sparkles,
      'flower' => LucideIcons.flower,
      'speaker' => LucideIcons.speaker,
      'lightbulb' => LucideIcons.lightbulb,
      'layers' => LucideIcons.layers,
      'cooking_pot' => LucideIcons.cookingPot,
      'palette' => LucideIcons.palette,
      'utensils' => LucideIcons.utensils,
      'flower_2' => LucideIcons.flower2,
      'camera' => LucideIcons.camera,
      'music' => LucideIcons.music,
      'clipboard_list' => LucideIcons.clipboardList,
      'cake' => LucideIcons.cake,
      'car' => LucideIcons.car,
      'mic' => LucideIcons.mic,
      'baby' => LucideIcons.baby,
      'gift' => LucideIcons.gift,
      'video' => LucideIcons.video,
      'scissors' => LucideIcons.scissors,
      'paintbrush' => LucideIcons.paintbrush,
      _ => LucideIcons.package,
    };
