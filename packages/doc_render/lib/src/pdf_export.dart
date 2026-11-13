import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:pdf/pdf.dart';
import 'package:vector_math/vector_math_64.dart' show Matrix4;

import 'package:doc_model/doc_model.dart';

import 'image_layout.dart';
import 'table_layout.dart';
import 'text_layout.dart';

const double pageWidthPt = pageWidthMm * mmToPt;
const double pageHeightPt = pageHeightMm * mmToPt;

/// Lädt Schriften und Bilder (in der App über rootBundle, im Test von der Festplatte).
/// Übernommen aus dem Machbarkeitstest; Begründungen siehe spike/ERGEBNISSE.md.
typedef AssetLoader = Future<ByteData> Function(String key);

/// Messbericht: Wie genau liegen die Zeichen im PDF dort, wo Flutter sie am Bildschirm zeigt?
class FidelityReport {
  int words = 0;
  int glyphs = 0;
  int lines = 0;
  int brokenWords = 0;

  /// Abweichung jeder Zeichenposition nach dem Ausgleich (massgeblich).
  double maxDeviationMm = 0;
  double sumDeviationMm = 0;
  String worstWord = '';

  /// Abweichung der Wortbreite ohne Ausgleich (zeigt, was das PDF-Paket allein liefern würde).
  double maxRawWordDeviationMm = 0;

  double get meanDeviationMm => glyphs == 0 ? 0 : sumDeviationMm / glyphs;

  void addGlyph(String word, double deviationPt) {
    final mm = deviationPt.abs() / mmToPt;
    glyphs++;
    sumDeviationMm += mm;
    if (mm > maxDeviationMm) {
      maxDeviationMm = mm;
      worstWord = word;
    }
  }

  void addRawWord(double deviationPt) {
    words++;
    final mm = deviationPt.abs() / mmToPt;
    if (mm > maxRawWordDeviationMm) maxRawWordDeviationMm = mm;
  }

  @override
  String toString() =>
      'Wörter: $words, Zeichen: $glyphs, Zeilen: $lines, getrennte Wörter: $brokenWords, '
      'max. Abweichung Zeichenposition: ${maxDeviationMm.toStringAsFixed(3)} mm («$worstWord»), '
      'Mittel: ${meanDeviationMm.toStringAsFixed(4)} mm, '
      'ohne Ausgleich (Wortbreite): ${maxRawWordDeviationMm.toStringAsFixed(3)} mm';
}

class PdfExportResult {
  PdfExportResult(this.bytes, this.report);
  final Uint8List bytes;
  final FidelityReport report;
}


/// Erzeugt das PDF. Text wird nicht neu umbrochen: Jedes Wort wird an die Position gesetzt,
/// die der Flutter-Textsatz auf dem Bildschirm berechnet hat.
Future<PdfExportResult> exportPdf(TextlyDocument doc, AssetLoader load) async {
  final pdf = PdfDocument();
  final fonts = <String, PdfFont>{};
  final images = <String, PdfImage>{};
  final report = FidelityReport();

  Future<PdfFont> font(String asset) async =>
      fonts[asset] ??= PdfTtfFont(pdf, await load(asset));

  // Eingefügte Bilder stammen aus dem Dokument, die Bilder des Beispieldokuments aus der App.
  // PdfImage.file übernimmt JPG unverändert und wandelt PNG (auch mit Transparenz) um.
  Future<PdfImage> image(String asset) async {
    final cached = images[asset];
    if (cached != null) return cached;
    final Uint8List bytes;
    final own = doc.assets[asset];
    if (own != null) {
      bytes = own.bytes;
    } else {
      final data = await load(asset);
      bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    }
    return images[asset] = PdfImage.file(pdf, bytes: bytes);
  }

  for (final page in doc.pages) {
    final pageW = doc.pageWidth * mmToPt, pageH = doc.pageHeight * mmToPt;
    final p = PdfPage(pdf, pageFormat: PdfPageFormat(pageW, pageH));
    final g = p.getGraphics();
    // PDF zählt y von unten; die App von oben.
    double fy(double yTop) => pageH - yTop;

    for (final el in page.elements) {
      switch (el) {
        case TextBlock t:
          await _drawText(g, t, fy, font, report);
        case ImageBlock i:
          _drawImage(g, i, await image(i.asset), fy);
        case RectShape r:
          _drawRect(g, r, fy);
        case LineShape l:
          _drawLine(g, l, fy);
        case TableBlock t:
          await _drawTable(g, t, fy, font, report);
      }
    }
  }
  return PdfExportResult(Uint8List.fromList(await pdf.save()), report);
}

Future<void> _drawText(
  PdfGraphics g,
  TextBlock t,
  double Function(double) fy,
  Future<PdfFont> Function(String) font,
  FidelityReport report,
) async {
  final tp = layoutText(t);
  final lines = tp.computeLineMetrics();
  report.lines += lines.length;
  final ox = t.box.x * mmToPt + textPadX;
  final oy = t.box.y * mmToPt + textPadY;
  // Grundlinie: Die von Flutter gemeldeten Werte (LineMetrics.baseline, computeDistanceToActualBaseline)
  // liegen je nach Textart bis 0,5 pt neben der gezeichneten Grundlinie. Deshalb wird die Grundlinie
  // der ersten Zeile gemessen (siehe measuredFirstBaseline); Folgezeilen im gemeldeten Zeilenabstand.
  final firstBaseline = await measuredFirstBaseline(t);
  final lineShift = lines.isEmpty ? 0.0 : firstBaseline - lines.first.baseline;
  double baselineFor(Rect box) {
    for (final l in lines) {
      if (l.baseline > box.top - .01 && l.baseline <= box.bottom + .01) return l.baseline + lineShift;
    }
    return (lines.isEmpty ? box.bottom : lines.last.baseline) + lineShift;
  }

  double? charLeft(int i) =>
      tp.getBoxesForSelection(TextSelection(baseOffset: i, extentOffset: i + 1)).firstOrNull?.left;

  // Grenzen der formatierten Textstellen: Ein Wort kann mehrere Stellen enthalten (z. B. halb fett).
  final segments = segmentsOf(t.text.length, t.runs);
  final cuts = <int>{for (final s in segments) s.start};

  for (final m in RegExp(r'\S+').allMatches(t.text)) {
    final boxes = tp.getBoxesForSelection(TextSelection(baseOffset: m.start, extentOffset: m.end));
    if (boxes.isEmpty) continue;
    if (boxes.length == 1) {
      // Wort in Stücke gleicher Formatierung teilen
      final pieceStarts = [m.start, for (var c = m.start + 1; c < m.end; c++) if (cuts.contains(c)) c];
      for (var pi = 0; pi < pieceStarts.length; pi++) {
        final a = pieceStarts[pi];
        final b = pi + 1 < pieceStarts.length ? pieceStarts[pi + 1] : m.end;
        final eff = t.effectiveAt(a);
        final f = await font(fontAssetPath(t.effectiveFont, bold: eff.bold, italic: eff.italic));
        g.setFillColor(PdfColor.fromInt(eff.color));
        final piece = t.text.substring(a, b);
        // Lage des ganzen Stücks (nicht des ersten Zeichens: ein Emoji oder ein Buchstabe mit
        // nachgestelltem Akzent besteht aus mehreren Einheiten und hat allein keinen Kasten).
        final pieceBoxes = tp.getBoxesForSelection(TextSelection(baseOffset: a, extentOffset: b));
        if (pieceBoxes.isEmpty) continue;
        final first = pieceBoxes.first.toRect();
        // Flutter setzt mit Unterschneidung (Kerning), das PDF-Paket nicht. Das Stück wird deshalb
        // weiter geteilt: Weicht ein Zeichen mehr als die Toleranz ab (typisch bei Paaren wie «Ve»),
        // beginnt ein neues Teilstück genau an der Bildschirmposition.
        const tolerance = .05; // Punkt, entspricht 0,018 mm
        final advances = [for (var i = 0; i < piece.length; i++) f.stringMetrics(piece[i]).advanceWidth * t.size];
        final lefts = [for (var i = 0; i < piece.length; i++) charLeft(a + i) ?? double.nan];
        final pieceRight = pieceBoxes.last.right;
        report.addRawWord(pieceRight - first.left - advances.fold<double>(0, (x, v) => x + v));
        final baseline = fy(oy + baselineFor(first));
        var segStart = 0;
        var segX = lefts[0].isNaN ? first.left : lefts[0];
        var pos = segX;
        for (var i = 0; i <= piece.length; i++) {
          final breakHere = i == piece.length || (!lefts[i].isNaN && (pos - lefts[i]).abs() > tolerance);
          if (breakHere && i > segStart) {
            g.drawString(f, t.size, piece.substring(segStart, i), ox + segX, baseline);
            if (i < piece.length) {
              segStart = i;
              segX = pos = lefts[i];
            }
          }
          if (i < piece.length) {
            if (!lefts[i].isNaN) report.addGlyph(piece, pos - lefts[i]);
            pos += advances[i];
          }
        }
      }
    } else {
      // Wort über mehrere Zeilen (sehr lange Wörter): Zeichen einzeln setzen.
      report.brokenWords++;
      for (var i = m.start; i < m.end; i++) {
        final cb = tp.getBoxesForSelection(TextSelection(baseOffset: i, extentOffset: i + 1));
        if (cb.isEmpty) continue;
        final b = cb.first.toRect();
        final eff = t.effectiveAt(i);
        g.setFillColor(PdfColor.fromInt(eff.color));
        g.drawString(await font(fontAssetPath(t.effectiveFont, bold: eff.bold, italic: eff.italic)), t.size, t.text[i], ox + b.left, fy(oy + baselineFor(b)));
      }
    }
  }

  // Unterstreichungen: wie bei Flutter über die ganze Textstelle, auch über Leerzeichen, pro Zeile.
  // Lage und Dicke nach den Schriftmetriken von Roboto (post-Tabelle); nicht gemessen.
  for (final seg in segments.where((s) => s.style.underline == true)) {
    final eff = t.effectiveAt(seg.start);
    g.setStrokeColor(PdfColor.fromInt(eff.color));
    g.setLineWidth(t.size * .049);
    for (final box in tp.getBoxesForSelection(TextSelection(baseOffset: seg.start, extentOffset: seg.end))) {
      final r = box.toRect();
      final y = fy(oy + baselineFor(r) + t.size * .073);
      g.moveTo(ox + r.left, y);
      g.lineTo(ox + r.right, y);
      g.strokePath();
    }
  }
}

final _baselineCache = <String, double>{};

/// Misst, wo Flutter die Grundlinie der ersten Zeile tatsächlich zeichnet: Ein «H» (flache Unterkante)
/// wird mit demselben Stil 16-fach vergrössert gezeichnet; die unterste deckende Bildzeile ist die
/// Grundlinie (Genauigkeit rund 1/32 pt). Ergebnis pro Stil zwischengespeichert.
Future<double> measuredFirstBaseline(TextBlock t) async {
  final key = '${t.effectiveFont.name}|${t.kind.name}|${t.size}|${t.bold}|${t.italic}';
  final cached = _baselineCache[key];
  if (cached != null) return cached;
  const scale = 16.0;
  final probe = TextBlock(
    id: '_probe', box: const Box(0, 0, 1000, 10), kind: t.kind, size: t.size, color: 0xFF000000,
    bold: t.bold, italic: t.italic, text: 'H', font: t.font,
  );
  final tp = layoutText(probe);
  final box = tp.getBoxesForSelection(const TextSelection(baseOffset: 0, extentOffset: 1)).first;
  final w = (box.right * scale).ceil() + 2, h = (tp.height * scale).ceil() + 2;
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec)..scale(scale);
  tp.paint(canvas, Offset.zero);
  final image = await rec.endRecording().toImage(w, h);
  final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  image.dispose();
  var bottom = -1;
  for (var y = h - 1; y >= 0 && bottom < 0; y--) {
    for (var x = 0; x < w; x++) {
      if (data.getUint8((y * w + x) * 4 + 3) > 127) {
        bottom = y;
        break;
      }
    }
  }
  final baseline = bottom < 0 ? tp.computeDistanceToActualBaseline(TextBaseline.alphabetic) : (bottom + 1) / scale;
  return _baselineCache[key] = baseline;
}

void _drawImage(PdfGraphics g, ImageBlock i, PdfImage img, double Function(double) fy) {
  final x = i.box.x * mmToPt, y = i.box.y * mmToPt, w = i.box.w * mmToPt, h = i.box.h * mmToPt;
  final r = imagePlacement(i);
  g.saveContext();
  g.drawRect(x, fy(y + h), w, h);
  g.clipPath();
  if (i.quarterTurns == 0) {
    g.drawImage(img, x + r.left, fy(y + r.top + r.height), r.width, r.height);
  } else {
    // Um die Mitte der Zielfläche drehen. PDF zählt y nach oben, daher negativer Winkel für «im Uhrzeigersinn».
    final cx = x + r.left + r.width / 2, cy = fy(y + r.top + r.height / 2);
    final odd = i.quarterTurns.isOdd;
    final iw = odd ? r.height : r.width, ih = odd ? r.width : r.height;
    g.setTransform(Matrix4.identity()
      ..translateByDouble(cx, cy, 0, 1)
      ..rotateZ(-i.quarterTurns * math.pi / 2));
    g.drawImage(img, -iw / 2, -ih / 2, iw, ih);
  }
  g.restoreContext();
}

void _drawRect(PdfGraphics g, RectShape r, double Function(double) fy) {
  final x = r.box.x * mmToPt, y = r.box.y * mmToPt, w = r.box.w * mmToPt, h = r.box.h * mmToPt;
  // wie am Bildschirm: Rundung höchstens halb so gross wie die kürzere Seite (sonst Zacken bei dünnen Balken)
  final rad = r.round ? math.min(2.5 * mmToPt, math.min(w, h) / 2) : 0.0;
  void path() => rad > 0 ? g.drawRRect(x, fy(y + h), w, h, rad, rad) : g.drawRect(x, fy(y + h), w, h);
  if ((r.fill >> 24) & 0xFF != 0) {
    g.setFillColor(PdfColor.fromInt(r.fill));
    path();
    g.fillPath();
  }
  if (r.strokeWidth > 0) {
    final sw = r.strokeWidth * mmToPt;
    g.setStrokeColor(PdfColor.fromInt(r.stroke));
    g.setLineWidth(sw);
    // Rahmen liegt wie am Bildschirm innerhalb der Fläche.
    final i = sw / 2;
    if (rad > 0) {
      final ri = math.max(0.0, math.min(rad - i, math.min(w - sw, h - sw) / 2));
      g.drawRRect(x + i, fy(y + h - i), w - sw, h - sw, ri, ri);
    } else {
      g.drawRect(x + i, fy(y + h - i), w - sw, h - sw);
    }
    g.strokePath();
  }
}

/// Tabelle: Hintergründe, Zelltexte (wie Textblöcke, Wort für Wort an der Bildschirmposition), Linien.
Future<void> _drawTable(
  PdfGraphics g,
  TableBlock t,
  double Function(double) fy,
  Future<PdfFont> Function(String) font,
  FidelityReport report,
) async {
  final tops = tableRowTops(t);
  final edges = tableColumnEdges(t);
  final x0 = t.x * mmToPt, y0 = t.y * mmToPt;
  final w = edges.last * mmToPt;
  for (var r = 0; r < t.rowCount; r++) {
    final fill = t.rowFill(r);
    if (fill == null) continue;
    final top = y0 + tops[r] * mmToPt, h = (tops[r + 1] - tops[r]) * mmToPt;
    g.setFillColor(PdfColor.fromInt(fill));
    g.drawRect(x0, fy(top + h), w, h);
    g.fillPath();
  }
  for (var r = 0; r < t.rowCount; r++) {
    for (var c = 0; c < t.columnCount; c++) {
      final cell = tableCellBlock(t, r, c, top: t.y + tops[r]);
      if (cell.text.isNotEmpty) await _drawText(g, cell, fy, font, report);
    }
  }
  final segs = tableSegments(t, tops);
  if (segs.isEmpty) return;
  g.setStrokeColor(PdfColor.fromInt(t.lineColor));
  g.setLineWidth(t.lineWidth * mmToPt);
  g.setLineCap(PdfLineCap.square);
  for (final s in segs) {
    g.moveTo(x0 + s.x1 * mmToPt, fy(y0 + s.y1 * mmToPt));
    g.lineTo(x0 + s.x2 * mmToPt, fy(y0 + s.y2 * mmToPt));
  }
  g.strokePath();
}

void _drawLine(PdfGraphics g, LineShape l, double Function(double) fy) {
  g.setStrokeColor(PdfColor.fromInt(l.color));
  g.setLineWidth(l.width * mmToPt);
  g.setLineCap(PdfLineCap.round);
  g.moveTo(l.a.x * mmToPt, fy(l.a.y * mmToPt));
  g.lineTo(l.b.x * mmToPt, fy(l.b.y * mmToPt));
  g.strokePath();
}
