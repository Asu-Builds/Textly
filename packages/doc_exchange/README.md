# doc_exchange – Austausch mit PowerPoint

Reines Dart. `exportPptx` schreibt ein Textly-Dokument als `.pptx`, `importPptx` liest eine `.pptx`
als Textly-Dokument (mit Hinweisen, was nicht übernommen werden konnte).

## Abbildung Textly ↔ PowerPoint

| Textly | PowerPoint | Hin und zurück |
|---|---|---|
| Seite (A4 hochformat) | Folie, Foliengrösse 210 × 297 mm | verlustfrei |
| Textblock | Textfeld; Innenabstand 1 / 0,8 mm; «Höhe passt sich an» = Grösse an Text anpassen; Zeilenabstand exakt in pt | verlustfrei |
| Textart | Formname («Fliesstext 3», «Titel 1» …) | verlustfrei, solange der Name nicht geändert wird |
| fett, kursiv, unterstrichen, Farbe pro Textstelle | ein Textlauf pro Textstelle mit vollständigen Angaben | verlustfrei |
| Zeilenumbruch im Block | neuer Absatz | verlustfrei |
| Bild «Fläche füllen» mit Ausschnitt | Bild mit Zuschnitt | verlustfrei |
| Bild «Ganzes Bild» | Bild in seiner sichtbaren Lage | sieht gleich aus; kommt als «Fläche füllen» zurück |
| Rechteck (eckig/abgerundet, Füllung, Rahmen) | Rechteck / abgerundetes Rechteck; Rahmen mittig → Form um halbe Rahmenstärke verkleinert | verlustfrei |
| Linie | Verbindungslinie, runde Enden | verlustfrei |
| Reihenfolge vorne/hinten | Reihenfolge im Folienbaum | verlustfrei |

## Import fremder Präsentationen

- Übernommen: Textfelder (auch Platzhalter mit Lage aus Layout/Master), Bilder JPG/PNG mit Zuschnitt,
  Rechtecke, Linien, gruppierte Formen (aufgelöst), Design- und RGB-Farben.
- Folien in anderem Format (z. B. 16:9) werden auf A4 hochformat verkleinert; Hinweis an den Benutzer.
- Nicht übernommen, mit Hinweis: Tabellen, Diagramme, SmartArt, andere Formen (Kreise, Pfeile …),
  Bilder in EMF/SVG, verschiedene Schriftgrössen in einem Textfeld (Textly: eine Grösse pro Block).
- Text aus Formen mit Füllung wird als Rechteck plus Textblock übernommen.

## Ergebnisse des Tests (10. November 2026)

- **Textly → PPTX → Textly:** inhaltlich identisch (automatischer Test `test/pptx_test.dart`).
- **LibreOffice öffnet die Datei** ohne Fehler. Bilder samt Ausschnitt, Rechtecke mit Rahmen, Linien und
  alle Positionen liegen deckungsgleich mit dem Textly-PDF. Formatierte Wörter bleiben erhalten.
- **LibreOffice speichert neu → Textly liest ein:** alle Angaben erhalten, auch Textarten (Formnamen) und
  Formatierung; einzige Abweichung 0,01 mm Rundung (`tool/compare_pptx.dart`).
- **Schrift:** Roboto war auf dem Testrechner nicht installiert; LibreOffice hat eine breitere Ersatzschrift
  genommen, deshalb brechen dort Zeilen anders um. Für gleiches Aussehen braucht der Empfänger die
  Schriften (oder sie werden eingebettet, siehe unten).
- **PowerPoint:** auf dem Testrechner nicht vorhanden – noch von Hand zu prüfen.

## Offen

- Test in PowerPoint (Windows/macOS) und Google Slides.
- Schriften in die PPTX einbetten, damit sie überall gleich aussehen.
- Zeilenhöhe: Textly und PowerPoint verteilen den Zeilenabstand unterschiedlich; mit gleicher Schrift
  ist eine kleine vertikale Verschiebung zu erwarten (nicht gemessen, da PowerPoint fehlt).
