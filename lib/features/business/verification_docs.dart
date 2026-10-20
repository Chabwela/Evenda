import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../app/providers.dart';
import '../../core/errors.dart';
import '../../core/format.dart';
import '../../data/backend.dart';
import '../../design/ev.dart';
import '../../domain/models.dart';

/// What the server has for this business: the only source for "uploaded".
final verificationDocsProvider = FutureProvider.autoDispose.family<List<VerificationDocument>, String>((ref, businessId) {
  ref.watchDomains(const [DataDomain.business]);
  return ref.watch(backendProvider).business.verificationDocuments(businessId);
});

/// The admin's reason while the business is rejected (null otherwise).
final verificationFeedbackProvider = FutureProvider.autoDispose.family<String?, String>((ref, businessId) {
  ref.watchDomains(const [DataDomain.business]);
  return ref.watch(backendProvider).business.verificationFeedback(businessId);
});

/// Document types a vendor can send: (wire, label, hint).
const kVerificationDocTypes = <(String, String, String)>[
  ('pacra_certificate', 'PACRA certificate', 'Certificate of incorporation or business name registration'),
  ('tpin', 'ZRA TPIN certificate', 'Tax registration'),
  ('national_id', 'Owner’s NRC', 'National registration card of the owner'),
];

class _Upload {
  _Upload(this.doc);
  final PickedDocument doc;
  String? error; // null while uploading
}

/// One row per document type, each showing its real state: not sent,
/// uploading, didn't upload (with Retry), or uploaded (the server has it),
/// then accepted / not accepted after review.
class VerificationDocsSection extends ConsumerStatefulWidget {
  const VerificationDocsSection({
    super.key,
    required this.businessId,
    this.types = kVerificationDocTypes,
    this.locked = false,
    this.allowReplacingRejected = false,
    this.onBusyChanged,
    this.picker = pickDocument,
  });

  final String businessId;
  final List<(String, String, String)> types;

  /// In review or verified: show what was sent, no new uploads.
  final bool locked;

  /// Even when [locked] (in review), a document Evenda turned down can be
  /// replaced; the new one goes straight to the reviewer.
  final bool allowReplacingRejected;
  final ValueChanged<bool>? onBusyChanged;

  /// Camera / gallery / file sheet; replaceable in tests.
  final Future<PickedDocument?> Function(BuildContext context, {String title}) picker;

  @override
  ConsumerState<VerificationDocsSection> createState() => _VerificationDocsSectionState();
}

class _VerificationDocsSectionState extends ConsumerState<VerificationDocsSection> {
  final _uploads = <String, _Upload>{};

  bool get _busy => _uploads.values.any((u) => u.error == null);

  void _set(VoidCallback f) {
    final was = _busy;
    setState(f);
    if (was != _busy) widget.onBusyChanged?.call(_busy);
  }

  Future<void> _pick(String type, String label) async {
    final doc = await widget.picker(context, title: label);
    if (doc == null || !mounted) return;
    await _send(type, label, _Upload(doc));
  }

  Future<void> _send(String type, String label, _Upload u) async {
    _set(() {
      u.error = null;
      _uploads[type] = u;
    });
    try {
      await ref.read(backendProvider).business.uploadVerificationDocument(widget.businessId, type, u.doc.bytes, u.doc.ext);
      // Keep "Uploading" until the server's list includes it, so the row never
      // says uploaded for a document Evenda doesn't have.
      final _ = await ref.refresh(verificationDocsProvider(widget.businessId).future);
      if (!mounted) return;
      _set(() => _uploads.remove(type));
      showToast(context, '$label uploaded', icon: LucideIcons.circleCheck);
    } catch (e) {
      if (!mounted) return;
      final err = EvError.from(e);
      _set(() => u.error = switch (err.code) {
            'offline' => 'No internet. Nothing was sent.',
            'timeout' => 'The connection was too slow. Nothing was saved.',
            _ => err.userMessage,
          });
    }
  }

  @override
  Widget build(BuildContext context) {
    final docs = ref.watch(verificationDocsProvider(widget.businessId));
    final all = docs.value ?? const <VerificationDocument>[];
    return EvSurface(
      padding: EdgeInsets.zero,
      child: Column(children: [
        for (final (i, (type, label, hint)) in widget.types.indexed) ...[
          if (i > 0) const EvDivider(indent: 64),
          _row(type, label, hint, all.where((d) => d.docType == type).toList(), loading: !docs.hasValue && !docs.hasError),
        ],
      ]),
    );
  }

  Widget _row(String type, String label, String hint, List<VerificationDocument> sent, {required bool loading}) {
    final u = _uploads[type];
    final latest = sent.firstOrNull;

    if (u != null && u.error == null) {
      return Column(children: [
        EvRow(
          leading: const SizedBox(width: 36, height: 36, child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator(strokeWidth: 2.4))),
          title: label,
          subtitle: 'Uploading ${u.doc.name} · ${_size(u.doc.bytes.length)}…',
        ),
        const LinearProgressIndicator(minHeight: 2),
      ]);
    }
    if (u != null) {
      return EvRow(
        leading: const IconTile(LucideIcons.circleAlert, tone: Tone.critical),
        title: label,
        meta: Text('Didn’t upload. ${u.error}', style: EvType.small.copyWith(color: EvColors.danger)),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          EvButton('Retry', kind: EvButtonKind.secondary, compact: true, onPressed: () => _send(type, label, u)),
          IconButton(tooltip: 'Dismiss', icon: const Icon(LucideIcons.x, size: 18), onPressed: () => _set(() => _uploads.remove(type))),
        ]),
      );
    }
    if (latest == null) {
      return EvRow(
        leading: const IconTile(LucideIcons.fileText),
        title: label,
        subtitle: loading ? 'Checking…' : hint,
        trailing: widget.locked || loading ? null : EvButton('Upload', kind: EvButtonKind.secondary, compact: true, onPressed: () => _pick(type, label)),
      );
    }

    final (icon, tone, status) = switch (latest.status) {
      'accepted' => (LucideIcons.badgeCheck, Tone.positive, 'Accepted'),
      'rejected' => (LucideIcons.circleX, Tone.critical, 'Not accepted${latest.reviewNote == null || latest.reviewNote!.isEmpty ? '' : ': ${latest.reviewNote}'}'),
      _ => (LucideIcons.circleCheck, Tone.positive, 'Uploaded · waiting for review'),
    };
    final when = '${latest.formatLabel} · ${EvDates.dayShort(latest.createdAt)}${sent.length > 1 ? ' · ${sent.length} files' : ''}';
    return EvRow(
      leading: IconTile(icon, tone: tone),
      title: label,
      meta: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(status, style: EvType.small.copyWith(color: tone == Tone.critical ? EvColors.danger : EvColors.success, fontWeight: FontWeight.w600)),
        Text(when, style: EvType.caption),
      ]),
      trailing: widget.locked && !(widget.allowReplacingRejected && latest.status == 'rejected')
          ? null
          : latest.status == 'rejected'
              ? EvButton('Replace', kind: EvButtonKind.secondary, compact: true, onPressed: () => _pick(type, label))
              : TextButton(onPressed: () => _pick(type, label), child: const Text('Add')),
    );
  }

  static String _size(int b) => b < 1024 * 1024 ? '${(b / 1024).ceil()} KB' : '${(b / 1048576).toStringAsFixed(1)} MB';
}
