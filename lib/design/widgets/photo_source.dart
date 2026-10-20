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
