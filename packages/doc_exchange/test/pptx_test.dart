import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:doc_exchange/doc_exchange.dart';
import 'package:doc_model/doc_model.dart';
import 'package:test/test.dart';
import 'package:xml/xml.dart';

Uint8List? _appAsset(String key) {
  final f = File('../../app/$key');
  return f.existsSync() ? f.readAsBytesSync() : null;
}

/// Beispieldokument mit allem, was der Austausch abdecken soll.
TextlyDocument _testDocument() {
  var doc = sampleDocument();
  final p1 = doc.page(0);
  final body = p1.elements.whereType<TextBlock>().firstWhere((t) => t.kind == TextKind.body);
  var runs = applyInlineStyle(const [], body.text.length, 13, 21, const InlineStyle(bold: true));
  runs = applyInlineStyle(runs, body.text.length, 25, 31, const InlineStyle(italic: true, color: 0xFFB4442C));
  runs = applyInlineStyle(runs, body.text.length, 40, 52, const InlineStyle(underline: true));
  doc = doc.replaceElement(0, body.copyWith(runs: runs, align: TextAlignment.center).withFont(TextFont.lora));
  final glacier = p1.elements.whereType<ImageBlock>().first;
  doc = doc.replaceElement(0, withCropAt(withCropZoom(glacier, 1.6), .1, .7));
  final lake = p1.elements.whereType<ImageBlock>().last;
  doc = doc.replaceElement(0, lake.copyWith(fit: ImageFit.contain, box: lake.box.copyWith(w: 60)));
  final cap = p1.elements.whereType<TextBlock>().last.withFont(TextFont.caveat);
  doc = doc.replaceElement(0, cap.copyWith(box: cap.box.copyWith(h: 7), text: 'Zwei Zeilen\nmit Umbruch & <Sonderzeichen> «äöü»'));
  doc = doc.addElement(0, LineShape(id: 'steigend', a: const Pt(30, 280), b: const Pt(90, 270), width: 1.2, color: 0xFF1F7A5A));
  final rect = doc.page(1).elements.whereType<RectShape>().first;
  doc = doc.replaceElement(1, rect.copyWith(strokeWidth: 1.2, stroke: 0xFFB4442C, fill: 0xFFF7F0DC));
  // gedrehte Bilder: 90° mit Ausschnitt, 180°, 270° als ganzes Bild
  final turned = withQuarterTurn(glacier.copyWith(id: 'gedreht', box: const Box(20, 150, 60, 40)));
  doc = doc.addElement(1, withCropAt(withCropZoom(turned, 1.5), .2, .6));
  doc = doc.addElement(1, withQuarterTurn(withQuarterTurn(glacier.copyWith(id: 'kopf', box: const Box(100, 150, 60, 40)))));
  doc = doc.addElement(1, withQuarterTurn(glacier.copyWith(id: 'links', box: const Box(100, 210, 60, 40), fit: ImageFit.contain), clockwise: false));
  doc = doc.addElement(1, const RectShape(id: 'eckig', box: Box(20, 100, 50, 30), fill: 0x00FFFFFF, strokeWidth: .6, round: false));
  return doc;
}

void main() {
  final doc = _testDocument();
  final pptx = exportPptx(doc, boxOf: (e) => e.box, externalImage: _appAsset);

  test('Paket ist vollständig und jedes XML wohlgeformt', () {
    final zip = ZipDecoder().decodeBytes(pptx);
    final names = zip.files.map((f) => f.name).toSet();
    for (final required in [
      '[Content_Types].xml', '_rels/.rels', 'ppt/presentation.xml', 'ppt/slideMasters/slideMaster1.xml',
      'ppt/slideLayouts/slideLayout1.xml', 'ppt/theme/theme1.xml', 'ppt/slides/slide1.xml', 'ppt/slides/slide2.xml',
    ]) {
      expect(names, contains(required));
    }
    expect(names.where((n) => n.startsWith('ppt/media/')).length, 2, reason: 'jedes Bild einmal');
    for (final f in zip.files.where((f) => f.name.endsWith('.xml') || f.name.endsWith('.rels'))) {
      expect(() => XmlDocument.parse(String.fromCharCodes(f.content)), returnsNormally, reason: f.name);
    }
    Directory('build').createSync();
    File('build/textly-test.pptx').writeAsBytesSync(pptx);
  });

  test('Hin und zurück: Dokument bleibt inhaltlich gleich', () {
    final r = importPptx(pptx);
    expect(r.notes, isEmpty, reason: '${r.notes}');
    final back = r.document;
    expect(back.pages.length, doc.pages.length);
    for (var p = 0; p < doc.pages.length; p++) {
      final a = doc.page(p).elements, b = back.page(p).elements;
      expect(b.length, a.length, reason: 'Seite ${p + 1}');
      for (var i = 0; i < a.length; i++) {
        final x = a[i], y = b[i];
        expect(y.runtimeType, x.runtimeType, reason: 'Seite ${p + 1}, Element $i');
        switch ((x, y)) {
          case (TextBlock s, TextBlock t):
            expect(t.text, s.text);
            expect((t.kind, t.size, t.bold, t.italic, t.color, t.align), (s.kind, s.size, s.bold, s.italic, s.color, s.align));
            expect(t.runs, s.runs, reason: 'Formatierung «${s.text}»');
            expect(t.font, s.font, reason: 'Schriftart «${s.text}»');
            _box(t.box, s.box);
          case (ImageBlock s, ImageBlock t):
            expect((t.naturalWidth, t.naturalHeight), (s.naturalWidth, s.naturalHeight));
            expect(t.quarterTurns, s.quarterTurns);
            if (s.fit == ImageFit.cover) {
              _box(t.box, s.box);
              expect(t.zoom, closeTo(s.zoom, 1e-3));
              expect(t.cropX, closeTo(s.cropX, 1e-3));
              expect(t.cropY, closeTo(s.cropY, 1e-3));
            } else {
              // «Ganzes Bild»: kommt als Bild in seiner sichtbaren Lage zurück (gleich sichtbar)
              final p0 = containPlacement(s);
              _box(t.box, Box(s.box.x + p0.x, s.box.y + p0.y, p0.w, p0.h));
              expect(t.fit, ImageFit.cover);
              expect(t.zoom, closeTo(1, 1e-3));
            }
          case (RectShape s, RectShape t):
            _box(t.box, s.box);
            expect((t.fill, t.stroke, t.round), (s.fill, s.strokeWidth > 0 ? s.stroke : t.stroke, s.round));
            expect(t.strokeWidth, closeTo(s.strokeWidth, 1e-4));
          case (LineShape s, LineShape t):
            final same = _near(t.a, s.a) && _near(t.b, s.b) || _near(t.a, s.b) && _near(t.b, s.a);
            expect(same, isTrue, reason: '${s.a}–${s.b} / ${t.a}–${t.b}');
            expect(t.color, s.color);
            expect(t.width, closeTo(s.width, 1e-4));
          default:
            fail('unerwartet');
        }
      }
    }
  });

  test('Folien im Format 16:9 werden A4 quer, angepasst und gemeldet', () {
    final zip = ZipDecoder().decodeBytes(pptx);
    final out = Archive();
    for (final f in zip.files) {
      if (f.name == 'ppt/presentation.xml') {
        final xml = String.fromCharCodes(f.content).replaceFirst(RegExp(r'<p:sldSz[^>]*/>'), '<p:sldSz cx="12192000" cy="6858000"/>');
        out.addFile(ArchiveFile.string(f.name, xml));
      } else {
        out.addFile(ArchiveFile(f.name, f.content.length, f.content));
      }
    }
    final r = importPptx(ZipEncoder().encodeBytes(out));
    expect(r.notes.single, contains('A4 quer'));
    expect(r.document.orientation, PageOrientation.landscape);
    // Der Text beginnt an der verkleinerten Stelle; der Innenabstand von Textly bleibt 1 mm.
    final first = r.document.page(0).elements.first;
    const scale = 297 / 338.666; // 338,7 × 190,5 mm passt über die Breite in 297 × 210 mm
    expect(first.box.x + 1, closeTo((doc.page(0).elements.first.box.x + 1) * scale, .01));
  });

  test('Keine PowerPoint-Datei: verständliche Meldung', () {
    expect(() => importPptx(Uint8List.fromList([1, 2, 3])), throwsA(isA<PptxImportException>()));
  });
  test('Fremde Folien: Platzhalter mit Lage im Layout und gruppierte Formen', () {
    final zip = ZipDecoder().decodeBytes(pptx);
    final out = Archive();
    const title = '<p:sp><p:nvSpPr><p:cNvPr id="90" name="Title 1"/><p:cNvSpPr/><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr>'
        '<p:spPr/><p:txBody><a:bodyPr/><a:p><a:r><a:rPr sz="3200" b="1"/><a:t>Fremder Titel</a:t></a:r></a:p></p:txBody></p:sp>';
    // Gruppe: Kind-Koordinaten 0..1000 werden auf 10..30 mm abgebildet (Faktor 2 cm / 1000 EMU)
    const group = '<p:grpSp><p:nvGrpSpPr><p:cNvPr id="91" name="Gruppe"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>'
        '<p:grpSpPr><a:xfrm><a:off x="360000" y="7200000"/><a:ext cx="720000" cy="720000"/><a:chOff x="0" y="0"/><a:chExt cx="1000" cy="1000"/></a:xfrm></p:grpSpPr>'
        '<p:sp><p:nvSpPr><p:cNvPr id="92" name="Rechteck 9"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x="500" y="0"/><a:ext cx="500" cy="500"/></a:xfrm>'
        '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:solidFill><a:schemeClr val="accent1"/></a:solidFill></p:spPr></p:sp></p:grpSp>';
    const chart = '<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id="93" name="Diagramm"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr></p:graphicFrame>';
    const layoutTitle = '<p:sp><p:nvSpPr><p:cNvPr id="2" name="Titel"/><p:cNvSpPr/><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr>'
        '<p:spPr><a:xfrm><a:off x="720000" y="360000"/><a:ext cx="6120000" cy="1080000"/></a:xfrm></p:spPr></p:sp>';
    for (final f in zip.files) {
      var content = String.fromCharCodes(f.content);
      if (f.name == 'ppt/slides/slide2.xml') {
        content = content.replaceFirst('</p:spTree>', '$title$group$chart</p:spTree>');
      } else if (f.name == 'ppt/slideLayouts/slideLayout1.xml') {
        content = content.replaceFirst('</p:spTree>', '$layoutTitle</p:spTree>');
      } else {
        out.addFile(ArchiveFile(f.name, f.content.length, f.content));
        continue;
      }
      out.addFile(ArchiveFile.string(f.name, content));
    }
    final r = importPptx(ZipEncoder().encodeBytes(out));
    final els = r.document.page(1).elements;
    final t = els.whereType<TextBlock>().firstWhere((e) => e.text == 'Fremder Titel');
    expect(t.box.x + 1, closeTo(20 + 2.54, 1e-3), reason: 'Lage aus dem Layout, Innenabstand PowerPoint 2,54 mm');
    expect((t.size, t.bold), (32.0, true));
    final rect = els.whereType<RectShape>().last;
    expect(rect.box.x, closeTo(20, 1e-3)); // 10 mm + 500/1000 × 20 mm
    expect(rect.box.w, closeTo(10, 1e-3));
    expect(rect.fill, 0xFF2F5BD3, reason: 'Designfarbe accent1');
    expect(r.notes.join(), contains('Diagramm oder anderes eingebettetes Objekt'));
  });

  test('Querformat: Foliengrösse 297 × 210 mm und zurück als Querformat', () {
    final quer = doc.withOrientation(PageOrientation.landscape);
    final bytes = exportPptx(quer, boxOf: (e) => e.box, externalImage: _appAsset);
    final pres = String.fromCharCodes(ZipDecoder().decodeBytes(bytes).findFile('ppt/presentation.xml')!.content);
    expect(pres, contains('cx="10692000" cy="7560000"')); // 297 × 210 mm in EMU
    final back = importPptx(bytes);
    expect(back.document.orientation, PageOrientation.landscape);
    expect(back.notes.where((n) => n.contains('Format')), isEmpty, reason: 'A4 quer passt ohne Anpassung');
  });

  test('A5 und A3 bleiben beim Speichern und Öffnen erhalten', () {
    for (final paper in [PaperSize.a5, PaperSize.a3]) {
      final d = doc.withPaper(paper);
      final back = importPptx(exportPptx(d, boxOf: (e) => e.box, externalImage: _appAsset));
      expect(back.document.paper, paper);
      expect(back.document.pageWidth, closeTo(paper.shortMm, .5));
      expect(back.notes.where((n) => n.contains('Format')), isEmpty, reason: '$paper ohne Anpassung');
    }
  });

  /// Folie 2 um [xml] ergänzen (bzw. mit [replace] verändern) und wieder einlesen.
  PptxImport withSlide2(String xml, {String Function(String)? replace}) {
    final zip = ZipDecoder().decodeBytes(pptx);
    final out = Archive();
    for (final f in zip.files) {
      if (f.name == 'ppt/slides/slide2.xml') {
        var content = String.fromCharCodes(f.content).replaceFirst('</p:spTree>', '$xml</p:spTree>');
        if (replace != null) content = replace(content);
        out.addFile(ArchiveFile.string(f.name, content));
      } else {
        out.addFile(ArchiveFile(f.name, f.content.length, f.content));
      }
    }
    return importPptx(ZipEncoder().encodeBytes(out));
  }

  test('gedrehte Verbindungslinie wird senkrecht übernommen', () {
    // waagrecht 100 mm lang, um 90° gedreht: senkrecht durch die Mitte (50 mm | 50 mm)
    const cxn = '<p:cxnSp><p:nvCxnSpPr><p:cNvPr id="95" name="Verbinder"/><p:cNvCxnSpPr/><p:nvPr/></p:nvCxnSpPr>'
        '<p:spPr><a:xfrm rot="5400000"><a:off x="0" y="1800000"/><a:ext cx="3600000" cy="0"/></a:xfrm><a:prstGeom prst="line"><a:avLst/></a:prstGeom></p:spPr></p:cxnSp>';
    final l = withSlide2(cxn).document.page(1).elements.whereType<LineShape>().last;
    expect(l.a.x, closeTo(50, 1e-6));
    expect(l.b.x, closeTo(50, 1e-6));
    expect((l.a.y - l.b.y).abs(), closeTo(100, 1e-6));
  });

  test('beschädigte Folie und ungültige Farbe: verständliche Meldung bzw. Vorgabefarbe', () {
    expect(() => withSlide2('', replace: (c) => c.replaceFirst('</p:spTree>', '<p:sp>')), throwsA(isA<PptxImportException>()));
    const badColor = '<p:sp><p:nvSpPr><p:cNvPr id="96" name="Rechteck"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="360000" cy="360000"/></a:xfrm>'
        '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:solidFill><a:srgbClr val="ZZZ"/></a:solidFill><a:ln w="12700"><a:solidFill><a:srgbClr val="FF0000"/></a:solidFill></a:ln></p:spPr></p:sp>';
    expect(() => withSlide2(badColor), returnsNormally);
  });

  test('sehr schmales Textfeld bekommt eine positive Breite', () {
    const narrow = '<p:sp><p:nvSpPr><p:cNvPr id="97" name="Text"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="91440" cy="91440"/></a:xfrm>'
        '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr><p:txBody><a:bodyPr/><a:p><a:r><a:t>schmal</a:t></a:r></a:p></p:txBody></p:sp>';
    final t = withSlide2(narrow).document.page(1).elements.whereType<TextBlock>().firstWhere((e) => e.text == 'schmal');
    expect(t.box.w, greaterThan(0));
  });

  test('Steuerzeichen und flache Flächen: Export bleibt gültig', () {
    var d = TextlyDocument(pages: [DocPage(id: 'p', elements: const [])]);
    d = d.addElement(0, TextBlock.ofKind(id: 't', box: const Box(10, 10, 80, 10), text: 'x\u000By\u0001z\r'));
    d = d.addElement(0, const RectShape(id: 'r', box: Box(10, 50, 50, 0)));
    final bytes = exportPptx(d, boxOf: (e) => e.box);
    final slide = String.fromCharCodes(ZipDecoder().decodeBytes(bytes).findFile('ppt/slides/slide1.xml')!.content);
    expect(slide.contains('\u000B') || slide.contains('\u0001') || slide.contains('\r'), isFalse);
    expect(slide, isNot(contains('NaN')));
    expect((importPptx(bytes).document.page(0).elements.whereType<TextBlock>().single).text, 'xyz');
  });

  test('Tabelle: echte PowerPoint-Tabelle, hin und zurück ohne Verlust', () {
    for (final style in TableStyle.values) {
      final t = TableBlock(
        id: 'tab',
        x: 15,
        y: 120,
        columns: const [40, 70, 70],
        cells: const [
          ['Datum', 'Anlass', 'Preis'],
          ['12. März', 'Generalversammlung\nmit Essen', 'Fr. 25.–'],
          ['4. Mai', 'Wanderung & <Picknick>', ''],
        ],
        align: const [TextAlignment.left, TextAlignment.left, TextAlignment.right],
        size: 14,
        zebra: true,
      ).withStyle(style).withFont(TextFont.lora);
      final d = TextlyDocument(pages: [DocPage(id: 'p', elements: [t])]);
      final bytes = exportPptx(d, boxOf: (e) => e.box.copyWith(h: 30), rowHeightsOf: (_) => const [8, 14, 8]);
      final slide = String.fromCharCodes(ZipDecoder().decodeBytes(bytes).findFile('ppt/slides/slide1.xml')!.content);
      expect(slide, contains('<a:tbl>'));
      expect(XmlDocument.parse(slide).findAllElements('a:gridCol'), hasLength(3));
      final back = importPptx(bytes).document.page(0).elements.single as TableBlock;
      expect(back.cells, t.cells, reason: style.name);
      for (var c = 0; c < 3; c++) {
        expect(back.columns[c], closeTo(t.columns[c], .01));
      }
      expect(back.x, closeTo(15, .01));
      expect(back.y, closeTo(120, .01));
      expect(back.headerRow, isTrue);
      expect(back.style, style);
      expect(back.size, 14, reason: 'beliebige Grösse bleibt erhalten');
      expect(back.align, t.align);
      expect(back.lines, TableLines.all);
      expect(back.lineColor, t.lineColor);
      expect(back.font, TextFont.lora);
      if (style == TableStyle.header) expect(back.headerColor, t.headerColor);
      expect(back.zebra, isTrue);
    }
  });

  test('Tabelle: nur waagrechte Linien und keine Linien bleiben erhalten', () {
    for (final lines in [TableLines.horizontal, TableLines.none, TableLines.outer]) {
      final t = TableBlock.empty(id: 'tab', x: 20, y: 40, width: 120, cols: 2, rows: 3).copyWith(lines: lines, lineWidth: tableLineStrong);
      final d = TextlyDocument(pages: [DocPage(id: 'p', elements: [t])]);
      final back = importPptx(exportPptx(d, boxOf: (e) => e.box)).document.page(0).elements.single as TableBlock;
      expect(back.lines, lines);
      if (lines != TableLines.none) expect(back.lineWidth, tableLineStrong);
    }
  });
}


bool _near(Pt a, Pt b) => (a.x - b.x).abs() < 1e-3 && (a.y - b.y).abs() < 1e-3;

void _box(Box a, Box b) {
  expect(a.x, closeTo(b.x, 1e-3));
  expect(a.y, closeTo(b.y, 1e-3));
  expect(a.w, closeTo(b.w, 1e-3));
  expect(a.h, closeTo(b.h, 1e-3));
}
