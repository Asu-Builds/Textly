// Bildschirmfotos für die Anleitung (docs/bilder) – automatisch, damit sie zur App passen.
//
// Aufruf aus dem Ordner app:   flutter test tool/docs_screenshots_test.dart
//
// Für jede Aufnahme entsteht <name>.png; marken.js enthält die Lage wichtiger Knöpfe (in Prozent des
// Bildes), mit der die Website die nummerierten Markierungen setzt.
// Braucht Windows (Schrift Segoe UI aus C:\Windows\Fonts).
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:doc_model/doc_model.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:textly/editor/editor_controller.dart';
import 'package:textly/files/services.dart';
import 'package:textly/history/history_store.dart';
import 'package:textly/library/document_library.dart';
import 'package:textly/library/home_page.dart';
import 'package:textly/main.dart';
import 'package:textly/spell/spell_check.dart';

const _size = Size(1280, 760); // Laptop-Fenster
const _ratio = 1.5; // scharf auf hochauflösenden Bildschirmen
final _out = Directory('../docs/bilder');

Future<ByteData> _disk(String p) async => ByteData.sublistView(await File(p).readAsBytes());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final segoe = FontLoader('Segoe UI');
    for (final f in ['segoeui', 'seguisb', 'segoeuib', 'segoeuii', 'segoeuil', 'segoeuisl']) {
      segoe.addFont(_disk('C:/Windows/Fonts/$f.ttf'));
    }
    await segoe.load();
    final root = Platform.environment['FLUTTER_ROOT'] ?? 'C:/dev/flutter';
    await (FontLoader('MaterialIcons')..addFont(_disk('$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf'))).load();
    for (final (family, prefix) in [('TextlySans', 'Sans'), ('TextlyCondensed', 'Cond')]) {
      final l = FontLoader(family);
      for (final s in ['Regular', 'Bold', 'Italic', 'BoldItalic']) {
        l.addFont(_disk('assets/fonts/$prefix-$s.ttf'));
      }
      await l.load();
    }
    _out.createSync(recursive: true);
  });

  testWidgets('Bildschirmfotos der Anleitung', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = _size * _ratio;
    tester.view.devicePixelRatio = _ratio;
    addTearDown(tester.view.reset);

    // Bibliothek wie beim ersten Start, dazu ein paar frühere Stände für den Verlauf
    final fs = MemoryFileAccess();
    final services = AppServices(files: fs, loadAsset: (k) async => File(k).readAsBytesSync(), setWindowTitle: (_) {});
    final lib = DocumentLibrary(fs, 'C:/Textly', loadAsset: services.loadAsset);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    var t = today;
    late LibraryEntry sample;
    await tester.runAsync(() async {
      sample = await lib.create(sampleDocument(), name: 'Beispiel: Vereinsausflug');
      final h = HistoryStore(fs, 'V/${sample.id}', clock: () => t);
      final d = sampleDocument();
      for (final (day, hh, label, kind) in [
        (2, 9, 'Ausgangsstand', 'start'),
        (2, 10, 'Bearbeitet: 2 Texte', 'edit'),
        (1, 14, 'Bild wurde gelöscht', 'delete'),
        (1, 15, 'Bearbeitet: 1 Bild, 1 Text', 'edit'),
        (0, 9, 'Bearbeitet: 3 Texte', 'edit'),
      ]) {
        t = today.subtract(Duration(days: day)).add(Duration(hours: hh));
        await h.record(d, label: label, kind: kind, session: 1, subject: kind == 'delete' ? 'image' : null);
      }
    });
    EditorController? c;
    final shotKey = GlobalKey();
    final allMarks = <String, Map<String, List<double>>>{};
    await tester.pumpWidget(RepaintBoundary(
      key: shotKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: textlyTheme(),
        home: HomePage(
          library: lib,
          services: services,
          fitOnStart: true,
          autosaveDelay: const Duration(milliseconds: 50),
          historyFor: (id) => HistoryStore(fs, 'V/$id'),
          newController: (d) => c = EditorController(d, spell: SpellChecker(WordListBackend(const []))),
        ),
      ),
    ));

    Future<void> settle([int ms = 900]) async {
      await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
    }

    Future<void> tap(String key) async {
      await tester.tap(find.byKey(ValueKey(key)).first);
      await settle(400);
    }

    /// Meldungen unten ausblenden (sie gehören nicht ins Bild).
    Future<void> noSnack() async {
      final ctx = tester.element(find.byType(Scaffold).last);
      ScaffoldMessenger.of(ctx).clearSnackBars();
      await settle(300);
    }

    Future<void> shot(String name, List<String> keys) async {
      await settle();
      final marks = <String, List<double>>{};
      for (final k in keys) {
        final f = find.byKey(ValueKey(k));
        if (f.evaluate().isEmpty) {
          fail('Aufnahme $name: Knopf «$k» nicht gefunden');
        }
        final r = tester.getRect(f.first);
        // Schlüssel mit wechselnder Kennung (z. B. doc-card-<id>) unter festem Namen ablegen
        final mk = RegExp(r'^(doc-card|element|history-day)-').firstMatch(k)?.group(1) ?? k;
        marks[mk] = [
          for (final v in [r.left / _size.width, r.top / _size.height, r.width / _size.width, r.height / _size.height]) (v * 1000).round() / 10,
        ];
      }
      await tester.runAsync(() async {
        final im = await (shotKey.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage(pixelRatio: _ratio);
        final b = await im.toByteData(format: ui.ImageByteFormat.png);
        File('${_out.path}/$name.png').writeAsBytesSync(b!.buffer.asUint8List());
      });
      allMarks[name] = marks;
    }

    await settle(1500);
    // 1 Startseite
    await shot('startseite', ['home-new', 'doc-card-${sample.id}', 'home-nav-templates', 'home-nav-trash', 'home-import']);
    // 2 Neu beginnen
    await tap('home-new');
    await settle(800);
    await shot('neu-beginnen', ['home-new', 'home-new-blank', 'home-paper-a4', 'home-orient-portrait', 'tpl-builtin-flyer', 'home-filter-all']);

    // 3 Vorlage «Flyer» geöffnet
    await tester.ensureVisible(find.byKey(const ValueKey('tpl-builtin-flyer')));
    await tap('tpl-builtin-flyer');
    await settle(1500);
    await noSnack();
    final flyer = c!;
    await shot('vorlage-offen', ['doc-name', 'tool-text', 'tool-image', 'tool-table', 'tool-finish', 'tool-undo', 'zoom-control']);

    // 4 Text überschreiben
    final title = flyer.page.elements.whereType<TextBlock>().firstWhere((x) => x.kind == TextKind.title);
    flyer.startEditing(title, title.text.length);
    await settle();
    await shot('text-schreiben', ['text-editor', 'float-text-bar', 'prop-kind-title']);
    flyer.finishEditing();

    // 5 Bild ersetzen und zuschneiden
    final pic = flyer.page.elements.whereType<ImageBlock>().first;
    flyer.select(pic.id);
    await settle();
    await tester.ensureVisible(find.byKey(const ValueKey('img-replace')));
    await settle(300);
    await shot('bild-ersetzen', ['element-${pic.id}', 'img-replace', 'crop-area']);

    // 6 Namen geben
    flyer.select(null);
    await tap('doc-name');
    await tester.enterText(find.byKey(const ValueKey('doc-name-field')), 'Sommerfest 2027');
    await settle(300);
    await shot('namen-geben', ['doc-name-field', 'doc-name-ok']);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle();

    // 7 Seite: Papiergrösse
    await shot('seitenformat', ['prop-paper-a5', 'prop-paper-a4', 'prop-orient-portrait', 'prop-grid']);

    // 8 Tabelle
    // Platz schaffen: den grünen Kasten unten vorübergehend entfernen
    final gone = [for (final e in flyer.page.elements) if (e.box.y > 140 && e.box.y < 190) e.id];
    for (final id in gone) {
      flyer.select(id);
      flyer.deleteSelected();
    }
    await settle(300);
    await noSnack();
    flyer.addTable(3, rows: 3);
    await settle();
    // in die freie Fläche zwischen Text und grünem Kasten
    flyer.updateSelectedTable((t) => t
        .copyWith(y: 142)
        .withCell(0, 0, 'Zeit').withCell(0, 1, 'Was').withCell(0, 2, 'Wo')
        .withCell(1, 0, '14 Uhr').withCell(1, 1, 'Spiele').withCell(1, 2, 'Wiese')
        .withCell(2, 0, '18 Uhr').withCell(2, 1, 'Grill').withCell(2, 2, 'Festzelt'));
    await settle(300);
    final table = flyer.page.elements.whereType<TableBlock>().last;
    flyer.selectCell(table, 1, 1);
    await settle();
    await shot('tabelle', ['table-add-row', 'table-add-col', 'move-grip', 'prop-table-style-header']);
    flyer.finishEditing();
    while (gone.any((id) => flyer.page.find(id) == null) && flyer.canUndo) {
      flyer.undo();
    }
    await settle();

    // 9 Drucken, PDF, E-Mail
    await tap('tool-finish');
    await settle(1200);
    await shot('drucken', ['preview-print', 'preview-pdf', 'finish-email', 'finish-template']);
    await tester.tap(find.byKey(const ValueKey('preview-close')));
    await settle();

    // 10 zurück zur Startseite, Beispiel öffnen, frühere Stände
    await tap('go-home');
    await settle(1200);
    await noSnack();
    await tester.drag(find.byType(ListView).first, const Offset(0, 3000)); // ganz nach oben
    await settle(300);
    await tap('doc-card-${sample.id}');
    await settle(1500);
    await noSnack();
    await tap('tool-history');
    await settle();
    final y = today.subtract(const Duration(days: 1));
    await tap('history-day-${y.year}-${y.month}-${y.day}');
    await settle();
    await tap('history-back');
    await settle();
    await shot('fruehere-staende', ['history-to-now', 'history-tl-restore', 'history-day-${y.year}-${y.month}-${y.day}', 'tool-history']);
    await tap('history-to-now');
    await tap('go-home');
    await settle(1200);
    await noSnack();
    await tester.drag(find.byType(ListView).first, const Offset(0, 3000));
    await settle(300);

    // 11 Als Vorlage speichern
    await tap('doc-menu-${sample.id}');
    await settle();
    await shot('dokument-menue', ['doc-copy', 'doc-template', 'doc-trash']);
    await tap('doc-template');
    await settle();
    await shot('vorlage-speichern', ['tpl-name', 'tpl-kind-programm', 'tpl-save']);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle();

    // Lage der Knöpfe für die Markierungen der Website (als Skript: funktioniert auch ohne Webserver)
    File('${_out.path}/marken.js').writeAsStringSync(
      '// Automatisch erzeugt von app/tool/docs_screenshots_test.dart – nicht von Hand ändern.\n'
      'window.TEXTLY_MARKEN = {\n${allMarks.entries.map((e) => '  "${e.key}": ${jsonEncode(e.value)}').join(',\n')}\n};\n',
    );

    debugDefaultTargetPlatformOverride = null;
    // Mausbewegungen und Zeitgeber der App sauber beenden
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    expect(GestureBinding.instance, isNotNull);
  });
}
