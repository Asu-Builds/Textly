import 'dart:io';

import 'package:doc_model/doc_model.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:textly/editor/editor_canvas.dart';
import 'package:textly/editor/editor_controller.dart';
import 'package:textly/editor/editor_page.dart';
import 'package:textly/spell/spell_check.dart';

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

  Future<EditorController> pumpEditor(WidgetTester tester, {Size size = const Size(1600, 1200)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = EditorController(sampleDocument(), spell: SpellChecker(WordListBackend(const [])));
    await tester.pumpWidget(MaterialApp(home: EditorPage(controller: c)));
    await tester.pump();
    return c;
  }

  Future<void> click(WidgetTester tester, Finder f) async {
    final g = await tester.startGesture(tester.getCenter(f), kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 150));
    await g.up();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('Werkzeuge sind beschriftet und fügen ein', (tester) async {
    final c = await pumpEditor(tester);
    for (final label in ['Rückgängig', 'Wiederholen', 'Text', 'Bild', 'Tabelle', 'Form', 'Ganze Seite', 'Drucken, PDF, E-Mail …']) {
      expect(find.text(label), findsWidgets, reason: label);
    }
    expect(find.text('Ansicht'), findsNothing, reason: 'Zoom unten rechts, Raster bei der Seite');
    for (final caption in ['Einfügen', 'Bearbeiten']) {
      expect(find.text(caption), findsOneWidget, reason: caption);
    }
    // Fläche und Linie unter «Form ▾»
    final before = c.page.elements.length;
    await click(tester, find.byKey(const ValueKey('tool-shape')));
    await tester.pumpAndSettle();
    expect(find.text('Linie'), findsOneWidget);
    await click(tester, find.byKey(const ValueKey('tool-rect')));
    expect(c.page.elements.length, before + 1);
    expect(c.selected, isA<RectShape>());
  });

  testWidgets('«Neue Seite» unter den Seiten fügt eine Seite ein und zeigt sie', (tester) async {
    final c = await pumpEditor(tester);
    expect(c.doc.pages, hasLength(2));
    await tester.ensureVisible(find.byKey(const ValueKey('page-add')));
    await click(tester, find.byKey(const ValueKey('page-add')));
    expect(c.doc.pages, hasLength(3));
    expect(find.byKey(const ValueKey('page-thumb-2')), findsOneWidget);
  });

  testWidgets('«Ganze Seite» passt den Zoom an das Fenster an', (tester) async {
    await pumpEditor(tester, size: const Size(1600, 900));
    String label() => tester.widget<Text>(find.byKey(const ValueKey('zoom-label'))).data!;
    expect(label(), '120 %');
    await click(tester, find.byKey(const ValueKey('zoom-fit')));
    final percent = int.parse(label().split(' ').first);
    expect(percent, lessThan(120));
    expect(percent, greaterThan(40));
  });

  testWidgets('Zoom unten rechts bleibt, auch wenn ein Element ausgewählt ist', (tester) async {
    final c = await pumpEditor(tester, size: const Size(1600, 900));
    final zoom = find.byKey(const ValueKey('zoom-control'));
    expect(tester.getRect(zoom).bottom, greaterThan(800));
    expect(tester.getRect(zoom).right, lessThan(1600 - 300), reason: 'links der Eigenschaften');
    c.select(c.page.elements.whereType<ImageBlock>().first.id);
    await tester.pump();
    expect(zoom, findsOneWidget);
    await click(tester, find.byKey(const ValueKey('zoom-in')));
    expect(tester.widget<Text>(find.byKey(const ValueKey('zoom-label'))).data, '144 %');
  });

  testWidgets('Hilfe zeigt Tipps und Tastenkürzel', (tester) async {
    await pumpEditor(tester);
    await click(tester, find.byKey(const ValueKey('tool-help')));
    expect(find.text('So funktioniert Textly'), findsOneWidget);
    expect(find.text('Strg+Z / Strg+Y'), findsOneWidget);
    await click(tester, find.byKey(const ValueKey('help-close')));
    await tester.pumpAndSettle();
    expect(find.text('So funktioniert Textly'), findsNothing);
  });

  testWidgets('Speicherstand: nichts bei neuem Dokument, «Nicht gespeichert» nach einer Änderung', (tester) async {
    final c = await pumpEditor(tester);
    expect(find.text('Nicht gespeichert'), findsNothing);
    expect(find.text('Gespeichert'), findsNothing);
    c.addRect();
    await tester.pump();
    expect(find.text('Nicht gespeichert'), findsOneWidget);
  });

  testWidgets('kleine Fenster (1280 und 1000 Bildpunkte): Werkzeugleiste ohne Überlauf, alles erreichbar', (tester) async {
    for (final w in [1280.0, 1000.0]) {
      await pumpEditor(tester, size: Size(w, 720));
      expect(tester.takeException(), isNull, reason: 'Breite $w');
      for (final k in ['tool-text', 'tool-shape', 'zoom-fit', 'tool-finish', 'tool-undo', 'tool-redo', 'tool-help']) {
        final r = tester.getRect(find.byKey(ValueKey(k)));
        expect(r.right, lessThanOrEqualTo(w), reason: '$k bei $w');
      }
    }
  });

  testWidgets('Kopf: Hauptknopf sagt, was möglich ist; Einfügen vorne, Rückgängig rechts in der Befehlszeile', (tester) async {
    await pumpEditor(tester, size: const Size(1600, 900));
    expect(find.text('Drucken, PDF, E-Mail …'), findsOneWidget);
    expect(find.textContaining('Fertigstellen'), findsNothing);
    expect(tester.getRect(find.byKey(const ValueKey('tool-finish'))).right, closeTo(1600 - 14, 1), reason: 'rechtsbündig zum Fenster');
    final undo = tester.getRect(find.byKey(const ValueKey('tool-undo')));
    final text = tester.getRect(find.byKey(const ValueKey('tool-text')));
    expect(undo.top, greaterThan(tester.getRect(find.byKey(const ValueKey('tool-finish'))).bottom), reason: 'Rückgängig in der Befehlszeile, unter dem Kopf');
    expect(text.left, lessThan(undo.left), reason: '«Einfügen» zuerst, «Bearbeiten» rechts');
    final insertCenter = (text.left + tester.getRect(find.byKey(const ValueKey('tool-shape'))).right) / 2;
    final page = tester.getRect(find.byType(EditorCanvas));
    expect(insertCenter, closeTo(page.center.dx, 20), reason: '«Einfügen» mittig über der Seite');
    expect(tester.getRect(find.byKey(const ValueKey('doc-name'))).center.dx, closeTo(800, 2), reason: 'Name mitten im Kopf');
    await click(tester, find.byKey(const ValueKey('tool-finish')));
    await tester.pumpAndSettle();
    expect(find.text('Drucken'), findsOneWidget);
    expect(find.byKey(const ValueKey('preview-pdf')), findsOneWidget);
  });

  testWidgets('keine Fusszeile; an der Auswahl nur Nötiges; Seite löschen bietet Rückgängig an', (tester) async {
    final c = await pumpEditor(tester);
    c.select(c.page.elements.whereType<ImageBlock>().first.id);
    await tester.pump();
    expect(find.byKey(const ValueKey('act-delete')), findsNothing, reason: 'Fusszeile entfällt');
    expect(find.descendant(of: find.byKey(const ValueKey('float-selection-bar')), matching: find.text('Löschen')), findsOneWidget);
    for (final gone in ['Kopie', 'Sperren']) {
      expect(find.descendant(of: find.byKey(const ValueKey('float-selection-bar')), matching: find.text(gone)), findsNothing, reason: gone);
    }
    c.select(null);
    await tester.pump();
    final n = c.doc.pages.length;
    await tester.tap(find.byTooltip('Seite löschen').first);
    await tester.pumpAndSettle();
    expect(c.doc.pages.length, n - 1);
    await tester.pump(const Duration(milliseconds: 600)); // Meldung fährt herein
    await tester.tap(find.descendant(of: find.byType(SnackBar), matching: find.text('Rückgängig')));
    await tester.pumpAndSettle();
    expect(c.doc.pages.length, n);
  });

  testWidgets('Querformat wählen: Seite wird breit, Rückgängig stellt Hochformat wieder her', (tester) async {
    final c = await pumpEditor(tester);
    c.select(null);
    await tester.pump();
    final hoch = tester.getSize(find.byKey(const ValueKey('page-background')));
    expect(hoch.width, lessThan(hoch.height));
    await tester.ensureVisible(find.byKey(const ValueKey('prop-orient-landscape')));
    await click(tester, find.byKey(const ValueKey('prop-orient-landscape')));
    await tester.pumpAndSettle();
    expect(c.doc.orientation, PageOrientation.landscape);
    final quer = tester.getSize(find.byKey(const ValueKey('page-background')));
    expect(quer.width, greaterThan(quer.height));
    // das Beispieldokument ist für Hochformat gemacht: Elemente ragen unten hinaus
    expect(find.byKey(const ValueKey('prop-outside')), findsOneWidget);
    c.undo();
    await tester.pumpAndSettle();
    expect(c.doc.orientation, PageOrientation.portrait);
  });

  testWidgets('Papiergrösse A5: Seite kleiner, alles mitskaliert, Meldung mit Rückgängig', (tester) async {
    final c = await pumpEditor(tester);
    c.select(null);
    await tester.pump();
    final title = c.page.elements.whereType<TextBlock>().firstWhere((t) => t.kind == TextKind.title);
    await tester.ensureVisible(find.byKey(const ValueKey('prop-paper-a5')));
    await click(tester, find.byKey(const ValueKey('prop-paper-a5')));
    await tester.pump();
    expect(c.doc.paper, PaperSize.a5);
    expect((c.doc.pageWidth, c.doc.pageHeight), (148, 210));
    final small = c.page.find(title.id)! as TextBlock;
    expect(small.size, closeTo(title.size * 148 / 210, .01), reason: 'Schrift mitverkleinert');
    expect(small.box.x, closeTo(title.box.x * 148 / 210, .01));
    expect(find.textContaining('Auf A5 umgestellt'), findsOneWidget);
    await tester.drag(find.byType(ListView).last, const Offset(0, 600));
    await tester.pump();
    expect(find.textContaining('A5 Hochformat'), findsOneWidget);
    expect(find.byKey(const ValueKey('prop-outside')), findsNothing, reason: 'alles passt weiterhin');
    await tester.pump(const Duration(milliseconds: 600)); // Meldung fährt herein
    await tester.tap(find.descendant(of: find.byType(SnackBar), matching: find.text('Rückgängig')));
    await tester.pump();
    expect(c.doc.paper, PaperSize.a4);
    expect((c.page.find(title.id)! as TextBlock).size, title.size);
  });

  testWidgets('Zoom mit Strg+Plus, Strg+Minus und Strg+0 (ganze Seite)', (tester) async {
    await pumpEditor(tester, size: const Size(1600, 900));
    String label() => tester.widget<Text>(find.byKey(const ValueKey('zoom-label'))).data!;
    expect(label(), '120 %');
    Future<void> ctrl(LogicalKeyboardKey k) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(k);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
    }

    await ctrl(LogicalKeyboardKey.numpadAdd);
    expect(label(), '144 %');
    await ctrl(LogicalKeyboardKey.minus);
    await ctrl(LogicalKeyboardKey.minus);
    expect(label(), '100 %');
    await ctrl(LogicalKeyboardKey.digit0);
    expect(int.parse(label().split(' ').first), lessThan(100), reason: 'ganze Seite');
  });
}
