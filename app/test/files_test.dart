import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:doc_exchange/doc_exchange.dart';
import 'package:doc_model/doc_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:textly/editor/editor_controller.dart';
import 'package:textly/editor/editor_page.dart';
import 'package:textly/files/services.dart';
import 'package:textly/spell/spell_check.dart';

Future<ByteData> _fromDisk(String key) async => ByteData.sublistView(await File(key).readAsBytes());

/// Dateidialog-Attrappe: gibt der Reihe nach die vorbereiteten Pfade zurück.
class FakePicker implements FilePicker {
  final answers = <String?>[];
  final calls = <String>[];
  @override
  Future<String?> pickOpen({required String label, required List<String> extensions}) async {
    calls.add('öffnen ${extensions.first}');
    return answers.isEmpty ? null : answers.removeAt(0);
  }

  @override
  Future<String?> pickSave({required String suggestedName, required String label, required List<String> extensions}) async {
    calls.add('speichern $suggestedName');
    return answers.isEmpty ? null : answers.removeAt(0);
  }
}

class Harness {
  Harness() {
    services = AppServices(
      picker: picker,
      files: fs,
      recovery: RecoveryStore(fs, 'daten'),
      loadAsset: (k) async => File(k).readAsBytesSync(),
      setWindowTitle: (t) => titles.add(t),
    );
  }
  final picker = FakePicker();
  final fs = MemoryFileAccess();
  final titles = <String>[];
  late final AppServices services;
  late EditorController c;

  Future<void> pump(WidgetTester tester, {TextlyDocument? doc}) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    c = EditorController(doc ?? sampleDocument(), spell: SpellChecker(WordListBackend(const [])), untitledName: 'Beispiel');
    await tester.pumpWidget(MaterialApp(home: EditorPage(key: UniqueKey(), controller: c, services: services)));
    await tester.pump();
  }

  void change() {
    final t = c.page.elements.whereType<TextBlock>().first;
    c.commit(c.doc.replaceElement(0, t.copyWith(text: 'Herbstausflug ${c.history.undoDepth}')));
  }

  Future<void> menu(WidgetTester tester, String item) async {
    await tester.tap(find.byKey(const ValueKey('menu-file')));
    await tester.pump();
    await tester.tap(find.byKey(ValueKey(item)));
    await tester.pump();
    await tester.pump();
  }
}

/// Dokumentname, mit « •» solange etwas nicht gespeichert ist (wie im Fenstertitel).
String _title(WidgetTester tester) {
  final name = (tester.widget<Text>(find.byKey(const ValueKey('doc-title')))).data!;
  final dirty = find.descendant(of: find.byKey(const ValueKey('doc-status')), matching: find.text('Nicht gespeichert')).evaluate().isNotEmpty;
  return dirty ? '$name •' : name;
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

  testWidgets('Speichern: beim ersten Mal mit Dialog, danach direkt; Punkt zeigt Ungespeichertes', (tester) async {
    final h = Harness();
    await h.pump(tester);
    expect(_title(tester), 'Beispiel');
    h.change();
    await tester.pump();
    expect(_title(tester), 'Beispiel •');
    expect(h.titles.last, 'Beispiel • – Textly', reason: 'Fenstertitel');

    h.picker.answers.add('C:/Dokumente/Ausflug'); // ohne Endung
    await h.menu(tester, 'menu-save');
    expect(h.picker.calls, ['speichern Beispiel.textly']);
    expect(h.fs.files.keys, contains('C:/Dokumente/Ausflug.textly'));
    expect(_title(tester), 'Ausflug');
    final saved = decodeTextly(h.fs.files['C:/Dokumente/Ausflug.textly']!);
    expect(saved.toJson()['pages'], h.c.doc.toJson()['pages']);
    expect(saved.assets, hasLength(2), reason: 'Beispielbilder eingebettet');

    h.change();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(h.picker.calls, hasLength(1), reason: 'zweites Speichern ohne Dialog');
    expect(_title(tester), 'Ausflug');
    expect((decodeTextly(h.fs.files['C:/Dokumente/Ausflug.textly']!).page(0).elements.first as TextBlock).text, startsWith('Herbstausflug'));
  });

  testWidgets('Öffnen ersetzt das Dokument; Dateiname wird Titel', (tester) async {
    final h = Harness();
    await h.pump(tester);
    final other = TextlyDocument(pages: [
      DocPage(id: 'x', elements: [TextBlock.ofKind(id: 't', box: const Box(20, 20, 100, 10), text: 'Aus der Datei')]),
    ]);
    h.fs.files['D:/Vereine/Programm.textly'] = encodeTextly(other);
    h.picker.answers.add('D:/Vereine/Programm.textly');
    await h.menu(tester, 'menu-open');
    expect((h.c.page.elements.single as TextBlock).text, 'Aus der Datei');
    expect(_title(tester), 'Programm');
    expect(h.c.history.canUndo, isFalse, reason: 'Verlauf beginnt neu');
  });

  testWidgets('Rückfrage bei ungespeicherten Änderungen: Abbrechen, Nicht speichern, Speichern', (tester) async {
    final h = Harness();
    await h.pump(tester);
    h.change();
    await tester.pump();
    final before = h.c.doc;

    await h.menu(tester, 'menu-new');
    expect(find.text('Änderungen an «Beispiel» speichern?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('discard-cancel')));
    await tester.pump();
    expect(identical(h.c.doc, before), isTrue, reason: 'Abbrechen lässt alles, wie es ist');

    await h.menu(tester, 'menu-new');
    await tester.tap(find.byKey(const ValueKey('discard-no')));
    await tester.pump();
    await tester.pump();
    expect(h.c.doc.pages.single.elements, isEmpty);
    expect(_title(tester), 'Unbenannt');

    // Neues Dokument ändern, dann «Neu» mit «Speichern»
    h.c.addRect();
    await tester.pump();
    h.picker.answers.add('C:/neu.textly');
    await h.menu(tester, 'menu-new');
    await tester.tap(find.byKey(const ValueKey('discard-save')));
    await tester.pump();
    await tester.pump();
    expect(h.fs.files.keys, contains('C:/neu.textly'));
    expect(h.c.doc.pages.single.elements, isEmpty);
  });

  testWidgets('Fenster schliessen mit ungespeicherten Änderungen fragt nach', (tester) async {
    final h = Harness();
    await h.pump(tester);
    h.change();
    await tester.pump();
    final exit = tester.binding.handleRequestAppExit();
    await tester.pump();
    expect(find.text('Änderungen an «Beispiel» speichern?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('discard-cancel')));
    await tester.pump();
    expect(await exit, AppExitResponse.cancel);

    final exit2 = tester.binding.handleRequestAppExit();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('discard-no')));
    await tester.pump();
    expect(await exit2, AppExitResponse.exit);
  });

  testWidgets('Wiederherstellung: Sicherung im Hintergrund, Angebot beim nächsten Start', (tester) async {
    final h = Harness();
    await h.pump(tester);
    h.change();
    await tester.pump();
    expect(h.fs.files.keys.any((k) => k.contains('wiederherstellung')), isFalse);
    await tester.pump(const Duration(seconds: 4));
    expect(h.fs.files.keys.where((k) => k.contains('wiederherstellung')), hasLength(2), reason: 'Sicherung geschrieben');
    final changedText = (h.c.page.elements.first as TextBlock).text;

    // «Absturz»: neue App-Instanz mit demselben Datenordner
    final h2 = Harness();
    h2.fs.files.addAll(h.fs.files);
    await h2.pump(tester);
    await tester.pump();
    expect(find.text('Ungespeicherte Änderungen gefunden'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('recovery-restore')));
    await tester.pump();
    await tester.pump();
    expect((h2.c.page.elements.first as TextBlock).text, changedText);
    expect(h2.c.isDirty, isTrue);
    expect(_title(tester), 'Wiederhergestellt •');

    // Speichern entfernt die Sicherung
    h2.picker.answers.add('C:/gerettet.textly');
    await h2.menu(tester, 'menu-save');
    expect(h2.fs.files.keys.any((k) => k.contains('wiederherstellung')), isFalse);
  });

  testWidgets('PowerPoint exportieren und öffnen', (tester) async {
    final h = Harness();
    await h.pump(tester);
    h.picker.answers.add('C:/Vortrag');
    await h.menu(tester, 'menu-pptx-export');
    final pptx = h.fs.files['C:/Vortrag.pptx'];
    expect(pptx, isNotNull);
    expect(importPptx(pptx!).document.pages, hasLength(2));

    h.picker.answers.add('C:/Vortrag.pptx');
    await h.menu(tester, 'menu-pptx-open');
    expect(h.c.doc.pages, hasLength(2));
    expect(_title(tester), 'Vortrag •', reason: 'importiert = ungespeichert');
    expect(h.c.filePath, isNull, reason: 'PowerPoint-Datei wird nicht überschrieben');
  });

  testWidgets('Kaputte Datei öffnen: verständliche Meldung, Dokument bleibt', (tester) async {
    final h = Harness();
    await h.pump(tester);
    h.fs.files['C:/kaputt.textly'] = Uint8List.fromList([1, 2, 3]);
    h.picker.answers.add('C:/kaputt.textly');
    await h.menu(tester, 'menu-open');
    expect(find.text('Die Datei ist kein Textly-Dokument oder beschädigt.'), findsOneWidget);
    expect(h.c.doc.pages, hasLength(2));
  });
}
