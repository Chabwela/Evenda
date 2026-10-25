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

/// Where a verification stands, from the admin's side: whose move it is.
enum _Stage {
  notSubmitted('Not sent for review yet', Tone.neutral),
  toReview('Documents to review', Tone.waiting),
  readyToVerify('Ready to verify', Tone.positive),
  waitingVendor('Waiting for the vendor', Tone.progress),
  sentBack('Sent back to the vendor', Tone.critical),
  verified('Verified business', Tone.positive);

  const _Stage(this.label, this.tone);
  final String label;
  final Tone tone;
}

/// Documents grouped for review: the newest upload of each type is what's
/// being judged; older ones (replaced or turned down) are history.
class _Docs {
  _Docs(List<AdminDocument> all) {
    final sorted = [...all]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    for (final d in sorted) {
      if (current.any((c) => c.docType == d.docType)) {
        earlier.add(d);
      } else {
        current.add(d);
      }
    }
  }
  final current = <AdminDocument>[];
  final earlier = <AdminDocument>[];

  /// A newer upload of a type that already had one (the vendor replaced it).
  bool isReplacement(AdminDocument d) => earlier.any((e) => e.docType == d.docType);
  int get toReview => current.where((d) => d.status == 'submitted').length;
}

_Stage _stageOf(AdminBusinessDetail d, _Docs docs) => switch (d.verification) {
      VerificationStatus.verified => _Stage.verified,
      VerificationStatus.rejected => _Stage.sentBack,
      VerificationStatus.unverified => _Stage.notSubmitted,
      VerificationStatus.pending when docs.toReview > 0 => _Stage.toReview,
      VerificationStatus.pending when d.hasAcceptedDocument => _Stage.readyToVerify,
      VerificationStatus.pending when docs.current.isNotEmpty => _Stage.waitingVendor,
      VerificationStatus.pending => _Stage.notSubmitted,
    };

/// The last reason given when verification was sent back (from the audit trail).
String? _lastSendBackReason(AdminBusinessDetail d) {
  for (final h in d.history) {
    if (h['action'] == 'business.verification' && (h['after'] as Map?)?['verification_status'] == 'rejected') {
      final r = '${h['reason'] ?? ''}'.trim();
      return r.isEmpty ? null : r;
    }
  }
  return null;
}

/// Admin review of one business. It answers "whose move is it?" first, puts
/// the documents being judged next (the newest of each type; replaced ones
/// fold away), then who the business is. Verification is two steps: accept
/// (or reject) the documents, then verify or send it back to the vendor.
class AdminBusinessReviewScreen extends ConsumerWidget {
  const AdminBusinessReviewScreen({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(_detailProvider(id));
    final role = ref.watch(adminSessionProvider).value?.role ?? ref.watch(backendProvider).admin.current?.role;
    final canVerify = role?.can('business.verify') ?? false;
    final d = detail.value;
    void changed() => ref.invalidate(_detailProvider(id));
    return Scaffold(
      appBar: AppBar(
        title: const Text('Business review'),
        centerTitle: false,
        actions: [if (d != null && canVerify) _MoreMenu(d: d, onChanged: changed)],
      ),
      body: AsyncView<AdminBusinessDetail>(
        value: detail,
        onRetry: changed,
        data: (d) => _Body(d: d, canVerify: canVerify, onChanged: changed),
      ),
      bottomNavigationBar: d == null || !canVerify ? null : _DecisionBar(d: d, onChanged: changed),
    );
  }
}

/// Verify or send back, with the reason the vendor will see.
Future<void> _setVerification(BuildContext context, WidgetRef ref, AdminBusinessDetail d, VerificationStatus s, VoidCallback onChanged) async {
  final verify = s == VerificationStatus.verified;
  final revoke = d.verification == VerificationStatus.verified && !verify;
  final reason = await confirmWithReason(
    context,
    title: verify ? 'Verify ${d.name}?' : (revoke ? 'Revoke verification?' : 'Send back to the vendor?'),
    body: verify
        ? 'Other vendors will see the verified badge. The business is notified and your note goes in the audit log.'
        : 'Say what to fix. The vendor sees this on their profile and can upload new documents and send it again.',
    confirm: verify ? 'Verify' : (revoke ? 'Revoke' : 'Send back'),
    required: !verify,
    destructive: !verify,
  );
  if (reason == null || !context.mounted) return;
  final ok = await guard(context, () async {
    await ref.read(backendProvider).admin.setVerification(d.id, s, reason);
    return true;
  }, success: verify ? 'Business verified' : 'Sent back to the vendor');
  if (ok == true) onChanged();
}

/// Rare, serious actions live here, away from the everyday decision.
class _MoreMenu extends ConsumerWidget {
  const _MoreMenu({required this.d, required this.onChanged});
  final AdminBusinessDetail d;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final suspended = d.status == BusinessStatus.suspended;
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
        await ref.read(backendProvider).admin.setBusinessStatus(d.id, suspended ? BusinessStatus.active : BusinessStatus.suspended, reason);
        return true;
      }, success: suspended ? 'Account reactivated' : 'Account suspended');
      if (ok == true) onChanged();
    }

    return PopupMenuButton<String>(
      tooltip: 'More actions',
      icon: const Icon(LucideIcons.ellipsisVertical),
      onSelected: (v) => switch (v) {
        'revoke' => _setVerification(context, ref, d, VerificationStatus.rejected, onChanged),
        _ => setStatus(),
      },
      itemBuilder: (_) => [
        if (d.verification == VerificationStatus.verified) const PopupMenuItem(value: 'revoke', child: Text('Revoke verification')),
        PopupMenuItem(
          value: 'status',
          child: Text(suspended ? 'Reactivate account' : 'Suspend account', style: TextStyle(color: suspended ? EvColors.ink : EvColors.danger)),
        ),
      ],
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
    int n(String k) => (c[k] as num?)?.toInt() ?? 0;
    final docs = _Docs(d.documents);
    final stage = _stageOf(d, docs);
    final sentBackReason = stage == _Stage.sentBack ? _lastSendBackReason(d) : null;

    const section = EdgeInsets.fromLTRB(0, EvSpace.x6, 0, EvSpace.x2);
    return ListView(padding: const EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x2, EvSpace.gutter, EvSpace.x10), children: [
      // Identity
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        BusinessAvatar(name: d.name, logoUrl: d.logoPath == null ? null : backend.photoUrl(d.logoPath!), size: 56, verified: d.verification == VerificationStatus.verified),
        const SizedBox(width: EvSpace.x3),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(d.name, style: EvType.title),
            const SizedBox(height: 2),
            Text('${categoryById(d.primaryCategory).name} · ${d.neighbourhood ?? 'No area set'} · joined ${EvDates.dayShort(d.createdAt)}', style: EvType.small),
            if (d.status == BusinessStatus.suspended || !d.onboarded) ...[
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 6, children: [
                if (d.status == BusinessStatus.suspended) const StatusPill('Suspended', tone: Tone.critical, dense: true),
                if (!d.onboarded) const StatusPill('Onboarding unfinished', tone: Tone.waiting, dense: true),
              ]),
            ],
          ]),
        ),
      ]),

      // Whose move it is, in one line.
      const SizedBox(height: EvSpace.x4),
      _StageLine(stage: stage, docs: docs, sentBackReason: sentBackReason),
      if (d.description.isNotEmpty) ...[const SizedBox(height: EvSpace.x4), Text(d.description, style: EvType.body.copyWith(color: EvColors.ink2))],

      // Documents first: this is what the admin is here to judge.
      SectionHeader('Documents', count: docs.current.length, padding: section),
      if (docs.current.isEmpty)
        Text('No documents uploaded yet. The business can’t be verified until it sends a PACRA certificate, TPIN or ID.', style: EvType.small)
      else
        for (final doc in docs.current) ...[
          _DocumentCard(doc: doc, replacement: docs.isReplacement(doc), canReview: canVerify, onChanged: onChanged),
          const SizedBox(height: EvSpace.x2),
        ],
      if (docs.earlier.isNotEmpty) _EarlierUploads(docs: docs.earlier),

      // Activity: what the business has done on Evenda, on the page.
      const SectionHeader('Activity', padding: section),
      EvStatRow(padding: EdgeInsets.zero, stats: [
        EvStat('Listings · ${n('published_listings')} live', '${n('listings')}'),
        EvStat('Bookings · supplier / hirer', '${n('bookings_as_supplier')} / ${n('bookings_as_requester')}'),
        EvStat('Disputes', '${n('disputes')}', alert: n('disputes') > 0),
      ]),
      if (n('flagged_listings') > 0)
        Padding(
          padding: const EdgeInsets.only(top: EvSpace.x2),
          child: Text('${plural(n('flagged_listings'), 'listing')} under moderation', style: EvType.small.copyWith(color: EvColors.danger)),
        ),

      // Owner and contact
      const SectionHeader('Owner & contact', padding: section),
      EvSurface(
        padding: EdgeInsets.zero,
        child: Column(children: [
          _Fact(LucideIcons.user, 'Owner', '${owner['name'] ?? ''}'.isEmpty ? '—' : owner['name']),
          _Fact(LucideIcons.atSign, 'Account email', '${owner['email'] ?? '—'}',
              note: owner['email_confirmed'] == true ? ('Confirmed', EvColors.success) : ('Not confirmed', EvColors.warning)),
          _Fact(LucideIcons.phone, 'Business phone', ZambianPhone.display(d.phone).isEmpty ? '—' : ZambianPhone.display(d.phone),
              action: d.phone == null ? null : () => launchUrl(Uri.parse('tel:${d.phone}'))),
          _Fact(LucideIcons.messageCircle, 'WhatsApp', ZambianPhone.display(d.whatsapp).isEmpty ? '—' : ZambianPhone.display(d.whatsapp),
              action: d.whatsapp == null
                  ? null
                  : () => launchUrl(Uri.parse('https://wa.me/${ZambianPhone.waDigits(d.whatsapp!)}?text=${Uri.encodeComponent('Hello from the Evenda team about ${d.name}.')}'),
                      mode: LaunchMode.externalApplication)),
          if (d.email != null && d.email != owner['email'])
            _Fact(LucideIcons.mail, 'Business email', d.email!, action: () => launchUrl(Uri.parse('mailto:${d.email}?subject=${Uri.encodeComponent('Evenda: ${d.name}')}'))),
          _Fact(LucideIcons.mapPin, 'Location', [d.neighbourhood, d.addressLine, 'serves ${d.serviceRadiusKm} km'].whereType<String>().where((s) => s.isNotEmpty).join(' · '),
              action: d.lat == null
                  ? null
                  : () => launchUrl(Uri.parse('https://www.google.com/maps/search/?api=1&query=${d.lat},${d.lng}'), mode: LaunchMode.externalApplication)),
          for (final t in d.team.where((t) => t['role'] != 'owner'))
            _Fact(LucideIcons.users, 'Team · ${'${t['role']}'.capitalized}', '${t['name'] ?? ''}'.ifEmpty('Invited member')),
        ]),
      ),

      SectionHeader('Decision history', count: d.history.length, padding: section),
      if (d.history.isEmpty)
        Text('No admin decisions yet.', style: EvType.small)
      else
        for (final h in d.history)
          Padding(
            padding: const EdgeInsets.only(bottom: EvSpace.x3),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_historyLabel(h), style: EvType.smallStrong),
              if ('${h['reason'] ?? ''}'.isNotEmpty) Text('“${h['reason']}”', style: EvType.small),
              Text('${'${h['by'] ?? ''}'.ifEmpty('Admin')} · ${EvDates.dayTime(DateTime.parse(h['at']).toLocal())}', style: EvType.caption),
            ]),
          ),
    ]);
  }

  static String _historyLabel(Map<String, dynamic> h) {
    final after = (h['after'] as Map?) ?? const {};
    return switch (h['action']) {
      'business.verification' => switch ('${after['verification_status']}') {
          'verified' => 'Verified',
          'rejected' => 'Sent back to the vendor',
          final v => 'Verification set to ${v.replaceAll('_', ' ')}',
        },
      'business.status' => 'Account ${after['status'] == 'suspended' ? 'suspended' : 'reactivated'}',
      'document.review' => 'Document ${after['status']}',
      'payment.void' => 'Payment record voided',
      final a => '$a',
    };
  }
}

/// "Whose move is it?" in one quiet line, with the reason when sent back.
class _StageLine extends StatelessWidget {
  const _StageLine({required this.stage, required this.docs, this.sentBackReason});
  final _Stage stage;
  final _Docs docs;
  final String? sentBackReason;

  @override
  Widget build(BuildContext context) {
    final detail = switch (stage) {
      _Stage.toReview => '${plural(docs.toReview, 'document')} waiting for you. Open each one before you accept it.',
      _Stage.readyToVerify => 'A document is accepted. Verify the business, or send it back.',
      _Stage.waitingVendor =>
        '${docs.current.length == 1 ? 'The document was rejected' : 'All current documents were rejected'}. The vendor is asked to upload a replacement; it will appear here.',
      _Stage.sentBack => sentBackReason == null ? 'They can upload new documents and send it again.' : '“$sentBackReason” They can fix it and send it again.',
      _Stage.verified => 'Shown with the verified badge.',
      _Stage.notSubmitted => docs.current.isEmpty ? 'No documents yet.' : 'The vendor hasn’t sent it for review.',
    };
    return Container(
      padding: const EdgeInsets.only(left: EvSpace.x3),
      decoration: BoxDecoration(border: Border(left: BorderSide(color: stage.tone == Tone.neutral ? EvColors.sandDeep : stage.tone.fg, width: 3))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(stage.label, style: EvType.bodyStrong.copyWith(color: stage.tone == Tone.neutral ? EvColors.ink : stage.tone.fg)),
        const SizedBox(height: 2),
        Text(detail, style: EvType.small),
      ]),
    );
  }
}

class _DocumentCard extends ConsumerStatefulWidget {
  const _DocumentCard({required this.doc, required this.replacement, required this.canReview, required this.onChanged});
  final AdminDocument doc;
  final bool replacement;
  final bool canReview;
  final VoidCallback onChanged;

  @override
  ConsumerState<_DocumentCard> createState() => _DocumentCardState();
}

class _DocumentCardState extends ConsumerState<_DocumentCard> {
  bool _opening = false;

  Future<void> _open() async {
    setState(() => _opening = true);
    await _openDocument(context, ref, widget.doc);
    if (mounted) setState(() => _opening = false);
  }

  Future<void> _review(String status) async {
    final accepting = status == 'accepted';
    final note = await confirmWithReason(
      context,
      title: accepting ? 'Accept this ${widget.doc.typeLabel}?' : 'Reject this ${widget.doc.typeLabel}?',
      body: accepting
          ? 'Only accept it if you opened it and it is genuine, legible, current and matches this business. Add a note (optional).'
          : 'Say what is wrong so the vendor can fix it, e.g. "Blurry, name not readable" or "Registered name does not match". They are asked for a replacement.',
      confirm: accepting ? 'Accept' : 'Reject',
      required: !accepting,
      destructive: !accepting,
    );
    if (note == null || !mounted) return;
    final ok = await guard(context, () async {
      await ref.read(backendProvider).admin.reviewDocument(widget.doc.id, status, note);
      return true;
    }, success: accepting ? 'Document accepted' : 'Vendor asked for a replacement');
    if (ok == true) widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final doc = widget.doc;
    final undecided = doc.status == 'submitted';
    final (label, tone) = switch (doc.status) {
      'accepted' => ('Accepted', Tone.positive),
      'rejected' => ('Rejected', Tone.critical),
      _ => (widget.replacement ? 'Replacement' : 'To review', Tone.waiting),
    };
    return EvSurface(
      padding: const EdgeInsets.fromLTRB(EvSpace.x4, EvSpace.x3, EvSpace.x3, EvSpace.x3),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InkWell(
          onTap: _opening ? null : _open,
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(doc.typeLabel, style: EvType.bodyStrong),
                Text('${doc.formatLabel} · uploaded ${EvDates.dayShort(doc.createdAt)}', style: EvType.caption),
              ]),
            ),
            StatusPill(label, tone: tone, dense: true),
          ]),
        ),
        if (doc.reviewNote != null || doc.reviewedAt != null) ...[
          const SizedBox(height: 6),
          Text(
            [
              if (doc.reviewNote != null) '“${doc.reviewNote}”',
              if (doc.reviewedAt != null) '${(doc.reviewedBy ?? '').ifEmpty('Admin')}, ${EvDates.dayShort(doc.reviewedAt!)}',
            ].join(' · '),
            style: EvType.caption,
          ),
        ],
        const SizedBox(height: EvSpace.x2),
        // Open is always first: nothing is judged unseen. Wraps onto a second
        // line on narrow phones / large text instead of overflowing.
        OverflowBar(alignment: MainAxisAlignment.spaceBetween, overflowAlignment: OverflowBarAlignment.end, overflowSpacing: 4, spacing: 8, children: [
          TextButton.icon(
            onPressed: _opening ? null : _open,
            icon: _opening ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(LucideIcons.eye, size: 18),
            label: Text(doc.viewInApp ? 'Open' : 'Open ${doc.formatLabel}'),
          ),
          if (widget.canReview && undecided)
            Row(mainAxisSize: MainAxisSize.min, children: [
              EvButton('Reject', kind: EvButtonKind.quiet, compact: true, onPressed: () => _review('rejected')),
              const SizedBox(width: 6),
              EvButton('Accept', compact: true, icon: LucideIcons.check, onPressed: () => _review('accepted')),
            ])
          else if (widget.canReview)
            TextButton(
              onPressed: () => _review(doc.status == 'accepted' ? 'rejected' : 'accepted'),
              child: Text(doc.status == 'accepted' ? 'Withdraw acceptance' : 'Accept instead'),
            ),
        ]),
      ]),
    );
  }
}

/// Opens a document: photos in the zoomable viewer, PDF/Word in the phone's app.
Future<void> _openDocument(BuildContext context, WidgetRef ref, AdminDocument doc) async {
  final url = await guard(context, () => ref.read(backendProvider).admin.documentUrl(doc.storagePath));
  if (url == null || !context.mounted) return;
  if (!doc.viewInApp) {
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  } else {
    await Navigator.of(context).push(MaterialPageRoute(fullscreenDialog: true, builder: (_) => _ImageViewer(url: url, title: doc.typeLabel)));
  }
}

/// Replaced and turned-down uploads, folded away but one tap from view.
class _EarlierUploads extends ConsumerWidget {
  const _EarlierUploads({required this.docs});
  final List<AdminDocument> docs;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: EdgeInsets.zero,
          title: Text('Earlier uploads (${docs.length})', style: EvType.smallStrong),
          children: [
            for (final doc in docs)
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                onTap: () => _openDocument(context, ref, doc),
                title: Text('${doc.typeLabel} · ${EvDates.dayShort(doc.createdAt)}', style: EvType.small.copyWith(color: EvColors.ink)),
                subtitle: Text(
                  [doc.status == 'rejected' ? 'Rejected' : (doc.status == 'accepted' ? 'Accepted' : 'Not reviewed'), if (doc.reviewNote != null) '“${doc.reviewNote}”'].join(' · '),
                  style: EvType.caption,
                ),
                trailing: Icon(LucideIcons.eye, size: 16, color: EvColors.ink3),
              ),
          ],
        ),
      );
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

/// The everyday decision, pinned and slim: verify, or send it back with a
/// reason. Shown only when there's a decision to make.
class _DecisionBar extends ConsumerWidget {
  const _DecisionBar({required this.d, required this.onChanged});
  final AdminBusinessDetail d;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stage = _stageOf(d, _Docs(d.documents));
    if (stage == _Stage.verified || stage == _Stage.sentBack || stage == _Stage.notSubmitted) return const SizedBox.shrink();
    final canVerify = d.hasAcceptedDocument;
    return Container(
      decoration: BoxDecoration(color: EvColors.cream, border: Border(top: BorderSide(color: EvColors.hairline))),
      padding: EdgeInsets.fromLTRB(EvSpace.gutter, EvSpace.x3, EvSpace.gutter, EvSpace.x3 + MediaQuery.paddingOf(context).bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (!canVerify)
          Padding(
            padding: const EdgeInsets.only(bottom: EvSpace.x2),
            child: Text('Accept a document to verify.', style: EvType.caption, textAlign: TextAlign.center),
          ),
        Row(children: [
          Expanded(
            child: EvButton('Send back', kind: EvButtonKind.secondary, expand: true,
                onPressed: () => _setVerification(context, ref, d, VerificationStatus.rejected, onChanged)),
          ),
          const SizedBox(width: EvSpace.x2),
          Expanded(
            child: EvButton('Verify', icon: LucideIcons.badgeCheck, expand: true,
                onPressed: canVerify ? () => _setVerification(context, ref, d, VerificationStatus.verified, onChanged) : null),
          ),
        ]),
      ]),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact(this.icon, this.label, this.value, {this.action, this.note});
  final IconData icon;
  final String label;
  final String value;
  final VoidCallback? action;
  final (String, Color)? note;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: action,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: EvSpace.x4, vertical: 10),
          child: Row(children: [
            Icon(icon, size: 18, color: EvColors.ink3),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, style: EvType.caption),
                Text(value, style: EvType.body),
                if (note != null) Text(note!.$1, style: EvType.caption.copyWith(color: note!.$2, fontWeight: FontWeight.w600)),
              ]),
            ),
            if (action != null) Icon(LucideIcons.externalLink, size: 16, color: EvColors.forest),
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
