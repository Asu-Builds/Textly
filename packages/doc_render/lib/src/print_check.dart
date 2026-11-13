import 'dart:math' as math;

import 'package:doc_model/doc_model.dart';

import 'text_layout.dart';

/// Abstand zum Papierrand, den viele Drucker nicht bedrucken (mm).
const double unprintableMarginMm = 5;

/// Unter dieser Auflösung wirken Bilder im Druck unscharf.
const double minPrintDpi = 150;

enum PrintIssueKind { cutOff, nearEdge, lowResolution, missingCharacters }

/// Ein Hinweis vor dem Drucken (Spezifikation 9.2).
class PrintIssue {
  const PrintIssue(this.pageIndex, this.elementId, this.kind, this.message);
  final int pageIndex;
  final String elementId;
  final PrintIssueKind kind;
  final String message;

  /// Schwerwiegend: Inhalt geht verloren (abgeschnitten).
  bool get isSevere => kind == PrintIssueKind.cutOff;
}

/// Anfang eines Textes, ohne ein Emoji (Ersatzpaar) zu halbieren.
String _cut(String s, int n) {
  var end = n;
  final last = s.codeUnitAt(end - 1);
  if (last >= 0xD800 && last <= 0xDBFF) end--;
  return s.substring(0, end);
}

String _what(DocElement e) => switch (e) {
      TextBlock t => '«${t.text.length > 28 ? '${_cut(t.text, 28).trimRight()} …' : t.text}»',
      ImageBlock _ => 'Ein Bild',
      RectShape _ => 'Ein Rechteck',
      LineShape _ => 'Eine Linie',
      TableBlock _ => 'Eine Tabelle',
    };

/// Wirksame Auflösung eines Bildes im Druck (Bildpunkte pro Zoll über die Rahmenbreite).
double imagePrintDpi(ImageBlock i) {
  final visiblePixels = i.fit == ImageFit.cover ? i.naturalWidth * cropWindow(i).w : i.naturalWidth.toDouble();
  final printedMm = i.fit == ImageFit.cover ? i.box.w : math.min(i.box.w, i.box.h * i.naturalAspect);
  return visiblePixels / (printedMm / 25.4);
}

/// Fläche, die tatsächlich gedruckt wird. Bei linksbündigem Text endet sie mit der längsten Zeile –
/// ein breiter Rahmen um einen kurzen Text ragt sonst «über den Rand», ohne dass etwas fehlt.
Box _inkBox(DocElement e) {
  final b = renderedBox(e);
  if (e is! TextBlock || e.align != TextAlignment.left) return b;
  final lines = layoutText(e).computeLineMetrics();
  if (lines.isEmpty) return b;
  final widest = lines.map((l) => l.left + l.width).reduce(math.max);
  return b.copyWith(w: math.min(b.w, (widest + 2 * textPadX) / mmToPt));
}

/// Prüft das Dokument vor dem Drucken bzw. vor dem PDF.
///
/// - abgeschnitten: Element ragt über den Papierrand,
/// - am Rand: näher als [unprintableMarginMm] am Papierrand (Rechtecke ausgenommen: Hintergründe
///   und Balken dürfen bewusst bis an den Rand reichen),
/// - unscharf: Bild mit weniger als [minPrintDpi].
List<PrintIssue> printIssues(TextlyDocument doc) {
  final out = <PrintIssue>[];
  for (var p = 0; p < doc.pages.length; p++) {
    for (final e in doc.pages[p].elements) {
      final b = _inkBox(e);
      const t = .1;
      final w = doc.pageWidth, h = doc.pageHeight;
      final cut = b.x < -t || b.y < -t || b.right > w + t || b.bottom > h + t;
      final outside = b.right <= 0 || b.bottom <= 0 || b.x >= w || b.y >= h;
      if (outside) {
        out.add(PrintIssue(p, e.id, PrintIssueKind.cutOff, '${_what(e)} liegt ganz ausserhalb der Seite und wird nicht gedruckt.'));
      } else if (cut) {
        out.add(PrintIssue(p, e.id, PrintIssueKind.cutOff, '${_what(e)} ragt über den Papierrand und wird abgeschnitten.'));
      } else if (e is! RectShape &&
          (b.x < unprintableMarginMm ||
              b.y < unprintableMarginMm ||
              b.right > w - unprintableMarginMm ||
              b.bottom > h - unprintableMarginMm)) {
        out.add(PrintIssue(p, e.id, PrintIssueKind.nearEdge,
            '${_what(e)} liegt sehr nah am Papierrand. Viele Drucker drucken die äussersten 5 mm nicht.'));
      }
      // Emojis und Schriftzeichen, die Textlys Schriften nicht kennen: am Bildschirm sichtbar, im PDF nicht
      final text = switch (e) {
        TextBlock t => t.text,
        TableBlock t => t.cells.expand((r) => r).join(' '),
        _ => '',
      };
      if (hasUnprintableCharacters(text)) {
        out.add(PrintIssue(p, e.id, PrintIssueKind.missingCharacters,
            '${_what(e)} enthält Emojis oder Zeichen, die im PDF und beim Drucken fehlen. Bitte durch Wörter ersetzen.'));
      }
      if (e is ImageBlock) {
        final dpi = imagePrintDpi(e);
        if (dpi < minPrintDpi) {
          out.add(PrintIssue(p, e.id, PrintIssueKind.lowResolution,
              'Ein Bild wird unscharf gedruckt (${dpi.round()} dpi). Mach es kleiner oder nimm ein grösseres Foto.'));
        }
      }
    }
  }
  return out;
}

/// Enthält [s] Zeichen, die Textlys Schriften nicht haben (Emojis, Symbole, chinesische, japanische,
/// koreanische, arabische Schrift …)? Bildschirm zeigt sie mit Ersatzschriften, das PDF nicht.
bool hasUnprintableCharacters(String s) {
  for (final r in s.runes) {
    if (r > 0xFFFF) return true; // Emojis und seltene Schriften
    if (r >= 0x2600 && r <= 0x27BF) return true; // Symbole, Dingbats (☀ ✂ ✔ …)
    if (r >= 0x2B00 && r <= 0x2BFF) return true; // Pfeile und Symbole
    if (r >= 0x0590 && r <= 0x08FF) return true; // Hebräisch, Arabisch …
    if (r >= 0x0900 && r <= 0x0DFF) return true; // indische Schriften
    if (r >= 0x2E80 && r <= 0xD7FF) return true; // CJK, Hangul
    if (r >= 0xE000 && r <= 0xF8FF) return true; // private Zeichen (z. B. Wingdings aus Word)
    if (r == 0xFE0F || r == 0x200D) return true; // Emoji-Steuerzeichen
  }
  return false;
}
