import 'dart:io';

import 'package:doc_model/doc_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:textly/editor/editor_controller.dart';
import 'package:textly/editor/editor_page.dart';
import 'package:textly/spell/spell_check.dart';

Future<ByteData> _fromDisk(String key) async => ByteData.sublistView(await File(key).readAsBytes());

void main() {
  setUpAll(() async {
    for (final (family, prefix) in [('TextlySans', 'Sans'), ('TextlyCondensed', 'Cond')]) {
      final loader = FontLoader(family);
      for (final style in ['Regular', 'Bold', 'Italic', 'BoldItalic']) {
        loader.addFont(_fromDisk('assets/fonts/$prefix-$style.ttf'));
      }
      await loader.load();
    }
  });

  // Regressionstest: Bei zentriertem Text blieb der Cursor mit Pfeil runter stehen, und Flutter
  // meldete «Failed assertion … isValid» (Fehler in Flutters VerticalCaretMovementRun).
  for (final align in TextAlignment.values) {
    testWidgets('Pfeil hoch/runter bewegt den Cursor zeilenweise ($align), mit Umschalt wird markiert', (tester) async {
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = EditorController(sampleDocument(), spell: SpellChecker(WordListBackend(const [])));
      await tester.pumpWidget(MaterialApp(home: EditorPage(controller: c)));
      var t = c.page.elements.whereType<TextBlock>().firstWhere((e) => e.kind == TextKind.body);
      c.commit(c.doc.replaceElement(0, t.copyWith(align: align)));
      t = c.page.find(t.id)! as TextBlock;
      c.startEditing(t, 3);
      await tester.pump();
      await tester.pump();

      final positions = <int>[c.textController.selection.baseOffset];
      for (var i = 0; i < 3; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        positions.add(c.textController.selection.baseOffset);
      }
      expect(tester.takeException(), isNull);
      for (var i = 1; i < positions.length; i++) {
        expect(positions[i], greaterThan(positions[i - 1]), reason: 'Zeile ${i + 1}: $positions');
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(c.textController.selection.baseOffset, positions[2], reason: 'eine Zeile zurück, gleiche Spalte');

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      final sel = c.textController.selection;
      expect((sel.baseOffset, sel.extentOffset), (positions[2], positions[3]));
      expect(tester.takeException(), isNull);
      c.finishEditing();
      await tester.pump(const Duration(milliseconds: 400));
    });
  }
}
