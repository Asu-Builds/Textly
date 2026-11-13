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

EditorController _controller() => EditorController(sampleDocument(), spell: SpellChecker(WordListBackend(const [])));

T _first<T extends DocElement>(EditorController c) => c.page.elements.whereType<T>().first;

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

  group('EditorController', () {
    test('Verschieben ist ein einziger Rückgängig-Schritt', () {
      final c = _controller();
      final img = _first<ImageBlock>(c);
      expect(c.beginGesture(img.id), isTrue);
      for (var i = 1; i <= 10; i++) {
        c.updateMove(i.toDouble(), i / 2, free: true);
      }
      c.endGesture();
      expect(c.page.find(img.id)!.box, img.box.translate(10, 5));
      expect(c.history.undoDepth, 1);
      c.undo();
      expect(c.page.find(img.id)!.box, img.box);
      c.redo();
      expect(c.page.find(img.id)!.box, img.box.translate(10, 5));
    });

    test('Bild: Eckgriff behält Seitenverhältnis, Seitengriff ändert die Form', () {
      final c = _controller();
      final img = _first<ImageBlock>(c);
      c.beginGesture(img.id);
      c.updateResize(Handle.se, -30, 0, free: true);
      c.endGesture();
      final a = c.page.find(img.id)!.box;
      expect(a.w / a.h, closeTo(img.box.w / img.box.h, 1e-9));
      expect(a.x, img.box.x);
      c.beginGesture(img.id);
      c.updateResize(Handle.s, 0, -40, free: true);
      c.endGesture();
      final b = c.page.find(img.id)!.box;
      expect(b.w, a.w);
      expect(b.h, a.h - 40);
    });

    test('Text: Seitengriff ändert nur die Breite, die Höhe folgt dem Text', () {
      final c = _controller();
      final t = c.page.elements.whereType<TextBlock>().firstWhere((e) => e.kind == TextKind.body);
      c.beginGesture(t.id);
      c.updateResize(Handle.e, 20, 0, free: true);
      c.endGesture();
      final wider = c.page.find(t.id) as TextBlock;
      expect(wider.box.w, t.box.w + 20);
      expect(renderedBox(wider).h, lessThan(renderedBox(t).h), reason: 'breiter = weniger Zeilen');
    });

    test('Linie: Endpunkt rastet waagrecht ein', () {
      final c = _controller();
      final l = _first<LineShape>(c);
      c.beginGesture(l.id);
      c.updateLineEnd(false, 5, 1.2, free: false);
      c.endGesture();
      final moved = c.page.find(l.id) as LineShape;
      expect(moved.b.y, l.a.y);
      expect(moved.b.x, l.b.x + 5);
    });

    test('Gesperrtes Element lässt sich nicht verschieben', () {
      final c = _controller();
      final img = _first<ImageBlock>(c);
      c.select(img.id);
      c.toggleLockSelected();
      expect(c.beginGesture(img.id), isFalse);
      c.updateMove(10, 10);
      c.endGesture();
      expect(c.page.find(img.id)!.box, img.box);
      c.nudgeSelected(5, 0);
      expect(c.page.find(img.id)!.box, img.box);
    });

    test('Pfeiltasten am selben Element ergeben einen Schritt', () {
      final c = _controller();
      final img = _first<ImageBlock>(c);
      c.select(img.id);
      for (var i = 0; i < 4; i++) {
        c.nudgeSelected(1, 0);
      }
      expect(c.history.undoDepth, 1);
      c.undo();
      expect(c.page.find(img.id)!.box, img.box);
    });

    test('Text bearbeiten ist ein Schritt; leerer Text entfernt den Block', () {
      final c = _controller();
      final t = _first<TextBlock>(c);
      c.startEditing(t, 0);
      c.textController.text = 'Herbstausflug';
      c.onEditingChanged();
      c.textController.text = 'Herbstausflug 2026';
      c.onEditingChanged();
      c.finishEditing();
      expect((c.page.find(t.id) as TextBlock).text, 'Herbstausflug 2026');
      expect(c.history.undoDepth, 1);
      c.undo();
      expect((c.page.find(t.id) as TextBlock).text, t.text);

      c.startEditing(t, 0);
      c.textController.text = '   ';
      c.finishEditing();
      expect(c.page.find(t.id), isNull);
      expect(c.selectedId, isNull);
      c.undo();
      expect(c.page.find(t.id), isNotNull);
    });

    test('Rückgängig während der Bearbeitung übernimmt zuerst den Text', () {
      final c = _controller();
      final t = _first<TextBlock>(c);
      c.startEditing(t, 0);
      c.textController.text = 'Neu';
      c.onEditingChanged();
      expect(c.canUndo, isTrue);
      c.undo();
      expect((c.page.find(t.id) as TextBlock).text, t.text);
      expect(c.editingId, isNull);
    });

    test('Löschen, Duplizieren, Reihenfolge und Seiten mit Rückgängig', () {
      final c = _controller();
      final img = _first<ImageBlock>(c);
      final count = c.page.elements.length;
      c.select(img.id);
      c.duplicateSelected();
      expect(c.page.elements.length, count + 1);
      expect(c.selected!.box, img.box.translate(5, 5));
      c.deleteSelected();
      expect(c.page.elements.length, count);
      c.select(img.id);
      c.bringSelectedToFront();
      expect(c.page.elements.last.id, img.id);
      c.addPage();
      expect(c.doc.pages.length, 3);
      expect(c.pageIndex, 1);
      c.undo();
      expect(c.doc.pages.length, 2);
      expect(c.pageIndex, 1);
    });
  });

  group('Arbeitsfläche', () {
    Future<EditorController> pumpEditor(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = _controller();
      await tester.pumpWidget(MaterialApp(home: EditorPage(controller: c)));
      await tester.pump();
      return c;
    }

    testWidgets('Bild anklicken und ziehen verschiebt es; Strg+Z macht es rückgängig', (tester) async {
      final c = await pumpEditor(tester);
      final img = _first<ImageBlock>(c);
      final finder = find.byKey(ValueKey('element-${img.id}'));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft); // ohne Einrasten
      await tester.drag(finder, const Offset(60, 30));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
      final moved = c.page.find(img.id)!.box;
      // 60 Bildpunkte bei Zoom 1.2 → 60 / 1.2 pt → in mm
      expect(moved.x - img.box.x, closeTo(60 / 1.2 / mmToPt, .5));
      expect(moved.y - img.box.y, closeTo(30 / 1.2 / mmToPt, .5));
      expect(c.selectedId, img.id);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(c.page.find(img.id)!.box, img.box);
    });

    testWidgets('Eckgriff am Bild ziehen ändert die Grösse proportional', (tester) async {
      final c = await pumpEditor(tester);
      final img = _first<ImageBlock>(c);
      await tester.tap(find.byKey(ValueKey('element-${img.id}')));
      await tester.pump();
      await tester.drag(find.byKey(const ValueKey('handle-se')), const Offset(-120, 0));
      await tester.pump();
      final b = c.page.find(img.id)!.box;
      expect(b.w, lessThan(img.box.w - 20));
      expect(b.w / b.h, closeTo(img.box.w / img.box.h, 1e-6));
    });

    testWidgets('Text: ein Klick setzt den Cursor, Klick daneben übernimmt', (tester) async {
      final c = await pumpEditor(tester);
      final t = _first<TextBlock>(c);
      final finder = find.byKey(ValueKey('element-${t.id}'));
      await tester.tap(finder);
      await tester.pump();
      await tester.pump();
      expect(c.selectedId, t.id);
      expect(c.editingId, t.id, reason: 'ein Klick genügt (wie in Word)');
      expect(find.byKey(const ValueKey('text-editor')), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('text-editor')), 'Herbstausflug 2026');
      await tester.pump();
      await tester.tapAt(const Offset(1250, 600)); // neben die Seite
      await tester.pump();
      expect(c.editingId, isNull);
      expect((c.page.find(t.id) as TextBlock).text, 'Herbstausflug 2026');
    });

    testWidgets('Entf löscht das ausgewählte Element', (tester) async {
      final c = await pumpEditor(tester);
      final img = _first<ImageBlock>(c);
      await tester.tap(find.byKey(ValueKey('element-${img.id}')));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pump();
      expect(c.page.find(img.id), isNull);
    });

    testWidgets('Textblock am Griff «Verschieben» ziehen', (tester) async {
      final c = await pumpEditor(tester);
      final t = _first<TextBlock>(c);
      await tester.tap(find.byKey(ValueKey('element-${t.id}')));
      await tester.pump();
      // Maus: Die Arbeitsfläche scrollt sonst bei einem Touch-Zug mit
      await tester.drag(find.byKey(const ValueKey('move-grip')), const Offset(0, 120), kind: PointerDeviceKind.mouse);
      await tester.pump();
      expect(c.page.find(t.id)!.box.y - t.box.y, closeTo(120 / 1.2 / mmToPt, .5));
      expect((c.page.find(t.id) as TextBlock).text, t.text);
    });
  });

  // Echte Mausbedienung: Taste wird eine Weile gehalten, Bewegungen kommen in Schritten.
  // (tester.tap/drag sind «unendlich schnell» und haben einen Fehler übersehen, siehe unten.)
  group('Arbeitsfläche mit echter Maus', () {
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
      await tester.pump(const Duration(milliseconds: 400)); // kein Doppelklick
    }

    Future<void> drag(WidgetTester tester, Offset from, Offset by) async {
      final g = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 200));
      for (var i = 1; i <= 10; i++) {
        await g.moveTo(from + by * (i / 10));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await tester.pump();
    }

    testWidgets('Textblock am Griff verschieben', (tester) async {
      final c = await pumpEditor(tester);
      final t = _first<TextBlock>(c);
      await click(tester, tester.getCenter(find.byKey(ValueKey('element-${t.id}'))));
      expect(c.selectedId, t.id);
      await drag(tester, tester.getCenter(find.byKey(const ValueKey('move-grip'))), const Offset(0, 120));
      expect(c.page.find(t.id)!.box.y - t.box.y, closeTo(120 / 1.2 / mmToPt, .5));
      expect(c.selectedId, t.id);
    });

    testWidgets('Textblock am Seitengriff breiter machen', (tester) async {
      final c = await pumpEditor(tester);
      final t = c.page.elements.whereType<TextBlock>().firstWhere((e) => e.kind == TextKind.body);
      await click(tester, tester.getCenter(find.byKey(ValueKey('element-${t.id}'))));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft); // ohne Einrasten
      await drag(tester, tester.getCenter(find.byKey(const ValueKey('handle-e'))), const Offset(60, 0));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      expect(c.page.find(t.id)!.box.w - t.box.w, closeTo(60 / 1.2 / mmToPt, .5));
    });

    testWidgets('Bild am Eckgriff verkleinern', (tester) async {
      final c = await pumpEditor(tester);
      final img = _first<ImageBlock>(c);
      await click(tester, tester.getCenter(find.byKey(ValueKey('element-${img.id}'))));
      await drag(tester, tester.getCenter(find.byKey(const ValueKey('handle-se'))), const Offset(-120, 0));
      expect(c.page.find(img.id)!.box.w, lessThan(img.box.w - 20));
    });

    testWidgets('Beim Schreiben: Klick setzt Cursor, Ziehen und Doppelklick markieren, Bearbeitung bleibt', (tester) async {
      final c = await pumpEditor(tester);
      final t = c.page.elements.whereType<TextBlock>().firstWhere((e) => e.kind == TextKind.body);
      final block = tester.getRect(find.byKey(ValueKey('element-${t.id}')));
      await click(tester, block.topLeft + const Offset(30, 10));
      await click(tester, block.topLeft + const Offset(30, 10));
      await tester.pump();
      expect(c.editingId, t.id);

      // Klick an eine andere Stelle im Text: Cursor wandert, Bearbeitung bleibt
      final before = c.textController.selection.baseOffset;
      await click(tester, block.topLeft + const Offset(150, 30));
      expect(c.editingId, t.id, reason: 'zweiter Klick im Text darf die Bearbeitung nicht beenden');
      expect(c.selectedId, t.id);
      expect(c.textController.selection.baseOffset, isNot(before));

      // Mit der Maus über Text ziehen markiert
      await drag(tester, block.topLeft + const Offset(10, 10), const Offset(120, 0));
      expect(c.editingId, t.id);
      expect(c.textController.selection.isCollapsed, isFalse, reason: 'Ziehen muss Text markieren');

      // Doppelklick markiert ein Wort
      final at = block.topLeft + const Offset(60, 30);
      final g1 = await tester.startGesture(at, kind: PointerDeviceKind.mouse);
      await g1.up();
      await tester.pump(const Duration(milliseconds: 80));
      final g2 = await tester.startGesture(at, kind: PointerDeviceKind.mouse);
      await g2.up();
      await tester.pump(const Duration(milliseconds: 400));
      expect(c.editingId, t.id);
      final sel = c.textController.selection;
      expect(sel.isCollapsed, isFalse, reason: 'Doppelklick muss ein Wort markieren');
      expect(c.textController.text.substring(sel.start, sel.end).contains(' '), isFalse);
    });
  });
}
