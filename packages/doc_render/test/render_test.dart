import 'dart:io';
import 'dart:ui' as ui;

import 'package:doc_model/doc_model.dart';
import 'package:doc_render/doc_render.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Schriften und Bilder liegen in der App.
const appDir = '../../app';
Future<ByteData> _fromDisk(String key) async => ByteData.sublistView(await File('$appDir/$key').readAsBytes());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    // alle Schriften wie in der App (ohne Kursivschnitt: aufrecht)
    for (final f in TextFont.values) {
      final loader = FontLoader(fontInfos[f]!.family);
      for (final (bold, italic) in [(false, false), (true, false), (false, true), (true, true)]) {
        loader.addFont(_fromDisk(fontAssetPath(f, bold: bold, italic: italic)));
      }
      await loader.load();
    }
  });

  test('PDF setzt jedes Zeichen an die Bildschirmposition', () async {
    final result = await exportPdf(sampleDocument(), _fromDisk);
    final r = result.report;
    expect(r.words, greaterThan(100));
    expect(r.maxDeviationMm, lessThan(.01), reason: '$r');
    expect(String.fromCharCodes(result.bytes.take(5)), '%PDF-');
  });

  test('PDF ist mit jeder Schriftart deckungsgleich mit dem Bildschirm', () async {
    var doc = sampleDocument();
    for (final f in TextFont.values) {
      // alle Texte beider Seiten in dieser Schrift
      for (var p = 0; p < doc.pages.length; p++) {
        for (final t in doc.page(p).elements.whereType<TextBlock>()) {
          doc = doc.replaceElement(p, t.withFont(f));
        }
      }
      final r = (await exportPdf(doc, _fromDisk)).report;
      // Kerning-Rundung einzelner Zeichen; unsichtbar (0,02 mm ≈ 0,06 pt)
      expect(r.maxDeviationMm, lessThan(.02), reason: '${fontInfos[f]!.label}: $r');
      expect(r.meanDeviationMm, lessThan(.002), reason: '${fontInfos[f]!.label}: $r');
    }
  });

  test('PDF mit Emoji und nachgestellten Akzenten bricht nicht ab', () async {
    // «é» als e + Akzent (so kopiert ein Mac), Emoji am Wortanfang, Emoji in fett formatiertem Text
    final texts = ['Hi 😃 x', '😃', 'été', 'áb 😀😃 Ende', '😃😃😃 mit Text dahinter, der umbricht ' * 4];
    var doc = TextlyDocument(pages: [DocPage(id: 'p', elements: const [])]);
    for (final (i, text) in texts.indexed) {
      doc = doc.addElement(0, TextBlock.ofKind(id: 't$i', box: Box(20, 20 + i * 30.0, 120, 10), text: text)
          .copyWith(runs: [StyleRun(0, text.length < 3 ? text.length : 2, const InlineStyle(bold: true))]));
    }
    final r = await exportPdf(doc, _fromDisk);
    expect(String.fromCharCodes(r.bytes.take(5)), '%PDF-');
  });

  test('Druckhinweis halbiert kein Emoji', () {
    final t = TextBlock.ofKind(id: 't', box: const Box(1, 20, 150, 10), text: '${'a' * 27}😃 Rest');
    final issue = printIssues(TextlyDocument(pages: [DocPage(id: 'p', elements: [t])])).firstWhere((i) => i.kind == PrintIssueKind.nearEdge);
    // gültiges UTF-16: keine einzelne Hälfte eines Paars
    final units = issue.message.codeUnits;
    for (var i = 0; i < units.length; i++) {
      if (units[i] >= 0xD800 && units[i] <= 0xDBFF) {
        expect(i + 1 < units.length && units[i + 1] >= 0xDC00 && units[i + 1] <= 0xDFFF, isTrue, reason: issue.message);
      }
    }
  });

  test('Querformat: PDF-Seite 297 × 210 mm, Druckprüfung mit Querformat-Rändern', () async {
    final rect = const RectShape(id: 'r', box: Box(240, 20, 40, 20));
    final hoch = TextlyDocument(pages: [DocPage(id: 'p', elements: [rect])]);
    final quer = hoch.withOrientation(PageOrientation.landscape);
    expect(printIssues(hoch).single.kind, PrintIssueKind.cutOff);
    expect(printIssues(quer), isEmpty);
    final pdf = String.fromCharCodes((await exportPdf(quer, _fromDisk)).bytes);
    final box = RegExp(r'/MediaBox\s*\[\s*0\s+0\s+([\d.]+)\s+([\d.]+)').firstMatch(pdf)!;
    expect(double.parse(box[1]!), closeTo(297 * mmToPt, .01));
    expect(double.parse(box[2]!), closeTo(210 * mmToPt, .01));
  });

  testWidgets('Eingabefeld bricht genau gleich um wie Anzeige und PDF', (tester) async {
    for (final t in sampleDocument().pages.expand((p) => p.elements).whereType<TextBlock>()) {
      await tester.pumpWidget(MaterialApp(
        home: Material(
          child: MediaQuery.withNoTextScaling(
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: textLayoutWidth(t) + caretMargin,
                child: TextField(
                  controller: TextEditingController(text: t.text),
                  style: textStyleFor(t),
                  strutStyle: strutFor(t),
                  textAlign: textAlignFor(t),
                  maxLines: null,
                  cursorWidth: cursorWidth,
                  selectionHeightStyle: ui.BoxHeightStyle.tight,
                  decoration: const InputDecoration.collapsed(hintText: null),
                ),
              ),
            ),
          ),
        ),
      ));
      final editable = tester.state<EditableTextState>(find.byType(EditableText)).renderEditable;
      final tp = layoutText(t);
      for (final m in RegExp(r'\S+').allMatches(t.text)) {
        final sel = TextSelection(baseOffset: m.start, extentOffset: m.end);
        final a = tp.getBoxesForSelection(sel).first;
        final b = editable.getBoxesForSelection(sel).first;
        expect((a.left - b.left).abs(), lessThan(.001), reason: '«${m[0]}»: links');
        expect((a.top - b.top).abs(), lessThan(.001), reason: '«${m[0]}»: Zeile');
      }
    }
  });

  test('Bildausschnitt: Fläche füllen deckt den Rahmen, ganzes Bild passt hinein', () {
    const img = ImageBlock(id: 'i', box: Box(0, 0, 100, 50), asset: 'x', naturalWidth: 1000, naturalHeight: 1000);
    final cover = imagePlacement(img);
    expect(cover.width, closeTo(100 * mmToPt, 1e-9));
    expect(cover.height, closeTo(100 * mmToPt, 1e-9));
    expect(cover.top, closeTo(-25 * mmToPt, 1e-9));
    final contain = imagePlacement(img.copyWith(fit: ImageFit.contain));
    expect(contain.height, closeTo(50 * mmToPt, 1e-9));
    expect(contain.left, closeTo(25 * mmToPt, 1e-9));
  });

  test('Textblock mit automatischer Höhe wird gemessen', () {
    final t = sampleDocument().page(0).elements.whereType<TextBlock>().firstWhere((e) => e.kind == TextKind.body);
    final b = renderedBox(t);
    expect(b.h, greaterThan(20));
    // gespeicherte Höhe ist nur ein Richtwert
    expect(renderedBox(t.copyWith(box: t.box.copyWith(h: 5))).h, closeTo(b.h, 1e-9));
  });

  group('Druckprüfung', () {
    TextlyDocument docWith(List<DocElement> els) => TextlyDocument(pages: [DocPage(id: 'p', elements: els)]);

    test('Beispieldokument hat keine Probleme', () {
      expect(printIssues(sampleDocument()), isEmpty);
    });

    test('abgeschnitten, ausserhalb, am Rand; Rechtecke am Rand sind erlaubt', () {
      final issues = printIssues(docWith([
        TextBlock.ofKind(id: 'zu-weit', box: const Box(150, 20, 80, 10), text: 'Ragt rechts hinaus und füllt die ganze Zeile aus'),
        // breiter Rahmen, aber kurzer linksbündiger Text: nichts wird abgeschnitten
        TextBlock.ofKind(id: 'kurz', box: const Box(150, 60, 80, 10), text: 'Kurz'),
        const ImageBlock(id: 'weg', box: Box(-60, 20, 50, 40), asset: 'a', naturalWidth: 3000, naturalHeight: 2400),
        const LineShape(id: 'rand', a: Pt(2, 100), b: Pt(100, 100)),
        const RectShape(id: 'balken', box: Box(0, 0, 210, 20)),
      ]));
      expect({for (final i in issues) i.elementId: i.kind}, {
        'zu-weit': PrintIssueKind.cutOff,
        'weg': PrintIssueKind.cutOff,
        'rand': PrintIssueKind.nearEdge,
      });
      expect(issues.firstWhere((i) => i.elementId == 'weg').message, contains('ganz ausserhalb'));
      expect(issues.firstWhere((i) => i.elementId == 'zu-weit').message, contains('«Ragt rechts hinaus und füllt …»'));
    });

    test('Text wird nie abgeschnitten: alte Dateien mit fester Höhe öffnen automatisch', () {
      final t = TextBlock.ofKind(id: 't', box: const Box(20, 20, 40, 5), text: 'Ein langer Text, der nicht in fünf Millimeter Höhe passt.');
      final old = TextBlock.fromJson(t.toJson()..['autoHeight'] = false);
      expect(renderedBox(old).h, greaterThan(10));
      expect(printIssues(docWith([old])), isEmpty);
    });

    test('unscharfes Bild: Auflösung über die Rahmenbreite, Ausschnitt eingerechnet', () {
      const small = ImageBlock(id: 'k', box: Box(20, 20, 170, 100), asset: 'a', naturalWidth: 640, naturalHeight: 480);
      expect(imagePrintDpi(small), closeTo(640 / (170 / 25.4), 1e-9));
      expect(printIssues(docWith([small])).single.kind, PrintIssueKind.lowResolution);
      const big = ImageBlock(id: 'g', box: Box(20, 20, 170, 100), asset: 'a', naturalWidth: 3000, naturalHeight: 2000);
      expect(printIssues(docWith([big])), isEmpty);
      expect(printIssues(docWith([withCropZoom(big, 4)])).single.kind, PrintIssueKind.lowResolution, reason: 'stark vergrösserter Ausschnitt');
    });
  });

  test('Tabelle: Zeilen wachsen mit dem Text, Höhe wird gemessen', () {
    final t = TableBlock(
      id: 't',
      x: 15,
      y: 100,
      columns: const [30, 60],
      cells: const [
        ['Datum', 'Anlass'],
        ['12. März', 'Generalversammlung mit Essen und anschliessendem Lotto im Saal'],
        ['', ''],
      ],
    );
    final h = tableRowHeights(t);
    expect(h[2], closeTo(h[0], 1e-9), reason: 'leere Zeile: so hoch wie eine Textzeile');
    expect(h[2], greaterThanOrEqualTo(tableMinRowMm));
    expect(h[1], greaterThan(h[0] * 1.5), reason: 'langer Text bricht um');
    expect(renderedBox(t).h, closeTo(h.reduce((a, b) => a + b), 1e-9));
    final cell = tableCellBlock(t, 1, 1);
    expect(cell.box.x, closeTo(15 + 30 + tableCellPadXMm, 1e-9));
    expect(cell.box.y, closeTo(100 + h[0] + tableCellPadYMm, 1e-9));
    expect((tableCellBlock(t, 0, 0).bold, tableCellBlock(t, 1, 0).bold), (true, false));
  });

  test('Tabelle im PDF: Zelltexte an der Bildschirmposition', () async {
    final t = TableBlock(
      id: 't',
      x: 15,
      y: 40,
      columns: const [40, 80],
      cells: const [
        ['Datum', 'Anlass'],
        ['12. März', 'Generalversammlung'],
      ],
      zebra: true,
    );
    final result = await exportPdf(TextlyDocument(pages: [DocPage(id: 'p', elements: [t])]), _fromDisk);
    expect(result.report.words, 5, reason: 'Datum, Anlass, 12., März, Generalversammlung');
    expect(result.report.maxDeviationMm, lessThan(.05));
    expect(result.bytes.length, greaterThan(1000));
  });

  test('Emojis und fremde Schriftzeichen werden gemeldet, gewöhnliche Sonderzeichen nicht', () {
    expect(hasUnprintableCharacters('Grüsse – «Sommerfest» · 12 € · Ålesund'), isFalse);
    expect(hasUnprintableCharacters('Viel Spass 🙂'), isTrue);
    expect(hasUnprintableCharacters('Sonne ☀'), isTrue);
    expect(hasUnprintableCharacters('東京'), isTrue);
    final doc = TextlyDocument(pages: [
      DocPage(id: 'p', elements: [TextBlock.ofKind(id: 't', box: const Box(20, 20, 100, 10), text: 'Hallo 🎉')]),
    ]);
    expect(printIssues(doc).where((i) => i.kind == PrintIssueKind.missingCharacters), hasLength(1));
  });
}
