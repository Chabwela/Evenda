import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../tokens.dart';
import 'states.dart';
import 'surfaces.dart';

/// Camera or gallery. Vendors are often standing in their yard next to the
/// stock, so taking the photo there and then must be as easy as picking one.
/// Uses the system camera app, so Evenda needs no camera permission.
Future<List<XFile>> pickPhotos(
  BuildContext context, {
  required String title,
  bool multiple = false,
  double? maxWidth = 1600,
  int imageQuality = 82,
  int limit = 8,
}) async {
  final source = await showEvSheet<ImageSource>(
    context,
    title: title,
    builder: (c) => Padding(
      padding: const EdgeInsets.fromLTRB(0, 0, 0, EvSpace.x6),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        EvRow(
          leading: const IconTile(LucideIcons.camera),
          title: 'Take a photo',
          subtitle: 'Use the camera now',
          onTap: () => Navigator.pop(c, ImageSource.camera),
        ),
        const EvDivider(indent: 72),
        EvRow(
          leading: const IconTile(LucideIcons.images),
          title: multiple ? 'Choose from gallery' : 'Choose a photo',
          subtitle: multiple ? 'Pick up to $limit at once' : 'From your gallery',
          onTap: () => Navigator.pop(c, ImageSource.gallery),
        ),
      ]),
    ),
  );
  if (source == null) return const [];
  final picker = ImagePicker();
  try {
    if (source == ImageSource.gallery && multiple) {
      return await picker.pickMultiImage(maxWidth: maxWidth, imageQuality: imageQuality, limit: limit);
    }
    final f = await picker.pickImage(source: source, maxWidth: maxWidth, imageQuality: imageQuality);
    return f == null ? const [] : [f];
  } catch (_) {
    if (context.mounted) {
      showToast(context, source == ImageSource.camera ? 'Couldn’t open the camera. Choose a photo from your gallery instead.' : 'Couldn’t open your photos.',
          icon: LucideIcons.circleAlert);
    }
    return const [];
  }
}

/// Verification documents vendors actually have: phone photos (incl. iPhone
/// HEIC), scans as PDF, and Word files. Mirrors the `verification` bucket's
/// allowed types (migration 20261020000400). Executables, archives and other
/// formats are refused, because staff open these files on their phones.
const kDocumentTypes = <String, String>{
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'png': 'image/png',
  'webp': 'image/webp',
  'heic': 'image/heic',
  'heif': 'image/heif',
  'pdf': 'application/pdf',
  'doc': 'application/msword',
  'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
};

/// Largest document accepted (the bucket's limit).
const kMaxDocumentBytes = 10 * 1024 * 1024;

typedef PickedDocument = ({Uint8List bytes, String ext, String name});

/// Camera, photo or file (PDF, Word…) for a verification document.
/// Returns null when cancelled or when the file is refused (with a message).
Future<PickedDocument?> pickDocument(BuildContext context, {String title = 'Verification document'}) async {
  final choice = await showEvSheet<String>(
    context,
    title: title,
    subtitle: 'Photo, PDF or Word document · up to 10 MB',
    builder: (c) => Padding(
      padding: const EdgeInsets.fromLTRB(0, 0, 0, EvSpace.x6),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        EvRow(leading: const IconTile(LucideIcons.camera), title: 'Take a photo', subtitle: 'Lay it flat in good light', onTap: () => Navigator.pop(c, 'camera')),
        const EvDivider(indent: 72),
        EvRow(leading: const IconTile(LucideIcons.images), title: 'Choose a photo', subtitle: 'From your gallery', onTap: () => Navigator.pop(c, 'gallery')),
        const EvDivider(indent: 72),
        EvRow(leading: const IconTile(LucideIcons.fileText), title: 'Choose a file', subtitle: 'PDF, Word or image from your phone', onTap: () => Navigator.pop(c, 'file')),
      ]),
    ),
  );
  if (choice == null || !context.mounted) return null;

  void refuse(String m) {
    if (context.mounted) showToast(context, m, icon: LucideIcons.circleAlert);
  }

  try {
    String name;
    Uint8List bytes;
    if (choice == 'file') {
      final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: kDocumentTypes.keys.toList());
      if (files.isEmpty) return null;
      name = files.first.name;
      bytes = await files.first.xFile.readAsBytes();
    } else {
      // Full resolution: staff must be able to read the small print.
      final f = await ImagePicker().pickImage(source: choice == 'camera' ? ImageSource.camera : ImageSource.gallery, imageQuality: 90);
      if (f == null) return null;
      name = f.name;
      bytes = await f.readAsBytes();
    }
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    if (!kDocumentTypes.containsKey(ext)) {
      refuse('That file type can’t be used. Upload a photo, PDF or Word document.');
      return null;
    }
    if (bytes.length > kMaxDocumentBytes) {
      refuse('That file is ${(bytes.length / 1048576).toStringAsFixed(1)} MB. The limit is 10 MB: take a photo instead, or save the PDF smaller.');
      return null;
    }
    return (bytes: bytes, ext: ext, name: name);
  } catch (_) {
    refuse(choice == 'camera' ? 'Couldn’t open the camera.' : 'Couldn’t open that file.');
    return null;
  }
}
