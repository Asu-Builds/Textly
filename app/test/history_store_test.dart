import 'dart:io' show FileSystemException;
import 'dart:convert';
import 'dart:typed_data';

import 'package:doc_model/doc_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:textly/files/services.dart';
import 'package:textly/history/history_store.dart';

TextlyDocument _doc(String text, {ImageAsset? asset}) {
  var d = TextlyDocument(pages: [
    DocPage(id: 'p', elements: [
      TextBlock.ofKind(id: 't', box: const Box(20, 20, 100, 10), text: text),
      if (asset != null) ImageBlock(id: 'i', box: const Box(20, 40, 50, 40), asset: asset.id, naturalWidth: 10, naturalHeight: 8),
    ]),
  ]);
  if (asset != null) d = d.addAsset(asset);
  return d;
}

final _img = ImageAsset(id: 'bild1', bytes: Uint8List.fromList(List.filled(5000, 7)), mimeType: 'image/png', width: 10, height: 8);

void main() {
  late MemoryFileAccess fs;
  late DateTime now;
  late HistoryStore h;

  setUp(() {
    fs = MemoryFileAccess();
    now = DateTime(2026, 11, 11, 12);
    h = HistoryStore(fs, 'L:/Verlauf/d1', clock: () => now);
  });

  test('Stände ablegen und lesen; Bilder nur einmal gespeichert', () async {
    await h.record(_doc('A', asset: _img), label: 'Erstellt', kind: 'add', session: 1);
    now = now.add(const Duration(minutes: 1));
    await h.record(_doc('B', asset: _img), label: 'Text geändert', kind: 'edit', session: 1);
    final list = await h.entries();
    expect(list.map((e) => e.label), ['Erstellt', 'Text geändert']);
    expect(((await h.load(list.first.n)).page(0).elements.first as TextBlock).text, 'A');
    expect((await h.load(list.last.n)).assets['bild1']!.bytes.length, 5000);
    expect(fs.files.keys.where((k) => k.contains('/bilder/')), hasLength(1));
    final stateSize = fs.files['L:/Verlauf/d1/staende/1.json.gz']!.length;
    expect(stateSize, lessThan(1500), reason: 'komprimiert und ohne Bilddaten');
  });

  test('Sitzungen, Meilensteine und Namen; Verzeichnis übersteht Neustart', () async {
    expect(await h.newSession(), 1);
    final e = await h.record(_doc('A'), label: 'Geöffnet', kind: 'other', session: 1, milestone: 'Geöffnet');
    await h.mark(e.n, name: 'Entwurf für den Vorstand');
    final again = HistoryStore(fs, 'L:/Verlauf/d1');
    final list = await again.entries();
    expect((list.single.milestone, list.single.name), ('Geöffnet', 'Entwurf für den Vorstand'));
    expect(await again.newSession(), 2);
    await again.mark(e.n, name: '');
    expect((await again.entries()).single.name, isNull);
  });

  test('Ausdünnen: älter als 30 Tage weg, Benanntes und Neuester bleiben', () async {
    final start = now;
    now = start.subtract(const Duration(days: 40));
    final old = <HistoryEntry>[];
    for (var i = 0; i < 3; i++) {
      old.add(await h.record(_doc('alt $i', asset: i == 2 ? _img : null), label: 'x', kind: 'edit', session: 1));
    }
    await h.mark(old[1].n, name: 'Wichtig');
    now = start.subtract(const Duration(days: 3));
    final recent = await h.record(_doc('neu'), label: 'y', kind: 'delete', session: 2);
    now = start;
    expect(await h.thin(), 2);
    expect((await h.entries()).map((e) => e.n), [old[1].n, recent.n]);
    expect(fs.files.keys.where((k) => k.contains('/bilder/')), isEmpty, reason: 'Bild wird nicht mehr gebraucht');
    // nur alte Stände: der neueste bleibt trotzdem
    final h2 = HistoryStore(fs, 'L:/Verlauf/d2', clock: () => now);
    now = start.subtract(const Duration(days: 60));
    await h2.record(_doc('a'), label: 'x', kind: 'edit', session: 1);
    await h2.record(_doc('b'), label: 'x', kind: 'edit', session: 1);
    now = start;
    await h2.thin();
    expect(await h2.entries(), hasLength(1));
  });

  test('altes Format (jede Kleinigkeit) wird entfernt', () async {
    await h.record(_doc('A', asset: _img), label: 'x', kind: 'edit', session: 1);
    final index = fs.files['L:/Verlauf/d1/verzeichnis.json']!;
    final list = (jsonDecode(utf8.decode(index)) as Map)['entries'];
    fs.files['L:/Verlauf/d1/verzeichnis.json'] = Uint8List.fromList(utf8.encode(jsonEncode(list)));
    final again = HistoryStore(fs, 'L:/Verlauf/d1');
    expect(await again.entries(), isEmpty);
    expect(fs.files, isEmpty);
  });

  test('beschädigtes Verzeichnis: Verlauf beginnt neu', () async {
    fs.files['L:/Verlauf/d1/verzeichnis.json'] = Uint8List.fromList([9, 9, 9]);
    expect(await h.entries(), isEmpty);
    await h.record(_doc('A'), label: 'Geöffnet', kind: 'other', session: 1);
    expect(await h.entries(), hasLength(1));
  });

  test('alles löschen', () async {
    await h.record(_doc('A', asset: _img), label: 'Erstellt', kind: 'add', session: 1);
    await h.deleteAll();
    expect(fs.files, isEmpty);
  });

  test('beschädigtes Verzeichnis: alte Stände bleiben, neue werden dahinter nummeriert', () async {
    final fs = MemoryFileAccess();
    final h = HistoryStore(fs, 'V');
    final d = TextlyDocument(pages: [DocPage(id: 'p')]);
    await h.record(d, label: 'eins', kind: 'edit', session: 1);
    await h.record(d, label: 'zwei', kind: 'edit', session: 1);
    final zwei = fs.files['V/staende/2.json.gz'];
    fs.files['V/verzeichnis.json'] = Uint8List.fromList(utf8.encode('{kaputt'));
    final fresh = HistoryStore(fs, 'V');
    final e = await fresh.record(d, label: 'drei', kind: 'edit', session: 2);
    expect(e.n, 3, reason: 'hinter den vorhandenen Ständen');
    expect(fs.files['V/staende/2.json.gz'], zwei, reason: 'nicht überschrieben');
    expect(fs.files.containsKey('V/verzeichnis.defekt.json'), isTrue);
  });

  test('Verzeichnis gerade nicht lesbar: Fehler statt leerem Neubeginn', () async {
    final fs = _Unreadable();
    final h = HistoryStore(fs, 'V');
    await h.record(TextlyDocument(pages: [DocPage(id: 'p')]), label: 'eins', kind: 'edit', session: 1);
    fs.fail = true;
    await expectLater(HistoryStore(fs, 'V').entries(), throwsA(isA<FileSystemException>()));
  });
}

class _Unreadable extends MemoryFileAccess {
  bool fail = false;
  @override
  Future<Uint8List> read(String path) async => fail ? throw const FileSystemException('offline') : super.read(path);
}
