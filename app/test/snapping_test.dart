import 'dart:io';

import 'package:doc_model/doc_model.dart';
import 'package:doc_render/doc_render.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:textly/editor/editor_controller.dart';
import 'package:textly/editor/editor_page.dart';
import 'package:textly/spell/spell_check.dart';

Future<ByteData> _fromDisk(String key) async => ByteData.sublistView(await File(key).readAsBytes());

/// Leere Seite mit zwei Rechtecken: A bei x = 40, B weit weg.
EditorController _twoRects() {
  final doc = TextlyDocument(pages: [
    DocPage(id: 'p', elements: const [
      RectShape(id: 'a', box: Box(40, 40, 50, 30)),
      RectShape(id: 'b', box: Box(120, 150, 40, 20)),
    ]),
  ]);
  return EditorController(doc, spell: SpellChecker(WordListBackend(const [])))..viewZoom = 1.2;
}

Box _box(EditorController c, String id) => c.page.find(id)!.box;

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

  group('Einrasten im Controller', () {
    test('ohne Ziel in der Nähe rastet die linke obere Ecke am Raster ein', () {
      final c = _twoRects();
      c.beginGesture('b');
      c.updateMove(-12.3, 7.4);
      expect(c.guides, isEmpty);
      c.endGesture();
      final b = _box(c, 'b');
      expect((b.x % 5, b.y % 5), (0, 0));
    });

    test('Kante an Kante eines anderen Elements, mit Ausrichtungslinie während des Ziehens', () {
      final c = _twoRects();
      c.beginGesture('b');
      c.updateMove(-79.2, 0); // linke Kante von B auf 40.8 → an linker Kante von A (40)
      expect(c.guides, contains(const Guide(SnapAxis.vertical, 40)));
      c.endGesture();
      expect(_box(c, 'b').x, 40);
      expect(c.guides, isEmpty, reason: 'Linien verschwinden nach dem Loslassen');
    });

    test('Mitte an Seitenmitte', () {
      final c = _twoRects();
      c.beginGesture('b');
      c.updateMove(-34.4, 0); // Mitte 140 - 34.4 = 105.6 → 105
      c.endGesture();
      expect(_box(c, 'b').centerX, pageWidthMm / 2);
    });

    test('Alt-Taste (free) und ausgeschaltetes Raster rasten nicht ein', () {
      final c = _twoRects();
      c.beginGesture('b');
      c.updateMove(-12.3, 7.4, free: true);
      c.endGesture();
      expect(_box(c, 'b'), const Box(107.7, 157.4, 40, 20));
      c.setSnapToGrid(false);
      c.beginGesture('b');
      c.updateMove(2.2, 1.1);
      c.endGesture();
      expect(_box(c, 'b').x, closeTo(109.9, 1e-9), reason: 'kein Raster, kein Ziel in der Nähe');
    });

    test('Griff: gezogene Kante rastet an anderer Kante ein', () {
      final c = _twoRects();
      c.beginGesture('a');
      c.updateResize(Handle.e, 30.9, 0); // rechte Kante 90 + 30.9 = 120.9 → an linker Kante von B (120)
      c.endGesture();
      expect(_box(c, 'a').right, 120);
      expect(_box(c, 'a').x, 40, reason: 'linke Kante bleibt');
    });

    test('Bild am Eckgriff: Kante rastet ein, Seitenverhältnis bleibt', () {
      final c = EditorController(sampleDocument(), spell: SpellChecker(WordListBackend(const [])))..viewZoom = 1.2;
      final img = c.page.elements.whereType<ImageBlock>().last; // 108..190, Seitenverhältnis 0,8
      c.beginGesture(img.id);
      c.updateResize(Handle.se, 4.2, 0); // rechte Kante 194.2 → Seitenrand 195
      c.endGesture();
      final b = _box(c, img.id);
      expect(b.right, pageWidthMm - pageMarginMm);
      expect(b.w / b.h, closeTo(img.box.w / img.box.h, 1e-9));
    });

    test('Überlappung erkennen und darunter verschieben', () {
      final c = _twoRects();
      final doc = c.doc
          .addElement(0, TextBlock.ofKind(id: 't', box: const Box(45, 50, 60, 10), text: 'Text über einem Bild'))
          .addElement(0, const ImageBlock(id: 'i', box: Box(40, 45, 80, 40), asset: 'x', naturalWidth: 800, naturalHeight: 400));
      c.commit(doc);
      c.select('t');
      expect(c.overlapsOfSelected().map((e) => e.id), ['i'], reason: 'Rechtecke zählen nicht');
      expect(c.moveSelectedBelowOverlaps(), isTrue);
      expect(c.overlapsOfSelected(), isEmpty);
      expect(_box(c, 't').y, 90); // unter dem Bild (85) + 4 mm, aufs Raster
    });
  });

  group('Einrasten mit echter Maus', () {
    Future<EditorController> pumpEditor(WidgetTester tester, EditorController c) async {
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: EditorPage(controller: c)));
      await tester.pump();
      return c;
    }

    testWidgets('Ausrichtungslinie erscheint beim Ziehen und rastet ein', (tester) async {
      final c = await pumpEditor(tester, _twoRects());
      final b = tester.getRect(find.byKey(const ValueKey('element-b')));
      final a = tester.getRect(find.byKey(const ValueKey('element-a')));
      final g = await tester.startGesture(b.center, kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 200));
      // B so ziehen, dass seine linke Kante 3 Bildschirmpunkte neben der linken Kante von A liegt
      final target = b.center + Offset(a.left - b.left + 3, 0);
      for (var i = 1; i <= 10; i++) {
        await g.moveTo(b.center + (target - b.center) * (i / 10));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(c.guides, contains(const Guide(SnapAxis.vertical, 40)));
      await g.up();
      await tester.pump();
      expect(_box(c, 'b').x, 40);
      expect(c.guides, isEmpty);
    });

    testWidgets('Schalter in den Eigenschaften der Seite', (tester) async {
      final c = await pumpEditor(tester, _twoRects());
      c.select(null);
      await tester.pump();
      // nichts ausgewählt: rechts die Seite mit «Raster»
      await tester.tap(find.byKey(const ValueKey('prop-grid')));
      await tester.pump();
      expect(c.showGrid, isFalse);
      await tester.tap(find.byKey(const ValueKey('prop-snap')));
      await tester.pump();
      expect(c.snapToGrid, isFalse);
      await tester.tap(find.text('10 mm'));
      await tester.pump();
      expect(c.gridSize, 10);
    });

    testWidgets('Überlappung wird markiert; «Darunter verschieben» löst sie auf', (tester) async {
      final c = EditorController(sampleDocument(), spell: SpellChecker(WordListBackend(const [])));
      await pumpEditor(tester, c);
      final caption = c.page.elements.whereType<TextBlock>().firstWhere((t) => t.kind == TextKind.caption);
      final img = c.page.elements.whereType<ImageBlock>().first;
      // Bildunterschrift auf das Bild schieben
      c.select(caption.id);
      c.nudgeSelected(0, -20);
      await tester.pump();
      expect(find.byKey(ValueKey('overlap-${img.id}')), findsOneWidget);
      expect(find.byKey(const ValueKey('prop-overlap')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('move-below'))); // Eigenschaftenleiste scrollt
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('move-below')));
      await tester.pump();
      expect(find.byKey(ValueKey('overlap-${img.id}')), findsNothing);
      expect(renderedBox(c.page.find(caption.id)!).y, greaterThanOrEqualTo(img.box.bottom + 4));
    });
  });
}
