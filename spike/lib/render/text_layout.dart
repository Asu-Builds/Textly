import 'package:flutter/painting.dart';

import '../model/document.dart';

/// Gemeinsamer Textsatz für Bildschirm, Bearbeitung und PDF.
///
/// Alle Längen in Punkt. Die Seite wird in Punkt aufgebaut und für den Bildschirm
/// nur skaliert. So hängt der Zeilenumbruch nicht vom Zoom ab.

const double kTextPadX = 1.0 * kMmToPt;
const double kTextPadY = 0.8 * kMmToPt;

/// Breite, die das Eingabefeld zusätzlich für den Cursor reserviert (Flutter: Abstand 1 + Cursorbreite).
const double kCursorWidth = 1.5;
const double kCaretMargin = 1.0 + kCursorWidth;


class KindStyle {
  const KindStyle(this.family, this.size, this.bold, this.italic, this.color, this.lineHeight);
  final String family;
  final double size;
  final bool bold, italic;
  final int color;
  final double lineHeight;
}

KindStyle kindStyle(TextKind k) => switch (k) {
      TextKind.title => const KindStyle('TextlyCondensed', 26, true, false, 0xFF1D2733, 1.15),
      TextKind.subtitle => const KindStyle('TextlyCondensed', 13, false, false, 0xFF5B6773, 1.3),
      TextKind.heading => const KindStyle('TextlyCondensed', 13, true, false, 0xFF1D2733, 1.25),
      TextKind.body => const KindStyle('TextlySans', 10.5, false, false, 0xFF1D2733, 1.45),
      TextKind.caption => const KindStyle('TextlySans', 8.5, false, true, 0xFF5B6773, 1.35),
    };

TextStyle textStyleFor(TextElement t) {
  final k = kindStyle(t.kind);
  return TextStyle(
    fontFamily: k.family,
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

TextAlign textAlignFor(TextElement t) => switch (t.align) {
      TextAlignment.left => TextAlign.left,
      TextAlignment.center => TextAlign.center,
      TextAlignment.right => TextAlign.right,
    };

/// Breite, in welcher der Text umbrochen wird.
double textLayoutWidth(TextElement t) => t.w * kMmToPt - 2 * kTextPadX;

/// Feste Zeilenhöhe (Strut) für Anzeige, Eingabefeld und PDF. Beide Widgets erhalten genau
/// dieselbe Angabe, damit der Text beim Wechsel in die Bearbeitung nicht springt.
StrutStyle strutFor(TextElement t) => StrutStyle.fromTextStyle(textStyleFor(t), forceStrutHeight: true);

/// Setzt einen Textblock. Ergebnis ist massgeblich für Bildschirm und PDF.
TextPainter layoutText(TextElement t) {
  final tp = TextPainter(
    text: TextSpan(text: t.text, style: textStyleFor(t)),
    strutStyle: strutFor(t),
    textAlign: textAlignFor(t),
    textDirection: TextDirection.ltr,
    textScaler: TextScaler.noScaling,
    textWidthBasis: TextWidthBasis.parent,
  );
  tp.layout(minWidth: textLayoutWidth(t), maxWidth: textLayoutWidth(t));
  return tp;
}

/// Höhe des Blocks in Punkt (automatisch oder fest).
double textBlockHeight(TextElement t, TextPainter tp) =>
    t.autoHeight ? tp.height + 2 * kTextPadY : t.h * kMmToPt;
