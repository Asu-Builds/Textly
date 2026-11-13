import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:doc_exchange/doc_exchange.dart';
import 'package:doc_model/doc_model.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

const _w = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"';

/// Kleine Word-Datei aus Teilen zusammenbauen.
Uint8List _docx(
  String body, {
  String? styles,
  String? numbering,
  Map<String, String> extra = const {},
  Map<String, List<int>> media = const {},
  Map<String, String> rels = const {},
  String sect = '',
}) {
  final a = Archive();
  void add(String name, String content) {
    final b = utf8.encode(content);
    a.addFile(ArchiveFile(name, b.length, b));
  }

  media.forEach((name, bytes) => a.addFile(ArchiveFile('word/media/$name', bytes.length, bytes)));
  if (media.isNotEmpty || rels.isNotEmpty) {
    add('word/_rels/document.xml.rels',
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '${media.keys.map((n) => '<Relationship Id="r${n.split('.').first}" Type="image" Target="media/$n"/>').join()}'
        '${rels.entries.map((e) => '<Relationship Id="${e.key}" Type="x" Target="${e.value}"/>').join()}</Relationships>');
  }

  add('[Content_Types].xml', '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>');
  add('word/document.xml', '<?xml version="1.0"?><w:document $_w><w:body>$body$sect</w:body></w:document>');
  if (styles != null) add('word/styles.xml', '<?xml version="1.0"?><w:styles $_w>$styles</w:styles>');
  if (numbering != null) add('word/numbering.xml', '<?xml version="1.0"?><w:numbering $_w>$numbering</w:numbering>');
  extra.forEach(add);
  return Uint8List.fromList(ZipEncoder().encode(a));
}

String _p(String text, {String? style, String jc = '', String rPr = ''}) =>
    '<w:p><w:pPr>${style == null ? '' : '<w:pStyle w:val="$style"/>'}${jc.isEmpty ? '' : '<w:jc w:val="$jc"/>'}</w:pPr>'
    '<w:r>${rPr.isEmpty ? '' : '<w:rPr>$rPr</w:rPr>'}<w:t xml:space="preserve">$text</w:t></w:r></w:p>';

/// Vereinfachte Höhe: Zeilen × Schriftgrösse (statt echter Satz in der App); Tabellen: Zeilen × 7 mm.
double _measure(DocElement e) => switch (e) {
  TextBlock t => t.text.split('\n').fold(0, (n, l) => n + 1 + l.length ~/ 90) * t.size * .45 + 2,
  TableBlock t => t.rowCount * 7.0,
  _ => e.box.h,
};

/// Bild im Text (DrawingML), Grösse in mm.
String _pic(String id, double wMm, double hMm, {String jc = ''}) =>
    '<w:p><w:pPr>${jc.isEmpty ? '' : '<w:jc w:val="$jc"/>'}</w:pPr><w:r><w:drawing><wp:inline xmlns:wp="wp">'
    '<wp:extent cx="${(wMm * 36000).round()}" cy="${(hMm * 36000).round()}"/>'
    '<a:graphic xmlns:a="a"><a:graphicData><pic:pic xmlns:pic="pic"><pic:blipFill><a:blip xmlns:r="r" r:embed="r$id"/></pic:blipFill></pic:pic></a:graphicData></a:graphic>'
    '</wp:inline></w:drawing></w:r></w:p>';

List<int> _png(int w, int h) => img.encodePng(img.Image(width: w, height: h));

String _tc(String text, {String tcPr = ''}) => '<w:tc>${tcPr.isEmpty ? '' : '<w:tcPr>$tcPr</w:tcPr>'}<w:p><w:r><w:t>$text</w:t></w:r></w:p></w:tc>';

const _styles = '''
<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri"/><w:sz w:val="22"/></w:rPr></w:rPrDefault></w:docDefaults>
<w:style w:type="paragraph" w:default="1" w:styleId="Standard"><w:name w:val="Normal"/></w:style>
<w:style w:type="paragraph" w:styleId="Titel"><w:name w:val="Title"/><w:basedOn w:val="Standard"/><w:rPr><w:sz w:val="56"/></w:rPr></w:style>
<w:style w:type="paragraph" w:styleId="berschrift1"><w:name w:val="heading 1"/><w:basedOn w:val="Standard"/><w:rPr><w:b/></w:rPr></w:style>
<w:style w:type="paragraph" w:styleId="Beschriftung"><w:name w:val="caption"/></w:style>
<w:style w:type="paragraph" w:styleId="Zitat"><w:name w:val="Quote"/><w:basedOn w:val="Standard"/><w:rPr><w:i/></w:rPr></w:style>
<w:style w:type="character" w:styleId="Fett"><w:name w:val="Strong"/><w:rPr><w:b/></w:rPr></w:style>
''';

List<TextBlock> _texts(TextlyDocument d) => [for (final p in d.pages) ...p.elements.whereType<TextBlock>()];

void main() {
  test('Titel, Überschrift, Fliesstext (auch deutsches Word), Formatierung und Ausrichtung', () {
    final r = importDocx(
      _docx(
        [
          _p('Vereinsausflug 2027', style: 'Titel'),
          _p('Programm', style: 'berschrift1'),
          '<w:p><w:r><w:t xml:space="preserve">Wir treffen uns </w:t></w:r><w:r><w:rPr><w:b/></w:rPr><w:t>um 8 Uhr</w:t></w:r>'
              '<w:r><w:t xml:space="preserve"> am </w:t></w:r><w:r><w:rPr><w:rStyle w:val="Fett"/><w:color w:val="C00000"/></w:rPr><w:t>Bahnhof</w:t></w:r><w:r><w:t>.</w:t></w:r></w:p>',
          _p('Bitte Wanderschuhe mitbringen.'),
          _p('Ein Zitat', style: 'Zitat', jc: 'center'),
          _p('Bild: Aletsch', style: 'Beschriftung'),
        ].join(),
        styles: _styles,
      ),
      heightMm: _measure,
    );
    final t = _texts(r.document);
    expect(t.map((b) => b.kind).toList(), [TextKind.title, TextKind.heading, TextKind.body, TextKind.body, TextKind.caption]);
    expect(t[0].text, 'Vereinsausflug 2027');
    expect(t[0].size, textKindPresets[TextKind.title]!.size, reason: 'Titel in der Textly-Vorlage');
    expect(t[2].text, 'Wir treffen uns um 8 Uhr am Bahnhof.\nBitte Wanderschuhe mitbringen.', reason: 'Fliesstext-Absätze in einem Block');
    expect(t[2].size, 11, reason: 'Grösse aus Word (Standard 11 pt)');
    final bold = t[2].runs.where((x) => x.style.bold == true).map((x) => t[2].text.substring(x.start, x.end)).toList();
    expect(bold, ['um 8 Uhr', 'Bahnhof'], reason: 'direkt und über Zeichenvorlage');
    expect(t[2].runs.any((x) => x.style.color == 0xFFC00000), isTrue);
    expect(t[3].align, TextAlignment.center, reason: 'andere Ausrichtung: eigener Block');
    expect(t[3].runs.single.style.italic, isTrue, reason: 'kursiv aus der Absatzvorlage');
    // untereinander, nicht überlappend, innerhalb der Ränder
    for (var i = 1; i < t.length; i++) {
      expect(t[i].box.y, greaterThanOrEqualTo(t[i - 1].box.bottom));
    }
    expect(t.first.box.x, 15);
    expect(t.first.box.w, 180);
    expect(r.notes, isEmpty);
  });

  test('Listen: Aufzählungszeichen und Nummern, auch verschachtelt', () {
    const numbering = '''
<w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:numFmt w:val="bullet"/><w:lvlText w:val=""/></w:lvl></w:abstractNum>
<w:abstractNum w:abstractNumId="1"><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/></w:lvl>
<w:lvl w:ilvl="1"><w:start w:val="1"/><w:numFmt w:val="lowerLetter"/><w:lvlText w:val="%2)"/></w:lvl></w:abstractNum>
<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
<w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num>''';
    String li(String text, int num, [int lvl = 0]) =>
        '<w:p><w:pPr><w:numPr><w:ilvl w:val="$lvl"/><w:numId w:val="$num"/></w:numPr></w:pPr><w:r><w:t>$text</w:t></w:r></w:p>';
    final r = importDocx(
      _docx(li('Äpfel', 1) + li('Birnen', 1) + li('Erstens', 2) + li('Unterpunkt', 2, 1) + li('Zweitens', 2), numbering: numbering),
      heightMm: _measure,
    );
    expect(_texts(r.document).single.text, '• Äpfel\n• Birnen\n1. Erstens\n    a) Unterpunkt\n2. Zweitens');
  });

  test('Seitenumbruch, volle Seiten, Abschnitt im Querformat', () {
    final long = List.generate(60, (i) => _p('Absatz ${i + 1} mit etwas Text.')).join();
    final r = importDocx(
      _docx(
        '${_p('Erste Seite')}<w:p><w:r><w:br w:type="page"/></w:r></w:p>${_p('Zweite Seite')}$long',
        sect: '<w:sectPr><w:pgSz w:w="16838" w:h="11906" w:orient="landscape"/></w:sectPr>',
      ),
      heightMm: _measure,
    );
    final d = r.document;
    expect(d.orientation, PageOrientation.landscape);
    expect(d.pages.length, greaterThan(2), reason: 'lange Texte gehen auf weiteren Seiten weiter');
    expect((d.pages[0].elements.single as TextBlock).text, 'Erste Seite');
    expect((d.pages[1].elements.first as TextBlock).text, startsWith('Zweite Seite'));
    for (final p in d.pages) {
      for (final e in p.elements) {
        expect(e.box.bottom, lessThanOrEqualTo(d.pageHeight - 15 + .01));
      }
    }
    final all = _texts(d).map((t) => t.text).join('\n');
    for (var i = 1; i <= 60; i++) {
      expect(all, contains('Absatz $i mit'), reason: 'kein Absatz verloren');
    }
    expect(r.notes, isEmpty);
  });

  test('Änderungen nachverfolgen, Links und Felder: angenommener Text', () {
    final r = importDocx(
      _docx(
        '<w:p><w:r><w:t xml:space="preserve">Treffpunkt: </w:t></w:r><w:del><w:r><w:delText>Bern</w:delText></w:r></w:del>'
        '<w:ins><w:r><w:t>Brig</w:t></w:r></w:ins><w:r><w:t xml:space="preserve">, </w:t></w:r>'
        '<w:hyperlink><w:r><w:t>www.tv-seetal.ch</w:t></w:r></w:hyperlink>'
        '<w:r><w:fldChar w:fldCharType="begin"/></w:r><w:r><w:instrText> DATE </w:instrText></w:r><w:r><w:fldChar w:fldCharType="separate"/></w:r>'
        '<w:r><w:t xml:space="preserve"> 12.11.2026</w:t></w:r><w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>',
      ),
      heightMm: _measure,
    );
    expect(_texts(r.document).single.text, 'Treffpunkt: Brig, www.tv-seetal.ch 12.11.2026');
  });

  test('Hinweise: Bild ohne Datei, Letter-Format, gemischte Grössen', () {
    final r = importDocx(
      _docx(
        '<w:p><w:r><w:drawing><wp:inline xmlns:wp="x"><a:graphic xmlns:a="y"><pic:pic xmlns:pic="z"/></a:graphic></wp:inline></w:drawing></w:r></w:p>'
        '<w:tbl><w:tr><w:tc><w:p><w:r><w:t>Datum</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>Anlass</w:t></w:r></w:p></w:tc></w:tr>'
        '<w:tr><w:tc><w:p><w:r><w:t>12. Mai</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>Wanderung</w:t></w:r></w:p></w:tc></w:tr></w:tbl>'
        '<w:p><w:r><w:rPr><w:sz w:val="24"/></w:rPr><w:t xml:space="preserve">Gross </w:t></w:r><w:r><w:rPr><w:sz w:val="16"/></w:rPr><w:t>klein</w:t></w:r></w:p>',
        sect: '<w:sectPr><w:pgSz w:w="12240" w:h="15840"/></w:sectPr>',
        extra: {'word/header1.xml': '<w:hdr $_w><w:p><w:r><w:t>Turnverein</w:t></w:r></w:p></w:hdr>'},
      ),
      heightMm: _measure,
    );
    final table = r.document.pages.first.elements.whereType<TableBlock>().single;
    expect(table.cells, [
      ['Datum', 'Anlass'],
      ['12. Mai', 'Wanderung'],
    ]);
    expect(r.notes, contains('1 Bild wurde nicht übernommen.'));
    expect(r.notes, contains('Das Seitenformat (216 × 279 mm) wurde auf A4 umgestellt.'));
    expect(r.notes, contains('Verschiedene Schriftgrössen innerhalb eines Absatzes wurden angeglichen.'));
  });

  test('Bilder: Grösse wie in Word, zu breite verkleinert, Ausrichtung, Text davor und danach', () {
    final r = importDocx(
      _docx(
        '${_p('Vorher')}${_pic('1', 80, 40, jc: 'center')}'
        '<w:p><w:r><w:t xml:space="preserve">Im Absatz </w:t></w:r><w:r><w:drawing><wp:inline xmlns:wp="wp"><wp:extent cx="${300 * 36000}" cy="${150 * 36000}"/>'
        '<a:graphic xmlns:a="a"><pic:pic xmlns:pic="pic"><a:blip xmlns:r="r" r:embed="r2"/></pic:pic></a:graphic></wp:inline></w:drawing></w:r>'
        '<w:r><w:t xml:space="preserve"> danach</w:t></w:r></w:p>',
        media: {'1.png': _png(40, 20), '2.png': _png(60, 30)},
      ),
      heightMm: _measure,
    );
    final els = r.document.pages.expand((p) => p.elements).toList();
    expect(els.map((e) => e.runtimeType.toString()), ['TextBlock', 'ImageBlock', 'TextBlock', 'ImageBlock', 'TextBlock']);
    final a = els[1] as ImageBlock, b = els[3] as ImageBlock;
    expect(a.box.w, closeTo(80, .01));
    expect(a.box.h, closeTo(40, .01));
    expect(a.box.centerX, closeTo(105, .01), reason: 'zentriert wie der Absatz');
    expect(b.box.w, 180, reason: 'höchstens so breit wie der Satzspiegel');
    expect(b.box.h, closeTo(90, .01), reason: 'Seitenverhältnis bleibt');
    expect(r.document.assets[a.asset]!.width, 40);
    expect(r.document.assets, hasLength(2));
    expect((els[2] as TextBlock).text, 'Im Absatz ');
    expect((els[4] as TextBlock).text, ' danach');
    for (var i = 1; i < els.length; i++) {
      expect(els[i].box.y, greaterThanOrEqualTo(els[i - 1].box.bottom), reason: 'untereinander');
    }
    expect(r.notes, isEmpty);
  });

  test('Bilder: Zuschnitt aus Word wird Ausschnitt; Aufbereitung der App wird benutzt', () {
    // 100 × 50 Bild, in Word links 50 % abgeschnitten → sichtbar die rechte Hälfte (50 × 50)
    final body = '<w:p><w:r><w:drawing><wp:inline xmlns:wp="wp"><wp:extent cx="${40 * 36000}" cy="${40 * 36000}"/>'
        '<a:graphic xmlns:a="a"><pic:pic xmlns:pic="pic"><pic:blipFill><a:blip xmlns:r="r" r:embed="r1"/><a:srcRect l="50000"/></pic:blipFill></pic:pic></a:graphic>'
        '</wp:inline></w:drawing></w:r></w:p>';
    final file = _docx(body, media: {'1.png': _png(100, 50)});
    final i = importDocx(file, heightMm: _measure).document.pages.single.elements.whereType<ImageBlock>().single;
    final w = cropWindow(i);
    expect(w.x, closeTo(.5, .001), reason: 'rechte Hälfte sichtbar');
    expect(w.w, closeTo(.5, .001));
    expect(w.h, closeTo(1, .001));

    // Aufbereitung (in der App: Drehung aus den Kameradaten, Verkleinern)
    var calls = 0;
    final r = importDocx(
      file,
      heightMm: _measure,
      prepareImage: (b) {
        calls++;
        return ImageAsset(id: 'vorbereitet', bytes: b, mimeType: 'image/png', width: 50, height: 100);
      },
    );
    expect(calls, 1);
    final p = r.document.pages.single.elements.whereType<ImageBlock>().single;
    expect((p.asset, p.naturalWidth, p.naturalHeight), ('vorbereitet', 50, 100));
    // nicht lesbar → Hinweis statt Bild
    final none = importDocx(file, heightMm: _measure, prepareImage: (_) => throw const FormatException('kaputt'));
    expect(none.document.pages.single.elements.whereType<ImageBlock>(), isEmpty);
    expect(none.notes, contains('1 Bild wurde nicht übernommen.'));
  });

  test('Tabellen: Spaltenbreiten, farbige Kopfzeile, Linien, Ausrichtung, verbundene Zellen', () {
    const grid = '<w:tblGrid><w:gridCol w:w="1440"/><w:gridCol w:w="4320"/></w:tblGrid>';
    final r = importDocx(
      _docx(
        '<w:tbl><w:tblPr><w:jc w:val="center"/><w:tblBorders><w:top w:val="single" w:sz="4" w:color="1F7A5A"/><w:bottom w:val="single"/>'
        '<w:left w:val="single"/><w:right w:val="single"/><w:insideH w:val="single"/><w:insideV w:val="single"/></w:tblBorders></w:tblPr>$grid'
        '<w:tr>${_tc('Zeit', tcPr: '<w:shd w:fill="2F5BD3"/>')}${_tc('Was', tcPr: '<w:shd w:fill="2F5BD3"/>')}</w:tr>'
        '<w:tr><w:tc><w:p><w:pPr><w:jc w:val="right"/></w:pPr><w:r><w:t>7.30</w:t></w:r></w:p></w:tc>${_tc('Treffpunkt')}</w:tr>'
        '<w:tr>${_tc('Ganzer Tag', tcPr: '<w:gridSpan w:val="2"/>')}</w:tr></w:tbl>'
        '<w:tbl><w:tblPr><w:tblBorders><w:top w:val="single"/><w:bottom w:val="single"/><w:insideH w:val="single"/></w:tblBorders></w:tblPr>'
        '<w:tr>${_tc('a')}${_tc('b')}</w:tr></w:tbl>'
        '<w:tbl><w:tr>${_tc('ohne')}${_tc('Linien')}</w:tr></w:tbl>',
      ),
      heightMm: _measure,
    );
    final t = r.document.pages.single.elements.whereType<TableBlock>().toList();
    expect(t, hasLength(3));
    expect(t[0].columns[0], closeTo(25.4, .01), reason: '1 Zoll');
    expect(t[0].columns[1], closeTo(76.2, .01));
    expect(t[0].x, closeTo(15 + (180 - 101.6) / 2, .01), reason: 'zentriert');
    expect(t[0].headerRow, isTrue);
    expect(t[0].style, TableStyle.header);
    expect(t[0].headerColor, 0xFF2F5BD3);
    expect(t[0].lines, TableLines.all);
    expect(t[0].lineColor, 0xFF1F7A5A);
    expect(t[0].align, [TextAlignment.right, TextAlignment.left]);
    expect(t[0].cells[2], ['Ganzer Tag', '']);
    expect(t[1].lines, TableLines.horizontal);
    expect(t[1].headerRow, isFalse, reason: 'nur eine Zeile');
    expect(t[1].width, closeTo(180, .01), reason: 'ohne Breiten: ganze Breite, gleich verteilt');
    expect(t[2].lines, TableLines.none, reason: 'Word ohne Rahmen');
    expect(t[1].y, greaterThanOrEqualTo(t[0].y + 3 * 7));
    expect(r.notes, ['Verbundene Tabellenzellen wurden getrennt.']);
  });

  test('lange Tabelle geht auf der nächsten Seite weiter, Kopfzeile wiederholt', () {
    final rows = [for (var i = 1; i <= 50; i++) '<w:tr>${_tc('Zeile $i')}${_tc('x')}</w:tr>'].join();
    final r = importDocx(
      _docx('<w:tbl><w:tr><w:trPr><w:tblHeader/></w:trPr>${_tc('Name')}${_tc('Wert')}</w:tr>$rows</w:tbl>'),
      heightMm: _measure,
    );
    final parts = [for (final p in r.document.pages) ...p.elements.whereType<TableBlock>()];
    expect(parts.length, greaterThan(1));
    expect(parts.map((t) => r.document.pages.indexWhere((p) => p.elements.contains(t))).toSet().length, parts.length, reason: 'je Seite ein Teil');
    for (final t in parts) {
      expect(t.cells.first, ['Name', 'Wert'], reason: 'Kopfzeile auf jeder Seite');
      expect(t.y + t.rowCount * 7, lessThanOrEqualTo(282 + .01));
    }
    final body = [for (final t in parts) ...t.cells.skip(1).map((c) => c.first)];
    expect(body, [for (var i = 1; i <= 50; i++) 'Zeile $i'], reason: 'keine Zeile verloren oder doppelt');
    expect(parts.map((t) => t.id).toSet(), hasLength(parts.length));
  });

  test('Kopf- und Fusszeile auf jeder Seite, Seitenzahlen, eigene erste Seite', () {
    const r = 'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"';
    final long = List.generate(70, (i) => _p('Absatz ${i + 1} mit etwas Text.')).join();
    final res = importDocx(
      _docx(
        long,
        sect: '<w:sectPr $r><w:headerReference w:type="default" r:id="rH"/><w:headerReference w:type="first" r:id="rH1"/>'
            '<w:footerReference w:type="default" r:id="rF"/><w:titlePg/></w:sectPr>',
        rels: {'rH': 'header1.xml', 'rH1': 'header2.xml', 'rF': 'footer1.xml'},
        extra: {
          'word/header1.xml': '<w:hdr $_w>${_p('Turnverein Seetal', jc: 'right')}</w:hdr>',
          'word/header2.xml': '<w:hdr $_w>${_p('Briefkopf erste Seite')}</w:hdr>',
          'word/footer1.xml': '<w:ftr $_w><w:p><w:pPr><w:jc w:val="center"/></w:pPr><w:r><w:t xml:space="preserve">Seite </w:t></w:r>'
              '<w:r><w:fldChar w:fldCharType="begin"/></w:r><w:r><w:instrText> PAGE </w:instrText></w:r><w:r><w:fldChar w:fldCharType="separate"/></w:r>'
              '<w:r><w:t>1</w:t></w:r><w:r><w:fldChar w:fldCharType="end"/></w:r><w:r><w:t xml:space="preserve"> von </w:t></w:r>'
              '<w:fldSimple w:instr=" NUMPAGES "><w:r><w:t>9</w:t></w:r></w:fldSimple></w:p></w:ftr>',
        },
      ),
      heightMm: _measure,
    );
    final d = res.document;
    expect(d.pages.length, greaterThan(1));
    for (var i = 0; i < d.pages.length; i++) {
      final t = d.pages[i].elements.whereType<TextBlock>().toList();
      final head = t.first;
      expect(head.text, i == 0 ? 'Briefkopf erste Seite' : 'Turnverein Seetal');
      expect(head.box.y, 15);
      // wie Word: «Erste Seite anders» ohne eigene Fusszeile → auf Seite 1 keine Fusszeile
      final foot = i == 0 ? null : t.last;
      if (foot != null) {
        expect(foot.text, 'Seite ${i + 1} von ${d.pages.length}');
        expect(foot.align, TextAlignment.center);
        expect(foot.box.bottom, closeTo(282, .01), reason: 'Fusszeile unten im Satzspiegel');
      } else {
        expect(t.last.text, isNot(startsWith('Seite')));
      }
      for (final b in t.sublist(1, foot == null ? t.length : t.length - 1)) {
        expect(b.box.y, greaterThanOrEqualTo(head.box.bottom + 5), reason: 'Text unter der Kopfzeile');
        expect(b.box.bottom, lessThanOrEqualTo(282 - 5 - 5 + .01), reason: 'Text über der Fusszeile');
      }
    }
    final all = _texts(d).map((t) => t.text).join('\n');
    for (var i = 1; i <= 70; i++) {
      expect(all, contains('Absatz $i mit'));
    }
    expect(res.notes, isEmpty);
  });

  test('Fussnoten am Ende, Textfelder als Text (nur einmal), verborgener Text, Grossbuchstaben', () {
    const mc = 'xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"';
    String box(String text) => '<w:txbxContent>${_p(text)}</w:txbxContent>';
    final r = importDocx(
      _docx(
        '<w:p><w:r><w:t>Der Gletscher ist 23 km lang</w:t></w:r><w:r><w:footnoteReference w:id="2"/></w:r><w:r><w:t>.</w:t></w:r></w:p>'
        '<w:p><w:r><w:t xml:space="preserve">Sichtbar </w:t></w:r><w:r><w:rPr><w:vanish/></w:rPr><w:t>geheim </w:t></w:r>'
        '<w:r><w:rPr><w:caps/></w:rPr><w:t>gross</w:t></w:r></w:p>'
        '<w:p><w:r><mc:AlternateContent $mc><mc:Choice Requires="wps"><w:drawing><wps:wsp xmlns:wps="wps"><wps:txbx>${box('Im Kasten')}</wps:txbx></wps:wsp></w:drawing></mc:Choice>'
        '<mc:Fallback><w:pict><v:shape xmlns:v="v"><v:textbox>${box('Im Kasten')}</v:textbox></v:shape></w:pict></mc:Fallback></mc:AlternateContent></w:r></w:p>',
        extra: {
          'word/footnotes.xml': '<w:footnotes $_w><w:footnote w:type="separator" w:id="-1"><w:p><w:r><w:separator/></w:r></w:p></w:footnote>'
              '<w:footnote w:id="2"><w:p><w:r><w:footnoteRef/></w:r><w:r><w:t xml:space="preserve"> Quelle: Glacier Monitoring</w:t></w:r></w:p></w:footnote></w:footnotes>',
        },
      ),
      heightMm: _measure,
    );
    final t = _texts(r.document).map((b) => b.text).toList();
    expect(t.first, startsWith('Der Gletscher ist 23 km lang[1].\nSichtbar GROSS'));
    expect(t.join('\n'), isNot(contains('geheim')));
    expect('Im Kasten'.allMatches(t.join('\n')), hasLength(1), reason: 'Word speichert Textfelder doppelt');
    expect(t.last, '[1]  Quelle: Glacier Monitoring', reason: 'Fussnote als eigener Block am Ende');
    expect(r.notes, containsAll(['Die Fussnote steht am Ende des Dokuments.', 'Ein Textfeld wurde als gewöhnlicher Text eingefügt.']));
  });

  test('A5 und A3 werden erkannt', () {
    final a5 = importDocx(_docx(_p('Flyer'), sect: '<w:sectPr><w:pgSz w:w="8391" w:h="11906"/></w:sectPr>'), heightMm: _measure);
    expect(a5.document.paper, PaperSize.a5);
    expect(_texts(a5.document).single.box.w, closeTo(148 - 30, .01), reason: 'Satzspiegel auf A5');
    expect(a5.notes, isEmpty);
    final a3 = importDocx(_docx(_p('Plakat'), sect: '<w:sectPr><w:pgSz w:w="23811" w:h="16838" w:orient="landscape"/></w:sectPr>'), heightMm: _measure);
    expect((a3.document.paper, a3.document.orientation), (PaperSize.a3, PageOrientation.landscape));
    expect(a3.document.pageWidth, 420);
  });

  test('alte .doc-Datei und kaputte Dateien: verständliche Meldung', () {
    final ole = Uint8List.fromList([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1, 0, 0]);
    expect(
      () => importDocx(ole, heightMm: _measure),
      throwsA(isA<DocxImportException>().having((e) => e.message, 'message', contains('Speichern unter'))),
    );
    expect(() => importDocx(Uint8List.fromList([1, 2, 3]), heightMm: _measure), throwsA(isA<DocxImportException>()));
    final noWord = Archive()..addFile(ArchiveFile('x.txt', 1, [65]));
    expect(() => importDocx(Uint8List.fromList(ZipEncoder().encode(noWord)), heightMm: _measure), throwsA(isA<DocxImportException>()));
  });

  test('leeres Dokument: eine leere Seite; leere Absätze nur als Leerzeile im Text', () {
    expect(importDocx(_docx(''), heightMm: _measure).document.pages, hasLength(1));
    final r = importDocx(_docx(_p('') + _p('Eins') + _p('') + _p('') + _p('Zwei') + _p('')), heightMm: _measure);
    expect(_texts(r.document).single.text, 'Eins\n\nZwei');
  });

  test('präparierte Datei: riesiger Teil wird nicht entpackt, verständliche Meldung', () {
    final bomb = List<int>.filled(64 * 1024 * 1024 + 1024, 0); // packt sich auf wenige KB zusammen
    final file = _docx(_pic('1', 40, 30), media: {'1.png': bomb});
    expect(file.length, lessThan(2 * 1024 * 1024));
    expect(
      () => importDocx(file, heightMm: _measure),
      throwsA(isA<DocxImportException>().having((e) => e.message, 'message', contains('zu gross'))),
    );
  });

  test('Listen mit Startwert 0, riesiger Startwert, Fussnote mit Verweis auf sich selbst, Textfeld in Zelle', () {
    const numbering = '''
<w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:start w:val="0"/><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/></w:lvl></w:abstractNum>
<w:abstractNum w:abstractNumId="1"><w:lvl w:ilvl="0"><w:start w:val="1000000000"/><w:numFmt w:val="upperRoman"/><w:lvlText w:val="%1."/></w:lvl></w:abstractNum>
<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num><w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num>''';
    String li(String text, int num) => '<w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="$num"/></w:numPr></w:pPr><w:r><w:t>$text</w:t></w:r></w:p>';
    const mc = 'xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"';
    final box = '<w:txbxContent>${_p('Unterschrift')}</w:txbxContent>';
    final r = importDocx(
      _docx(
        li('Vorbereitung', 1) + li('Anreise', 1) + li('Gross', 2) +
            '<w:p><w:r><w:t>Text</w:t></w:r><w:r><w:footnoteReference w:id="2"/></w:r></w:p>'
                '<w:tbl><w:tr><w:tc><w:p><w:r><mc:AlternateContent $mc><mc:Choice Requires="wps"><w:drawing><wps:wsp xmlns:wps="wps"><wps:txbx>$box</wps:txbx></wps:wsp></w:drawing></mc:Choice>'
                '<mc:Fallback><w:pict><v:shape xmlns:v="v"><v:textbox>$box</v:textbox></v:shape></w:pict></mc:Fallback></mc:AlternateContent></w:r></w:p></w:tc></w:tr></w:tbl>',
        numbering: numbering,
        extra: {
          'word/footnotes.xml': '<w:footnotes $_w><w:footnote w:id="2"><w:p><w:r><w:t>Quelle</w:t></w:r><w:r><w:footnoteReference w:id="2"/></w:r></w:p></w:footnote></w:footnotes>',
        },
      ),
      heightMm: _measure,
    );
    final all = _texts(r.document).map((t) => t.text).join('\n');
    expect(all, contains('0. Vorbereitung\n1. Anreise'), reason: 'Startwert 0 zählt hoch');
    expect(all, contains('32767. Gross'), reason: 'Startwert begrenzt, ohne riesige römische Zahl');
    expect(all, contains('[1] Quelle'), reason: 'Fussnote mit Verweis auf sich selbst: kein Fehler');
    final cell = r.document.pages.expand((p) => p.elements).whereType<TableBlock>().single.cells.single.single;
    expect(cell, 'Unterschrift', reason: 'Textfeld in der Zelle nur einmal');
  });
}
