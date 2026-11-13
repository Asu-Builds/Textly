import 'dart:io';
import 'dart:typed_data';

import 'package:doc_model/doc_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:textly/files/services.dart';
import 'package:textly/library/document_library.dart';

TextlyDocument _doc(String title, {String body = 'Text'}) => TextlyDocument(pages: [
      DocPage(id: 'p', elements: [
        TextBlock.ofKind(id: 'b', box: const Box(20, 40, 100, 10), text: body),
        TextBlock.ofKind(id: 't', box: const Box(20, 20, 100, 10), text: title, kind: TextKind.title),
      ]),
    ]);

void main() {
  late MemoryFileAccess fs;
  late DateTime now;
  late DocumentLibrary lib;

  setUp(() {
    fs = MemoryFileAccess();
    now = DateTime(2026, 11, 11, 10);
    lib = DocumentLibrary(fs, 'C:/Textly', loadAsset: (k) async => File(k).readAsBytesSync(), clock: () => now);
  });

  test('Name aus dem Titel; folgt Änderungen, bis er selbst gewählt wird', () async {
    final e = await lib.create(_doc('Herbstausflug 2026'));
    expect(e.name, 'Herbstausflug 2026');
    expect((await lib.save(e.id, _doc('Herbstausflug 2027'))).name, 'Herbstausflug 2027');
    await lib.rename(e.id, 'Mein Flyer');
    expect((await lib.save(e.id, _doc('Anders'))).name, 'Mein Flyer', reason: 'eigener Name bleibt');
    expect(autoDocumentName(TextlyDocument(pages: [DocPage(id: 'x')])), 'Unbenanntes Dokument');
    expect(autoDocumentName(_doc('', body: 'Nur Fliesstext\nzweite Zeile')), 'Nur Fliesstext');
  });

  test('Speichern und Laden; neueste zuerst; Verzeichnis übersteht Neustart', () async {
    final a = await lib.create(_doc('A'));
    now = now.add(const Duration(minutes: 5));
    final b = await lib.create(_doc('B'));
    expect((await lib.entries()).map((e) => e.name), ['B', 'A']);
    now = now.add(const Duration(minutes: 5));
    await lib.save(a.id, _doc('A2'));
    expect((await lib.entries()).first.id, a.id);

    final again = DocumentLibrary(fs, 'C:/Textly', loadAsset: (k) async => null);
    expect((await again.entries()).map((e) => e.name), ['A2', 'B']);
    expect(((await again.load(b.id)).page(0).elements.last as TextBlock).text, 'B');
  });

  test('Beispieldokument mit App-Bildern wird vollständig gespeichert', () async {
    final e = await lib.create(sampleDocument());
    final back = await lib.load(e.id);
    expect(back.assets, hasLength(2));
  });

  test('Als Kopie verwenden lässt das Original unverändert', () async {
    final a = await lib.create(_doc('Flyer 2025'));
    final copy = await lib.duplicate(a.id);
    expect(copy.name, 'Kopie von Flyer 2025');
    await lib.save(copy.id, _doc('Flyer 2026'));
    expect(((await lib.load(a.id)).page(0).elements.last as TextBlock).text, 'Flyer 2025');
  });

  test('Papierkorb: löschen, wiederherstellen, nach 30 Tagen endgültig weg', () async {
    final a = await lib.create(_doc('Alt'));
    final b = await lib.create(_doc('Behalten'));
    await lib.moveToTrash(a.id);
    expect((await lib.entries()).map((e) => e.id), [b.id]);
    expect((await lib.entries(trash: true)).map((e) => e.id), [a.id]);
    await lib.restore(a.id);
    expect(await lib.entries(trash: true), isEmpty);

    await lib.moveToTrash(a.id);
    now = now.add(const Duration(days: 29));
    expect(await lib.purgeTrash(), isEmpty);
    now = now.add(const Duration(days: 2));
    expect(await lib.purgeTrash(), [a.id]);
    expect(fs.files.containsKey(lib.pathOf(a.id)), isFalse);
    expect((await lib.entries()).map((e) => e.id), [b.id]);
  });

  test('beschädigtes Verzeichnis: leer beginnen statt abstürzen', () async {
    fs.files['C:/Textly/bibliothek.json'] = Uint8List.fromList([1, 2, 3]);
    expect(await lib.entries(), isEmpty);
    expect((await lib.create(_doc('Neu'))).name, 'Neu');
  });

  test('gleichzeitige Speichervorgänge geraten nicht durcheinander', () async {
    final a = await lib.create(_doc('A'));
    final b = await lib.create(_doc('B'));
    await Future.wait([lib.save(a.id, _doc('A1')), lib.save(b.id, _doc('B1')), lib.save(a.id, _doc('A2'))]);
    final again = DocumentLibrary(fs, 'C:/Textly', loadAsset: (k) async => null);
    expect({for (final e in await again.entries()) e.name}, {'A2', 'B1'});
  });
}
