import 'package:doc_model/doc_model.dart';
import 'package:test/test.dart';

void main() {
  group('Dokument', () {
    test('JSON hin und zurück ergibt dasselbe Dokument', () {
      final doc = sampleDocument();
      final again = TextlyDocument.fromJson(doc.toJson());
      expect(again.toJson(), doc.toJson());
    });

    test('neuere Formatversion wird abgelehnt', () {
      final j = sampleDocument().toJson()..['version'] = formatVersion + 1;
      expect(() => TextlyDocument.fromJson(j), throwsFormatException);
    });

    test('Operationen verändern das Original nicht und teilen unveränderte Seiten', () {
      final doc = sampleDocument();
      final el = doc.page(0).elements.first;
      final moved = doc.replaceElement(0, el.translated(5, 0));
      expect(doc.page(0).elements.first.box.x, el.box.x);
      expect(moved.page(0).elements.first.box.x, el.box.x + 5);
      expect(identical(moved.page(1), doc.page(1)), isTrue);
    });

    test('Reihenfolge: nach vorne und nach hinten', () {
      final doc = sampleDocument();
      final first = doc.page(0).elements.first.id;
      final front = doc.bringToFront(0, first);
      expect(front.page(0).elements.last.id, first);
      expect(front.sendToBack(0, first).page(0).elements.first.id, first);
    });

    test('Seiten einfügen, verschieben, löschen; letzte Seite bleibt', () {
      var doc = sampleDocument();
      doc = doc.insertPage(1, DocPage(id: 'neu'));
      expect(doc.pages.map((p) => p.id), ['p1', 'neu', 'p2']);
      doc = doc.movePage(1, 2);
      expect(doc.pages.map((p) => p.id), ['p1', 'p2', 'neu']);
      doc = doc.removePage(0).removePage(0);
      expect(doc.pages.length, 1);
      expect(doc.removePage(0).pages.length, 1);
    });

    test('Elementlisten sind unveränderlich', () {
      final doc = sampleDocument();
      expect(() => doc.page(0).elements.removeLast(), throwsUnsupportedError);
    });
  });

  group('Verlauf', () {
    test('rückgängig und wiederholen', () {
      final a = sampleDocument();
      final h = History(a);
      final b = a.removePage(1);
      h.push(b);
      expect(h.present, same(b));
      expect(h.undo(), isTrue);
      expect(h.present, same(a));
      expect(h.redo(), isTrue);
      expect(h.present, same(b));
      expect(h.redo(), isFalse);
    });

    test('neue Änderung löscht die Wiederholen-Liste', () {
      final a = sampleDocument();
      final h = History(a)..push(a.removePage(1));
      h.undo();
      h.push(a.movePage(0, 1));
      expect(h.canRedo, isFalse);
    });

    test('Zusammenfassen mit gleichem Schlüssel ergibt einen Schritt', () {
      final a = sampleDocument();
      final id = a.page(0).elements.first.id;
      final h = History(a);
      var d = a;
      for (var i = 0; i < 5; i++) {
        d = d.replaceElement(0, d.page(0).find(id)!.translated(1, 0));
        h.push(d, mergeKey: 'nudge:$id');
      }
      expect(h.undoDepth, 1);
      h.undo();
      expect(h.present, same(a));
    });

    test('Grenze der Schritte wird eingehalten', () {
      var d = sampleDocument();
      final h = History(d, limit: 3);
      for (var i = 0; i < 5; i++) {
        d = d.insertPage(0, DocPage(id: 'x$i'));
        h.push(d);
      }
      expect(h.undoDepth, 3);
    });
  });

  group('Griffe', () {
    const start = Box(10, 10, 40, 20);

    test('Seitengriff ändert nur eine Kante', () {
      expect(resizeBox(start, Handle.e, 10, 99), const Box(10, 10, 50, 20));
      expect(resizeBox(start, Handle.n, 99, -5), const Box(10, 5, 40, 25));
    });

    test('Eckgriff frei ändert Breite und Höhe', () {
      expect(resizeBox(start, Handle.se, 10, 10), const Box(10, 10, 50, 30));
    });

    test('Eckgriff mit Seitenverhältnis: gegenüberliegende Ecke bleibt fest', () {
      final r = resizeBox(start, Handle.nw, -20, 0, keepAspect: true);
      expect(r.w / r.h, closeTo(2, 1e-9));
      expect(r.right, start.right);
      expect(r.bottom, start.bottom);
      expect(r.w, 60);
    });

    test('Mindestgrösse wird eingehalten, auch über die gegenüberliegende Kante hinaus', () {
      final r = resizeBox(start, Handle.w, 100, 0);
      expect(r.w, minElementSize);
      expect(r.right, start.right);
      final p = resizeBox(start, Handle.se, -100, -100, keepAspect: true);
      expect(p.h, greaterThanOrEqualTo(minElementSize - 1e-9));
      expect(p.w / p.h, closeTo(2, 1e-9));
    });
  });

  test('IDs sind eindeutig', () {
    final ids = {for (var i = 0; i < 10000; i++) newId()};
    expect(ids.length, 10000);
  });

  group('Schriftart', () {
    final t = TextBlock.ofKind(id: 't', box: const Box(0, 0, 50, 10), text: 'Hallo', kind: TextKind.title);

    test('ohne Wahl gilt die Vorgabe der Textart', () {
      expect(t.font, isNull);
      expect(t.effectiveFont, TextFont.robotoCondensed);
      expect(t.withKind(TextKind.body).effectiveFont, TextFont.roboto);
    });

    test('gewählte Schrift bleibt beim Wechsel der Textart und beim Speichern', () {
      final l = t.withFont(TextFont.lora);
      expect(l.withKind(TextKind.body).effectiveFont, TextFont.lora);
      expect(l.copyWith(size: 30).font, TextFont.lora);
      expect(TextBlock.fromJson(l.toJson()).font, TextFont.lora);
      expect(l.withFont(null).effectiveFont, TextFont.robotoCondensed);
      expect(t.toJson().containsKey('font'), isFalse);
      expect(TextBlock.fromJson(l.toJson()..['font'] = 'gibtsnicht').font, isNull);
    });

    test('Dateien und Namen', () {
      expect(fontAssetPath(TextFont.lora, bold: true, italic: true), 'assets/fonts/Lora-BoldItalic.ttf');
      expect(fontAssetPath(TextFont.caveat, bold: false, italic: true), 'assets/fonts/Caveat-Regular.ttf', reason: 'ohne Kursivschnitt');
      expect(fontByName('playfair display'), TextFont.playfair);
      expect(fontByName('Arial'), isNull);
    });
  });

  group('Querformat', () {
    test('Masse, Speichern und Erhalt bei Änderungen', () {
      final q = sampleDocument().withOrientation(PageOrientation.landscape);
      expect((q.pageWidth, q.pageHeight), (297.0, 210.0));
      expect((sampleDocument().pageWidth, sampleDocument().pageHeight), (210.0, 297.0));
      final again = TextlyDocument.fromJson(q.toJson());
      expect(again.orientation, PageOrientation.landscape);
      expect(q.insertPage(1, DocPage(id: 'n')).orientation, PageOrientation.landscape);
      expect(q.withoutUnusedAssets().orientation, PageOrientation.landscape);
      expect(sampleDocument().toJson().containsKey('orientation'), isFalse, reason: 'Hochformat wie bisher');
    });

    test('Einrasten an Rand und Mitte des Querformats', () {
      final t = SnapTargets.forPage(const [], width: 297, height: 210);
      expect(t.xs, containsAll([0.0, 148.5, 297.0]));
      expect(t.ys, containsAll([0.0, 105.0, 210.0]));
    });
  });

  group('Papiergrösse', () {
    TextlyDocument doc() => TextlyDocument(pages: [
          DocPage(id: 'p', elements: [
            TextBlock.ofKind(id: 't', box: const Box(20, 30, 170, 12), text: 'Sommerfest', kind: TextKind.title),
            const ImageBlock(id: 'i', box: Box(20, 50, 170, 100), asset: 'a', naturalWidth: 340, naturalHeight: 200),
            const LineShape(id: 'l', a: Pt(20, 160), b: Pt(190, 160), width: .5),
            TableBlock(id: 'tb', x: 20, y: 170, columns: const [85, 85], cells: const [['a', 'b']]),
          ]),
        ]);

    test('A4 ist die Vorgabe; A5 und A3 mit richtigen Massen, auch quer', () {
      expect((doc().pageWidth, doc().pageHeight), (210, 297));
      final a5 = doc().withPaper(PaperSize.a5);
      expect((a5.pageWidth, a5.pageHeight), (148, 210));
      final a3q = doc().withOrientation(PageOrientation.landscape).withPaper(PaperSize.a3);
      expect((a3q.pageWidth, a3q.pageHeight), (420, 297));
      expect(a3q.withOrientation(PageOrientation.portrait).paper, PaperSize.a3, reason: 'Drehen behält die Grösse');
    });

    test('Umstellen skaliert alles mit: Lage, Grösse, Schrift, Linien, Tabellen', () {
      final a5 = doc().withPaper(PaperSize.a5);
      const f = 148 / 210;
      final t = a5.page(0).find('t')! as TextBlock;
      expect(t.box.x, closeTo(20 * f, 1e-9));
      expect(t.box.w, closeTo(170 * f, 1e-9));
      expect(t.size, closeTo(26 * f, 1e-9));
      final i = a5.page(0).find('i')! as ImageBlock;
      expect(i.box.h, closeTo(100 * f, 1e-9));
      final l = a5.page(0).find('l')! as LineShape;
      expect(l.b.x, closeTo(190 * f, 1e-9));
      expect(l.width, closeTo(.5 * f, 1e-9));
      final tb = a5.page(0).find('tb')! as TableBlock;
      expect(tb.width, closeTo(170 * f, 1e-9));
      expect(tb.size, closeTo(10.5 * f, 1e-9));
      // und zurück: wieder wie vorher
      final back = a5.withPaper(PaperSize.a4).page(0).find('t')! as TextBlock;
      expect(back.box.y, closeTo(30, 1e-9));
      expect(back.size, closeTo(26, 1e-9));
      // ohne Skalieren bleibt alles, wo es ist
      expect((doc().withPaper(PaperSize.a3, scale: false).page(0).find('t')! as TextBlock).box.x, 20);
    });

    test('wird gespeichert; ältere Dateien ohne Angabe sind A4', () {
      final a3 = doc().withPaper(PaperSize.a3);
      expect(a3.toJson()['paper'], 'a3');
      expect(doc().toJson().containsKey('paper'), isFalse);
      final back = TextlyDocument.fromJson(a3.toJson());
      expect(back.paper, PaperSize.a3);
      expect(TextlyDocument.fromJson(doc().toJson()).paper, PaperSize.a4);
    });
  });
}
