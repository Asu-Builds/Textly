import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:doc_exchange/doc_exchange.dart';
import 'package:doc_model/doc_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:textly/editor/editor_controller.dart';
import 'package:textly/editor/editor_page.dart';
import 'package:textly/files/services.dart';
import 'package:textly/library/document_library.dart';
import 'package:textly/library/home_page.dart';
import 'package:textly/spell/spell_check.dart';

Future<ByteData> _fromDisk(String key) async => ByteData.sublistView(await File(key).readAsBytes());

class _Picker implements FilePicker {
  final answers = <String?>[];
  final suggested = <String>[];
  @override
  Future<String?> pickOpen({required String label, required List<String> extensions}) async => answers.isEmpty ? null : answers.removeAt(0);
  @override
  Future<String?> pickSave({required String suggestedName, required String label, required List<String> extensions}) async {
    suggested.add(suggestedName);
    return answers.isEmpty ? null : answers.removeAt(0);
  }
}

TextlyDocument _doc(String title) => TextlyDocument(pages: [
      DocPage(id: 'p', elements: [TextBlock.ofKind(id: 't', box: const Box(20, 20, 150, 10), text: title, kind: TextKind.title)]),
    ]);

/// Dateizugriff, der auf Wunsch versagt (gesperrte Datei, Speicher voll, Ordner offline).
class _FlakyFiles extends MemoryFileAccess {
  bool failWrites = false, failReads = false;

  @override
  Future<void> write(String path, Uint8List bytes) async {
    if (failWrites && path.startsWith('C:/Textly')) throw const FileSystemException('gesperrt');
    return super.write(path, bytes);
  }

  @override
  Future<Uint8List> read(String path) async {
    if (failReads && path.startsWith('C:/Textly')) throw const FileSystemException('offline');
    return super.read(path);
  }
}

class _Env {
  final fs = _FlakyFiles();
  final picker = _Picker();
  late final services = AppServices(picker: picker, files: fs, loadAsset: (k) async => File(k).readAsBytesSync(), setWindowTitle: (_) {});
  late final lib = DocumentLibrary(fs, 'C:/Textly', loadAsset: services.loadAsset);
  EditorController? last;

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: HomePage(
        library: lib,
        services: services,
        autosaveDelay: const Duration(milliseconds: 20),
        newController: (d) => last = EditorController(d, spell: SpellChecker(WordListBackend(const []))),
      ),
    ));
    await settle(tester);
  }

  /// Dateizugriffe (Futures), Zeitgeber und Seitenübergänge abarbeiten.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }
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

  testWidgets('Öffnen, ändern, automatisch gespeichert, zurück: Name folgt dem Titel', (tester) async {
    final env = _Env();
    final e = await env.lib.create(_doc('Herbstausflug'));
    await env.pump(tester);
    expect(find.text('Herbstausflug'), findsOneWidget);

    await tester.tap(find.byKey(ValueKey('doc-card-${e.id}')));
    await env.settle(tester);
    expect(find.byType(EditorPage), findsOneWidget);
    expect(find.textContaining('gespeichert'), findsNothing, reason: 'Speichern geschieht still');
    expect(find.byKey(const ValueKey('menu-file')), findsNothing, reason: 'kein Datei-Menü, kein Speichern');

    final c = env.last!;
    final t = c.page.elements.single as TextBlock;
    c.commit(c.doc.replaceElement(0, t.copyWith(text: 'Winterwanderung')));
    await tester.pump();
    await env.settle(tester);
    expect(find.textContaining('gespeichert'), findsNothing);
    expect(tester.widget<Text>(find.byKey(const ValueKey('doc-title'))).data, 'Winterwanderung', reason: 'Name folgt dem ersten Text');
    expect(((await env.lib.load(e.id)).page(0).elements.single as TextBlock).text, 'Winterwanderung');

    await tester.tap(find.byKey(const ValueKey('go-home')));
    await env.settle(tester);
    expect(find.byType(EditorPage), findsNothing);
    expect(find.text('Winterwanderung'), findsOneWidget);
  });

  testWidgets('Name im Kopf ändern: Enter übernimmt, Esc bricht ab, leer folgt wieder dem Titel', (tester) async {
    final env = _Env();
    final e = await env.lib.create(_doc('Herbstausflug'));
    await env.pump(tester);
    await tester.tap(find.byKey(ValueKey('doc-card-${e.id}')));
    await env.settle(tester);
    String title() => tester.widget<Text>(find.byKey(const ValueKey('doc-title'))).data!;
    expect(title(), 'Herbstausflug');
    final c = env.last!;
    c.select(c.page.elements.single.id);
    await tester.pump();

    // Klick auf den Namen: Eingabefeld; Rücktaste löscht im Feld, nicht das ausgewählte Element
    await tester.tap(find.byKey(const ValueKey('doc-name')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('doc-name-field')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(c.page.elements, hasLength(1));
    await tester.enterText(find.byKey(const ValueKey('doc-name-field')), 'Ausflug Säntis');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await env.settle(tester);
    expect(title(), 'Ausflug Säntis');
    expect((await env.lib.entries()).single.name, 'Ausflug Säntis');

    // Eigener Name bleibt, auch wenn sich der Titel ändert
    c.commit(c.doc.replaceElement(0, (c.page.elements.single as TextBlock).copyWith(text: 'Wanderung')));
    await env.settle(tester);
    expect(title(), 'Ausflug Säntis');

    // Esc bricht ab
    await tester.tap(find.byKey(const ValueKey('doc-name')));
    await tester.pump();
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('doc-name-field')), 'Falsch');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await env.settle(tester);
    expect(title(), 'Ausflug Säntis');

    // Leer: Name folgt wieder dem ersten Text
    await tester.tap(find.byKey(const ValueKey('doc-name')));
    await tester.pump();
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('doc-name-field')), '');
    await tester.tap(find.byKey(const ValueKey('doc-name-ok')));
    await env.settle(tester);
    expect(title(), 'Wanderung');
  });

  testWidgets('Meldung «im Papierkorb» verschwindet von selbst und kommt nicht mit ins Dokument', (tester) async {
    final env = _Env();
    final a = await env.lib.create(_doc('Alt'));
    final b = await env.lib.create(_doc('Neu'));
    await env.pump(tester);
    await tester.tap(find.byKey(ValueKey('doc-menu-${a.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('doc-trash')));
    await env.settle(tester);
    expect(find.text('«Alt» liegt im Papierkorb.'), findsOneWidget);

    // anderes Dokument öffnen: Meldung ist weg
    await tester.tap(find.byKey(ValueKey('doc-card-${b.id}')));
    await env.settle(tester);
    expect(find.byType(EditorPage), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('«Alt» liegt im Papierkorb.'), findsNothing);
    expect(find.byType(SnackBar), findsNothing);

    // zurück und nochmals löschen: nach einigen Sekunden von selbst weg
    await tester.tap(find.byKey(const ValueKey('go-home')));
    await env.settle(tester);
    await tester.tap(find.byKey(ValueKey('doc-menu-${b.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('doc-trash')));
    await env.settle(tester);
    expect(find.byType(SnackBar), findsOneWidget);
    await tester.pump(const Duration(seconds: 7));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('Word-Datei hereinholen: Text auf A4-Seiten, Hinweise bleiben im Dokument sichtbar', (tester) async {
    final env = _Env();
    const w = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"';
    final a = Archive();
    final xml = utf8.encode('<w:document $w><w:body>'
        '<w:p><w:pPr><w:pStyle w:val="Title"/></w:pPr><w:r><w:t>Einladung</w:t></w:r></w:p>'
        '<w:p><w:r><w:t>Liebe Mitglieder</w:t></w:r></w:p>'
        '<w:p><w:r><w:drawing><pic:pic xmlns:pic="p"/></w:drawing></w:r></w:p>'
        '</w:body></w:document>');
    a.addFile(ArchiveFile('word/document.xml', xml.length, xml));
    final styles = utf8.encode('<w:styles $w><w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/></w:style></w:styles>');
    a.addFile(ArchiveFile('word/styles.xml', styles.length, styles));
    await env.fs.write('C:/Einladung.docx', Uint8List.fromList(ZipEncoder().encode(a)));
    await env.pump(tester);
    env.picker.answers.add('C:/Einladung.docx');
    await tester.tap(find.byKey(const ValueKey('home-import')));
    await env.settle(tester);
    expect(find.byType(EditorPage), findsOneWidget, reason: 'gleich geöffnet');
    final c = env.last!;
    final texts = c.page.elements.whereType<TextBlock>().toList();
    expect(texts.map((t) => (t.kind, t.text)), [(TextKind.title, 'Einladung'), (TextKind.body, 'Liebe Mitglieder')]);
    expect(texts[1].box.y, greaterThanOrEqualTo(texts[0].box.bottom));
    expect(find.textContaining('1 Bild wurde nicht übernommen.'), findsOneWidget, reason: 'Hinweis im geöffneten Dokument');
    expect((await env.lib.entries()).single.name, 'Einladung');
    await tester.tap(find.byKey(const ValueKey('go-home')));
    await env.settle(tester);
  });

  testWidgets('Als Kopie verwenden: Original bleibt; Papierkorb und Wiederherstellen', (tester) async {
    final env = _Env();
    final e = await env.lib.create(_doc('Flyer 2025'));
    await env.pump(tester);

    await tester.tap(find.byKey(ValueKey('doc-menu-${e.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('doc-copy')));
    await env.settle(tester);
    expect(find.byType(EditorPage), findsOneWidget, reason: 'die Kopie wird gleich geöffnet');
    final c = env.last!;
    c.commit(c.doc.replaceElement(0, (c.page.elements.single as TextBlock).copyWith(text: 'Flyer 2026')));
    await env.settle(tester);
    await tester.tap(find.byKey(const ValueKey('go-home')));
    await env.settle(tester);
    expect(find.text('Flyer 2025'), findsOneWidget, reason: 'Original unverändert');
    expect(find.text('Kopie von Flyer 2025'), findsOneWidget, reason: 'eigener Name bleibt');

    await tester.tap(find.byKey(ValueKey('doc-menu-${e.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('doc-trash')));
    await env.settle(tester);
    expect(find.text('Flyer 2025'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('home-nav-trash')));
    await env.settle(tester);
    expect(find.text('Flyer 2025'), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('trash-restore-${e.id}')));
    await env.settle(tester);
    expect(find.text('Der Papierkorb ist leer.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('home-nav-docs')));
    await env.settle(tester);
    expect(find.text('Flyer 2025'), findsOneWidget);
  });

  testWidgets('Datei hereinholen: Kopie in «Meine Dokumente», Original bleibt', (tester) async {
    final env = _Env();
    env.fs.files['E:/Stick/Einladung.textly'] = encodeTextly(_doc('Einladung GV'));
    await env.pump(tester);
    env.picker.answers.add('E:/Stick/Einladung.textly');
    await tester.tap(find.byKey(const ValueKey('home-import')));
    await env.settle(tester);
    expect(find.byType(EditorPage), findsOneWidget);
    final c = env.last!;
    c.commit(c.doc.replaceElement(0, (c.page.elements.single as TextBlock).copyWith(text: 'Geändert')));
    await env.settle(tester);
    final original = decodeTextly(env.fs.files['E:/Stick/Einladung.textly']!);
    expect((original.page(0).elements.single as TextBlock).text, 'Einladung GV', reason: 'Datei auf dem Stick unverändert');
    expect((await env.lib.entries()).single.name, 'Einladung');
  });

  testWidgets('Teilen: Kopie zum Weiterbearbeiten; Strg+S speichert ohne Dialog', (tester) async {
    final env = _Env();
    final e = await env.lib.create(_doc('Programm'));
    await env.pump(tester);
    await tester.tap(find.byKey(ValueKey('doc-card-${e.id}')));
    await env.settle(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await env.settle(tester);
    expect(env.picker.suggested, isEmpty, reason: 'kein Speichern-Dialog');
    expect(find.textContaining('speichert jede Änderung automatisch'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('tool-finish')));
    await env.settle(tester);
    expect(find.text('Per E-Mail senden'), findsOneWidget);
    env.picker.answers.add('E:/Stick/Programm');
    await tester.tap(find.byKey(const ValueKey('finish-textly')));
    await env.settle(tester);
    expect(env.picker.suggested, ['Programm.textly']);
    expect(env.fs.files.containsKey('E:/Stick/Programm.textly'), isTrue);
  });

  testWidgets('leeres Blatt mit Format, leer wieder verlassen: bleibt nicht liegen', (tester) async {
    final env = _Env();
    await env.pump(tester);
    // Format auf der Kachel wählen, dann aufs Blatt klicken
    await tester.ensureVisible(find.byKey(const ValueKey('home-new-blank')));
    await tester.tap(find.byKey(const ValueKey('home-paper-a5')));
    await tester.tap(find.byKey(const ValueKey('home-orient-landscape')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('home-new-blank')));
    await env.settle(tester);
    expect(env.last!.doc.orientation, PageOrientation.landscape);
    expect(env.last!.doc.paper, PaperSize.a5);
    await tester.tap(find.byKey(const ValueKey('go-home')));
    await env.settle(tester);
    expect(await env.lib.entries(), isEmpty);
  });

  testWidgets('Vorlagen: mitgelieferte nutzen, eigene speichern, daraus neu beginnen, Filter, Seite «Vorlagen»', (tester) async {
    final env = _Env();
    final e = await env.lib.create(_doc('Vereinsprogramm 2027'));
    await env.pump(tester);

    // mitgelieferte Vorlage: Klick legt ein neues Dokument an und öffnet es
    await tester.ensureVisible(find.byKey(const ValueKey('tpl-builtin-flyer')));
    await tester.tap(find.byKey(const ValueKey('tpl-builtin-flyer')));
    await env.settle(tester);
    expect(find.byType(EditorPage), findsOneWidget);
    expect(env.last!.doc.paper, PaperSize.a5, reason: 'Flyer ist A5');
    expect(find.textContaining('aus der Vorlage «Flyer»'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('go-home')));
    await env.settle(tester);
    expect((await env.lib.entries()).map((x) => x.name), contains('Sommerfest'), reason: 'neues Dokument, Name aus dem Titel');

    // eigenes Dokument als Vorlage speichern
    await tester.tap(find.byKey(ValueKey('doc-menu-${e.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('doc-template')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('tpl-name')), 'Programm');
    await tester.tap(find.byKey(const ValueKey('tpl-kind-programm')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('tpl-save')));
    await env.settle(tester);
    final tpls = await env.lib.entries(templates: true);
    expect(tpls.single.name, 'Programm');
    expect(tpls.single.templateKind, 'programm');
    expect((await env.lib.entries()).where((x) => x.name == 'Programm'), isEmpty, reason: 'Vorlagen nicht unter den Dokumenten');
    expect(find.byKey(ValueKey('tpl-card-${tpls.single.id}')), findsOneWidget, reason: 'unter «Neu beginnen»');

    // Filter «Meine Vorlagen»: nur die eigene, kein leeres Blatt, keine mitgelieferten
    await tester.ensureVisible(find.byKey(const ValueKey('home-filter-mine')));
    await tester.tap(find.byKey(const ValueKey('home-filter-mine')));
    await tester.pump();
    expect(find.byKey(const ValueKey('tpl-builtin-flyer')), findsNothing);
    expect(find.byKey(const ValueKey('home-new-blank')), findsNothing);

    // daraus neu beginnen: Kopie, Vorlage bleibt
    final before = (await env.lib.entries()).length;
    await tester.tap(find.byKey(ValueKey('tpl-card-${tpls.single.id}')));
    await env.settle(tester);
    expect(find.byType(EditorPage), findsOneWidget);
    final c = env.last!;
    c.commit(c.doc.replaceElement(0, (c.page.elements.single as TextBlock).copyWith(text: 'Programm 2028')));
    await env.settle(tester);
    await tester.tap(find.byKey(const ValueKey('go-home')));
    await env.settle(tester);
    expect((await env.lib.entries()).length, before + 1);
    expect(((await env.lib.load(tpls.single.id)).page(0).elements.single as TextBlock).text, 'Vereinsprogramm 2027', reason: 'Vorlage unverändert');

    // Seite «Vorlagen»
    await tester.tap(find.byKey(const ValueKey('home-nav-templates')));
    await env.settle(tester);
    expect(find.text('Vorlagen'), findsWidgets);
    expect(find.byKey(ValueKey('tpl-card-${tpls.single.id}')), findsOneWidget);
    expect(find.byKey(const ValueKey('tpl-builtin-einladung')), findsOneWidget);
  });

  testWidgets('Speichern klappt nicht: beim Verlassen fragen statt Änderungen still verlieren', (tester) async {
    final env = _Env();
    final e = await env.lib.create(_doc('Herbstausflug'));
    await env.pump(tester);
    await tester.tap(find.byKey(ValueKey('doc-card-${e.id}')));
    await env.settle(tester);
    final c = env.last!;
    env.fs.failWrites = true;
    c.commit(c.doc.replaceElement(0, (c.page.elements.single as TextBlock).copyWith(text: 'Winterwanderung')));
    await env.settle(tester);
    expect(find.text('Nicht gespeichert'), findsOneWidget, reason: 'Hinweis im Kopf');

    // Strg+S bestätigt nicht fälschlich
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await env.settle(tester);
    expect(find.textContaining('Alles gespeichert'), findsNothing);
    expect(find.textContaining('Speichern hat gerade nicht geklappt'), findsOneWidget);

    // Verlassen: Rückfrage, «Abbrechen» bleibt im Dokument
    await tester.tap(find.byKey(const ValueKey('go-home')));
    await env.settle(tester);
    expect(find.byKey(const ValueKey('save-failed')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('save-failed-stay')));
    await env.settle(tester);
    expect(find.byType(EditorPage), findsOneWidget);

    // Datei wieder frei: «Nochmals versuchen» speichert und schliesst
    await tester.tap(find.byKey(const ValueKey('go-home')));
    await env.settle(tester);
    env.fs.failWrites = false;
    await tester.tap(find.byKey(const ValueKey('save-failed-retry')));
    await env.settle(tester);
    expect(find.byType(EditorPage), findsNothing);
    expect(((await env.lib.load(e.id)).page(0).elements.single as TextBlock).text, 'Winterwanderung', reason: 'nichts verloren');
  });

  testWidgets('Speichern klappt nicht: Kopie an einem anderen Ort sichern', (tester) async {
    final env = _Env();
    final e = await env.lib.create(_doc('Herbstausflug'));
    await env.pump(tester);
    await tester.tap(find.byKey(ValueKey('doc-card-${e.id}')));
    await env.settle(tester);
    final c = env.last!;
    env.fs.failWrites = true;
    c.commit(c.doc.replaceElement(0, (c.page.elements.single as TextBlock).copyWith(text: 'Gerettet')));
    await env.settle(tester);
    await tester.tap(find.byKey(const ValueKey('go-home')));
    await env.settle(tester);
    env.picker.answers.add('D:/Stick/Herbstausflug');
    await tester.tap(find.byKey(const ValueKey('save-failed-copy')));
    await env.settle(tester);
    expect(find.byType(EditorPage), findsNothing);
    final copy = decodeTextly(env.fs.files['D:/Stick/Herbstausflug.textly']!);
    expect((copy.page(0).elements.single as TextBlock).text, 'Gerettet');
  });

  testWidgets('Liste gerade nicht lesbar: Hinweis statt leerer Liste, nichts wird überschrieben', (tester) async {
    final env = _Env();
    final a = await env.lib.create(_doc('Herbstausflug'));
    final b = await env.lib.create(_doc('Sommerfest'));
    final before = env.fs.files['C:/Textly/bibliothek.json'];
    env.fs.failReads = true;
    // frische Bibliothek (wie nach einem Neustart der App), damit nichts aus dem Speicher kommt
    final lib = DocumentLibrary(env.fs, 'C:/Textly', loadAsset: env.services.loadAsset);
    tester.view.physicalSize = const Size(1600, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: HomePage(library: lib, services: env.services, newController: (d) => EditorController(d, spell: SpellChecker(WordListBackend(const [])))),
    ));
    await env.settle(tester);
    expect(find.byKey(const ValueKey('home-unavailable')), findsOneWidget);
    // «Neues Dokument» überschreibt die Liste nicht
    await tester.tap(find.byKey(const ValueKey('home-new')));
    await env.settle(tester);
    expect(find.byType(EditorPage), findsNothing);
    expect(env.fs.files['C:/Textly/bibliothek.json'], before, reason: 'Liste unverändert');
    // Ordner wieder erreichbar
    env.fs.failReads = false;
    await tester.tap(find.byKey(const ValueKey('home-retry')));
    await env.settle(tester);
    expect(find.byKey(const ValueKey('home-unavailable')), findsNothing);
    expect(find.byKey(ValueKey('doc-card-${a.id}')), findsOneWidget);
    expect(find.byKey(ValueKey('doc-card-${b.id}')), findsOneWidget);
  });

  testWidgets('Liste beschädigt: Sicherung und Neuaufbau aus den Dokumentdateien', (tester) async {
    final env = _Env();
    final a = await env.lib.create(_doc('Herbstausflug'));
    final b = await env.lib.create(_doc('Sommerfest'));
    env.fs.files['C:/Textly/bibliothek.json'] = Uint8List.fromList(utf8.encode('{kaputt'));
    final lib = DocumentLibrary(env.fs, 'C:/Textly', loadAsset: env.services.loadAsset);
    tester.view.physicalSize = const Size(1600, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: HomePage(library: lib, services: env.services, newController: (d) => EditorController(d, spell: SpellChecker(WordListBackend(const [])))),
    ));
    await env.settle(tester);
    expect(find.byKey(ValueKey('doc-card-${a.id}')), findsOneWidget);
    expect(find.byKey(ValueKey('doc-card-${b.id}')), findsOneWidget);
    expect(find.text('Sommerfest'), findsOneWidget, reason: 'Name aus dem Inhalt');
    expect(find.textContaining('neu aufgebaut'), findsOneWidget);
    expect(utf8.decode(env.fs.files['C:/Textly/bibliothek.defekt.json']!), '{kaputt', reason: 'Original aufbewahrt');
  });

  testWidgets('Doppelklick auf eine Dokumentkarte öffnet das Dokument nur einmal', (tester) async {
    final env = _Env();
    final e = await env.lib.create(_doc('Herbstausflug'));
    await env.pump(tester);
    await tester.tap(find.byKey(ValueKey('doc-card-${e.id}')));
    await tester.tap(find.byKey(ValueKey('doc-card-${e.id}')));
    await env.settle(tester);
    expect(find.byType(EditorPage, skipOffstage: false), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('go-home')));
    await env.settle(tester);
    // auch eine Vorlage legt bei Doppelklick nur ein Dokument an
    await tester.ensureVisible(find.byKey(const ValueKey('tpl-builtin-brief')));
    await tester.tap(find.byKey(const ValueKey('tpl-builtin-brief')));
    await tester.tap(find.byKey(const ValueKey('tpl-builtin-brief')));
    await env.settle(tester);
    expect(find.byType(EditorPage, skipOffstage: false), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('go-home')));
    await env.settle(tester);
    expect((await env.lib.entries()).length, 2);
  });

  testWidgets('«Neues Dokument» führt zu «Neu beginnen»; ohne Dokumente steht es zuoberst', (tester) async {
    final env = _Env();
    await env.pump(tester);
    expect(find.byKey(const ValueKey('home-empty')), findsOneWidget);
    expect(find.text('Zuletzt bearbeitet'), findsNothing);
    expect(tester.getRect(find.byKey(const ValueKey('home-new-blank'))).top, lessThan(tester.getRect(find.byKey(const ValueKey('home-import'))).top));
    // mit vielen Dokumenten und einer Suche: der Knopf leert die Suche und zeigt «Neu beginnen»
    for (var i = 0; i < 12; i++) {
      await env.lib.create(_doc('Dokument $i'));
    }
    await tester.tap(find.byKey(const ValueKey('home-nav-trash')));
    await env.settle(tester);
    await tester.tap(find.byKey(const ValueKey('home-nav-docs')));
    await env.settle(tester);
    await tester.enterText(find.byKey(const ValueKey('home-search')), 'xyz');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('home-new')));
    await env.settle(tester);
    await tester.pumpAndSettle();
    expect(find.byType(EditorPage), findsNothing, reason: 'legt nicht still ein A4-Blatt an');
    final blank = tester.getRect(find.byKey(const ValueKey('home-new-blank')));
    expect(blank.top, lessThan(1100), reason: 'zu «Neu beginnen» gescrollt');
    expect(blank.bottom, greaterThan(0));
  });

  test('relative Zeitangaben', () {
    final now = DateTime(2026, 11, 11, 15);
    expect(relativeTime(now.subtract(const Duration(seconds: 20)), now), 'gerade eben');
    expect(relativeTime(now.subtract(const Duration(minutes: 5)), now), 'vor 5 Minuten');
    expect(relativeTime(now.subtract(const Duration(hours: 3)), now), 'vor 3 Stunden');
    expect(relativeTime(DateTime(2026, 11, 10, 9), now), 'gestern');
    expect(relativeTime(DateTime(2026, 11, 7), now), 'vor 4 Tagen');
    expect(relativeTime(DateTime(2026, 3, 12), now), '12.3.2026');
  });
}
