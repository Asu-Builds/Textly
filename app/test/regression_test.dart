// Fehler aus der Analyse vom 10.11.2026: je ein Test, damit sie nicht wiederkommen.
import 'dart:async';
import 'dart:io';

import 'package:doc_exchange/doc_exchange.dart';
import 'package:doc_model/doc_model.dart';
import 'package:doc_render/doc_render.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:textly/editor/editor_controller.dart';
import 'package:textly/editor/editor_page.dart';
import 'package:textly/editor/rich_text_controller.dart';
import 'package:textly/files/services.dart';
import 'package:textly/images/image_import.dart';
import 'package:textly/spell/spell_check.dart';

Future<ByteData> _fromDisk(String key) async => ByteData.sublistView(await File(key).readAsBytes());

EditorController _controller() => EditorController(sampleDocument(), spell: SpellChecker(WordListBackend(const [])));
T _first<T extends DocElement>(EditorController c) => c.page.elements.whereType<T>().first;

/// Dateizugriff, dessen Schreiben erst auf Freigabe fertig wird (langsames Laufwerk).
class _SlowFiles extends MemoryFileAccess {
  Completer<void>? gate;
  @override
  Future<void> write(String path, Uint8List bytes) async {
    final g = gate;
    if (g != null) await g.future;
    return super.write(path, bytes);
  }
}

class _Picker implements FilePicker {
  @override
  Future<String?> pickOpen({required String label, required List<String> extensions}) async => null;
  @override
  Future<String?> pickSave({required String suggestedName, required String label, required List<String> extensions}) async => null;
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

  testWidgets('nach dem Schreiben (Esc) wirkt Entf sofort, ohne Klick auf eine leere Stelle', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = _controller();
    await tester.pumpWidget(MaterialApp(home: EditorPage(controller: c)));
    await tester.pump();
    final t = _first<TextBlock>(c);
    final finder = find.byKey(ValueKey('element-${t.id}'));
    await tester.tap(finder);
    await tester.pump();
    await tester.pump();
    expect(c.editingId, t.id);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump();
    expect(c.editingId, isNull);
    expect(c.selectedId, t.id);
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pump();
    expect(c.page.find(t.id), isNull, reason: 'Tastatur muss nach dem Schreiben wieder beim Editor sein');
    await tester.pump(const Duration(milliseconds: 400));
  });

  group('Speichern', () {
    test('Dateiname auch aus Windows-Pfaden mit Rückwärtsstrich', () {
      final c = _controller()..markSaved(r'C:\Users\me\Dokumente\Ausflug.textly');
      expect(c.displayName, 'Ausflug');
    });

    test('nach dem Speichern verschmilzt der nächste Schritt nicht mit dem gespeicherten', () {
      final c = _controller();
      final img = _first<ImageBlock>(c);
      c.select(img.id);
      c.nudgeSelected(1, 0);
      c.markSaved('C:/a.textly');
      c.nudgeSelected(1, 0);
      c.undo();
      expect(c.page.find(img.id)!.box.x, img.box.x + 1, reason: 'zurück zum gespeicherten Stand');
      expect(c.isDirty, isFalse);
    });

    testWidgets('Änderung während des Schreibens der Datei bleibt ungespeichert', (tester) async {
      final files = _SlowFiles();
      final services = AppServices(picker: _Picker(), files: files, recovery: RecoveryStore(files, 'daten'), loadAsset: (k) async => File(k).readAsBytesSync());
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = _controller()..markSaved('C:/a.textly');
      await tester.pumpWidget(MaterialApp(home: EditorPage(controller: c, services: services)));
      await tester.pump();
      c.addRect(); // ungespeichert
      files.gate = Completer<void>();
      final saving = tester.runAsync(() async {
        // Strg+S
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      });
      await saving;
      await tester.pump();
      c.addLine(); // während die Datei geschrieben wird
      files.gate!.complete();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      expect(c.isDirty, isTrue, reason: 'die Linie ist nicht in der Datei');
      final saved = decodeTextly(files.files['C:/a.textly']!);
      expect(saved.page(0).elements.whereType<RectShape>().length, c.doc.page(0).elements.whereType<RectShape>().length);
      expect(saved.page(0).elements.whereType<LineShape>().length, c.doc.page(0).elements.whereType<LineShape>().length - 1);
      await tester.pump(const Duration(seconds: 4));
    });

    test('fehlgeschlagenes Speichern lässt keine Hilfsdatei liegen', () async {
      final dir = await Directory.systemTemp.createTemp('textly_');
      addTearDown(() => dir.delete(recursive: true));
      final target = '${dir.path}${Platform.pathSeparator}ziel.textly';
      await Directory(target).create(); // Ziel ist ein Ordner: Umbenennen schlägt fehl
      await expectLater(const RealFileAccess().write(target, Uint8List.fromList([1, 2, 3])), throwsA(isA<FileSystemException>()));
      expect(File('$target.speichern').existsSync(), isFalse);
    });

    test('zwei Fenster bekommen getrennte Sicherungsordner', () async {
      final dir = await Directory.systemTemp.createTemp('textly_');
      final a = await claimRecoveryDirectory(dir.path);
      final b = await claimRecoveryDirectory(dir.path);
      expect(a, isNot(b));
    });
  });

  group('Befehle während Schreiben und Ziehen', () {
    testWidgets('Sperren und Ebenen während des Schreibens bleiben erhalten', (tester) async {
      final c = _controller();
      final t = c.page.elements.whereType<TextBlock>().firstWhere((e) => e.kind == TextKind.body);
      c.startEditing(t, 0);
      c.textController.text = 'Neu ${t.text}';
      c.onEditingChanged();
      c.toggleLockSelected();
      c.sendSelectedToBack();
      c.finishEditing();
      final now = c.page.find(t.id) as TextBlock;
      expect(now.locked, isTrue);
      expect(now.text, startsWith('Neu '));
      expect(c.page.elements.first.id, t.id, reason: 'nach hinten');
    });

    test('Entf während des Ziehens: Element bleibt gelöscht', () {
      final c = _controller();
      final img = _first<ImageBlock>(c);
      c.beginGesture(img.id);
      c.updateMove(10, 0, free: true);
      c.deleteSelected();
      c.endGesture();
      expect(c.page.find(img.id), isNull);
    });

    test('Strg+D während des Ziehens: Kopie bleibt, Auswahl gültig', () {
      final c = _controller();
      final img = _first<ImageBlock>(c);
      final n = c.page.elements.length;
      c.beginGesture(img.id);
      c.updateMove(10, 0, free: true);
      c.duplicateSelected();
      c.endGesture();
      expect(c.page.elements.length, n + 1);
      expect(c.selected, isNotNull);
      expect(c.page.find(img.id)!.box.x, img.box.x + 10, reason: 'die Verschiebung wurde übernommen');
    });

    test('Rückgängig während des Ausschnitt-Ziehens bricht die Vorschau ab', () {
      final c = _controller();
      final img = _first<ImageBlock>(c);
      c.select(img.id);
      c.updateSelectedImage((i) => withCropZoom(i, 2));
      c.beginPreview();
      c.previewSelected(withCropAt(c.selected! as ImageBlock, 0, 0));
      c.undo();
      c.previewSelected(withCropAt(c.selected! as ImageBlock, .1, .1)); // Maus bewegt sich weiter
      c.endPreview();
      expect((c.page.find(img.id)! as ImageBlock).zoom, 1, reason: 'Vergrösserung rückgängig gemacht');
      expect(c.history.canRedo, isTrue);
    });
  });

  group('Gesperrte Elemente', () {
    test('lassen sich weder ändern noch löschen noch bearbeiten', () {
      final c = _controller();
      final t = c.page.elements.whereType<TextBlock>().first;
      final img = _first<ImageBlock>(c);
      c.select(t.id);
      c.toggleLockSelected();
      c.updateSelectedText((b) => b.copyWith(size: 40));
      c.deleteSelected();
      c.startEditing(c.selected! as TextBlock, 0);
      expect((c.page.find(t.id)! as TextBlock).size, t.size);
      expect(c.editingId, isNull);
      c.select(img.id);
      c.toggleLockSelected();
      c.updateSelectedImage((i) => i.copyWith(fit: ImageFit.contain));
      c.deleteSelected();
      expect((c.page.find(img.id)! as ImageBlock).fit, ImageFit.cover);
    });
  });

  test('Seite verschieben, die man nicht ansieht: Ansicht bleibt auf derselben Seite', () {
    final c = _controller();
    c.addPage(); // 3 Seiten, angezeigt: die neue Seite 2 (Index 1)
    final shown = c.page.id;
    c.movePage(2, 1); // letzte Seite nach vorne, an der angezeigten vorbei
    expect(c.page.id, shown);
    c.movePage(0, 2); // erste Seite nach hinten
    expect(c.page.id, shown);
  });

  test('PDF mit Emoji am Wortanfang', () async {
    final doc = TextlyDocument(pages: [
      DocPage(id: 'p', elements: [TextBlock.ofKind(id: 't', box: const Box(20, 20, 100, 10), text: 'Hallo 😃 Welt')]),
    ]);
    expect((await exportPdf(doc, _fromDisk)).bytes, isNotEmpty);
  });

  test('Rückgängig im Textfeld bringt gelöschten fetten Text fett zurück', () {
    final rc = RichTextController();
    rc.load(TextBlock.ofKind(id: 't', box: const Box(0, 0, 50, 10), text: 'foo bar').copyWith(runs: const [StyleRun(0, 3, InlineStyle(bold: true))]),
        const TextSelection.collapsed(offset: 3));
    rc.value = const TextEditingValue(text: ' bar', selection: TextSelection.collapsed(offset: 0));
    expect(rc.runs, isEmpty);
    // so stellt Flutters Rückgängig im Feld den Text wieder her
    rc.value = const TextEditingValue(text: 'foo bar', selection: TextSelection.collapsed(offset: 3));
    expect(rc.runs, const [StyleRun(0, 3, InlineStyle(bold: true))]);
    rc.dispose();
  });

  test('leere und abgeschnittene Bilddateien: verständliche Meldung', () {
    expect(() => prepareImageSync(Uint8List(0)), throwsA(isA<ImageImportException>()));
    expect(() => prepareImageSync(Uint8List.fromList([0x42, 0x4D, 1, 2, 3, 4, 5, 6, 7, 8])), throwsA(isA<ImageImportException>()));
    final png = File('assets/images/glacier.jpg').readAsBytesSync();
    expect(() => prepareImageSync(Uint8List.sublistView(png, 0, 40)), throwsA(isA<ImageImportException>()));
  });

  testWidgets('PDF speichern fragt nach dem Ort; Abbrechen erzeugt nichts', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final files = MemoryFileAccess();
    final picker = _RecordingPicker();
    final c = _controller();
    await tester.pumpWidget(MaterialApp(home: EditorPage(controller: c, services: AppServices(picker: picker, files: files))));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('tool-finish')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('preview-pdf')));
    await tester.pump();
    expect(picker.suggested, ['Unbenannt.pdf']);
    expect(files.files, isEmpty);
  });

  testWidgets('Start mit Dateiname (Doppelklick im Explorer) öffnet die Datei', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final files = MemoryFileAccess();
    final doc = TextlyDocument(pages: [
      DocPage(id: 'p', elements: [TextBlock.ofKind(id: 't', box: const Box(20, 20, 100, 10), text: 'Aus dem Explorer')]),
    ], orientation: PageOrientation.landscape);
    files.files['C:/Briefe/Bericht.textly'] = encodeTextly(doc);
    final c = EditorController(TextlyDocument(pages: [DocPage(id: 'leer')]), spell: SpellChecker(WordListBackend(const [])));
    await tester.pumpWidget(MaterialApp(
      home: EditorPage(controller: c, services: AppServices(picker: _Picker(), files: files), startupFile: 'C:/Briefe/Bericht.textly'),
    ));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect((c.page.elements.single as TextBlock).text, 'Aus dem Explorer');
    expect(c.displayName, 'Bericht');
    expect(c.doc.orientation, PageOrientation.landscape);
  });
}

class _RecordingPicker implements FilePicker {
  final suggested = <String>[];
  @override
  Future<String?> pickOpen({required String label, required List<String> extensions}) async => null;
  @override
  Future<String?> pickSave({required String suggestedName, required String label, required List<String> extensions}) async {
    suggested.add(suggestedName);
    return null;
  }
}
