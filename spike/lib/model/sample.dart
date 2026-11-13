import 'document.dart';
import '../render/text_layout.dart';

/// Beispieldokumente für den Vergleich Bildschirm gegen PDF.
/// Seite 1 entspricht dem Beispiel aus Prototyp v3, Seite 2 ist eine textlastige Anleitung.
TextlyDocument sampleDocument() {
  var n = 0;
  String id() => 'e${n++}';
  TextElement t(TextKind kind, double x, double y, double w, String text, {bool? bold}) {
    final s = kindStyle(kind);
    return TextElement(
      id: id(), x: x, y: y, w: w, kind: kind, size: s.size, color: s.color,
      bold: bold ?? s.bold, italic: s.italic, text: text,
    );
  }

  return TextlyDocument([
    DocPage('p1', [
      t(TextKind.title, 18, 20, 174, 'Vereinsausflug ins Aletschgebiet'),
      t(TextKind.subtitle, 18, 35, 174, 'Wanderverein Oberwallis · Samstag, 12. September 2026'),
      LineElement(id: id(), x1: 20, y1: 45, x2: 190, y2: 45),
      ImageElement(id: id(), x: 20, y: 52, w: 170, h: 90, asset: 'assets/images/glacier.jpg', nw: 1500, nh: 1000),
      t(TextKind.caption, 19, 143, 172, 'Blick vom Eggishorn auf den Grossen Aletschgletscher'),
      t(TextKind.heading, 19, 156, 82, 'Von der Riederalp zum Eggishorn'),
      t(TextKind.body, 19, 166, 82,
          'Um 7.40 Uhr startete die Gruppe mit 23 Mitgliedern in Brig. Mit der Luftseilbahn ging es auf die '
          'Riederalp und von dort auf dem Höhenweg durch den Aletschwald, vorbei an jahrhundertealten Arven und Lärchen.'),
      t(TextKind.body, 19, 212, 82,
          'Nach der Mittagsrast am Märjelensee erreichten wir am frühen Nachmittag das Eggishorn. Die Aussicht auf '
          'den längsten Gletscher der Alpen entschädigte für jeden Höhenmeter. Zurück ging es mit der Bahn nach Fiesch.'),
      ImageElement(id: id(), x: 108, y: 158, w: 82, h: 102.5, asset: 'assets/images/lake.jpg', nw: 1000, nh: 1250),
      t(TextKind.caption, 107, 262, 84, 'Abendstimmung am Märjelensee'),
    ]),
    DocPage('p2', [
      t(TextKind.title, 18, 20, 174, 'Anleitung: Wanderbericht erstellen'),
      t(TextKind.body, 19, 36, 172,
          'Diese Seite prüft längere Texte. Sie enthält Absätze unterschiedlicher Breite, Umlaute, Zahlen, '
          'Satzzeichen und Zeilenumbrüche innerhalb eines Blocks.'),
      RectElement(id: id(), x: 20, y: 52, w: 170, h: 30, fill: 0xFFE8EEF7),
      t(TextKind.body, 25, 57, 160,
          'Wichtig: Fotos vor dem Einfügen nicht verkleinern. Die App wählt die passende Auflösung selbst und '
          'behält genug Reserve für den Druck mit 300 dpi.', bold: true),
      t(TextKind.heading, 19, 90, 172, '1. Fotos auswählen und einfügen'),
      t(TextKind.body, 19, 98, 82,
          'Ziehe die Fotos aus dem Explorer direkt auf die Seite oder wähle «Bild» in der Werkzeugleiste. '
          'Grosse Dateien (über 10 MB) werden automatisch verkleinert. Danach kannst du jedes Bild verschieben, '
          'über die runden Ecken vergrössern und über die Seitengriffe in die gewünschte Form bringen.\n'
          'Tipp: Der Ausschnitt lässt sich rechts in der Eigenschaftenleiste wählen.'),
      t(TextKind.body, 108, 98, 82,
          'Für Panoramen eignet sich ein schmales Band über die ganze Seitenbreite. Hochformatige Bilder wirken '
          'neben einer Textspalte am besten. Achte auf genügend Abstand zum Seitenrand: Viele Drucker lassen '
          'rund 4–5 mm unbedruckt.'),
      t(TextKind.heading, 19, 160, 172, '2. Texte schreiben'),
      t(TextKind.body, 19, 168, 172,
          'Klicke einmal auf einen Textblock, um ihn auszuwählen, und ein zweites Mal, um zu schreiben. '
          'Die Eingabetaste beginnt eine neue Zeile im selben Block; einen neuen Block legst du über «Text» an. '
          'Überschriften, Bildunterschriften und Fliesstext unterscheiden sich nur durch die Textart – Schrift, '
          'Grösse und Farbe passen sich automatisch an. So bleibt das Dokument einheitlich, auch wenn mehrere '
          'Personen daran arbeiten. Kosten für Nichtmitglieder: CHF 15.–; Anmeldeschluss 01.10.2026, 18:00 Uhr.'),
      t(TextKind.caption, 19, 215, 172, 'Letzte Änderung: 10. November 2026 · Version 0.1 · Seite 2 von 2'),
    ]),
  ]);
}
