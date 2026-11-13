import 'dart:io';

import 'package:doc_model/doc_model.dart';
import 'package:doc_render/doc_render.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:textly/editor/editor_controller.dart';
import 'package:textly/editor/editor_page.dart';
import 'package:textly/editor/properties_panel.dart';
import 'package:textly/spell/spell_check.dart';

Future<ByteData> _fromDisk(String key) async => ByteData.sublistView(await File(key).readAsBytes());

EditorController _controller() => EditorController(sampleDocument(), spell: SpellChecker(WordListBackend(const [])));

TextBlock _body(EditorController c) => c.page.elements.whereType<TextBlock>().firstWhere((e) => e.kind == TextKind.body);
TextBlock _get(EditorController c, String id) => c.page.find(id)! as TextBlock;

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

  group('Schriftgrösse in Stufen', () {
    test('rauf und runter', () {
      expect(stepFontSize(10.5, 1), 11);
      expect(stepFontSize(10.5, -1), 10);
      expect(stepFontSize(72, 1), 72);
      expect(stepFontSize(7, -1), 7);
    });
    test('Werte zwischen den Stufen rasten ein', () {
      expect(stepFontSize(10.7, 1), 11);
      expect(stepFontSize(10.7, -1), 10.5);
    });
  });

  group('Textstil im Controller', () {
    test('Textart übernimmt die Vorgaben; ein Schritt; rückgängig', () {
      final c = _controller();
      final t = _body(c);
      c.select(t.id);
      c.updateSelectedText((b) => b.withKind(TextKind.title));
      final title = _get(c, t.id);
      expect(title.kind, TextKind.title);
      expect(title.size, textKindPresets[TextKind.title]!.size);
      expect(title.bold, isTrue);
      c.undo();
      expect(_get(c, t.id).kind, TextKind.body);
    });

    test('mehrmals Grösse + ist ein Schritt', () {
      final c = _controller();
      final t = _body(c);
      c.select(t.id);
      for (var i = 0; i < 3; i++) {
        c.updateSelectedText((b) => b.copyWith(size: stepFontSize(b.size, 1)), mergeKey: 'size');
      }
      expect(_get(c, t.id).size, 13);
      expect(c.history.undoDepth, 1);
    });

    test('beim Schreiben: Bearbeitung bleibt offen, Text und Stil bleiben erhalten', () {
      final c = _controller();
      final t = _body(c);
      c.startEditing(t, 0);
      c.textController.text = 'Neuer Anfang';
      c.textController.selection = const TextSelection(baseOffset: 0, extentOffset: 5);
      c.onEditingChanged();
      c.updateSelectedText((b) => b.copyWith(bold: true));
      expect(c.editingId, t.id);
      expect(c.textController.selection, const TextSelection(baseOffset: 0, extentOffset: 5));
      expect(_get(c, t.id).bold, isTrue);
      expect(_get(c, t.id).text, 'Neuer Anfang');
      c.textController.text = 'Neuer Anfang mit mehr Text';
      c.onEditingChanged();
      c.finishEditing();
      final done = _get(c, t.id);
      expect(done.bold, isTrue);
      expect(done.text, 'Neuer Anfang mit mehr Text');
      c.undo(); // Text nach dem Stilwechsel
      expect(_get(c, t.id).text, 'Neuer Anfang');
      expect(_get(c, t.id).bold, isTrue);
      c.undo(); // Stilwechsel samt bis dahin getipptem Text
      expect(_get(c, t.id).text, t.text);
      expect(_get(c, t.id).bold, isFalse);
    });

    test('grössere Schrift macht den Block höher', () {
      final c = _controller();
      final t = _body(c);
      c.select(t.id);
      final h = renderedBox(t).h;
      c.updateSelectedText((b) => b.copyWith(size: 20));
      expect(renderedBox(_get(c, t.id)).h, greaterThan(h * 1.5));
    });
  });

  group('Eigenschaftenleiste mit echter Maus', () {
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

    Future<void> clickKey(WidgetTester tester, String key) => click(tester, tester.getCenter(find.byKey(ValueKey(key))));

    testWidgets('ohne Auswahl keine Texteinstellungen, mit Textauswahl schon', (tester) async {
      final c = await pumpEditor(tester);
      expect(find.byKey(const ValueKey('prop-size-plus')), findsNothing);
      final t = _body(c);
      await clickKey(tester, 'element-${t.id}');
      expect(find.byKey(const ValueKey('prop-size-plus')), findsOneWidget);
      expect(find.byKey(const ValueKey('prop-kind-title')), findsOneWidget);
      final img = c.page.elements.whereType<ImageBlock>().first;
      await clickKey(tester, 'element-${img.id}');
      expect(find.byKey(const ValueKey('prop-size-plus')), findsNothing);
    });

    testWidgets('Grösse, Farbe, Textart und Ausrichtung per Klick', (tester) async {
      final c = await pumpEditor(tester);
      final t = _body(c);
      await clickKey(tester, 'element-${t.id}');
      await clickKey(tester, 'prop-size-plus');
      await clickKey(tester, 'prop-size-plus');
      expect(_get(c, t.id).size, 12);
      expect(find.text('12'), findsWidgets, reason: 'Grösse ohne «pt»');
      expect(find.textContaining(' pt'), findsNothing);
      await clickKey(tester, 'prop-color-ffb4442c');
      expect(_get(c, t.id).color, 0xFFB4442C);
      await clickKey(tester, 'prop-align-center');
      expect(_get(c, t.id).align, TextAlignment.center);
      await clickKey(tester, 'prop-kind-heading');
      expect(_get(c, t.id).kind, TextKind.heading);
      expect(c.selectedId, t.id);
    });

    testWidgets('Schriftart wählen und zur Vorgabe zurück; Löschen am Element', (tester) async {
      final c = await pumpEditor(tester);
      final t = _body(c);
      await clickKey(tester, 'element-${t.id}');
      await tester.ensureVisible(find.byKey(const ValueKey('prop-font')));
      await tester.pumpAndSettle();
      await clickKey(tester, 'prop-font');
      await tester.pumpAndSettle();
      expect(find.text('Playfair Display'), findsOneWidget, reason: 'Menü zeigt alle Schriften');
      await clickKey(tester, 'prop-font-lora');
      await tester.pumpAndSettle();
      expect(_get(c, t.id).font, TextFont.lora);
      expect(_get(c, t.id).effectiveFont, TextFont.lora);

      await clickKey(tester, 'prop-font');
      await tester.pumpAndSettle();
      await clickKey(tester, 'prop-font-default');
      await tester.pumpAndSettle();
      expect(_get(c, t.id).font, isNull);

      // keine Fusszeile mehr; Löschen steht an der Auswahl
      expect(find.byKey(const ValueKey('act-delete')), findsNothing);
      final n = c.page.elements.length;
      c.finishEditing();
      await tester.pump();
      await clickKey(tester, 'float-delete');
      expect(c.page.elements.length, n - 1);
    });

    testWidgets('beim Schreiben auf «Fett» klicken: Bearbeitung und Markierung bleiben', (tester) async {
      final c = await pumpEditor(tester);
      final t = _body(c);
      final block = tester.getRect(find.byKey(ValueKey('element-${t.id}')));
      await click(tester, block.topLeft + const Offset(30, 10));
      await click(tester, block.topLeft + const Offset(30, 10));
      await tester.pump();
      expect(c.editingId, t.id);
      c.textController.selection = const TextSelection(baseOffset: 3, extentOffset: 9);
      await tester.pump();
      await clickKey(tester, 'prop-bold');
      // Mit Markierung wirkt «Fett» nur auf den markierten Text
      expect(_get(c, t.id).bold, isFalse);
      expect(_get(c, t.id).runs, [const StyleRun(3, 9, InlineStyle(bold: true))]);
      expect(c.editingId, t.id, reason: 'Klick in die Leiste darf die Bearbeitung nicht beenden');
      expect(c.textFocus.hasFocus, isTrue, reason: 'Cursor bleibt im Text');
      expect(c.textController.selection, const TextSelection(baseOffset: 3, extentOffset: 9));
      // weiter tippen geht ohne neuen Klick
      await tester.enterText(find.byKey(const ValueKey('text-editor')), 'Fett geschrieben');
      await tester.pump();
      expect(c.editingId, t.id);
      await tester.pump(const Duration(milliseconds: 400)); // Rechtschreibprüfung läuft nach
    });

    testWidgets('Textblock hat nur Seitengriffe, keinen Höhengriff und keinen Höhenschalter', (tester) async {
      final c = await pumpEditor(tester);
      final t = _body(c);
      await clickKey(tester, 'element-${t.id}');
      expect(find.byKey(const ValueKey('handle-e')), findsOneWidget);
      expect(find.byKey(const ValueKey('handle-s')), findsNothing);
      expect(find.byKey(const ValueKey('prop-autoheight')), findsNothing);
    });
  });

  group('Rechteck und Linie', () {
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

    Future<void> clickKey(WidgetTester tester, String key) => click(tester, tester.getCenter(find.byKey(ValueKey(key))));

    testWidgets('Rechteck: Füllung, Rahmen mit Farbe, Ecken; jede Änderung rückgängig', (tester) async {
      final c = await pumpEditor(tester);
      c.goToPage(1);
      await tester.pump();
      final r = c.page.elements.whereType<RectShape>().first;
      // Ecke des Rechtecks anklicken (in der Mitte liegt ein Textblock)
      await click(tester, tester.getRect(find.byKey(ValueKey('element-${r.id}'))).topLeft + const Offset(6, 6));
      expect(c.selectedId, r.id);
      expect(find.byKey(const ValueKey('prop-strokecolor-ffb4442c')), findsNothing, reason: 'Rahmenfarbe erst mit Rahmen');
      await clickKey(tester, 'prop-fill-fff7f0dc');
      await clickKey(tester, 'prop-stroke-Kräftig');
      await clickKey(tester, 'prop-strokecolor-ffb4442c');
      await clickKey(tester, 'prop-corners-Eckig');
      final done = c.page.find(r.id)! as RectShape;
      expect(done.fill, 0xFFF7F0DC);
      expect(done.strokeWidth, 1.2);
      expect(done.stroke, 0xFFB4442C);
      expect(done.round, isFalse);
      expect(c.history.undoDepth, 4);
      await clickKey(tester, 'prop-fill-ffffff');
      expect((c.page.find(r.id)! as RectShape).fill, 0x00FFFFFF);
    });

    testWidgets('Linie: Farbe und Stärke', (tester) async {
      final c = await pumpEditor(tester);
      final l = c.page.elements.whereType<LineShape>().first;
      await click(tester, tester.getCenter(find.byKey(ValueKey('element-${l.id}'))));
      expect(c.selectedId, l.id);
      await clickKey(tester, 'prop-linecolor-ff1f7a5a');
      await clickKey(tester, 'prop-linewidth-Balken');
      final done = c.page.find(l.id)! as LineShape;
      expect(done.color, 0xFF1F7A5A);
      expect(done.width, 2.5);
      expect(find.byKey(const ValueKey('prop-size-plus')), findsNothing);
    });

    test('PDF mit durchsichtiger Füllung, Rahmen und dicker Linie', () async {
      final c = _controller();
      final l = c.page.elements.whereType<LineShape>().first;
      c.select(l.id);
      c.updateSelectedLine((s) => s.copyWith(width: 2.5, color: 0xFFB4442C));
      c.goToPage(1);
      final r = c.page.elements.whereType<RectShape>().first;
      c.select(r.id);
      c.updateSelectedRect((s) => s.copyWith(fill: 0x00FFFFFF, strokeWidth: 1.2, round: false));
      final result = await exportPdf(c.doc, _fromDisk);
      expect(String.fromCharCodes(result.bytes.take(5)), '%PDF-');
      expect(result.report.maxDeviationMm, lessThan(.01));
    });
  });
}
