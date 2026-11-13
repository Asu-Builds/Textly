import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:textly_spike/model/document.dart';
import 'package:textly_spike/model/sample.dart';
import 'package:textly_spike/render/text_layout.dart';
import 'package:textly_spike/spell/spell_check.dart';

Future<ByteData> _fromDisk(String key) async => ByteData.sublistView(await File(key).readAsBytes());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    for (final (family, prefix) in [('TextlySans', 'Sans'), ('TextlyCondensed', 'Cond')]) {
      final loader = FontLoader(family);
      for (final style in ['Regular', 'Bold', 'Italic', 'BoldItalic']) {
        loader.addFont(_fromDisk('assets/fonts/$prefix-$style.ttf'));
      }
      await loader.load();
    }
  });

  testWidgets('Eingabefeld bricht genau gleich um wie Anzeige und PDF', (tester) async {
    final blocks = [
      for (final p in sampleDocument().pages) ...p.elements.whereType<TextElement>(),
    ];
    for (final t in blocks) {
      await tester.pumpWidget(MaterialApp(
        home: Material(child: MediaQuery.withNoTextScaling(
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: textLayoutWidth(t) + kCaretMargin,
              child: TextField(
                controller: TextEditingController(text: t.text),
                style: textStyleFor(t),
                strutStyle: strutFor(t),
                textAlign: textAlignFor(t),
                maxLines: null,
                cursorWidth: kCursorWidth,
                // Gleiche Rechteck-Art wie TextPainter; das Eingabefeld nutzt sonst «includeLineSpacingMiddle».
                selectionHeightStyle: ui.BoxHeightStyle.tight,
                decoration: const InputDecoration.collapsed(hintText: null),
              ),
            ),
          ),
        ),
      )));
      final editable = tester.state<EditableTextState>(find.byType(EditableText)).renderEditable;
      final tp = layoutText(t);
      for (final m in RegExp(r'\S+').allMatches(t.text)) {
        final sel = TextSelection(baseOffset: m.start, extentOffset: m.end);
        final a = tp.getBoxesForSelection(sel).first;
        final b = editable.getBoxesForSelection(sel).first;
        expect((a.left - b.left).abs(), lessThan(.001), reason: '«${m[0]}» in ${t.kind.name}: links');
        expect((a.top - b.top).abs(), lessThan(.001), reason: '«${m[0]}» in ${t.kind.name}: Zeile');
      }
    }
  });

  test('Rechtschreibprüfung markiert unbekannte Wörter und schlägt vor', () async {
    final checker = SpellChecker(WordListBackend(['wanderung', 'gletscher', 'der', 'zum']));
    final spans = await checker.fetchSpellCheckSuggestions(const Locale('de', 'CH'), 'Die Wandrung zum Gletscher');
    expect(spans, isNotNull);
    final texts = spans!.map((s) => 'Die Wandrung zum Gletscher'.substring(s.range.start, s.range.end)).toList();
    expect(texts, ['Die', 'Wandrung']); // «Die» fehlt bewusst in der Liste
    expect(spans[1].suggestions, contains('Wanderung'));
  });
}
