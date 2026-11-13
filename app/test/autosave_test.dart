import 'dart:io';
import 'dart:typed_data';

import 'package:doc_model/doc_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:textly/editor/editor_controller.dart';
import 'package:textly/files/services.dart';
import 'package:textly/history/history_store.dart';
import 'package:textly/library/autosave.dart';
import 'package:textly/library/document_library.dart';
import 'package:textly/spell/spell_check.dart';

TextlyDocument _doc() => TextlyDocument(pages: [
      DocPage(id: 'p', elements: [
        TextBlock.ofKind(id: 'titel', box: const Box(20, 20, 150, 10), text: 'Herbstausflug', kind: TextKind.title),
        TextBlock.ofKind(id: 'a', box: const Box(20, 60, 150, 10), text: 'Anmeldung'),
        TextBlock.ofKind(id: 'b', box: const Box(20, 80, 150, 10), text: 'Treffpunkt'),
        const ImageBlock(id: 'i', box: Box(20, 100, 80, 60), asset: 'x', naturalWidth: 800, naturalHeight: 600),
      ]),
    ]).addAsset(ImageAsset(id: 'x', bytes: Uint8List.fromList(List.filled(200, 3)), mimeType: 'image/png', width: 800, height: 600));

class _Env {
  _Env();
  final fs = MemoryFileAccess();
  var now = DateTime(2026, 11, 11, 14);
  late final lib = DocumentLibrary(fs, 'C:/Textly', loadAsset: (k) async => File(k).readAsBytesSync(), clock: () => now);
  late final history = HistoryStore(fs, 'L:/Verlauf/d', clock: () => now);
  late EditorController c;
  late AutosaveSession s;

  Future<void> open() async {
    final e = await lib.create(_doc());
    c = EditorController(_doc(), spell: SpellChecker(WordListBackend(const [])));
    s = AutosaveSession(lib, e, c,
        delay: const Duration(milliseconds: 5), history: history, pause: const Duration(milliseconds: 80), clock: () => now);
    await _wait();
  }

  Future<void> _wait([int ms = 30]) => Future<void>.delayed(Duration(milliseconds: ms));

  /// Änderung übernehmen und warten, bis sie gespeichert ist.
  Future<void> change(TextlyDocument Function(TextlyDocument d) f) async {
    c.commit(f(c.doc));
    await _wait();
  }

  Future<List<String>> labels() async => [for (final e in await history.entries()) e.label];
}

void main() {
  test('nur geänderter Inhalt wird gespeichert, kleine Änderungen geben keinen eigenen Punkt', () async {
    final env = _Env();
    await env.open();
    expect(await env.labels(), ['Ausgangsstand']);
    final saved = (await env.lib.entry(env.s.id))!.modified;

    // gleicher Inhalt, neues Objekt → nichts schreiben
    env.now = env.now.add(const Duration(minutes: 1));
    await env.change((d) => d.replaceElement(0, d.page(0).find('a')!));
    expect((await env.lib.entry(env.s.id))!.modified, saved);

    // kleine Bearbeitungen: gespeichert, aber erst nach der Pause ein Punkt
    await env.change((d) => d.replaceElement(0, (d.page(0).find('a')! as TextBlock).copyWith(text: 'Anmeldung bis Freitag')));
    await env.change((d) => d.replaceElement(0, d.page(0).find('i')!.translated(5, 0)));
    expect((await env.lib.entry(env.s.id))!.modified, isNot(saved));
    expect(await env.labels(), ['Ausgangsstand']);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(await env.labels(), ['Ausgangsstand', 'Bearbeitet: 1 Text, 1 Bild']);
    expect((await env.history.entries()).last.from, isNotNull);
    env.s.dispose();
  });

  test('Löschen: Stand davor, mehrere Löschungen kurz nacheinander ein Punkt', () async {
    final env = _Env();
    await env.open();
    await env.change((d) => d.removeElement(0, 'a'));
    env.now = env.now.add(const Duration(seconds: 20));
    await env.change((d) => d.removeElement(0, 'b'));
    expect(await env.labels(), ['Ausgangsstand', '2 Elemente wurden gelöscht']);
    final del = (await env.history.entries()).last;
    expect((del.kind, del.subject), ('delete', 'text'));
    final after = await env.history.load(del.n);
    expect((after.page(0).find('a'), after.page(0).find('b')), (null, null), reason: 'Stand nach dem Löschen');
    expect((await env.history.loadBefore(del.n))!.page(0).find('a'), isNotNull, reason: 'Stand davor zum Zurückholen');

    // später: eigener Punkt
    env.now = env.now.add(const Duration(minutes: 5));
    await env.change((d) => d.removeElement(0, 'i'));
    expect((await env.labels()).last, 'Bild wurde gelöscht');
    env.s.dispose();
  });

  test('grosse Veränderung, Weitergeben, Verlassen', () async {
    final env = _Env();
    await env.open();
    await env.change((d) => d.replaceElement(0, d.page(0).find('i')!.translated(0, 50)));
    final big = (await env.history.entries()).last;
    expect((big.label, big.kind, big.subject), ('Bild wurde verschoben', 'big', 'image'));
    expect((await env.history.load(big.n)).page(0).find('i')!.box.y, 150, reason: 'Stand nach dem Verschieben');
    expect((await env.history.entries()).first.label, 'Ausgangsstand', reason: 'davor: der Stand vor dem Verschieben');

    await env.change((d) => d.withOrientation(PageOrientation.landscape));
    expect((await env.labels()).last, 'Auf Querformat umgestellt');

    await env.s.recordShare('Als PDF gespeichert');
    expect((await env.history.entries()).last.kind, 'share');

    // Verlassen legt angesammelte Bearbeitungen sofort ab
    env.c.commit(env.c.doc.replaceElement(0, (env.c.doc.page(0).find('b')! as TextBlock).copyWith(text: 'Treffpunkt Bahnhof')));
    await env.s.finish();
    expect((await env.labels()).last, 'Bearbeitet: 1 Text');
    env.s.dispose();
  });

  test('Wiederherstellen sichert den aktuellen Stand und legt keinen weiteren Punkt an', () async {
    final env = _Env();
    await env.open();
    final first = (await env.history.entries()).first;
    await env.change((d) => d.removeElement(0, 'a'));
    await env.s.restore(await env.history.load(first.n), 'Stand vor «Fliesstext wurde gelöscht» wiederhergestellt');
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(await env.labels(), ['Ausgangsstand', 'Fliesstext wurde gelöscht', 'Stand vor «Fliesstext wurde gelöscht» wiederhergestellt']);
    expect((await env.history.load((await env.history.entries()).last.n)).page(0).find('a'), isNotNull, reason: 'Stand danach');
    expect(env.c.page.find('a'), isNotNull);
    env.s.dispose();
  });

  test('Löschung merkt sich genau das Gelöschte; Bearbeitetes davor bleibt sichtbar', () async {
    final env = _Env();
    await env.open();
    // erst bearbeiten, dann löschen: die Bearbeitung bekommt ihren eigenen Punkt
    await env.change((d) => d.replaceElement(0, (d.page(0).find('b')! as TextBlock).copyWith(text: 'Treffpunkt Bahnhof')));
    await env.change((d) => d.removeElement(0, 'a'));
    env.now = env.now.add(const Duration(minutes: 5));
    await env.change((d) => d.removeElement(0, 'i'));
    expect(await env.labels(), ['Ausgangsstand', 'Bearbeitet: 1 Text', 'Fliesstext wurde gelöscht', 'Bild wurde gelöscht']);
    final list = await env.history.entries();
    expect(list[2].deleted, ['a']);
    expect(list[3].deleted, ['i']);
    expect([for (final e in list) e.subject], [null, 'text', 'text', 'image'], reason: 'Piktogramm: was betroffen ist');

    // Stand davor (für die gestrichelte Markierung) enthält genau das Gelöschte
    final before = (await env.history.loadBefore(list[2].n))!;
    expect(before.page(0).find('a'), isNotNull);
    expect((await env.history.load(list[2].n)).page(0).find('a'), isNull, reason: 'Stand danach ohne den Text');
    env.s.dispose();
  });

  test('Seite löschen: Stand davor enthält die Seite', () async {
    final env = _Env();
    await env.open();
    await env.change((d) => d.insertPage(1, DocPage(id: 'q', elements: [TextBlock.ofKind(id: 'z', box: const Box(10, 10, 50, 10), text: 'Seite zwei')])));
    env.now = env.now.add(const Duration(minutes: 5));
    await env.change((d) => d.removePage(1));
    final del = (await env.history.entries()).last;
    expect(del.label, 'Seite 2 wurde gelöscht');
    expect(del.deletedPages, ['q']);
    expect(del.subject, 'page');
    final before = (await env.history.loadBefore(del.n))!;
    expect(before.pages.map((p) => p.id), ['p', 'q']);
    expect(before.page(1).find('z'), isNotNull);
    env.s.dispose();
  });

  test('dazwischen bearbeitet: Löschungen bleiben getrennt und in der richtigen Reihenfolge', () async {
    final env = _Env();
    await env.open();
    await env.change((d) => d.removeElement(0, 'a'));
    await env.change((d) => d.replaceElement(0, (d.page(0).find('b')! as TextBlock).copyWith(text: 'Treffpunkt Bahnhof')));
    await env.change((d) => d.removeElement(0, 'i'));
    expect(await env.labels(), ['Ausgangsstand', 'Fliesstext wurde gelöscht', 'Bearbeitet: 1 Text', 'Bild wurde gelöscht']);
    env.s.dispose();
  });
}
