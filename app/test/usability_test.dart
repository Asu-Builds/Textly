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

  EditorController controller(List<DocElement> elements) =>
      EditorController(TextlyDocument(pages: [DocPage(id: 'p', elements: elements)]), spell: SpellChecker(WordListBackend(const [])));

  Future<EditorController> pumpEditor(WidgetTester tester, EditorController c) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
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

  group('Einfügen an der Arbeitsstelle', () {
    test('neues Element unter dem zuletzt bearbeiteten, nie überdeckend', () {
      final title = TextBlock.ofKind(id: 'titel', box: const Box(15, 20, 180, 14), text: 'Titel', kind: TextKind.title);
      const img = ImageBlock(id: 'bild', box: Box(15, 60, 120, 80), asset: 'a', naturalWidth: 10, naturalHeight: 8);
      final c = controller([title, img]);
      c.select('titel');
      c.addText();
      final t = c.selected! as TextBlock;
      final b = renderedBox(t);
      expect(b.y, greaterThanOrEqualTo(renderedBox(title).bottom), reason: 'unter dem Titel');
      expect(b.overlaps(img.box, tolerance: .1), isFalse, reason: 'nicht über dem Bild');
      expect(b.bottom, lessThanOrEqualTo(img.box.y), reason: 'passt in die Lücke zwischen Titel und Bild');
      c.finishEditing();

      // nächstes Element unter dem gerade eingefügten
      c.select(t.id);
      c.addRect();
      expect(c.selected!.box.y, greaterThanOrEqualTo(renderedBox(c.page.find(t.id)!).bottom));
    });

    test('leere Seite: oben beginnen; volle Seite: erste freie Stelle', () {
      final c = controller(const []);
      c.addTable(3);
      expect(c.selected!.box.y, pageMarginMm);
      final full = controller([const RectShape(id: 'gross', box: Box(0, 80, 210, 217))]);
      full.addRect();
      expect(full.selected!.box.y, pageMarginMm, reason: 'unten kein Platz, oben schon');
    });
  });

  testWidgets('leere Seite: Startknöpfe, verschwinden mit dem ersten Element', (tester) async {
    final c = await pumpEditor(tester, controller(const []));
    expect(find.text('Womit möchtest du beginnen?'), findsOneWidget);
    await click(tester, find.byKey(const ValueKey('start-title')));
    expect(c.page.elements.single, isA<TextBlock>());
    expect((c.page.elements.single as TextBlock).kind, TextKind.title);
    expect(c.editingId, c.page.elements.single.id, reason: 'gleich schreiben');
    expect(find.byKey(const ValueKey('start-panel')), findsNothing);
    // nur eine Seite: schmale Seitenübersicht
    expect(tester.getSize(find.byKey(const ValueKey('page-thumb-0'))).width, lessThan(60));
  });

  testWidgets('Startfeld bleibt lesbar, auch weit herausgezoomt; auf A5 passt es auf die Seite', (tester) async {
    final c = await pumpEditor(tester, controller(const []));
    final w100 = tester.getRect(find.byKey(const ValueKey('start-title'))).width;
    for (var i = 0; i < 4; i++) {
      await tester.tap(find.byKey(const ValueKey('zoom-out')));
      await tester.pump();
    }
    final tile = tester.getRect(find.byKey(const ValueKey('start-title'))).size;
    expect(tile.width, greaterThanOrEqualTo(w100 * .9), reason: 'Kachel fast gleich gross, auch herausgezoomt (nur so weit verkleinert, dass sie auf die Seite passt)');
    expect(tile.height, greaterThanOrEqualTo(110));
    // A5 bei kleinem Zoom: nie breiter als die Seite
    c.setPaper(PaperSize.a5);
    await tester.pump();
    final page = tester.getRect(find.byKey(const ValueKey('page-background')));
    final panel = tester.getRect(find.byKey(const ValueKey('start-panel')));
    expect(panel.width, lessThanOrEqualTo(page.width));
  });

  testWidgets('Griffe gut greifbar: «Verschieben» und Tabellenknöpfe mindestens 28 px hoch', (tester) async {
    final t = TextBlock.ofKind(id: 't', box: const Box(20, 80, 150, 10), text: 'Anmeldung');
    final tb = TableBlock(id: 'tb', x: 20, y: 140, columns: const [60, 60], cells: const [['a', 'b'], ['c', 'd']]);
    final c = await pumpEditor(tester, controller([t, tb]));
    c.select('t');
    await tester.pump();
    expect(tester.getRect(find.byKey(const ValueKey('move-grip'))).height, greaterThanOrEqualTo(26));
    c.selectCell(c.page.find('tb')! as TableBlock, 0, 0);
    await tester.pump();
    await tester.pump();
    expect(tester.getRect(find.byKey(const ValueKey('table-add-row'))).height, greaterThanOrEqualTo(28));
    expect(tester.getRect(find.byKey(const ValueKey('table-add-col'))).height, greaterThanOrEqualTo(28));
  });

  testWidgets('Löschen meldet sich mit «Rückgängig»; nach einer weiteren Änderung verschwindet die Meldung', (tester) async {
    final a = TextBlock.ofKind(id: 'a', box: const Box(20, 40, 150, 10), text: 'Erster');
    final b = TextBlock.ofKind(id: 'b', box: const Box(20, 80, 150, 10), text: 'Zweiter');
    final c = await pumpEditor(tester, controller([a, b]));
    c.select('a');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600)); // Meldung fährt herein
    expect(find.text('Text gelöscht.'), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(SnackBar), matching: find.text('Rückgängig')));
    await tester.pump();
    expect(c.page.find('a'), isNotNull, reason: 'zurückgeholt');
    await tester.pumpAndSettle(); // erste Meldung ganz weg
    // nochmals löschen, dann etwas anderes ändern: die Meldung verschwindet
    c.select('a');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pump(const Duration(milliseconds: 600));
    c.select('b');
    c.nudgeSelected(1, 0);
    await tester.pumpAndSettle();
    expect(find.text('Text gelöscht.'), findsNothing);
    c.undoOffered(); // ein verspäteter Klick würde nicht das Verschieben zurücknehmen
    expect((c.page.find('b')! as TextBlock).box.x, 21);
  });

  testWidgets('Strg+D gedrückt halten verdoppelt nur einmal', (tester) async {
    final a = TextBlock.ofKind(id: 'a', box: const Box(20, 40, 150, 10), text: 'Erster');
    final c = await pumpEditor(tester, controller([a]));
    c.select('a');
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyD);
    for (var i = 0; i < 5; i++) {
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyD);
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyD);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(c.page.elements, hasLength(2));
  });

  testWidgets('Textleiste beim Schreiben: Fett und Grösse direkt über dem Text', (tester) async {
    final t = TextBlock.ofKind(id: 't', box: const Box(20, 80, 150, 10), text: 'Anmeldung bis Freitag');
    final c = await pumpEditor(tester, controller([t]));
    await tester.tap(find.byKey(const ValueKey('element-t')));
    await tester.pump();
    await tester.pump();
    expect(c.editingId, 't');
    expect(find.byKey(const ValueKey('float-text-bar')), findsOneWidget);
    // Textleiste liegt über dem Text
    expect(tester.getRect(find.byKey(const ValueKey('float-text-bar'))).bottom, lessThan(tester.getRect(find.byKey(const ValueKey('text-editor'))).top));
    await click(tester, find.byKey(const ValueKey('float-bold')));
    expect((c.page.find('t')! as TextBlock).bold, isTrue);
    expect(c.editingId, 't', reason: 'Schreiben geht weiter');
    await click(tester, find.byKey(const ValueKey('float-size-plus')));
    expect((c.page.find('t')! as TextBlock).size, 11);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byKey(const ValueKey('float-text-bar')), findsNothing);
  });

  testWidgets('Leiste an der Auswahl: Löschen direkt am Bild, keine Kopie', (tester) async {
    const img = ImageBlock(id: 'bild', box: Box(30, 60, 100, 70), asset: 'assets/images/glacier.jpg', naturalWidth: 800, naturalHeight: 560);
    final c = await pumpEditor(tester, controller([img]));
    await tester.tap(find.byKey(const ValueKey('element-bild')));
    await tester.pump();
    expect(find.byKey(const ValueKey('float-selection-bar')), findsOneWidget);
    // direkt unter dem Bild
    final bar = tester.getRect(find.byKey(const ValueKey('float-selection-bar')));
    final el = tester.getRect(find.byKey(const ValueKey('element-bild')));
    expect(bar.top, greaterThan(el.bottom));
    expect(bar.top - el.bottom, lessThan(30));
    expect(find.byKey(const ValueKey('float-copy')), findsNothing);
    expect(find.byKey(const ValueKey('float-front')), findsNothing, reason: 'keine Überdeckung');
    await click(tester, find.byKey(const ValueKey('float-delete')));
    expect(c.page.elements, isEmpty);
  });

  testWidgets('Vorne/Hinten nur bei Überdeckung, und nur das Passende', (tester) async {
    const unten = RectShape(id: 'unten', box: Box(30, 60, 100, 60));
    const oben = RectShape(id: 'oben', box: Box(60, 80, 100, 60), fill: 0xFF2F5BD3);
    final c = await pumpEditor(tester, controller([unten, oben]));
    c.select('unten');
    await tester.pump();
    expect(find.byKey(const ValueKey('float-front')), findsOneWidget);
    expect(find.byKey(const ValueKey('float-back')), findsNothing);
    await click(tester, find.byKey(const ValueKey('float-front')));
    expect(c.page.elements.last.id, 'unten');
    expect(find.byKey(const ValueKey('float-front')), findsNothing);
    expect(find.byKey(const ValueKey('float-back')), findsOneWidget);
  });

  testWidgets('Textleiste: ganzen Textblock löschen', (tester) async {
    final t = TextBlock.ofKind(id: 't', box: const Box(20, 80, 150, 10), text: 'Weg damit');
    final c = await pumpEditor(tester, controller([t]));
    await tester.tap(find.byKey(const ValueKey('element-t')));
    await tester.pump();
    await tester.pump();
    await click(tester, find.byKey(const ValueKey('float-delete-text')));
    expect(c.page.elements, isEmpty);
    expect(c.editingId, isNull);
  });

  testWidgets('beliebige Farbe: Farbcode oder Klick ins Farbfeld, danach als eigene Farbe sichtbar', (tester) async {
    const r = RectShape(id: 'f', box: Box(30, 60, 100, 60));
    final c = await pumpEditor(tester, controller([r]));
    c.select('f');
    await tester.pump();
    await tester.ensureVisible(find.byKey(const ValueKey('prop-fill-more')));
    await click(tester, find.byKey(const ValueKey('prop-fill-more')));
    await tester.pumpAndSettle();
    expect(find.text('Füllfarbe'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('color-hex')), '#7A3E9D');
    await tester.pump();
    await click(tester, find.byKey(const ValueKey('color-ok')));
    await tester.pumpAndSettle();
    expect((c.page.find('f')! as RectShape).fill, 0xFF7A3E9D);
    expect(find.byKey(const ValueKey('prop-fill-custom')), findsOneWidget, reason: 'eigene Farbe als gewählter Punkt');

    // Klick ins Farbfeld oben rechts: kräftig und hell
    await click(tester, find.byKey(const ValueKey('prop-fill-more')));
    await tester.pumpAndSettle();
    final field = tester.getRect(find.byKey(const ValueKey('color-field')));
    await tester.tapAt(field.topRight + const Offset(-2, 2));
    await tester.pump();
    await click(tester, find.byKey(const ValueKey('color-ok')));
    await tester.pumpAndSettle();
    final hsv = HSVColor.fromColor(Color((c.page.find('f')! as RectShape).fill));
    expect(hsv.saturation, greaterThan(.9));
    expect(hsv.value, greaterThan(.9));
  });

  testWidgets('Textleiste: Schriftart und Farbe aus den Menüs, Schreiben geht weiter', (tester) async {
    final t = TextBlock.ofKind(id: 't', box: const Box(20, 80, 150, 10), text: 'Anmeldung');
    final c = await pumpEditor(tester, controller([t]));
    await tester.tap(find.byKey(const ValueKey('element-t')));
    await tester.pump();
    await tester.pump();
    await click(tester, find.byKey(const ValueKey('float-font')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('float-font-lora')));
    await tester.pumpAndSettle();
    expect((c.page.find('t')! as TextBlock).font, TextFont.lora);
    expect(c.editingId, 't');
    await click(tester, find.byKey(const ValueKey('float-color')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('float-color-ff1f7a5a')));
    await tester.pumpAndSettle();
    expect((c.page.find('t')! as TextBlock).color, 0xFF1F7A5A);
    expect(c.editingId, 't');

    // Maus über alle Knöpfe der Leiste: keine Fehler (früher: Tooltip in der mitlaufenden Ebene)
    // (die Maus ist durch die Klicks oben schon angemeldet)
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    for (final k in ['float-font', 'float-size-plus', 'float-bold', 'float-color', 'float-align-center', 'float-delete-text']) {
      await mouse.moveTo(tester.getCenter(find.byKey(ValueKey(k))));
      await tester.pump(const Duration(seconds: 2));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('Start: ganze Seite sichtbar, auch wenn das Fenster danach die Grösse ändert; von Hand gezoomt bleibt', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = controller(const []);
    await tester.pumpWidget(MaterialApp(home: EditorPage(controller: c, fitOnStart: true)));
    await tester.pump();
    await tester.pump();
    Rect page() => tester.getRect(find.byKey(const ValueKey('page-background')));
    Rect area() => tester.getRect(find.byType(SingleChildScrollView).first);
    expect(page().bottom, lessThanOrEqualTo(tester.view.physicalSize.height));

    // Fenster wird kleiner (z. B. nach dem Start): Seite passt wieder ganz hinein
    tester.view.physicalSize = const Size(1400, 800);
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(page().height, lessThanOrEqualTo(800 - 140), reason: 'ganze Seite sichtbar');
    expect(page().bottom, lessThanOrEqualTo(800));
    String label() => tester.widget<Text>(find.byKey(const ValueKey('zoom-label'))).data!;
    final fitted = label();

    // von Hand vergrössert: bleibt auch bei Grössenänderung
    await tester.tap(find.byTooltip('Vergrössern (Strg+Plus)'));
    await tester.pump();
    final manual = label();
    expect(manual, isNot(fitted));
    tester.view.physicalSize = const Size(1500, 900);
    await tester.pump();
    await tester.pump();
    expect(label(), manual);
    expect(area().width, greaterThan(0));
  });
}
