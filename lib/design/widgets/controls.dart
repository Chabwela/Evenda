import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/format.dart';
import '../motion.dart';
import '../theme.dart';
import '../tokens.dart';

enum EvButtonKind { primary, secondary, quiet, danger }

/// Buttons. One primary action per view; secondary is a tonal fill, quiet is
/// text-only. Loading keeps the button size and blocks repeat taps, which
/// is also the first line of defence against duplicate submissions.
class EvButton extends StatelessWidget {
  const EvButton(this.label,
      {super.key, this.onPressed, this.kind = EvButtonKind.primary, this.icon, this.loading = false, this.expand = false, this.compact = false});

  final String label;
  final VoidCallback? onPressed;
  final EvButtonKind kind;
  final IconData? icon;
  final bool loading;
  final bool expand;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (kind) {
      EvButtonKind.primary => (EvColors.forest, EvColors.inkOnDark),
      EvButtonKind.secondary => (EvColors.forestTint, EvColors.forest),
      EvButtonKind.quiet => (Colors.transparent, EvColors.forest),
      EvButtonKind.danger => (EvColors.dangerTint, EvColors.danger),
    };
    final enabled = onPressed != null && !loading;
    final child = AnimatedSwitcher(
      duration: EvMotion.of(context, EvMotion.fast),
      child: loading
          ? SizedBox(key: const ValueKey('l'), width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: fg))
          : Row(
              key: const ValueKey('c'),
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) Icon(icon, size: 18),
                if (icon != null && label.isNotEmpty) const SizedBox(width: 8),
                if (label.isNotEmpty) Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
              ],
            ),
    );
    final button = FilledButton(
      onPressed: enabled ? () {
        HapticFeedback.selectionClick();
        onPressed!();
      } : null,
      style: FilledButton.styleFrom(
        backgroundColor: bg,
        foregroundColor: fg,
        disabledBackgroundColor: kind == EvButtonKind.quiet ? Colors.transparent : EvColors.sand,
        disabledForegroundColor: loading ? fg : EvColors.ink3,
        minimumSize: Size(compact ? 40 : 64, compact ? 40 : 50),
        padding: EdgeInsets.symmetric(horizontal: compact ? 14 : 20),
        textStyle: compact ? EvType.smallStrong : EvType.label,
        elevation: 0,
      ),
      child: child,
    );
    return expand ? SizedBox(width: double.infinity, child: button) : button;
  }
}

/// Icon-only tap target (44 px) for headers and rows.
class EvIconButton extends StatelessWidget {
  const EvIconButton(this.icon, {super.key, required this.onPressed, this.tooltip, this.badge = 0, this.color});
  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final int badge;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip ?? '',
      child: InkResponse(
        onTap: onPressed,
        radius: 24,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Icon(icon, size: 22, color: color ?? EvColors.ink),
              if (badge > 0)
                Positioned(
                  top: 7,
                  right: 6,
                  child: AnimatedScale(
                    scale: 1,
                    duration: EvMotion.fast,
                    child: Container(
                      constraints: const BoxConstraints(minWidth: 17),
                      height: 17,
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      decoration: BoxDecoration(color: EvColors.bronze, borderRadius: BorderRadius.circular(9), border: Border.all(color: EvColors.cream, width: 1.5)),
                      alignment: Alignment.center,
                      child: Text(badge > 99 ? '99+' : '$badge', style: EvType.caption.copyWith(color: EvColors.inkOnDark, fontSize: 10, height: 1)),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Labelled text field: label above, helper/error below. Labels never float
/// inside the field, which keeps forms calm and scannable.
class EvField extends StatelessWidget {
  const EvField({
    super.key,
    required this.label,
    this.controller,
    this.initialValue,
    this.hint,
    this.helper,
    this.validator,
    this.onChanged,
    this.keyboardType,
    this.maxLines = 1,
    this.minLines,
    this.prefixText,
    this.suffixText,
    this.prefixIcon,
    this.inputFormatters,
    this.textInputAction,
    this.autofocus = false,
    this.optional = false,
    this.enabled = true,
    this.maxLength,
    this.onSubmitted,
    this.textCapitalization = TextCapitalization.sentences,
    this.autofillHints,
    this.autocorrect = true,
  });

  final String label;
  final TextEditingController? controller;
  final String? initialValue;
  final String? hint;
  final String? helper;
  final FormFieldValidator<String>? validator;
  final ValueChanged<String>? onChanged;
  final TextInputType? keyboardType;
  final int? maxLines;
  final int? minLines;
  final String? prefixText;
  final String? suffixText;
  final IconData? prefixIcon;
  final List<TextInputFormatter>? inputFormatters;
  final TextInputAction? textInputAction;
  final bool autofocus;
  final bool optional;
  final bool enabled;
  final int? maxLength;
  final ValueChanged<String>? onSubmitted;
  final TextCapitalization textCapitalization;
  final Iterable<String>? autofillHints;
  final bool autocorrect;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        EvFieldLabel(label, optional: optional),
        TextFormField(
          controller: controller,
          initialValue: controller == null ? initialValue : null,
          validator: validator,
          onChanged: onChanged,
          keyboardType: keyboardType,
          maxLines: maxLines,
          minLines: minLines,
          inputFormatters: inputFormatters,
          textInputAction: textInputAction,
          autofocus: autofocus,
          enabled: enabled,
          maxLength: maxLength,
          onFieldSubmitted: onSubmitted,
          textCapitalization: textCapitalization,
          autofillHints: autofillHints,
          autocorrect: autocorrect,
          enableSuggestions: autocorrect,
          style: EvType.body,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          decoration: InputDecoration(
            hintText: hint,
            helperText: helper,
            helperMaxLines: 3,
            prefixText: prefixText,
            suffixText: suffixText,
            prefixIcon: prefixIcon == null ? null : Icon(prefixIcon, size: 18, color: EvColors.ink3),
            prefixStyle: EvType.body.copyWith(color: EvColors.ink2),
            suffixStyle: EvType.small,
            counterText: '',
          ),
        ),
      ],
    );
  }
}

class EvFieldLabel extends StatelessWidget {
  const EvFieldLabel(this.label, {super.key, this.optional = false});
  final String label;
  final bool optional;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text.rich(TextSpan(children: [
          TextSpan(text: label, style: EvType.smallStrong.copyWith(color: EvColors.ink2)),
          if (optional) TextSpan(text: '  Optional', style: EvType.caption),
        ])),
      );
}

/// Zambian phone field with a fixed +260 prefix.
class EvPhoneField extends StatelessWidget {
  const EvPhoneField({super.key, required this.controller, this.label = 'Mobile number', this.optional = false, this.helper, this.autofocus = false});
  final TextEditingController controller;
  final String label;
  final bool optional;
  final String? helper;
  final bool autofocus;

  @override
  Widget build(BuildContext context) => EvField(
        label: label,
        controller: controller,
        hint: '97 123 4567',
        prefixText: '+260  ',
        helper: helper,
        optional: optional,
        autofocus: autofocus,
        keyboardType: TextInputType.phone,
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9 ]')), LengthLimitingTextInputFormatter(13)],
        validator: (v) => ZambianPhone.validate(v, required: !optional),
      );
}

/// A tappable field that opens a picker (date, time, selection sheet).
class EvPickerField extends StatelessWidget {
  const EvPickerField({super.key, required this.label, required this.value, required this.onTap, this.icon = LucideIcons.chevronDown, this.placeholder = 'Choose', this.optional = false, this.error});
  final String label;
  final String? value;
  final VoidCallback onTap;
  final IconData icon;
  final String placeholder;
  final bool optional;
  final String? error;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        EvFieldLabel(label, optional: optional),
        Material(
          color: EvColors.warmWhite,
          shape: RoundedRectangleBorder(borderRadius: EvRadius.smAll, side: BorderSide(color: error != null ? EvColors.danger : EvColors.sand)),
          child: InkWell(
            borderRadius: EvRadius.smAll,
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              child: Row(children: [
                Expanded(
                  child: Text(value ?? placeholder,
                      style: EvType.body.copyWith(color: value == null ? EvColors.ink3 : EvColors.ink), overflow: TextOverflow.ellipsis),
                ),
                Icon(icon, size: 18, color: EvColors.ink3),
              ]),
            ),
          ),
        ),
        if (error != null) Padding(padding: const EdgeInsets.only(top: 6, left: 2), child: Text(error!, style: EvType.caption.copyWith(color: EvColors.danger))),
      ],
    );
  }
}

Future<DateTime?> pickDate(BuildContext context, {DateTime? initial, DateTime? first, DateTime? last}) {
  final today = EvDates.today();
  return showDatePicker(
    context: context,
    initialDate: initial ?? today,
    firstDate: first ?? today,
    lastDate: last ?? today.add(const Duration(days: 540)),
  );
}

Future<TimeOfDay?> pickTime(BuildContext context, {TimeOfDay? initial}) => showTimePicker(
      context: context,
      initialTime: initial ?? const TimeOfDay(hour: 9, minute: 0),
      builder: (c, child) => MediaQuery(data: MediaQuery.of(c).copyWith(alwaysUse24HourFormat: true), child: child!),
    );

/// Quantity stepper with direct entry. The number animates when it changes.
class EvQuantityStepper extends StatefulWidget {
  const EvQuantityStepper({super.key, required this.value, required this.onChanged, this.min = 0, this.max, this.step = 1, this.label, this.helper});
  final int value;
  final ValueChanged<int> onChanged;
  final int min;
  final int? max;
  final int step;
  final String? label;
  final String? helper;

  @override
  State<EvQuantityStepper> createState() => _EvQuantityStepperState();
}

class _EvQuantityStepperState extends State<EvQuantityStepper> {
  late final _c = TextEditingController(text: '${widget.value}');

  @override
  void didUpdateWidget(EvQuantityStepper old) {
    super.didUpdateWidget(old);
    if ('${widget.value}' != _c.text) _c.text = '${widget.value}';
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _set(int v) {
    final clamped = v.clamp(widget.min, widget.max ?? 1 << 30);
    widget.onChanged(clamped);
    HapticFeedback.selectionClick();
  }

  @override
  Widget build(BuildContext context) {
    Widget btn(IconData i, VoidCallback? f) => Material(
          color: f == null ? EvColors.neutralTint : EvColors.forestTint,
          borderRadius: EvRadius.smAll,
          child: InkWell(
            borderRadius: EvRadius.smAll,
            onTap: f,
            child: SizedBox(width: 48, height: 48, child: Icon(i, size: 18, color: f == null ? EvColors.ink3 : EvColors.forest)),
          ),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.label != null) EvFieldLabel(widget.label!),
        Row(children: [
          btn(LucideIcons.minus, widget.value - widget.step >= widget.min ? () => _set(widget.value - widget.step) : null),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _c,
              textAlign: TextAlign.center,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: EvType.number,
              onChanged: (s) {
                final v = int.tryParse(s);
                if (v != null) widget.onChanged(v.clamp(widget.min, widget.max ?? 1 << 30));
              },
              decoration: const InputDecoration(contentPadding: EdgeInsets.symmetric(vertical: 11)),
            ),
          ),
          const SizedBox(width: 8),
          btn(LucideIcons.plus, widget.max == null || widget.value + widget.step <= widget.max! ? () => _set(widget.value + widget.step) : null),
        ]),
        if (widget.helper != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(widget.helper!, style: EvType.caption)),
      ],
    );
  }
}

/// Segmented control for switching views (not for navigation between areas).
class EvSegmented<T> extends StatelessWidget {
  const EvSegmented({super.key, required this.segments, required this.value, required this.onChanged, this.counts});
  final List<(T, String)> segments;
  final T value;
  final ValueChanged<T> onChanged;
  final Map<T, int>? counts;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: EvSpace.gutter),
      child: Row(
        children: [
          for (final (v, label) in segments)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: _Seg(
                label: label,
                count: counts?[v],
                selected: v == value,
                onTap: () => onChanged(v),
              ),
            ),
        ],
      ),
    );
  }
}

class _Seg extends StatelessWidget {
  const _Seg({required this.label, required this.selected, required this.onTap, this.count});
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final int? count;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: selected,
      button: true,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: EvMotion.of(context, EvMotion.fast),
          curve: EvMotion.standard,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: selected ? EvColors.forest : EvColors.warmWhite,
            borderRadius: BorderRadius.circular(EvRadius.pill),
            border: Border.all(color: selected ? EvColors.forest : EvColors.sand),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(label, style: EvType.smallStrong.copyWith(color: selected ? EvColors.inkOnDark : EvColors.ink)),
            if (count != null && count! > 0) ...[
              const SizedBox(width: 6),
              Text('$count', style: EvType.smallStrong.copyWith(color: selected ? EvColors.bronzeTint : EvColors.bronze)),
            ],
          ]),
        ),
      ),
    );
  }
}

/// Selectable chip for filters and multi-select options.
class EvChip extends StatelessWidget {
  const EvChip({super.key, required this.label, required this.selected, required this.onTap, this.icon, this.trailing});
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;
  final IconData? trailing;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: AnimatedContainer(
        duration: EvMotion.of(context, EvMotion.fast),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? EvColors.forestTint : EvColors.warmWhite,
          borderRadius: EvRadius.smAll,
          border: Border.all(color: selected ? EvColors.forest : EvColors.sand, width: selected ? 1.4 : 1),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[Icon(icon, size: 15, color: selected ? EvColors.forest : EvColors.ink2), const SizedBox(width: 6)],
          Text(label, style: EvType.smallStrong.copyWith(color: selected ? EvColors.forest : EvColors.ink)),
          if (trailing != null) ...[const SizedBox(width: 4), Icon(trailing, size: 14, color: selected ? EvColors.forest : EvColors.ink3)],
        ]),
      ),
    );
  }
}

/// Large selectable option (onboarding choices, fulfilment, responsibility).
class EvOptionTile extends StatelessWidget {
  const EvOptionTile({super.key, required this.title, required this.selected, required this.onTap, this.subtitle, this.icon, this.multi = false});
  final String title;
  final String? subtitle;
  final IconData? icon;
  final bool selected;
  final bool multi;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        borderRadius: EvRadius.mdAll,
        child: AnimatedContainer(
          duration: EvMotion.of(context, EvMotion.fast),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: selected ? EvColors.forestWash : EvColors.warmWhite,
            borderRadius: EvRadius.mdAll,
            border: Border.all(color: selected ? EvColors.forest : EvColors.sand, width: selected ? 1.6 : 1),
          ),
          child: Row(children: [
            if (icon != null) ...[
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(color: selected ? EvColors.forest : EvColors.neutralTint, borderRadius: EvRadius.smAll),
                child: Icon(icon, size: 20, color: selected ? EvColors.inkOnDark : EvColors.ink2),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: EvType.bodyStrong),
                if (subtitle != null) Padding(padding: const EdgeInsets.only(top: 2), child: Text(subtitle!, style: EvType.small)),
              ]),
            ),
            const SizedBox(width: 8),
            AnimatedContainer(
              duration: EvMotion.of(context, EvMotion.fast),
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                shape: multi ? BoxShape.rectangle : BoxShape.circle,
                borderRadius: multi ? BorderRadius.circular(6) : null,
                color: selected ? EvColors.forest : Colors.transparent,
                border: Border.all(color: selected ? EvColors.forest : EvColors.sandDeep, width: 1.6),
              ),
              child: selected ? const Icon(LucideIcons.check, size: 14, color: EvColors.inkOnDark) : null,
            ),
          ]),
        ),
      ),
    );
  }
}

class EvSwitchRow extends StatelessWidget {
  const EvSwitchRow({super.key, required this.title, required this.value, required this.onChanged, this.subtitle});
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => MergeSemantics(
        child: InkWell(
          onTap: () => onChanged(!value),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: EvType.bodyStrong),
                  if (subtitle != null) Text(subtitle!, style: EvType.small),
                ]),
              ),
              Switch(value: value, onChanged: onChanged),
            ]),
          ),
        ),
      );
}
