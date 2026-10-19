import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../app/providers.dart';
import '../../core/format.dart';
import '../../design/ev.dart';
import '../../domain/models.dart';
import '../shared/map_widgets.dart';

/// Business setup in six short steps. Progress is saved after every step
/// (onboarding_step), so a vendor can leave and resume where they stopped.
/// Service-only vendors are never asked about stock.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});
  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  static const _titles = ['Your business', 'What you offer', 'How to reach you', 'Where you work', 'Opening hours', 'Verification'];
  static const _days = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
  static const _dayNames = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

  final _forms = List.generate(6, (_) => GlobalKey<FormState>());
  int _step = 0;
  int _pickerGen = 0; // bumped when the exact pin arrives, to re-centre the map
  bool _busy = false;
  bool _loaded = false;
  bool _done = false;
  String? _bizId;

  final _name = TextEditingController();
  final _desc = TextEditingController();
  final _phone = TextEditingController();
  final _whatsapp = TextEditingController();
  final _email = TextEditingController();
  final _address = TextEditingController();
  String? _logo;
  Set<OfferingType> _offers = {};
  String? _primary;
  Set<String> _extra = {};
  bool _waSame = true;
  LatLng _point = kLusakaCentre;
  String _hood = 'Lusaka CBD';
  bool _pointChosen = false;
  LocationPrecision _precision = LocationPrecision.approximate;
  int _radius = 25;
  Map<String, String> _hours = {
    for (final d in ['mon', 'tue', 'wed', 'thu', 'fri']) d: '08:00-17:00',
    'sat': '08:00-13:00',
    'sun': 'closed',
  };
  int _docs = 0;

  void _load(Business? b) {
    if (_loaded) return;
    _loaded = true;
    final session = ref.read(sessionProvider).value;
    if (session?.phone != null) _phone.text = session!.phone!.substring(4);
    if (b == null) return;
    _bizId = b.id;
    _name.text = b.name;
    _desc.text = b.description;
    _logo = b.logoUrl;
    _offers = {...b.offeringTypes};
    _primary = b.primaryCategory;
    _extra = {...b.categories}..remove(b.primaryCategory);
    if (b.phone != null) _phone.text = b.phone!.substring(4);
    if (b.whatsapp != null && b.whatsapp != b.phone) {
      _waSame = false;
      _whatsapp.text = b.whatsapp!.substring(4);
    }
    _email.text = b.email ?? '';
    _address.text = b.addressLine ?? '';
    if (b.location != null) {
      _point = b.location!;
      _pointChosen = true;
      _hood = b.neighbourhood ?? nearestNeighbourhood(b.location!).name;
      _loadExactPin(b.id);
    }
    _precision = b.locationPrecision;
    _radius = b.serviceRadiusKm;
    if (b.operatingHours.isNotEmpty) _hours = {...b.operatingHours};
    _step = b.onboardingStep.clamp(0, 5);
  }

  /// [Business.location] is the public point, which may be rounded to about
  /// 500 m. Start the map on the exact pin so saving never moves the business.
  Future<void> _loadExactPin(String id) async {
    try {
      final p = await ref.read(backendProvider).business.exactLocation(id);
      if (p != null && mounted) {
        setState(() {
          _point = p;
          _pickerGen++;
        });
      }
    } catch (_) {
      // Keep the public point; the vendor can still adjust the pin.
    }
  }

  List<Category> get _relevantCategories =>
      kCategories.where((c) => _offers.contains(c.kind) || (_offers.contains(OfferingType.package))).toList();

  Future<void> _next() async {
    if (!(_forms[_step].currentState?.validate() ?? true)) return;
    final err = _stepError();
    if (err != null) {
      showToast(context, err, icon: LucideIcons.circleAlert);
      return;
    }
    setState(() => _busy = true);
    try {
      final b = ref.read(backendProvider).business;
      _bizId ??= await b.create(_name.text.trim());
      final current = await b.get(_bizId!);
      if (_step == 3) {
        await b.setLocation(_bizId!, _point, _precision, _hood);
      }
      final updated = current.copyWith(
        name: _name.text.trim(),
        description: _desc.text.trim(),
        logoUrl: _logo,
        offeringTypes: _offers,
        primaryCategory: _primary,
        phone: ZambianPhone.normalise(_phone.text),
        whatsapp: _waSame ? ZambianPhone.normalise(_phone.text) : ZambianPhone.normalise(_whatsapp.text),
        email: _email.text.trim().isEmpty ? null : _email.text.trim(),
        addressLine: _address.text.trim().isEmpty ? null : _address.text.trim(),
        serviceRadiusKm: _radius,
        operatingHours: _hours,
        onboardingStep: (_step + 1).clamp(0, 6),
      );
      await b.update(updated);
      if (_step == 1) await b.setCategories(_bizId!, [?_primary, ..._extra]);
      if (_step == 5) {
        ref.read(onboardingCelebrationProvider.notifier).set(true);
        try {
          await b.completeOnboarding(_bizId!);
        } catch (_) {
          ref.read(onboardingCelebrationProvider.notifier).set(false);
          rethrow;
        }
        if (mounted) setState(() => _done = true);
      } else if (mounted) {
        setState(() => _step++);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String? _stepError() => switch (_step) {
        1 when _offers.isEmpty => 'Choose at least one thing you offer.',
        1 when _primary == null => 'Choose your main category.',
        3 when !_pointChosen => 'Move the map to place your business pin.',
        _ => null,
      };

  Future<void> _pickLogo() async {
    final f = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 800, imageQuality: 85);
    if (f == null || !mounted) return;
    final bytes = await f.readAsBytes();
    final b = ref.read(backendProvider).business;
    final id = _bizId ?? await b.create(_name.text.trim().isEmpty ? 'My business' : _name.text.trim());
    _bizId = id;
    if (!mounted) return;
    final path = await guard(context, () => b.uploadLogo(id, bytes, f.name.split('.').last.toLowerCase()));
    if (path != null && mounted) setState(() => _logo = ref.read(backendProvider).photoUrl(path));
  }

  Future<void> _uploadDoc(String type) async {
    final f = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (f == null || !mounted || _bizId == null) return;
    final bytes = await f.readAsBytes();
    if (!mounted) return;
    final ok = await guard(context, () async {
      await ref.read(backendProvider).business.uploadVerificationDocument(_bizId!, type, bytes, f.name.split('.').last.toLowerCase());
      return true;
    }, success: 'Document uploaded');
    if (ok == true && mounted) setState(() => _docs++);
  }

  @override
  Widget build(BuildContext context) {
    final biz = ref.watch(myBusinessProvider);
    if (!biz.hasValue) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    _load(biz.value);
    if (_done) {
      return _Finished(
        name: _name.text.trim(),
        rents: _offers.contains(OfferingType.rental),
        onLeave: () => ref.read(onboardingCelebrationProvider.notifier).set(false),
      );
    }

    return PopScope(
      canPop: _step == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _step > 0) setState(() => _step--);
      },
      child: Scaffold(
        appBar: AppBar(
          leading: _step > 0 ? IconButton(icon: const Icon(LucideIcons.arrowLeft), onPressed: () => setState(() => _step--)) : null,
          automaticallyImplyLeading: false,
          title: Text('Step ${_step + 1} of 6', style: EvType.small),
          actions: [
            TextButton(
              onPressed: () async {
                if (await confirmAction(context, title: 'Sign out?', body: 'Your progress is saved. You can continue setup next time you sign in.')) {
                  await ref.read(backendProvider).auth.signOut();
                }
              },
              child: const Text('Save & exit'),
            ),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: EvSpace.gutter),
              child: Row(children: [
                for (var i = 0; i < 6; i++) ...[
                  if (i > 0) const SizedBox(width: 4),
                  Expanded(
                    child: AnimatedContainer(
                      duration: EvMotion.of(context, EvMotion.base),
                      height: 4,
                      decoration: BoxDecoration(color: i <= _step ? EvColors.forest : EvColors.sand, borderRadius: BorderRadius.circular(2)),
                    ),
                  ),
                ],
              ]),
            ),
          ),
        ),
        body: AnimatedSwitcher(
          duration: EvMotion.of(context, EvMotion.base),
          transitionBuilder: (c, a) => FadeTransition(opacity: a, child: SlideTransition(position: Tween(begin: const Offset(0.04, 0), end: Offset.zero).animate(a), child: c)),
          child: Form(
            key: _forms[_step],
            child: ListView(
              key: ValueKey(_step),
              padding: const EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x5, EvSpace.gutter, 120),
              children: [
                Text(_titles[_step], style: EvType.display),
                const SizedBox(height: EvSpace.x5),
                ..._stepBody(),
              ],
            ),
          ),
        ),
        bottomSheet: Container(
          color: EvColors.cream,
          padding: EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x3, EvSpace.gutter, EvSpace.x3 + MediaQuery.paddingOf(context).bottom),
          child: Row(children: [
            if (_step == 5) ...[
              Expanded(child: EvButton('Skip for now', kind: EvButtonKind.quiet, onPressed: _busy ? null : _next)),
              const SizedBox(width: 12),
            ],
            Expanded(flex: 2, child: EvButton(_step == 5 ? 'Finish setup' : 'Continue', loading: _busy, expand: true, onPressed: _next)),
          ]),
        ),
      ),
    );
  }

  List<Widget> _stepBody() {
    const gap = SizedBox(height: EvSpace.x5);
    switch (_step) {
      case 0:
        return [
          Row(children: [
            GestureDetector(
              onTap: _pickLogo,
              child: Stack(children: [
                BusinessAvatar(name: _name.text.isEmpty ? 'Your business' : _name.text, logoUrl: _logo, size: 72),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.all(5),
                    decoration: BoxDecoration(color: EvColors.forest, shape: BoxShape.circle, border: Border.all(color: EvColors.cream, width: 2)),
                    child: const Icon(LucideIcons.camera, size: 13, color: EvColors.inkOnDark),
                  ),
                ),
              ]),
            ),
            const SizedBox(width: EvSpace.x4),
            Expanded(child: Text('Add your logo so other vendors recognise you. Until then we show your initials.', style: EvType.small)),
          ]),
          gap,
          EvField(
            label: 'Business name',
            controller: _name,
            hint: 'e.g. Kabwata Party Hire',
            textCapitalization: TextCapitalization.words,
            onChanged: (_) => setState(() {}),
            validator: (v) => (v == null || v.trim().length < 2) ? 'Enter your business name' : null,
          ),
          gap,
          EvField(
            label: 'Describe your business',
            controller: _desc,
            hint: 'What you supply, the events you work and what makes you reliable.',
            maxLines: 4,
            minLines: 3,
            maxLength: 1200,
            optional: true,
          ),
        ];
      case 1:
        return [
          Text('Choose everything that applies. Evenda adapts to how you work — service businesses never manage stock.', style: EvType.small),
          const SizedBox(height: EvSpace.x4),
          for (final o in OfferingType.values) ...[
            EvOptionTile(
              title: o.label,
              subtitle: o.hint,
              multi: true,
              icon: switch (o) { OfferingType.rental => LucideIcons.boxes, OfferingType.service => LucideIcons.handshake, OfferingType.package => LucideIcons.packageCheck },
              selected: _offers.contains(o),
              onTap: () => setState(() {
                _offers.contains(o) ? _offers.remove(o) : _offers.add(o);
                if (_primary != null && !_relevantCategories.any((c) => c.id == _primary)) _primary = null;
                _extra.removeWhere((id) => !_relevantCategories.any((c) => c.id == id));
              }),
            ),
            const SizedBox(height: EvSpace.x2),
          ],
          if (_offers.isNotEmpty) ...[
            gap,
            const EvFieldLabel('Main category'),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final c in _relevantCategories)
                EvChip(label: c.name, icon: categoryIcon(c.id), selected: _primary == c.id, onTap: () => setState(() {
                  _primary = c.id;
                  _extra.remove(c.id);
                })),
            ]),
            gap,
            const EvFieldLabel('Also supply', optional: true),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final c in _relevantCategories.where((c) => c.id != _primary))
                EvChip(label: c.name, selected: _extra.contains(c.id), onTap: () => setState(() => _extra.contains(c.id) ? _extra.remove(c.id) : _extra.add(c.id))),
            ]),
          ],
        ];
      case 2:
        return [
          EvPhoneField(controller: _phone, label: 'Business phone', helper: 'Shown to vendors you quote or book with.'),
          const SizedBox(height: EvSpace.x2),
          EvSwitchRow(title: 'Same number for WhatsApp', value: _waSame, onChanged: (v) => setState(() => _waSame = v)),
          if (!_waSame) ...[const SizedBox(height: EvSpace.x2), EvPhoneField(controller: _whatsapp, label: 'WhatsApp number')],
          gap,
          EvField(
            label: 'Email',
            controller: _email,
            hint: 'bookings@yourbusiness.co.zm',
            keyboardType: TextInputType.emailAddress,
            optional: true,
            textCapitalization: TextCapitalization.none,
            validator: (v) => v == null || v.isEmpty || RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(v) ? null : 'Enter a valid email',
          ),
        ];
      case 3:
        return [
          Text('Stand at your yard, shop or studio and tap “Use my location”, then drag the map until the pin sits on your gate. Zoom in for a precise spot. This is used to match nearby suppliers and Evenda Now requests.',
              style: EvType.small),
          const SizedBox(height: EvSpace.x4),
          LocationPicker(
            key: ValueKey(_pickerGen),
            initial: _point,
            height: 300,
            autoLocate: !_pointChosen,
            showPrecision: true,
            pinLabel: _pointChosen ? _hood : 'Your business',
            onChanged: (p, n) => setState(() {
              _point = p;
              _hood = n.name;
              _pointChosen = true;
            }),
          ),
          const SizedBox(height: EvSpace.x3),
          EvPickerField(
            label: 'Neighbourhood',
            value: _hood,
            onTap: () async {
              final n = await pickFromSheet<String>(context, title: 'Neighbourhood', selected: _hood, options: [for (final n in kNeighbourhoods) (n.name, n.name, null)]);
              if (n != null) setState(() => _hood = n);
            },
          ),
          const SizedBox(height: EvSpace.x4),
          EvField(label: 'Street or landmark', controller: _address, hint: 'e.g. Plot 12, off Burma Road', optional: true),
          gap,
          const EvFieldLabel('Who sees your exact location?'),
          for (final p in LocationPrecision.values) ...[
            EvOptionTile(title: p.label, subtitle: p.hint, selected: _precision == p, onTap: () => setState(() => _precision = p)),
            const SizedBox(height: EvSpace.x2),
          ],
          gap,
          EvFieldLabel('Service area: within $_radius km'),
          Slider(value: _radius.toDouble(), min: 5, max: 150, divisions: 29, label: '$_radius km', onChanged: (v) => setState(() => _radius = v.round())),
          Text('Requests from further away won’t be sent to you.', style: EvType.caption),
        ];
      case 4:
        return [
          Text('Other vendors see when you can respond. Evenda Now requests still reach you outside these hours unless you turn them off.', style: EvType.small),
          const SizedBox(height: EvSpace.x4),
          EvSurface(
            padding: EdgeInsets.zero,
            child: Column(children: [
              for (var i = 0; i < 7; i++) ...[
                if (i > 0) const EvDivider(),
                HoursRow(
                  day: _dayNames[i],
                  value: _hours[_days[i]] ?? 'closed',
                  onChanged: (v) => setState(() => _hours[_days[i]] = v),
                ),
              ],
            ]),
          ),
        ];
      default:
        return [
          Text('Verified businesses show a badge and rank higher in supplier search. Upload a document now or later from Business → Profile.', style: EvType.small),
          const SizedBox(height: EvSpace.x4),
          for (final (type, label, hint) in const [
            ('pacra_certificate', 'PACRA certificate', 'Certificate of incorporation or business name registration'),
            ('tpin', 'ZRA TPIN certificate', 'Tax registration'),
            ('national_id', 'Owner’s NRC', 'National registration card of the owner'),
          ]) ...[
            EvSurface(
              padding: EdgeInsets.zero,
              child: EvRow(
                leading: const IconTile(LucideIcons.fileText),
                title: label,
                subtitle: hint,
                trailing: EvButton('Upload', kind: EvButtonKind.secondary, compact: true, onPressed: () => _uploadDoc(type)),
              ),
            ),
            const SizedBox(height: EvSpace.x2),
          ],
          if (_docs > 0) Text('$_docs document${_docs == 1 ? '' : 's'} uploaded. We’ll review after you finish setup.', style: EvType.small.copyWith(color: EvColors.success)),
        ];
    }
  }
}

class HoursRow extends StatelessWidget {
  const HoursRow({super.key, required this.day, required this.value, required this.onChanged});
  final String day;
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final open = value != 'closed';
    final parts = open ? value.split('-') : ['08:00', '17:00'];
    Future<void> pick(int i) async {
      final cur = parts[i].split(':');
      final t = await pickTime(context, initial: TimeOfDay(hour: int.parse(cur[0]), minute: int.parse(cur[1])));
      if (t == null) return;
      final s = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
      onChanged(i == 0 ? '$s-${parts[1]}' : '${parts[0]}-$s');
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: EvSpace.x4, vertical: 6),
      child: Row(children: [
        SizedBox(width: 92, child: Text(day, style: EvType.bodyStrong)),
        if (open) ...[
          TextButton(onPressed: () => pick(0), child: Text(parts[0])),
          Text('–', style: EvType.small),
          TextButton(onPressed: () => pick(1), child: Text(parts[1])),
        ] else
          Text('Closed', style: EvType.small),
        const Spacer(),
        Switch(value: open, onChanged: (v) => onChanged(v ? '08:00-17:00' : 'closed')),
      ]),
    );
  }
}

class _Finished extends StatelessWidget {
  const _Finished({required this.name, required this.rents, required this.onLeave});
  final String name;
  final bool rents;
  final VoidCallback onLeave;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(EvSpace.gutter),
          child: Column(children: [
            const Spacer(),
            const Celebration(size: 140),
            const SizedBox(height: EvSpace.x5),
            Text('$name is on Evenda', style: EvType.display, textAlign: TextAlign.center),
            const SizedBox(height: EvSpace.x3),
            Text(
              rents
                  ? 'Next, add your first listing so other vendors can find your stock.'
                  : 'Next, add a service listing so planners and decorators can quote you.',
              style: EvType.body.copyWith(color: EvColors.ink2),
              textAlign: TextAlign.center,
            ),
            const Spacer(),
            EvButton('Add a listing', expand: true, icon: LucideIcons.plus, onPressed: () {
              onLeave();
              context.go('/home');
              context.push('/business/listings/new?kind=${rents ? 'rental' : 'service'}');
            }),
            const SizedBox(height: EvSpace.x2),
            EvButton('Go to my dashboard', kind: EvButtonKind.quiet, expand: true, onPressed: () {
              onLeave();
              context.go('/home');
            }),
          ]),
        ),
      ),
    );
  }
}
