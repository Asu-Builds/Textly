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

  Future<EditorController> pumpEditor(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = EditorController(TextlyDocument(pages: [DocPage(id: 'p')]), spell: SpellChecker(WordListBackend(const [])));
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

  Future<void> clickAt(WidgetTester tester, Offset p) async {
    final g = await tester.startGesture(p, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 150));
    await g.up();
    await tester.pump(const Duration(milliseconds: 400));
  }

  TableBlock table(EditorController c) => c.page.elements.whereType<TableBlock>().single;

  /// Bildschirmpunkt einer Stelle der Tabelle (mm relativ zur Tabelle).
  Offset at(WidgetTester tester, EditorController c, double xMm, double yMm) {
    final t = table(c);
    final r = tester.getRect(find.byKey(ValueKey('element-${t.id}')));
    return Offset(r.left + xMm / t.width * r.width, r.top + yMm / tableHeightMm(t) * r.height);
  }

  testWidgets('Tabelle einfügen: Spalten direkt wählen, sofort in die erste Zelle schreiben, Tab', (tester) async {
    final c = await pumpEditor(tester);
    await click(tester, find.byKey(const ValueKey('tool-table')));
    await tester.pumpAndSettle();
    expect(find.text('Tabelle einfügen – wie viele Spalten?'), findsOneWidget);
    await click(tester, find.byKey(const ValueKey('table-cols-4')));
    await tester.pumpAndSettle();
    final t = table(c);
    expect((t.columnCount, t.rowCount, t.headerRow), (4, 3, true));
    expect(t.width, closeTo(c.doc.pageWidth - 2 * pageMarginMm, 1e-9), reason: 'zwischen den Seitenrändern');
    expect(c.selectedId, t.id);
    expect(c.editingCell, (row: 0, col: 0));

    await tester.enterText(find.byKey(const ValueKey('text-editor')), 'Datum');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(table(c).cells[0][0], 'Datum');
    expect(c.editingCell, (row: 0, col: 1));
    await tester.enterText(find.byKey(const ValueKey('text-editor')), 'Anlass');
    await tester.sendKeyEvent(LogicalKeyboardKey.tab, platform: 'windows');
    await tester.pump();
    expect(table(c).cells[0][1], 'Anlass');

    // nach der letzten Zelle entsteht mit Tab eine neue Zeile
    c.startCellEditing(table(c), 2, 3);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(table(c).rowCount, 4);
    expect(c.editingCell, (row: 3, col: 0));

    // Entf beim Schreiben löscht nicht die Tabelle
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pump();
    expect(c.page.elements.whereType<TableBlock>(), hasLength(1));
    c.finishEditing();
    // Rückgängig: die neue Zeile verschwindet wieder
    c.undo();
    expect(table(c).rowCount, 3);
  });

  testWidgets('Knöpfe an der Zelle: gleich beim Schreiben und Auswählen, Vorschau, einfügen und löschen', (tester) async {
    final c = await pumpEditor(tester);
    c.addTable(3);
    await tester.pump();
    // sofort beim Schreiben in der ersten Zelle sichtbar
    for (final k in ['table-add-col', 'table-add-row', 'table-del-row', 'table-del-col']) {
      expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
    }
    await tester.enterText(find.byKey(const ValueKey('text-editor')), 'Datum');
    await tester.pump();

    // Vorschau beim Zeigen
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.byKey(const ValueKey('table-add-row'))));
    await tester.pump();
    expect(find.byKey(const ValueKey('table-preview-addRow')), findsOneWidget);
    await mouse.moveTo(tester.getCenter(find.byKey(const ValueKey('table-del-row'))));
    await tester.pump();
    expect(find.byKey(const ValueKey('table-preview-deleteRow')), findsOneWidget);
    await mouse.moveTo(Offset.zero);
    await tester.pump();

    // «+ Zeile» beim Schreiben: Text bleibt, neue Zeile darunter, Cursor gleich dort
    await click(tester, find.byKey(const ValueKey('table-add-row')));
    expect(table(c).cells[0][0], 'Datum');
    expect(table(c).rowCount, 4);
    expect(c.editingCell, (row: 1, col: 0));
    // «+ Spalte»: rechts der Zelle, Tabelle bleibt gleich breit
    final w = table(c).width;
    await click(tester, find.byKey(const ValueKey('table-add-col')));
    expect(table(c).columnCount, 4);
    expect(table(c).width, closeTo(w, 1e-9));
    expect(c.editingCell, (row: 1, col: 1));
    // löschen am Rand: betrifft Zeile 2 bzw. Spalte 2
    await click(tester, find.byKey(const ValueKey('table-del-col')));
    expect(table(c).columnCount, 3);
    await click(tester, find.byKey(const ValueKey('table-del-row')));
    expect(table(c).rowCount, 3);
    expect(table(c).cells[0][0], 'Datum');

    // die Knöpfe bleiben auch nach dem Schreiben (Zelle gewählt)
    c.finishEditing();
    await tester.pump();
    expect(find.byKey(const ValueKey('table-add-row')), findsOneWidget);
    // anderes Element gewählt: keine Knöpfe
    c.select(null);
    await tester.pump();
    expect(find.byKey(const ValueKey('table-add-row')), findsNothing);
  });

  testWidgets('Rechtsklick: Zeile darüber, Spalte links; Spaltenlinie ziehen', (tester) async {
    final c = await pumpEditor(tester);
    c.addTable(3);
    c.finishEditing();
    await tester.pump();
    final t = table(c);
    final cell = at(tester, c, tableColumnEdges(t)[1] + 10, tableRowTops(t)[1] + 3);
    final g = await tester.startGesture(cell, kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
    await g.up();
    await tester.pumpAndSettle();
    expect(c.activeCell, (row: 1, col: 1));
    await tester.tap(find.byKey(const ValueKey('menu-row-above')));
    await tester.pumpAndSettle();
    expect(table(c).rowCount, 4);
    expect(c.editingCell, (row: 1, col: 1), reason: 'neue Zeile oberhalb, Cursor darin');

    // Spaltenlinie ziehen
    c.finishEditing();
    await tester.pump();
    final t3 = table(c);
    final start = at(tester, c, tableColumnEdges(t3)[1], tableRowTops(t3)[2] + 2);
    final before = t3.columns[0];
    final drag = await tester.startGesture(start, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 50));
    for (var i = 0; i < 6; i++) {
      await drag.moveBy(const Offset(10, 0));
      await tester.pump(const Duration(milliseconds: 30));
    }
    await drag.up();
    await tester.pump();
    expect(table(c).columns[0], greaterThan(before + 5));
    expect(table(c).width, closeTo(t3.width, 1e-6));
  });

  testWidgets('Eigenschaften: Vorlage, Linien, Spalte ausrichten', (tester) async {
    final c = await pumpEditor(tester);
    c.addTable(3);
    c.finishEditing();
    await tester.pump();
    expect(find.text('Wie soll die Tabelle aussehen?'), findsOneWidget);
    await click(tester, find.byKey(const ValueKey('prop-table-style-grid')));
    expect(table(c).style, TableStyle.grid);
    // Schriftgrösse wie bei Text: in Stufen, beliebig viele
    final plus = find.descendant(of: find.byKey(const ValueKey('prop-table-size')), matching: find.byKey(const ValueKey('prop-size-plus')));
    await tester.ensureVisible(plus);
    await click(tester, plus);
    await click(tester, plus);
    expect(table(c).size, 12);
    expect(find.text('12'), findsWidgets);
    expect(find.textContaining(' pt'), findsNothing);
    await tester.ensureVisible(find.byKey(const ValueKey('prop-table-lines-Waagrecht')));
    await click(tester, find.byKey(const ValueKey('prop-table-lines-Waagrecht')));
    expect(table(c).lines, TableLines.horizontal);

    // Zelle in Spalte 3 wählen, dann rechtsbündig und Zeile löschen
    final t = table(c);
    final cell = at(tester, c, tableColumnEdges(t)[2] + 10, tableRowTops(t)[1] + 3);
    await clickAt(tester, cell);
    expect(c.editingCell, (row: 1, col: 2));
    c.finishEditing();
    await tester.pump();
    await tester.ensureVisible(find.byKey(const ValueKey('prop-table-align-right')));
    await click(tester, find.byKey(const ValueKey('prop-table-align-right')));
    expect(table(c).align, [TextAlignment.left, TextAlignment.left, TextAlignment.right]);
    expect(c.activeCell, (row: 1, col: 2), reason: 'Zelle bleibt gewählt');
  });
}
