import 'package:evenda/design/ev.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fonts.dart';

void main() {
  setUpAll(loadAppFonts);

  testWidgets('Photo source sheet offers the camera and the gallery', (t) async {
    t.view.physicalSize = const Size(1080, 2400);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      theme: EvTheme.light(),
      home: Builder(builder: (c) => Scaffold(body: Center(child: TextButton(onPressed: () => pickPhotos(c, title: 'Add listing photos', multiple: true), child: const Text('open'))))),
    ));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    expect(find.text('Add listing photos'), findsOneWidget);
    expect(find.text('Take a photo'), findsOneWidget);
    expect(find.text('Choose from gallery'), findsOneWidget);
    expect(find.text('Pick up to 8 at once'), findsOneWidget);
    // Dismissing the sheet picks nothing and must not throw.
    await t.tapAt(const Offset(10, 10));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  });
}
