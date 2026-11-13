import 'package:doc_model/doc_model.dart';
import 'package:flutter/painting.dart';

import 'table_layout.dart';

/// Gemeinsamer Textsatz für Bildschirm, Bearbeitung und PDF.
///
/// Alle Längen in Punkt. Die Seite wird in Punkt aufgebaut und für den Bildschirm nur skaliert,
/// damit der Zeilenumbruch nicht vom Zoom abhängt. Die Vorgaben stammen aus dem Machbarkeitstest
/// (spike/ERGEBNISSE.md) und dürfen nicht ohne erneute Messung geändert werden.

const double textPadX = 1.0 * mmToPt;
const double textPadY = 0.8 * mmToPt;

/// Cursorbreite im Eingabefeld; Flutter reserviert zusätzlich 1 pt (Abstand) am rechten Rand.
const double cursorWidth = 1.5;
const double caretMargin = 1.0 + cursorWidth;

/// Vorgabeschrift und Zeilenhöhe je Textart (Grösse, Farbe und Stil kommen aus dem Modell;
/// eine gewählte Schriftart ersetzt die Familie, die Zeilenhöhe bleibt).
({String family, double lineHeight}) kindTypography(TextKind k) => switch (k) {
      TextKind.title => (family: 'TextlyCondensed', lineHeight: 1.15),
      TextKind.subtitle => (family: 'TextlyCondensed', lineHeight: 1.3),
      TextKind.heading => (family: 'TextlyCondensed', lineHeight: 1.25),
      TextKind.body => (family: 'TextlySans', lineHeight: 1.45),
      TextKind.caption => (family: 'TextlySans', lineHeight: 1.35),
    };

TextStyle textStyleFor(TextBlock t) {
  final k = kindTypography(t.kind);
  return TextStyle(
    fontFamily: fontInfos[t.effectiveFont]!.family,
    fontSize: t.size,
    height: k.lineHeight,
    // Ausdrücklich setzen: Das Material-Eingabefeld mischt sonst die Vorgabe des Designs hinein.
    leadingDistribution: TextLeadingDistribution.even,
    color: Color(t.color),
    fontWeight: t.bold ? FontWeight.w700 : FontWeight.w400,
    fontStyle: t.italic ? FontStyle.italic : FontStyle.normal,
    letterSpacing: 0,
    wordSpacing: 0,
  );
}

/// Stil einer formatierten Textstelle (Abweichung vom Blockstil).
TextStyle inlineTextStyle(InlineStyle s) => TextStyle(
      fontWeight: s.bold == null ? null : (s.bold! ? FontWeight.w700 : FontWeight.w400),
      fontStyle: s.italic == null ? null : (s.italic! ? FontStyle.italic : FontStyle.normal),
      color: s.color == null ? null : Color(s.color!),
      decoration: s.underline == true ? TextDecoration.underline : null,
    );

/// Markierung für Rechtschreibfehler (rote Wellenlinie).
const TextStyle misspelledStyle = TextStyle(
  decoration: TextDecoration.underline,
  decorationColor: Color(0xFFD32F2F),
  decorationStyle: TextDecorationStyle.wavy,
);

/// Der Text eines Blocks als formatierte Textstellen. Gleich für Anzeige, Eingabefeld und PDF.
/// [misspelled]: Bereiche mit roter Wellenlinie (nur im Eingabefeld). [text] und [runs] ersetzen
/// die Werte des Blocks (Eingabefeld während des Schreibens).
TextSpan textSpanFor(TextBlock t, {String? text, List<StyleRun>? runs, List<TextRange> misspelled = const []}) {
  final value = text ?? t.text;
  final segs = segmentsOf(value.length, runs ?? t.runs);
  if (misspelled.isEmpty && segs.length <= 1 && (segs.isEmpty || segs.first.style.isEmpty)) {
    return TextSpan(text: value, style: textStyleFor(t));
  }
  // Grenzen aus Formatierung und Rechtschreibfehlern zusammenführen
  final cuts = <int>{0, value.length};
  for (final s in segs) {
    cuts..add(s.start)..add(s.end);
  }
  for (final m in misspelled) {
    if (m.start >= 0 && m.end <= value.length) cuts..add(m.start)..add(m.end);
  }
  final sorted = cuts.toList()..sort();
  final children = <TextSpan>[];
  for (var i = 0; i < sorted.length - 1; i++) {
    final a = sorted[i], b = sorted[i + 1];
    if (a >= b) continue;
    var style = inlineTextStyle(styleAt(runs ?? t.runs, a));
    if (misspelled.any((m) => a >= m.start && a < m.end)) {
      // Unterstreichung des Textes und Wellenlinie lassen sich nicht kombinieren; die Wellenlinie gewinnt.
      style = style.merge(misspelledStyle);
    }
    children.add(TextSpan(text: value.substring(a, b), style: style));
  }
  return TextSpan(style: textStyleFor(t), children: children);
}

/// Feste Zeilenhöhe (Strut) für Anzeige, Eingabefeld und PDF. Beide Widgets erhalten genau
/// dieselbe Angabe, damit der Text beim Wechsel in die Bearbeitung nicht springt.
StrutStyle strutFor(TextBlock t) => StrutStyle.fromTextStyle(textStyleFor(t), forceStrutHeight: true);

TextAlign textAlignFor(TextBlock t) => switch (t.align) {
      TextAlignment.left => TextAlign.left,
      TextAlignment.center => TextAlign.center,
      TextAlignment.right => TextAlign.right,
    };

/// Breite, in welcher der Text umbrochen wird (pt).
double textLayoutWidth(TextBlock t) => t.box.w * mmToPt - 2 * textPadX;

/// Setzt einen Textblock. Ergebnis ist massgeblich für Bildschirm und PDF.
TextPainter layoutText(TextBlock t) {
  final tp = TextPainter(
    text: textSpanFor(t),
    strutStyle: strutFor(t),
    textAlign: textAlignFor(t),
    textDirection: TextDirection.ltr,
    textScaler: TextScaler.noScaling,
    textWidthBasis: TextWidthBasis.parent,
  );
  final w = textLayoutWidth(t).clamp(1.0, double.infinity);
  tp.layout(minWidth: w, maxWidth: w);
  return tp;
}

/// Höhe des Blocks in Punkt: Sie folgt immer dem Text (die gespeicherte Höhe ist nur ein Richtwert).
double textBlockHeightPt(TextBlock t, [TextPainter? tp]) => (tp ?? layoutText(t)).height + 2 * textPadY;

/// Tatsächliche Umrisse eines Elements in mm (Textblöcke werden gemessen).
Box renderedBox(DocElement e) => switch (e) {
      TextBlock t => t.box.copyWith(h: textBlockHeightPt(t) / mmToPt),
      TableBlock t => t.box.copyWith(h: tableHeightMm(t)),
      _ => e.box,
    };
