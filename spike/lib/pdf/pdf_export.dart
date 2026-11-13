import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:pdf/pdf.dart';

import '../model/document.dart';
import '../render/text_layout.dart';

/// Lädt eine Datei aus den Assets (in der App über rootBundle, im Test von der Festplatte).
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
    final mm = deviationPt.abs() / kMmToPt;
    glyphs++;
    sumDeviationMm += mm;
    if (mm > maxDeviationMm) {
      maxDeviationMm = mm;
      worstWord = word;
    }
  }

  void addRawWord(double deviationPt) {
    words++;
    final mm = deviationPt.abs() / kMmToPt;
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

String fontAsset(String family, bool bold, bool italic) {
  final prefix = family == 'TextlyCondensed' ? 'Cond' : 'Sans';
  final style = bold && italic ? 'BoldItalic' : bold ? 'Bold' : italic ? 'Italic' : 'Regular';
  return 'assets/fonts/$prefix-$style.ttf';
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

  Future<PdfImage> image(String asset) async {
    final cached = images[asset];
    if (cached != null) return cached;
    final bytes = (await load(asset)).buffer.asUint8List();
    return images[asset] = PdfImage.jpeg(pdf, image: bytes);
  }

  for (final page in doc.pages) {
    final p = PdfPage(pdf, pageFormat: const PdfPageFormat(kPageWidthPt, kPageHeightPt));
    final g = p.getGraphics();
    // PDF zählt y von unten; die App von oben.
    double fy(double yTop) => kPageHeightPt - yTop;

    for (final el in page.elements) {
      switch (el) {
        case TextElement t:
          await _drawText(g, t, fy, font, report);
        case ImageElement i:
          _drawImage(g, i, await image(i.asset), fy);
        case RectElement r:
          _drawRect(g, r, fy);
        case LineElement l:
          _drawLine(g, l, fy);
      }
    }
  }
  return PdfExportResult(Uint8List.fromList(await pdf.save()), report);
}

Future<void> _drawText(
  PdfGraphics g,
  TextElement t,
  double Function(double) fy,
  Future<PdfFont> Function(String) font,
  FidelityReport report,
) async {
  final tp = layoutText(t);
  final lines = tp.computeLineMetrics();
  report.lines += lines.length;
  final k = kindStyle(t.kind);
  final f = await font(fontAsset(k.family, t.bold, t.italic));
  final ox = t.x * kMmToPt + kTextPadX;
  final oy = t.y * kMmToPt + kTextPadY;
  final clipH = t.autoHeight ? null : t.h * kMmToPt;

  g.setFillColor(PdfColor.fromInt(t.color));
  if (clipH != null) {
    g.saveContext();
    g.drawRect(t.x * kMmToPt, fy(t.y * kMmToPt + clipH), t.w * kMmToPt, clipH);
    g.clipPath();
  }

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

  for (final m in RegExp(r'\S+').allMatches(t.text)) {
    final word = m.group(0)!;
    final boxes = tp.getBoxesForSelection(TextSelection(baseOffset: m.start, extentOffset: m.end));
    if (boxes.isEmpty) continue;
    if (boxes.length == 1) {
      final b = boxes.first.toRect();
      // Flutter setzt mit Unterschneidung (Kerning), das PDF-Paket nicht. Das Wort wird deshalb
      // in Stücke geteilt: Weicht ein Zeichen mehr als die Toleranz ab (typisch bei Paaren wie «Ve»),
      // beginnt ein neues Stück genau an der Bildschirmposition.
      const tolerance = .05; // Punkt, entspricht 0,018 mm
      final advances = [for (var i = 0; i < word.length; i++) f.stringMetrics(word[i]).advanceWidth * t.size];
      report.addRawWord(b.width - advances.fold<double>(0, (a, v) => a + v));
      final lefts = [
        for (var i = 0; i < word.length; i++)
          tp.getBoxesForSelection(TextSelection(baseOffset: m.start + i, extentOffset: m.start + i + 1)).firstOrNull?.left ??
              double.nan,
      ];
      final baseline = fy(oy + baselineFor(b));
      var segStart = 0;
      var segX = lefts[0].isNaN ? b.left : lefts[0];
      var pos = segX;
      for (var i = 0; i <= word.length; i++) {
        final breakHere = i == word.length || (!lefts[i].isNaN && (pos - lefts[i]).abs() > tolerance);
        if (breakHere && i > segStart) {
          g.drawString(f, t.size, word.substring(segStart, i), ox + segX, baseline);
          if (i < word.length) {
            segStart = i;
            segX = pos = lefts[i];
          }
        }
        if (i < word.length) {
          if (!lefts[i].isNaN) report.addGlyph(word, pos - lefts[i]);
          pos += advances[i];
        }
      }
    } else {
      // Wort über mehrere Zeilen (sehr lange Wörter): Zeichen einzeln setzen.
      report.brokenWords++;
      for (var i = m.start; i < m.end; i++) {
        final cb = tp.getBoxesForSelection(TextSelection(baseOffset: i, extentOffset: i + 1));
        if (cb.isEmpty) continue;
        final b = cb.first.toRect();
        g.drawString(f, t.size, t.text[i], ox + b.left, fy(oy + baselineFor(b)));
      }
    }
  }
  if (clipH != null) g.restoreContext();
}

final _baselineCache = <String, double>{};

/// Misst, wo Flutter die Grundlinie der ersten Zeile tatsächlich zeichnet: Ein «H» (flache Unterkante)
/// wird mit demselben Stil 16-fach vergrössert gezeichnet; die unterste deckende Bildzeile ist die
/// Grundlinie (Genauigkeit rund 1/32 pt). Ergebnis pro Stil zwischengespeichert.
Future<double> measuredFirstBaseline(TextElement t) async {
  final key = '${t.kind.name}|${t.size}|${t.bold}|${t.italic}';
  final cached = _baselineCache[key];
  if (cached != null) return cached;
  const scale = 16.0;
  final probe = TextElement(
    id: '_probe', x: 0, y: 0, w: 1000, kind: t.kind, size: t.size, color: 0xFF000000,
    bold: t.bold, italic: t.italic, text: 'H',
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

/// Lage des sichtbaren Bildes im Rahmen (in Punkt, relativ zum Rahmen).
Rect imagePlacement(ImageElement i) {
  final w = i.w * kMmToPt, h = i.h * kMmToPt;
  if (i.fit == ImageFit.contain) {
    final s = math.min(w / i.nw, h / i.nh);
    final iw = i.nw * s, ih = i.nh * s;
    return Rect.fromLTWH((w - iw) / 2, (h - ih) / 2, iw, ih);
  }
  final s = math.max(w / i.nw, h / i.nh) * i.zoom;
  final iw = i.nw * s, ih = i.nh * s;
  return Rect.fromLTWH((w - iw) * i.px, (h - ih) * i.py, iw, ih);
}

void _drawImage(PdfGraphics g, ImageElement i, PdfImage img, double Function(double) fy) {
  final x = i.x * kMmToPt, y = i.y * kMmToPt, w = i.w * kMmToPt, h = i.h * kMmToPt;
  final r = imagePlacement(i);
  g.saveContext();
  g.drawRect(x, fy(y + h), w, h);
  g.clipPath();
  g.drawImage(img, x + r.left, fy(y + r.top + r.height), r.width, r.height);
  g.restoreContext();
}

void _drawRect(PdfGraphics g, RectElement r, double Function(double) fy) {
  final x = r.x * kMmToPt, y = r.y * kMmToPt, w = r.w * kMmToPt, h = r.h * kMmToPt;
  final rad = r.round ? 2.5 * kMmToPt : 0.0;
  void path() => rad > 0 ? g.drawRRect(x, fy(y + h), w, h, rad, rad) : g.drawRect(x, fy(y + h), w, h);
  if ((r.fill >> 24) & 0xFF != 0) {
    g.setFillColor(PdfColor.fromInt(r.fill));
    path();
    g.fillPath();
  }
  if (r.strokeWidth > 0) {
    final sw = r.strokeWidth * kMmToPt;
    g.setStrokeColor(PdfColor.fromInt(r.stroke));
    g.setLineWidth(sw);
    // Rahmen liegt wie am Bildschirm innerhalb der Fläche.
    final i = sw / 2;
    if (rad > 0) {
      g.drawRRect(x + i, fy(y + h - i), w - sw, h - sw, rad - i, rad - i);
    } else {
      g.drawRect(x + i, fy(y + h - i), w - sw, h - sw);
    }
    g.strokePath();
  }
}

void _drawLine(PdfGraphics g, LineElement l, double Function(double) fy) {
  g.setStrokeColor(PdfColor.fromInt(l.color));
  g.setLineWidth(l.width * kMmToPt);
  g.setLineCap(PdfLineCap.round);
  g.moveTo(l.x1 * kMmToPt, fy(l.y1 * kMmToPt));
  g.lineTo(l.x2 * kMmToPt, fy(l.y2 * kMmToPt));
  g.strokePath();
}
