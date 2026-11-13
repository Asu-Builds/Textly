import 'dart:io';
import 'dart:ui' as ui;

import 'package:doc_model/doc_model.dart';
import 'package:doc_render/doc_render.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:textly/editor/editor_controller.dart';
import 'package:textly/editor/editor_page.dart';
import 'package:textly/editor/rich_text_controller.dart';
import 'package:textly/spell/spell_check.dart';

Future<ByteData> _fromDisk(String key) async => ByteData.sublistView(await File(key).readAsBytes());

EditorController _controller({Iterable<String> words = const []}) =>
    EditorController(sampleDocument(), spell: SpellChecker(WordListBackend(words)));

TextBlock _body(EditorController c) => c.page.elements.whereType<TextBlock>().firstWhere((e) => e.kind == TextKind.body);
TextBlock _get(EditorController c, String id) => c.page.find(id)! as TextBlock;

/// Fliesstext mit gemischter Formatierung: ein fettes, ein kursives, ein farbiges und ein unterstrichenes Wort.
TextBlock _mixed() {
  final t = TextBlock.ofKind(
    id: 'm',
    box: const Box(20, 20, 82, 10),
    text: 'Um 7.40 Uhr startete die Gruppe mit 23 Mitgliedern in Brig. Mit der Luftseilbahn ging es auf die Riederalp.',
  );
  var runs = applyInlineStyle(const [], t.text.length, 21, 24, const InlineStyle(bold: true)); // «die»
  runs = applyInlineStyle(runs, t.text.length, 25, 31, const InlineStyle(italic: true, color: 0xFFB4442C)); // «Gruppe»
  runs = applyInlineStyle(runs, t.text.length, 62, 76, const InlineStyle(bold: true, underline: true)); // Teil von «Luftseilbahn»
  return t.copyWith(runs: runs);
}

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

  testWidgets('Eingabefeld bricht mit gemischter Formatierung genau gleich um wie Anzeige und PDF', (tester) async {
    final t = _mixed();
    final rc = RichTextController()..load(t, const TextSelection.collapsed(offset: 0));
    await tester.pumpWidget(MaterialApp(
      home: Material(
        child: MediaQuery.withNoTextScaling(
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: textLayoutWidth(t) + caretMargin,
              child: TextField(
                controller: rc,
                style: textStyleFor(t),
                strutStyle: strutFor(t),
                maxLines: null,
                cursorWidth: cursorWidth,
                selectionHeightStyle: ui.BoxHeightStyle.tight,
                spellCheckConfiguration: const SpellCheckConfiguration.disabled(),
                decoration: const InputDecoration.collapsed(hintText: null),
              ),
            ),
          ),
        ),
      ),
    ));
    final editable = tester.state<EditableTextState>(find.byType(EditableText)).renderEditable;
    final tp = layoutText(t);
    for (var i = 0; i < t.text.length; i++) {
      final sel = TextSelection(baseOffset: i, extentOffset: i + 1);
      final a = tp.getBoxesForSelection(sel), b = editable.getBoxesForSelection(sel);
      if (a.isEmpty) continue;
      expect((a.first.left - b.first.left).abs(), lessThan(.001), reason: 'Zeichen $i «${t.text[i]}»: links');
      expect((a.first.top - b.first.top).abs(), lessThan(.001), reason: 'Zeichen $i: Zeile');
    }
    // Fettes Wort ist wirklich breiter als normal gesetzt
    final plain = layoutText(t.copyWith(runs: const []));
    final w1 = tp.getBoxesForSelection(const TextSelection(baseOffset: 21, extentOffset: 24)).first;
    final w0 = plain.getBoxesForSelection(const TextSelection(baseOffset: 21, extentOffset: 24)).first;
    expect(w1.right - w1.left, greaterThan(w0.right - w0.left));
  });

  test('PDF mit gemischter Formatierung: jedes Zeichen an der Bildschirmposition', () async {
    final doc = TextlyDocument(pages: [DocPage(id: 'p', elements: [_mixed()])]);
    final r = await exportPdf(doc, _fromDisk);
    expect(String.fromCharCodes(r.bytes.take(5)), '%PDF-');
    expect(r.report.maxDeviationMm, lessThan(.01), reason: '${r.report}');
  });

  group('Formatierung im Editor', () {
    test('Markierung fett: nur das Wort; Leiste zeigt den Zustand; ein Schritt', () {
      final c = _controller();
      final t = _body(c);
      c.startEditing(t, 0);
      c.textController.selection = const TextSelection(baseOffset: 3, extentOffset: 7); // «7.40»
      expect(c.hasTextSelection, isTrue);
      expect(c.inlineActive(InlineAttr.bold), isFalse);
      final depth = c.history.undoDepth;
      c.toggleInline(InlineAttr.bold);
      expect(c.inlineActive(InlineAttr.bold), isTrue);
      expect(c.editingId, t.id, reason: 'Bearbeitung bleibt offen');
      expect(c.textController.selection, const TextSelection(baseOffset: 3, extentOffset: 7));
      expect(_get(c, t.id).runs, [const StyleRun(3, 7, InlineStyle(bold: true))]);
      expect(_get(c, t.id).bold, isFalse);
      expect(c.history.undoDepth, depth + 1);
      c.toggleInline(InlineAttr.bold); // nochmals: wieder normal
      expect(_get(c, t.id).runs, isEmpty);
    });

    test('Weitertippen hinter dem fetten Wort bleibt fett; Abschliessen übernimmt die Formatierung', () {
      final c = _controller();
      final t = _body(c);
      c.startEditing(t, 0);
      c.textController.selection = const TextSelection(baseOffset: 3, extentOffset: 7);
      c.toggleInline(InlineAttr.bold);
      c.textController.value = TextEditingValue(
        text: t.text.replaceRange(7, 7, ' h'),
        selection: const TextSelection.collapsed(offset: 9),
      );
      c.onEditingChanged();
      c.finishEditing();
      expect(_get(c, t.id).runs, [const StyleRun(3, 9, InlineStyle(bold: true))]);
      expect(_get(c, t.id).text.substring(3, 9), '7.40 h');
    });

    test('Strg+B ohne Markierung: das als Nächstes Getippte wird fett', () {
      final c = _controller();
      final t = _body(c);
      c.startEditing(t, 2);
      c.toggleInline(InlineAttr.bold, fromKeyboard: true);
      expect(c.history.undoDepth, 0, reason: 'noch nichts geändert');
      c.textController.value = TextEditingValue(text: t.text.replaceRange(2, 2, 'X'), selection: const TextSelection.collapsed(offset: 3));
      expect(c.textController.runs, [const StyleRun(2, 3, InlineStyle(bold: true))]);
    });

    test('Ohne Markierung: Farbe und Fett gelten für den ganzen Block und ersetzen Abweichungen', () {
      final c = _controller();
      final t = _body(c);
      c.select(t.id);
      c.commit(c.doc.replaceElement(0, t.copyWith(runs: [const StyleRun(0, 2, InlineStyle(color: 0xFF2F5BD3, bold: true))])));
      c.setInlineColor(0xFF1F7A5A);
      expect(_get(c, t.id).color, 0xFF1F7A5A);
      expect(_get(c, t.id).runs, [const StyleRun(0, 2, InlineStyle(bold: true))]);
      expect(c.inlineActive(InlineAttr.bold), isFalse, reason: 'nicht jedes Zeichen ist fett');
      c.toggleInline(InlineAttr.bold);
      expect(_get(c, t.id).bold, isTrue);
      expect(_get(c, t.id).runs, isEmpty);
      c.toggleInline(InlineAttr.underline);
      expect(_get(c, t.id).runs.single.style, const InlineStyle(underline: true));
    });

    test('Rechtschreibfehler werden markiert, ohne die Formatierung zu verlieren', () async {
      final c = _controller(words: ['um', 'uhr']); // fast alles «falsch»
      final t = _body(c);
      c.startEditing(t, 0);
      c.textController.selection = const TextSelection(baseOffset: 13, extentOffset: 21); // «startete»
      c.toggleInline(InlineAttr.bold);
      await c.textController.checkSpellingNow();
      expect(c.textController.misspelled, isNotEmpty);
      final span = c.textController.buildTextSpan(context: _FakeContext(), withComposing: false);
      final children = span.children!.cast<TextSpan>();
      expect(children.any((s) => s.style?.fontWeight == FontWeight.w700), isTrue, reason: 'fett bleibt');
      expect(children.any((s) => s.style?.decorationStyle == TextDecorationStyle.wavy), isTrue, reason: 'Wellenlinie da');
      expect(c.textController.suggestionAt(15), isNotNull);
      c.finishEditing();
    });
  });

  group('Formatierung mit echter Maus', () {
    Future<EditorController> pumpEditor(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = _controller();
      await tester.pumpWidget(MaterialApp(home: EditorPage(controller: c)));
      await tester.pump();
      return c;
    }

    Future<void> click(WidgetTester tester, Offset at) async {
      final g = await tester.startGesture(at, kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 180));
      await g.up();
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('Wort doppelklicken, «Fett» und Farbe wählen, Strg+I: nur dieses Wort', (tester) async {
      final c = await pumpEditor(tester);
      final t = _body(c);
      final block = tester.getRect(find.byKey(ValueKey('element-${t.id}')));
      await click(tester, block.topLeft + const Offset(30, 10));
      await click(tester, block.topLeft + const Offset(30, 10));
      expect(c.editingId, t.id);
      // Doppelklick auf ein Wort in der zweiten Zeile
      final at = block.topLeft + const Offset(60, 30);
      final g1 = await tester.startGesture(at, kind: PointerDeviceKind.mouse);
      await g1.up();
      await tester.pump(const Duration(milliseconds: 80));
      final g2 = await tester.startGesture(at, kind: PointerDeviceKind.mouse);
      await g2.up();
      await tester.pump(const Duration(milliseconds: 400));
      final sel = c.textController.selection;
      expect(sel.isCollapsed, isFalse);
      expect(find.text('Farbe und Stil gelten für den markierten Text.'), findsOneWidget);

      await click(tester, tester.getCenter(find.byKey(const ValueKey('prop-bold'))));
      await click(tester, tester.getCenter(find.byKey(const ValueKey('prop-color-ffb4442c'))));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(c.editingId, t.id);
      expect(c.textController.selection, sel, reason: 'Markierung bleibt');

      final b = _get(c, t.id);
      expect(b.runs.single, StyleRun(sel.start, sel.end, const InlineStyle(bold: true, italic: true, color: 0xFFB4442C)));
      expect(b.bold, isFalse);
      expect(b.color, t.color);
      await tester.pump(const Duration(milliseconds: 400)); // Rechtschreibprüfung läuft nach
    });
  });
}

class _FakeContext extends Fake implements BuildContext {}
