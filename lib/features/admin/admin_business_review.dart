import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/providers.dart';
import '../../core/format.dart';
import '../../data/backend.dart';
import '../../design/ev.dart';
import '../../domain/models.dart';

final _detailProvider = FutureProvider.autoDispose.family<AdminBusinessDetail, String>((ref, id) {
  ref.watchDomains(const [DataDomain.admin]);
  return ref.watch(backendProvider).admin.businessDetail(id);
});

/// Admin review of one business: who runs it, how to reach them, what they
/// submitted, and every decision taken so far. Verification is a two-step
/// judgement: open and accept (or reject) the documents, then decide.
class AdminBusinessReviewScreen extends ConsumerWidget {
  const AdminBusinessReviewScreen({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(_detailProvider(id));
    final role = ref.watch(adminSessionProvider).value?.role ?? ref.watch(backendProvider).admin.current?.role;
    return Scaffold(
      appBar: AppBar(title: const Text('Business review'), centerTitle: false),
      body: AsyncView<AdminBusinessDetail>(
        value: detail,
        onRetry: () => ref.invalidate(_detailProvider(id)),
        data: (d) => _Body(d: d, canVerify: role?.can('business.verify') ?? false, onChanged: () => ref.invalidate(_detailProvider(id))),
      ),
      bottomNavigationBar: detail.value == null || !(role?.can('business.verify') ?? false)
          ? null
          : _DecisionBar(d: detail.value!, onChanged: () => ref.invalidate(_detailProvider(id))),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.d, required this.canVerify, required this.onChanged});
  final AdminBusinessDetail d;
  final bool canVerify;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final backend = ref.read(backendProvider);
    final owner = d.owner;
    final c = d.counts;
    String n(String k) => '${(c[k] as num?)?.toInt() ?? 0}';

    return ListView(padding: const EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x2, EvSpace.gutter, EvSpace.x10), children: [
      // Identity
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        BusinessAvatar(name: d.name, logoUrl: d.logoPath == null ? null : backend.photoUrl(d.logoPath!), size: 64, verified: d.verification == VerificationStatus.verified),
        const SizedBox(width: EvSpace.x4),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(d.name, style: EvType.title),
            const SizedBox(height: 4),
            Text('${categoryById(d.primaryCategory).name} · ${d.neighbourhood ?? 'No area set'}', style: EvType.small),
            const SizedBox(height: 8),
            Wrap(spacing: 6, runSpacing: 6, children: [
              StatusPill(d.verification.label, tone: toneForVerification(d.verification), dense: true),
              if (d.status == BusinessStatus.suspended) const StatusPill('Suspended', tone: Tone.critical, dense: true),
              if (!d.onboarded) const StatusPill('Onboarding unfinished', tone: Tone.waiting, dense: true),
            ]),
          ]),
        ),
      ]),
      if (d.description.isNotEmpty) ...[const SizedBox(height: EvSpace.x4), Text(d.description, style: EvType.body)],

      // Documents first: this is what the admin is here to judge.
      SectionHeader('Verification documents', count: d.documents.length, padding: const EdgeInsets.fromLTRB(0, EvSpace.x6, 0, EvSpace.x2)),
      if (d.documents.isEmpty)
        EvSurface(
          color: EvColors.warningTint,
          child: Text('No documents uploaded. The business cannot be verified until it submits a PACRA certificate, TPIN or ID.',
              style: EvType.small.copyWith(color: EvColors.warning)),
        )
      else
        for (final doc in d.documents) ...[
          _DocumentCard(doc: doc, canReview: canVerify, onChanged: onChanged),
          const SizedBox(height: EvSpace.x2),
        ],

      // Owner and contact
      const SectionHeader('Owner & contact', padding: EdgeInsets.fromLTRB(0, EvSpace.x6, 0, EvSpace.x2)),
      EvSurface(
        padding: EdgeInsets.zero,
        child: Column(children: [
          _Fact(LucideIcons.user, 'Owner', '${owner['name'] ?? ''}'.isEmpty ? '—' : owner['name']),
          _Fact(LucideIcons.atSign, 'Account email', '${owner['email'] ?? '—'}${owner['email_confirmed'] == true ? '  ✓ confirmed' : ''}'),
          if (owner['joined_at'] != null) _Fact(LucideIcons.calendarClock, 'Joined', EvDates.day(DateTime.parse(owner['joined_at']).toLocal())),
          _Fact(LucideIcons.phone, 'Business phone', ZambianPhone.display(d.phone).isEmpty ? '—' : ZambianPhone.display(d.phone),
              action: d.phone == null ? null : () => launchUrl(Uri.parse('tel:${d.phone}'))),
          _Fact(LucideIcons.messageCircle, 'WhatsApp', ZambianPhone.display(d.whatsapp).isEmpty ? '—' : ZambianPhone.display(d.whatsapp),
              action: d.whatsapp == null
                  ? null
                  : () => launchUrl(Uri.parse('https://wa.me/${ZambianPhone.waDigits(d.whatsapp!)}?text=${Uri.encodeComponent('Hello from the Evenda team about ${d.name}.')}'),
                      mode: LaunchMode.externalApplication)),
          if (d.email != null)
            _Fact(LucideIcons.mail, 'Business email', d.email!, action: () => launchUrl(Uri.parse('mailto:${d.email}?subject=${Uri.encodeComponent('Evenda: ${d.name}')}'))),
        ]),
      ),

      // Location
      const SectionHeader('Location', padding: EdgeInsets.fromLTRB(0, EvSpace.x6, 0, EvSpace.x2)),
      EvSurface(
        padding: EdgeInsets.zero,
        child: Column(children: [
          _Fact(LucideIcons.mapPin, 'Area', [d.neighbourhood, d.addressLine].whereType<String>().where((s) => s.isNotEmpty).join(' · ').ifEmpty('—')),
          _Fact(LucideIcons.radar, 'Serves within', '${d.serviceRadiusKm} km'),
          if (d.lat != null)
            _Fact(LucideIcons.crosshair, 'Exact pin', '${d.lat!.toStringAsFixed(5)}, ${d.lng!.toStringAsFixed(5)}',
                action: () => launchUrl(Uri.parse('https://www.google.com/maps/search/?api=1&query=${d.lat},${d.lng}'), mode: LaunchMode.externalApplication)),
        ]),
      ),

      // Activity
      const SectionHeader('Activity', padding: EdgeInsets.fromLTRB(0, EvSpace.x6, 0, EvSpace.x2)),
      Wrap(spacing: 8, runSpacing: 8, children: [
        _Count('Listings', n('listings'), sub: '${n('published_listings')} published'),
        _Count('Bookings as supplier', n('bookings_as_supplier')),
        _Count('Bookings as hirer', n('bookings_as_requester')),
        _Count('Disputes', n('disputes'), alert: n('disputes') != '0'),
        _Count('Moderated listings', n('flagged_listings'), alert: n('flagged_listings') != '0'),
      ]),

      if (d.team.isNotEmpty) ...[
        SectionHeader('Team', count: d.team.length, padding: const EdgeInsets.fromLTRB(0, EvSpace.x6, 0, EvSpace.x2)),
        EvSurface(
          padding: EdgeInsets.zero,
          child: Column(children: [
            for (final t in d.team)
              _Fact(LucideIcons.users, '${t['role']}'.capitalized, '${t['name'] ?? ''}'.ifEmpty('Invited member')),
          ]),
        ),
      ],

      SectionHeader('Decision history', count: d.history.length, padding: const EdgeInsets.fromLTRB(0, EvSpace.x6, 0, EvSpace.x2)),
      if (d.history.isEmpty)
        Text('No admin decisions yet.', style: EvType.small)
      else
        for (final h in d.history)
          Padding(
            padding: const EdgeInsets.only(bottom: EvSpace.x3),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Padding(padding: EdgeInsets.only(top: 2), child: Icon(LucideIcons.history, size: 15, color: EvColors.ink3)),
              const SizedBox(width: 8),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_historyLabel(h), style: EvType.smallStrong),
                  if ('${h['reason'] ?? ''}'.isNotEmpty) Text('“${h['reason']}”', style: EvType.small),
                  Text('${'${h['by'] ?? ''}'.ifEmpty('Admin')} · ${EvDates.dayTime(DateTime.parse(h['at']).toLocal())}', style: EvType.caption),
                ]),
              ),
            ]),
          ),
    ]);
  }

  static String _historyLabel(Map<String, dynamic> h) {
    final after = (h['after'] as Map?) ?? const {};
    return switch (h['action']) {
      'business.verification' => 'Verification set to ${'${after['verification_status']}'.replaceAll('_', ' ')}',
      'business.status' => 'Account ${after['status'] == 'suspended' ? 'suspended' : 'reactivated'}',
      'document.review' => 'Document ${after['status']}',
      final a => '$a',
    };
  }
}

class _DocumentCard extends ConsumerStatefulWidget {
  const _DocumentCard({required this.doc, required this.canReview, required this.onChanged});
  final AdminDocument doc;
  final bool canReview;
  final VoidCallback onChanged;

  @override
  ConsumerState<_DocumentCard> createState() => _DocumentCardState();
}

class _DocumentCardState extends ConsumerState<_DocumentCard> {
  bool _opening = false;

  Future<void> _open() async {
    setState(() => _opening = true);
    final url = await guard(context, () => ref.read(backendProvider).admin.documentUrl(widget.doc.storagePath));
    if (mounted) setState(() => _opening = false);
    if (url == null || !mounted) return;
    if (widget.doc.isPdf) {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } else {
      await Navigator.of(context).push(MaterialPageRoute(fullscreenDialog: true, builder: (_) => _ImageViewer(url: url, title: widget.doc.typeLabel)));
    }
  }

  Future<void> _review(String status) async {
    final accepting = status == 'accepted';
    final note = await confirmWithReason(
      context,
      title: accepting ? 'Accept this ${widget.doc.typeLabel}?' : 'Reject this ${widget.doc.typeLabel}?',
      body: accepting
          ? 'Only accept it if you opened it and it is genuine, legible, current and matches this business. Add a note (optional).'
          : 'Say what is wrong so the vendor can fix it, e.g. "Blurry, name not readable" or "Registered name does not match".',
      confirm: accepting ? 'Accept' : 'Reject',
      required: !accepting,
      destructive: !accepting,
    );
    if (note == null || !mounted) return;
    final ok = await guard(context, () async {
      await ref.read(backendProvider).admin.reviewDocument(widget.doc.id, status, note);
      return true;
    }, success: accepting ? 'Document accepted' : 'Document rejected');
    if (ok == true) widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final doc = widget.doc;
    final (label, tone) = switch (doc.status) {
      'accepted' => ('Accepted', Tone.positive),
      'rejected' => ('Rejected', Tone.critical),
      _ => ('Not reviewed', Tone.waiting),
    };
    return EvSurface(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          IconTile(doc.isPdf ? LucideIcons.fileText : LucideIcons.fileImage),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(doc.typeLabel, style: EvType.bodyStrong),
              Text('Uploaded ${EvDates.day(doc.createdAt)} · ${doc.isPdf ? 'PDF' : 'Photo'}', style: EvType.caption),
            ]),
          ),
          StatusPill(label, tone: tone, dense: true),
        ]),
        if (doc.reviewNote != null || doc.reviewedAt != null) ...[
          const SizedBox(height: 8),
          Text(
            [
              if (doc.reviewNote != null) '“${doc.reviewNote}”',
              if (doc.reviewedAt != null) '${(doc.reviewedBy ?? '').ifEmpty('Admin')}, ${EvDates.day(doc.reviewedAt!)}',
            ].join(' — '),
            style: EvType.caption,
          ),
        ],
        const SizedBox(height: EvSpace.x3),
        EvButton(doc.isPdf ? 'Open PDF' : 'View document', kind: EvButtonKind.secondary, icon: LucideIcons.eye, expand: true, loading: _opening, onPressed: _open),
        if (widget.canReview) ...[
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: EvButton('Reject', kind: EvButtonKind.danger, icon: LucideIcons.x, expand: true,
                  onPressed: doc.status == 'rejected' ? null : () => _review('rejected')),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: EvButton('Accept', icon: LucideIcons.check, expand: true, onPressed: doc.status == 'accepted' ? null : () => _review('accepted')),
            ),
          ]),
        ],
      ]),
    );
  }
}

/// Full-screen, zoomable document photo. Pinch to read small print.
class _ImageViewer extends StatelessWidget {
  const _ImageViewer({required this.url, required this.title});
  final String url;
  final String title;

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white, title: Text(title), centerTitle: false),
        body: InteractiveViewer(
          maxScale: 6,
          child: Center(
            child: Image.network(
              url,
              loadingBuilder: (c, child, p) => p == null ? child : const Center(child: CircularProgressIndicator(color: Colors.white)),
              errorBuilder: (c, e, s) => Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Could not load the document. Check the connection and open it again.', style: EvType.body.copyWith(color: Colors.white), textAlign: TextAlign.center),
              ),
            ),
          ),
        ),
      );
}

/// Verify / reject / suspend, pinned to the bottom of the review.
class _DecisionBar extends ConsumerWidget {
  const _DecisionBar({required this.d, required this.onChanged});
  final AdminBusinessDetail d;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.read(backendProvider).admin;
    final verified = d.verification == VerificationStatus.verified;
    final suspended = d.status == BusinessStatus.suspended;

    Future<void> setVerification(VerificationStatus s) async {
      final reason = await confirmWithReason(
        context,
        title: s == VerificationStatus.verified ? 'Verify ${d.name}?' : 'Reject verification?',
        body: s == VerificationStatus.verified
            ? 'Other vendors will see the verified badge. The business is notified and your note goes in the audit log.'
            : 'The business is notified with your reason so they can upload better documents.',
        confirm: s == VerificationStatus.verified ? 'Verify' : 'Reject',
        required: s != VerificationStatus.verified,
        destructive: s != VerificationStatus.verified,
      );
      if (reason == null || !context.mounted) return;
      final ok = await guard(context, () async {
        await api.setVerification(d.id, s, reason);
        return true;
      }, success: 'Recorded in audit log');
      if (ok == true) onChanged();
    }

    Future<void> setStatus() async {
      final reason = await confirmWithReason(
        context,
        title: suspended ? 'Reactivate ${d.name}?' : 'Suspend ${d.name}?',
        body: suspended ? 'They can list, quote and book again.' : 'Their listings disappear from search and they cannot transact until reactivated.',
        confirm: suspended ? 'Reactivate' : 'Suspend',
        destructive: !suspended,
      );
      if (reason == null || !context.mounted) return;
      final ok = await guard(context, () async {
        await api.setBusinessStatus(d.id, suspended ? BusinessStatus.active : BusinessStatus.suspended, reason);
        return true;
      }, success: 'Recorded in audit log');
      if (ok == true) onChanged();
    }

    return Container(
      decoration: const BoxDecoration(color: EvColors.warmWhite, border: Border(top: BorderSide(color: EvColors.sand))),
      padding: EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x3, EvSpace.gutter, EvSpace.x3 + MediaQuery.paddingOf(context).bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (!verified && !d.hasAcceptedDocument)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text('Open and accept at least one document to enable Verify.', style: EvType.caption, textAlign: TextAlign.center),
          ),
        Row(children: [
          Expanded(
            child: EvButton(suspended ? 'Reactivate' : 'Suspend', kind: suspended ? EvButtonKind.secondary : EvButtonKind.quiet,
                icon: suspended ? LucideIcons.rotateCcw : LucideIcons.ban, expand: true, onPressed: setStatus),
          ),
          const SizedBox(width: 8),
          if (d.verification != VerificationStatus.rejected)
            Expanded(
              child: EvButton('Reject', kind: EvButtonKind.secondary, expand: true, onPressed: () => setVerification(VerificationStatus.rejected)),
            ),
          if (d.verification != VerificationStatus.rejected) const SizedBox(width: 8),
          Expanded(
            child: EvButton(verified ? 'Verified' : 'Verify', icon: LucideIcons.badgeCheck, expand: true,
                onPressed: verified || !d.hasAcceptedDocument ? null : () => setVerification(VerificationStatus.verified)),
          ),
        ]),
      ]),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact(this.icon, this.label, this.value, {this.action});
  final IconData icon;
  final String label;
  final String value;
  final VoidCallback? action;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: action,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: EvSpace.x4, vertical: 12),
          child: Row(children: [
            Icon(icon, size: 18, color: EvColors.ink3),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, style: EvType.caption),
                Text(value, style: EvType.body),
              ]),
            ),
            if (action != null) const Icon(LucideIcons.externalLink, size: 16, color: EvColors.forest),
          ]),
        ),
      );
}

class _Count extends StatelessWidget {
  const _Count(this.label, this.value, {this.sub, this.alert = false});
  final String label;
  final String value;
  final String? sub;
  final bool alert;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: (MediaQuery.sizeOf(context).width - 2 * EvSpace.gutter - 8) / 2,
        child: EvSurface(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: EvType.caption, maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(value, style: EvType.number.copyWith(color: alert ? EvColors.danger : EvColors.ink)),
            if (sub != null) Text(sub!, style: EvType.caption),
          ]),
        ),
      );
}

extension on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
  String get capitalized => isEmpty ? this : '${this[0].toUpperCase()}${substring(1)}';
}

/// Opens the review screen (used from the Businesses list and Listings).
void openBusinessReview(BuildContext context, String id) => context.push('/admin/business/$id');
