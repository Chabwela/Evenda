import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../app/providers.dart';
import '../../core/alert_tone.dart';
import '../../data/backend.dart';
import '../../design/ev.dart';
import '../../domain/models.dart';
import '../find/listing_detail.dart';

final _prefsProvider = FutureProvider.autoDispose<NotificationPrefs>((ref) async {
  ref.watchDomains(const [DataDomain.notifications]);
  return ref.watch(backendProvider).notifications.prefs(ref.watch(bizIdProvider));
});

/// Relevance controls for broadcasts and reminders: what reaches you, how
/// fast, and when to stay quiet.
class NotificationSettingsScreen extends ConsumerStatefulWidget {
  const NotificationSettingsScreen({super.key});
  @override
  ConsumerState<NotificationSettingsScreen> createState() => _NotificationSettingsScreenState();
}

class _NotificationSettingsScreenState extends ConsumerState<NotificationSettingsScreen> {
  NotificationPrefs? _p;
  bool _dirty = false;
  bool _busy = false;

  void _set(NotificationPrefs p) => setState(() {
        _p = p;
        _dirty = true;
      });

  String _fmt(Duration d) => '${d.inHours.toString().padLeft(2, '0')}:${(d.inMinutes % 60).toString().padLeft(2, '0')}';

  Future<Duration?> _time(Duration current) async {
    final t = await pickTime(context, initial: TimeOfDay(hour: current.inHours, minute: current.inMinutes % 60));
    return t == null ? null : Duration(hours: t.hour, minutes: t.minute);
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    await guard(context, () => ref.read(backendProvider).notifications.savePrefs(ref.read(bizIdProvider), _p!), success: 'Notification settings saved');
    if (mounted) {
      setState(() {
      _busy = false;
      _dirty = false;
    });
    }
  }

  Widget _level(String title, String sub, PrefLevel value, ValueChanged<PrefLevel> onChanged, {List<PrefLevel> options = PrefLevel.values}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: EvType.bodyStrong),
          Text(sub, style: EvType.small),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [for (final l in options) EvChip(label: l.label, selected: value == l, onTap: () => onChanged(l))]),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(_prefsProvider);
    final follows = ref.watch(followsProvider);
    if (_p == null && prefs.hasValue) _p = prefs.value;
    final myId = ref.watch(bizIdProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: AsyncView(
        value: prefs,
        onRetry: () => ref.invalidate(_prefsProvider),
        data: (_) {
          final p = _p!;
          return ListView(padding: const EdgeInsets.fromLTRB(EvSpace.gutter, 0, EvSpace.gutter, 120), children: [
            _level('Supplier inventory updates', 'New listings, extra stock and reopened dates from relevant suppliers.', p.inventoryUpdates,
                (v) => _set(p.copyWith(inventoryUpdates: v))),
            if (p.inventoryUpdates == PrefLevel.immediate)
              Text('Only significant updates (e.g. 50+ items or new listings) are pushed; routine ones still go to your digest.', style: EvType.caption),
            const EvDivider(indent: 0),
            _level('Booking activity', 'Quote requests, quotations, acceptances and payments.', p.bookingActivity, (v) => _set(p.copyWith(bookingActivity: v))),
            const EvDivider(indent: 0),
            _level('Task reminders', 'Advance reminders and deadline alerts for your tasks.', p.taskReminders, (v) => _set(p.copyWith(taskReminders: v))),
            const EvDivider(indent: 0),
            EvSwitchRow(
              title: 'Evenda Now requests',
              subtitle: 'Urgent requests from nearby vendors who need something you have free.',
              value: p.nowRequests,
              onChanged: (v) => _set(p.copyWith(nowRequests: v)),
            ),
            if (p.nowRequests && !kIsWeb && defaultTargetPlatform == TargetPlatform.android) const _RingLikeACall(),
            const SectionHeader('Quiet hours', padding: EdgeInsets.fromLTRB(0, EvSpace.x6, 0, EvSpace.x2)),
            Text('No pushes in this window except critical deadlines and Evenda Now. Everything waits in your notification centre.', style: EvType.small),
            const SizedBox(height: EvSpace.x3),
            Row(children: [
              Expanded(child: EvPickerField(label: 'From', value: _fmt(p.quietStart), icon: LucideIcons.moon, onTap: () async {
                final d = await _time(p.quietStart);
                if (d != null) _set(p.copyWith(quietStart: d));
              })),
              const SizedBox(width: 12),
              Expanded(child: EvPickerField(label: 'Until', value: _fmt(p.quietEnd), icon: LucideIcons.sunrise, onTap: () async {
                final d = await _time(p.quietEnd);
                if (d != null) _set(p.copyWith(quietEnd: d));
              })),
            ]),
            const SizedBox(height: EvSpace.x4),
            EvPickerField(
              label: 'Daily digest',
              value: '${p.digestHour.toString().padLeft(2, '0')}:00',
              icon: LucideIcons.clock,
              onTap: () async {
                final h = await pickFromSheet<int>(context, title: 'Send my daily digest at', selected: p.digestHour, options: [
                  for (final h in const [5, 6, 7, 8, 9, 12, 17, 19]) (h, '${h.toString().padLeft(2, '0')}:00', null),
                ]);
                if (h != null) _set(p.copyWith(digestHour: h));
              },
            ),
            const SectionHeader('Categories I follow', padding: EdgeInsets.fromLTRB(0, EvSpace.x6, 0, EvSpace.x2)),
            Text('You hear about new stock in these categories from suppliers within ${p.preferredRadiusKm} km.', style: EvType.small),
            const SizedBox(height: EvSpace.x3),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final c in kCategories)
                EvChip(
                  label: c.name,
                  icon: categoryIcon(c.id),
                  selected: p.subscribedCategories.contains(c.id),
                  onTap: () {
                    final s = {...p.subscribedCategories};
                    s.contains(c.id) ? s.remove(c.id) : s.add(c.id);
                    _set(p.copyWith(subscribedCategories: s));
                  },
                ),
            ]),
            const SizedBox(height: EvSpace.x4),
            EvFieldLabel('Preferred area: within ${p.preferredRadiusKm} km'),
            Slider(value: p.preferredRadiusKm.toDouble().clamp(5, 100), min: 5, max: 100, divisions: 19, label: '${p.preferredRadiusKm} km',
                onChanged: (v) => _set(p.copyWith(preferredRadiusKm: v.round()))),
            const SectionHeader('Suppliers I follow', padding: EdgeInsets.fromLTRB(0, EvSpace.x6, 0, EvSpace.x2)),
            AsyncView(
              value: follows,
              loading: const SizedBox.shrink(),
              data: (list) => list.isEmpty
                  ? Text('Follow suppliers from their profile to always hear when they add stock, whatever the category.', style: EvType.small)
                  : Column(children: [
                      for (final f in list)
                        EvRow(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          leading: BusinessAvatar(name: f.supplier.name, logoUrl: f.supplier.logoUrl, verified: f.supplier.verified, size: 36),
                          title: f.supplier.name,
                          subtitle: f.muted ? 'Muted' : (f.pushEnabled ? 'Push on' : 'Digest only'),
                          onTap: () => context.push('/supplier/${f.supplier.id}'),
                          trailing: TextButton(
                            onPressed: () => guard(context, () => ref.read(backendProvider).discovery.setFollowMuted(myId, f.supplier.id, !f.muted)),
                            child: Text(f.muted ? 'Unmute' : 'Mute'),
                          ),
                        ),
                    ]),
            ),
          ]);
        },
      ),
      bottomSheet: AnimatedSlide(
        duration: EvMotion.of(context, EvMotion.base),
        offset: _dirty ? Offset.zero : const Offset(0, 1.2),
        child: Container(
          color: EvColors.warmWhite,
          padding: EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x3, EvSpace.gutter, EvSpace.x3 + MediaQuery.paddingOf(context).bottom),
          child: EvButton('Save settings', expand: true, loading: _busy, onPressed: _dirty ? _save : null),
        ),
      ),
    );
  }
}


/// Lets an Evenda Now request ring like a call when Evenda is closed: Android 14+
/// asks the user to allow full-screen alerts, and some phone makers stop
/// closed apps from waking unless battery saving is turned off for them.
class _RingLikeACall extends StatefulWidget {
  const _RingLikeACall();
  @override
  State<_RingLikeACall> createState() => _RingLikeACallState();
}

class _RingLikeACallState extends State<_RingLikeACall> with WidgetsBindingObserver {
  bool? _fullScreen;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Coming back from system settings: show the new state.
  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    final ok = await AlertTone.fullScreenAllowed();
    if (mounted) setState(() => _fullScreen = ok);
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: EvSpace.x2, bottom: EvSpace.x2),
        child: EvSurface(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Ring like a call', style: EvType.bodyStrong),
            const SizedBox(height: 4),
            Text('When a request comes in and Evenda is closed, your phone rings and the request opens full screen, even on the lock screen.',
                style: EvType.small),
            const SizedBox(height: EvSpace.x3),
            Row(children: [
              Icon(_fullScreen == false ? LucideIcons.circleAlert : LucideIcons.circleCheck, size: 18,
                  color: _fullScreen == false ? EvColors.warning : EvColors.success),
              const SizedBox(width: 8),
              Expanded(
                child: Text(_fullScreen == false ? 'Full-screen alerts are off for Evenda' : 'Full-screen alerts are allowed',
                    style: EvType.smallStrong),
              ),
              if (_fullScreen == false) TextButton(onPressed: AlertTone.openFullScreenSettings, child: const Text('Allow')),
            ]),
            const EvDivider(indent: 0),
            Row(children: [
              const Icon(LucideIcons.batteryCharging, size: 18, color: EvColors.ink3),
              const SizedBox(width: 8),
              Expanded(child: Text('If requests don\u2019t ring when Evenda is closed, let it run without battery limits.', style: EvType.small)),
              TextButton(onPressed: AlertTone.openBatterySettings, child: const Text('Open')),
            ]),
          ]),
        ),
      );
}
