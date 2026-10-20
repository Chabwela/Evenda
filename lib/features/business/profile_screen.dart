import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../app/providers.dart';
import '../../core/format.dart';
import '../../design/ev.dart';
import '../../domain/models.dart';
import '../onboarding/onboarding_screen.dart';
import '../shared/map_widgets.dart';

/// Business settings: identity, offering, contact, location, hours, verification.
class BusinessProfileScreen extends ConsumerStatefulWidget {
  const BusinessProfileScreen({super.key});
  @override
  ConsumerState<BusinessProfileScreen> createState() => _BusinessProfileScreenState();
}

class _BusinessProfileScreenState extends ConsumerState<BusinessProfileScreen> {
  static const _days = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
  static const _dayNames = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
  final _form = GlobalKey<FormState>();
  Business? _b;
  final _name = TextEditingController();
  final _desc = TextEditingController();
  final _phone = TextEditingController();
  final _wa = TextEditingController();
  final _email = TextEditingController();
  final _address = TextEditingController();
  LatLng? _point;
  String? _hood;
  bool _locationChanged = false;
  bool _busy = false;
  int _pickerGen = 0; // bumped when the exact pin arrives, to re-centre the map

  void _init(Business b) {
    if (_b != null) return;
    _b = b;
    _name.text = b.name;
    _desc.text = b.description;
    _phone.text = b.phone?.substring(4) ?? '';
    _wa.text = b.whatsapp?.substring(4) ?? '';
    _email.text = b.email ?? '';
    _address.text = b.addressLine ?? '';
    _point = b.location;
    _hood = b.neighbourhood;
    _loadExactPin(b.id);
  }

  /// [Business.location] may be rounded for other vendors; edit the exact pin,
  /// or changing only the privacy setting would save the rounded point.
  Future<void> _loadExactPin(String id) async {
    try {
      final p = await ref.read(backendProvider).business.exactLocation(id);
      if (p != null && mounted) {
        setState(() {
          _point = p;
          _pickerGen++;
        });
      }
    } catch (_) {}
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final b = _b!;
    setState(() => _busy = true);
    final api = ref.read(backendProvider).business;
    await guard(context, () async {
      await api.update(b.copyWith(
        name: _name.text.trim(),
        description: _desc.text.trim(),
        phone: ZambianPhone.normalise(_phone.text),
        whatsapp: ZambianPhone.normalise(_wa.text),
        email: _email.text.trim().isEmpty ? null : _email.text.trim(),
        addressLine: _address.text.trim().isEmpty ? null : _address.text.trim(),
      ));
      await api.setCategories(b.id, [if (b.primaryCategory != null) b.primaryCategory!, ...b.categories.where((c) => c != b.primaryCategory)]);
      if (_locationChanged && _point != null) await api.setLocation(b.id, _point!, b.locationPrecision, _hood ?? nearestNeighbourhood(_point!).name);
      // Fresh server copy, so the next save compares against this version.
      _b = await api.get(b.id);
      _locationChanged = false;
    }, success: 'Profile saved');
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _changeLogo() async {
    final f = (await pickPhotos(context, title: 'Business logo', maxWidth: 800, imageQuality: 85)).firstOrNull;
    if (f == null || !mounted) return;
    final bytes = await f.readAsBytes();
    if (!mounted) return;
    final backend = ref.read(backendProvider);
    await guard(context, () async {
      final path = await backend.business.uploadLogo(_b!.id, bytes, f.name.split('.').last.toLowerCase());
      // Save only the logo, on top of the server copy, so unsaved form edits stay in the form.
      final current = await backend.business.get(_b!.id);
      final url = backend.photoUrl(path);
      await backend.business.update(current.copyWith(logoUrl: url));
      // Keep the form's snapshot in step (logo and server version), or the
      // next "Save" would restore the old logo or be refused as out of date.
      final fresh = await backend.business.get(_b!.id);
      _b = _b!.copyWith(logoUrl: fresh.logoUrl).withVersionOf(fresh);
    }, success: 'Logo updated');
  }

  Future<void> _uploadDoc() async {
    final type = await pickFromSheet<String>(context, title: 'Document type', options: const [
      ('pacra_certificate', 'PACRA certificate', null),
      ('tpin', 'ZRA TPIN certificate', null),
      ('national_id', 'Owner’s NRC', null),
      ('other', 'Other', null),
    ]);
    if (type == null || !mounted) return;
    final doc = await pickDocument(context);
    if (doc == null || !mounted) return;
    await guard(context, () => ref.read(backendProvider).business.uploadVerificationDocument(_b!.id, type, doc.bytes, doc.ext),
        success: 'Uploaded. Submit for review when you’re ready.');
  }

  @override
  Widget build(BuildContext context) {
    final biz = ref.watch(myBusinessProvider).value;
    if (biz == null) return const Scaffold(body: Skeleton());
    _init(biz);
    final b = _b!;
    final cats = kCategories.where((c) => b.offeringTypes.contains(c.kind) || b.offeringTypes.contains(OfferingType.package)).toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Business profile')),
      body: Form(
        key: _form,
        child: ListView(padding: const EdgeInsets.fromLTRB(EvSpace.gutter, 0, EvSpace.gutter, 120), children: [
          Row(children: [
            Semantics(
              button: true,
              label: 'Change logo',
              child: InkWell(
                onTap: _changeLogo,
                borderRadius: BorderRadius.circular(20),
                child: Stack(clipBehavior: Clip.none, children: [
                  BusinessAvatar(name: b.name, logoUrl: biz.logoUrl, size: 64, verified: biz.verified),
                  Positioned(
                    right: -4,
                    bottom: -4,
                    child: Container(
                      padding: const EdgeInsets.all(5),
                      decoration: BoxDecoration(color: EvColors.forest, shape: BoxShape.circle, border: Border.all(color: EvColors.cream, width: 2)),
                      child: const Icon(LucideIcons.camera, size: 13, color: EvColors.inkOnDark),
                    ),
                  ),
                ]),
              ),
            ),
            const SizedBox(width: EvSpace.x4),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                StatusPill(biz.verification.label, tone: toneForVerification(biz.verification)),
                const SizedBox(height: 6),
                Text(switch (biz.verification) {
                  VerificationStatus.verified => 'Shown with a verified badge in search.',
                  VerificationStatus.pending => 'Documents are with the Evenda team for review.',
                  VerificationStatus.rejected => 'Please upload clearer or current documents.',
                  VerificationStatus.unverified => 'Upload a registration document to get verified.',
                }, style: EvType.small),
              ]),
            ),
          ]),
          if (biz.verification == VerificationStatus.unverified || biz.verification == VerificationStatus.rejected) ...[
            const SizedBox(height: EvSpace.x3),
            // Stacked: side by side, both labels were cut off on 360 dp phones.
            EvButton('Upload document', kind: EvButtonKind.secondary, icon: LucideIcons.fileUp, expand: true, onPressed: _uploadDoc),
            const SizedBox(height: 8),
            EvButton('Submit for review', icon: LucideIcons.shieldCheck, expand: true,
                onPressed: () => guard(context, () => ref.read(backendProvider).business.submitForVerification(b.id), success: 'Submitted for verification')),
          ],
          const SectionHeader('Identity', padding: EdgeInsets.fromLTRB(0, EvSpace.x6, 0, EvSpace.x2)),
          EvField(label: 'Business name', controller: _name, validator: (v) => (v == null || v.trim().length < 2) ? 'Required' : null),
          const SizedBox(height: EvSpace.x4),
          EvField(label: 'Description', controller: _desc, maxLines: 5, minLines: 3, maxLength: 1200, optional: true),
          const SizedBox(height: EvSpace.x4),
          const EvFieldLabel('What you offer'),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final o in OfferingType.values)
              EvChip(label: o.label, selected: b.offeringTypes.contains(o), onTap: () => setState(() {
                final s = {...b.offeringTypes};
                s.contains(o) ? s.remove(o) : s.add(o);
                if (s.isNotEmpty) _b = b.copyWith(offeringTypes: s);
              })),
          ]),
          const SizedBox(height: EvSpace.x4),
          const EvFieldLabel('Categories (tap twice for main)'),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final c in cats)
              EvChip(
                label: c.id == b.primaryCategory ? '${c.name} · main' : c.name,
                icon: c.id == b.primaryCategory ? LucideIcons.star : null,
                selected: b.categories.contains(c.id) || c.id == b.primaryCategory,
                onTap: () => setState(() {
                  final list = [...b.categories];
                  if (c.id == b.primaryCategory) return;
                  if (list.contains(c.id)) {
                    _b = b.copyWith(primaryCategory: c.id);
                  } else {
                    list.add(c.id);
                    _b = b.copyWith(categories: list);
                  }
                }),
              ),
          ]),
          const SectionHeader('Contact', padding: EdgeInsets.fromLTRB(0, EvSpace.x6, 0, EvSpace.x2)),
          EvPhoneField(controller: _phone, label: 'Business phone'),
          const SizedBox(height: EvSpace.x4),
          EvPhoneField(controller: _wa, label: 'WhatsApp', optional: true),
          const SizedBox(height: EvSpace.x4),
          EvField(label: 'Email', controller: _email, optional: true, keyboardType: TextInputType.emailAddress, textCapitalization: TextCapitalization.none),
          const SectionHeader('Location', padding: EdgeInsets.fromLTRB(0, EvSpace.x6, 0, EvSpace.x2)),
          LocationPicker(
            key: ValueKey(_pickerGen),
            initial: _point ?? kLusakaCentre,
            height: 260,
            showPrecision: true,
            pinLabel: _hood,
            onChanged: (p, n) => setState(() {
              _point = p;
              _hood = n.name;
              _locationChanged = true;
            }),
          ),
          const SizedBox(height: EvSpace.x3),
          EvField(label: 'Street or landmark', controller: _address, optional: true),
          const SizedBox(height: EvSpace.x4),
          for (final p in LocationPrecision.values) ...[
            EvOptionTile(title: p.label, subtitle: p.hint, selected: b.locationPrecision == p, onTap: () => setState(() {
              _b = b.copyWith(locationPrecision: p);
              _locationChanged = true;
            })),
            const SizedBox(height: 6),
          ],
          const SizedBox(height: EvSpace.x2),
          EvFieldLabel('Service area: within ${b.serviceRadiusKm} km'),
          Slider(value: b.serviceRadiusKm.toDouble().clamp(5, 150), min: 5, max: 150, divisions: 29, label: '${b.serviceRadiusKm} km',
              onChanged: (v) => setState(() => _b = b.copyWith(serviceRadiusKm: v.round()))),
          const SectionHeader('Opening hours', padding: EdgeInsets.fromLTRB(0, EvSpace.x6, 0, EvSpace.x2)),
          EvSurface(
            padding: EdgeInsets.zero,
            child: Column(children: [
              for (var i = 0; i < 7; i++) ...[
                if (i > 0) const EvDivider(),
                HoursRow(
                  day: _dayNames[i],
                  value: b.operatingHours[_days[i]] ?? 'closed',
                  onChanged: (v) => setState(() => _b = b.copyWith(operatingHours: {...b.operatingHours, _days[i]: v})),
                ),
              ],
            ]),
          ),
        ]),
      ),
      bottomSheet: Container(
        color: EvColors.warmWhite,
        padding: EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x3, EvSpace.gutter, EvSpace.x3 + MediaQuery.paddingOf(context).bottom),
        child: EvButton('Save changes', expand: true, loading: _busy, onPressed: _save),
      ),
    );
  }
}
