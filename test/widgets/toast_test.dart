import 'package:evenda/design/ev.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A message with an action (e.g. "Done — reminders cancelled · Undo") leaves
/// on its own; Flutter would otherwise keep it until tapped.
void main() {
  testWidgets('toast with Undo disappears by itself', (t) async {
    await t.pumpWidget(MaterialApp(
      theme: EvTheme.light(),
      home: Scaffold(
        body: Builder(
          builder: (c) => TextButton(
            onPressed: () => showToast(c, 'Done — reminders cancelled', action: 'Undo', onAction: () {}),
            child: const Text('Mark done'),
          ),
        ),
      ),
    ));
    await t.tap(find.text('Mark done'));
    await t.pumpAndSettle();
    expect(find.text('Done — reminders cancelled'), findsOneWidget);
    expect(find.text('Undo'), findsOneWidget);

    await t.pump(const Duration(seconds: 9));
    await t.pumpAndSettle();
    expect(find.text('Done — reminders cancelled'), findsNothing);
  });
}
