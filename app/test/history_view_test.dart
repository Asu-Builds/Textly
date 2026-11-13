import 'dart:io';

import 'package:doc_model/doc_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:textly/editor/editor_canvas.dart';
import 'package:textly/editor/editor_controller.dart';
import 'package:textly/editor/properties_panel.dart';
import 'package:textly/files/services.dart';
import 'package:textly/history/history_store.dart';
import 'package:textly/history/history_view.dart';
import 'package:textly/library/document_library.dart';
import 'package:textly/library/home_page.dart';
import 'package:textly/spell/spell_check.dart';

String _hm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

Future<ByteData> _fromDisk(String key) async => ByteData.sublistView(await File(key).readAsBytes());

TextlyDocument _doc() => TextlyDocument(pages: [
      DocPage(id: 'p', elements: [
        TextBlock.ofKind(id: 'titel', box: const Box(20, 20, 150, 10), text: 'Herbstausflug', kind: TextKind.title),
        TextBlock.ofKind(id: 'anm', box: const Box(20, 60, 150, 10), text: 'Anmeldung bis 10. Oktober'),
      ]),
    ]);

class _Env {
  final fs = MemoryFileAccess();
  late final services = AppServices(files: fs, loadAsset: (k) async => File(k).readAsBytesSync(), setWindowTitle: (_) {});
  late final lib = DocumentLibrary(fs, 'C:/Textly', loadAsset: services.loadAsset);
  HistoryStore history(String id) => HistoryStore(fs, 'L:/Verlauf/$id');
  EditorController? last;

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: HomePage(
        library: lib,
        services: services,
        historyFor: history,
        autosaveDelay: const Duration(milliseconds: 20),
        newController: (d) => last = EditorController(d, spell: SpellChecker(WordListBackend(const []))),
      ),
    ));
    await settle(tester);
  }

  /// Zurück zur Startseite: angesammelte Bearbeitungen werden abgelegt, keine Zeitgeber bleiben offen.
  Future<void> leave(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('go-home')));
    await settle(tester);
  }

  Future<void> settle(WidgetTester tester, [int n = 20]) async {
    for (var i = 0; i < n; i++) {
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

  testWidgets('Verlauf: Löschung ansehen, früheren Zustand anklicken, mit ihm fortfahren', (tester) async {
    final env = _Env();
    final e = await env.lib.create(_doc());
    await env.pump(tester);
    await tester.tap(find.byKey(ValueKey('doc-card-${e.id}')));
    await env.settle(tester);
    final c = env.last!;

    // Text löschen → Sicherungspunkt mit dem Stand davor
    c.commit(c.doc.removeElement(0, 'anm'));
    await env.settle(tester);
    final entries = await env.history(e.id).entries();
    expect(entries.map((x) => x.label), ['Ausgangsstand', 'Fliesstext wurde gelöscht']);
    expect(entries.last.kind, 'delete');

    await tester.tap(find.byKey(const ValueKey('tool-history')));
    await env.settle(tester);
    expect(find.byType(HistoryView), findsOneWidget);
    expect(find.byType(PropertiesPanel), findsOneWidget, reason: 'Editor bleibt, wie er ist');
    expect(find.byType(EditorCanvas), findsOneWidget, reason: '«Jetzt»: normale Arbeitsfläche');
    expect(find.byKey(const ValueKey('history-preview')), findsNothing);
    expect(find.byKey(ValueKey('history-entry-${entries.last.n}')), findsNothing, reason: 'keine Liste mehr, nur der Zeitstrahl');
    expect(find.byKey(ValueKey('history-mark-${entries.last.n}')), findsOneWidget);

    // Ein Schritt zurück: der Stand nach dem Löschen, gestrichelt wo der Text war
    await tester.tap(find.byKey(const ValueKey('history-back')));
    await env.settle(tester);
    expect(find.text('Früherer Stand: Fliesstext wurde gelöscht (heute ${_hm(entries.last.time)})'), findsOneWidget);
    expect(find.textContaining('noch nichts geändert'), findsOneWidget, reason: 'nur ansehen');
    expect(find.byKey(const ValueKey('history-ghost-anm')), findsOneWidget, reason: 'nur markiert, keine Aktion im Hauptfenster');
    expect(find.byType(EditorCanvas), findsNothing, reason: 'Vorschau statt Arbeitsfläche');
    expect(find.byType(PropertiesPanel), findsOneWidget, reason: 'Eigenschaften bleiben');
    expect(find.descendant(of: find.byKey(const ValueKey('history-pages')), matching: find.byType(ButtonStyleButton)), findsNothing);
    expect(find.text('Fliesstext wurde gelöscht · heute ${_hm(entries.last.time)}'), findsOneWidget, reason: 'unter dem Punkt');

    // am Zeitstrahl nur «Mit diesem Zustand fortfahren» (kein zweites «Rückgängig»)
    expect(find.byKey(ValueKey('history-tl-undelete-${entries.last.n}')), findsNothing);
    expect(find.text('Rückgängig'), findsOneWidget, reason: 'nur das Rückgängig der Befehlszeile');
    expect(find.descendant(of: find.byKey(ValueKey('history-mark-${entries.last.n}')), matching: find.byIcon(Icons.text_fields_rounded)), findsOneWidget, reason: 'Piktogramm: Text');
    expect(find.descendant(of: find.byKey(ValueKey('history-mark-${entries.last.n}')), matching: find.byIcon(Icons.close_rounded)), findsOneWidget, reason: 'Abzeichen: gelöscht');
    // zwei klare Wege: übernehmen oder zurück zum aktuellen Dokument; kein ✕-Knopf, kein «Stand benennen»
    expect(find.text('Mit diesem Stand weiterarbeiten'), findsOneWidget);
    expect(find.text('Zurück zu meinem aktuellen Dokument'), findsOneWidget);
    expect(find.text('Stand benennen'), findsNothing);
    expect(find.byKey(const ValueKey('history-close')), findsNothing);

    // ältesten Zustand anklicken (Pos1) und genau diesen wiederherstellen, dann rückgängig
    c.commit(c.doc.replaceElement(0, (c.page.find('titel')! as TextBlock).copyWith(text: 'Winterausflug')));
    await env.settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await env.settle(tester);
    expect(find.textContaining('Früherer Stand: Ausgangsstand (heute'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('history-tl-restore')));
    await env.settle(tester);
    expect(find.byType(HistoryView), findsNothing, reason: 'weiterarbeiten wie gewohnt');
    expect(find.byType(EditorCanvas), findsOneWidget, reason: 'weiterarbeiten am wiederhergestellten Stand');
    expect((c.page.find('titel')! as TextBlock).text, 'Herbstausflug');
    final after = await env.history(e.id).entries();
    expect(after.last.label, 'Stand von heute ${_hm(entries.first.time)} wiederhergestellt');
    expect(c.page.find('anm'), isNotNull);
    c.undo();
    expect((c.page.find('titel')! as TextBlock).text, 'Winterausflug', reason: 'Wiederherstellen ist rückgängig zu machen');
    await env.settle(tester);
    await env.leave(tester);
  });

  testWidgets('«Zurück zu meinem aktuellen Dokument» und «Zeitstrahl schliessen» ändern nichts', (tester) async {
    final env = _Env();
    final e = await env.lib.create(_doc());
    await env.pump(tester);
    await tester.tap(find.byKey(ValueKey('doc-card-${e.id}')));
    await env.settle(tester);
    final c = env.last!;
    c.commit(c.doc.removeElement(0, 'anm'));
    await env.settle(tester);

    await tester.tap(find.byKey(const ValueKey('tool-history')));
    await env.settle(tester);
    await tester.tap(find.byKey(const ValueKey('history-back')));
    await env.settle(tester);
    expect(find.byKey(const ValueKey('history-preview')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('history-to-now')));
    await env.settle(tester);
    expect(find.byType(HistoryView), findsNothing);
    expect(find.byType(EditorCanvas), findsOneWidget);
    expect(c.page.find('anm'), isNull, reason: 'nichts verändert');

    // bei «Jetzt»: beschrifteter Knopf statt ✕
    await tester.tap(find.byKey(const ValueKey('tool-history')));
    await env.settle(tester);
    expect(find.text('Zeitstrahl schliessen'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('history-close')));
    await env.settle(tester);
    expect(find.byType(HistoryView), findsNothing);
    await env.leave(tester);
  });

  testWidgets('Tage als Knöpfe: nur die Stände des gewählten Tages, Pfeile gehen über Tagesgrenzen', (tester) async {
    final env = _Env();
    final e = await env.lib.create(_doc());
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    var t = today;
    // Verlauf über sechs Tage: je ein Stand um 10 und um 15 Uhr
    final h = HistoryStore(env.fs, 'L:/Verlauf/${e.id}', clock: () => t);
    final d = _doc();
    t = today.subtract(const Duration(days: 6)).add(const Duration(hours: 9));
    await h.record(d, label: 'Ausgangsstand', kind: 'start', session: 1);
    for (var day = 5; day >= 1; day--) {
      t = today.subtract(Duration(days: day)).add(const Duration(hours: 10));
      await h.record(d, label: 'Bearbeitet: 1 Text', kind: 'edit', session: 1);
      t = today.subtract(Duration(days: day)).add(const Duration(hours: 15));
      await h.record(d, label: 'Bearbeitet: 2 Texte', kind: 'edit', session: 1);
    }
    await env.pump(tester);
    await tester.tap(find.byKey(ValueKey('doc-card-${e.id}')));
    await env.settle(tester);
    await tester.tap(find.byKey(const ValueKey('tool-history')));
    await env.settle(tester);

    final entries = await env.history(e.id).entries();
    String key(DateTime t) => 'history-day-${t.year}-${t.month}-${t.day}';
    DateTime dayOf(DateTime t) => DateTime(t.year, t.month, t.day);
    final yesterday = dayOf(today.subtract(const Duration(hours: 12)));
    expect(find.byKey(ValueKey(key(today))), findsOneWidget);
    expect(find.text('Heute'), findsOneWidget);
    expect(find.text('Gestern'), findsOneWidget);
    expect(find.byKey(const ValueKey('history-day-older')), findsOneWidget, reason: 'mehr als vier Tage');
    expect(find.byKey(const ValueKey('history-mark-now')), findsOneWidget);

    // Gestern: nur dessen zwei Stände, der letzte ist gewählt
    final y = [for (final x in entries) if (dayOf(x.time) == yesterday) x];
    expect(y, hasLength(2));
    await tester.tap(find.byKey(ValueKey(key(yesterday))));
    await env.settle(tester);
    expect(find.byKey(ValueKey('history-mark-${y.first.n}')), findsOneWidget);
    expect(find.byKey(ValueKey('history-mark-${y.last.n}')), findsOneWidget);
    expect(find.byKey(const ValueKey('history-mark-now')), findsNothing, reason: 'nur Stände von gestern');
    expect(find.text('Pause'), findsOneWidget, reason: 'fünf Stunden dazwischen');
    expect(find.text('Früherer Stand: Bearbeitet: 2 Texte (${historyTime(y.last.time, DateTime.now())})'), findsOneWidget);

    // → geht über die Tagesgrenze zu «Heute»
    await tester.tap(find.byKey(const ValueKey('history-forward')));
    await env.settle(tester);
    expect(find.byKey(const ValueKey('history-mark-now')), findsOneWidget);

    // ältere Tage im Menü «Älter»
    await tester.tap(find.byKey(const ValueKey('history-day-older')));
    await tester.pumpAndSettle();
    final first = dayOf(entries.first.time);
    await tester.tap(find.byKey(ValueKey('${key(first)}-item')));
    await env.settle(tester);
    expect(find.byKey(ValueKey('history-mark-${entries.first.n}')), findsOneWidget);
    expect(find.byKey(ValueKey(key(first))), findsOneWidget, reason: 'gewählter älterer Tag erscheint als Knopf');

    // Esc: zurück zum aktuellen Dokument
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await env.settle(tester);
    expect(find.byType(HistoryView), findsNothing);
    await env.leave(tester);
  });

  testWidgets('viele Stände: beim Öffnen ist «Jetzt» sichtbar, Scrollbalken unter den Uhrzeiten', (tester) async {
    final env = _Env();
    final e = await env.lib.create(_doc());
    final now = DateTime.now();
    var t = now;
    final h = HistoryStore(env.fs, 'L:/Verlauf/${e.id}', clock: () => t);
    for (var i = 40; i >= 1; i--) {
      t = now.subtract(Duration(minutes: i));
      await h.record(_doc(), label: 'Bearbeitet: 1 Text', kind: 'edit', session: 1);
    }
    await env.pump(tester);
    await tester.tap(find.byKey(ValueKey('doc-card-${e.id}')));
    await env.settle(tester);
    await tester.tap(find.byKey(const ValueKey('tool-history')));
    await env.settle(tester);

    final line = tester.getRect(find.byKey(const ValueKey('history-timeline')));
    final view = tester.getRect(find.byType(Scrollbar).last);
    expect(line.width, greaterThan(view.width), reason: 'zu viele Punkte für die Breite');
    final nowMark = tester.getRect(find.byKey(const ValueKey('history-mark-now')));
    expect(nowMark.right, lessThanOrEqualTo(view.right + 1), reason: '«Jetzt» beim Öffnen sichtbar');
    expect(nowMark.left, greaterThanOrEqualTo(view.left));
    final bar = tester.widget<Scrollbar>(find.byType(Scrollbar).last);
    expect(bar.thumbVisibility, isTrue, reason: 'Scrollbalken immer sichtbar');
    final time = tester.getRect(find.text('Jetzt').last);
    expect(view.bottom - time.bottom, greaterThanOrEqualTo(12), reason: 'Platz für den Balken unter den Uhrzeiten');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await env.settle(tester);
    await env.leave(tester);
  });

  testWidgets('früherer Stand angesehen: Tasten und rechte Leiste ändern das verdeckte Dokument nicht', (tester) async {
    final env = _Env();
    final e = await env.lib.create(_doc());
    await env.pump(tester);
    await tester.tap(find.byKey(ValueKey('doc-card-${e.id}')));
    await env.settle(tester);
    final c = env.last!;
    c.commit(c.doc.removeElement(0, 'anm'));
    await env.settle(tester);
    c.select('titel');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('tool-history')));
    await env.settle(tester);
    await tester.tap(find.byKey(const ValueKey('history-back')));
    await env.settle(tester);
    expect(find.byKey(const ValueKey('history-preview')), findsOneWidget);
    // Fokus zurück an den Editor (z. B. Klick neben den Zeitstrahl) und Entf
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await env.settle(tester);
    expect(c.page.find('titel'), isNotNull, reason: 'nichts gelöscht');
    expect(find.byKey(const ValueKey('history-preview')), findsOneWidget, reason: 'Vorschau bleibt');
    final panel = tester.widget<IgnorePointer>(find.ancestor(of: find.byType(PropertiesPanel), matching: find.byType(IgnorePointer)).first);
    expect(panel.ignoring, isTrue, reason: 'rechte Leiste gesperrt');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await env.settle(tester);
    await env.leave(tester);
  });

  test('Zeitangaben im Verlauf', () {
    final now = DateTime(2026, 11, 11, 15);
    expect(historyTime(DateTime(2026, 11, 11, 14, 5), now), 'heute 14:05');
    expect(historyTime(DateTime(2026, 11, 10, 19, 40), now), 'gestern 19:40');
    expect(historyTime(DateTime(2026, 3, 12, 9, 0), now), '12.3. 09:00');
  });
}
