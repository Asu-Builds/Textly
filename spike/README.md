# Textly – Machbarkeitstest (Flutter)

Prüft vor Entwicklungsbeginn die Annahmen aus dem Technologieentscheid MVP:

1. **PDF gleich Vorschau:** Das PDF übernimmt jedes Zeichen an die Position, die Flutter auf dem Bildschirm berechnet.
2. **Textbearbeitung im Block:** Erster Klick wählt aus, zweiter Klick setzt den Cursor an die Klickstelle.
3. **Rechtschreibprüfung:** Windows-Rechtschreibdienst (de-CH) im Flutter-Textfeld.
4. **Auslieferung:** noch offen (Installer, Codesignatur).

## Starten

```
cd spike
flutter run -d windows
```

In der App: «PDF erzeugen» schreibt `Dokumente\Textly\textly-machbarkeitstest.pdf` und öffnet es.
Rechts zeigt der Messbericht die Abweichung. «Differenz» legt das PDF über die Bildschirmseite:
Wo beide übereinstimmen, wird es schwarz.

## Tests

```
flutter test
```

- `fidelity_test.dart`: erzeugt `build/fidelity/textly-spike.pdf`, misst jede Zeichenposition und
  speichert die Bildschirmseiten als PNG (`SPIKE_RATIO=8` für höhere Auflösung).
- `editing_test.dart`: Eingabefeld bricht gleich um wie Anzeige und PDF; Rechtschreibprüfung mit Testwortliste.
- `windows_spell_test.dart` (nur Windows): Windows-Rechtschreibdienst, doppelte Wörter, Belastungstest.

## Aufbau

- `lib/model/` – Dokumentmodell (mm, pt), Beispieldokument mit zwei Seiten
- `lib/render/text_layout.dart` – gemeinsamer Textsatz für Bildschirm, Bearbeitung und PDF
- `lib/render/page_canvas.dart` – Seite in Punkt-Einheiten, Auswahl, Verschieben, Bearbeiten
- `lib/pdf/pdf_export.dart` – PDF-Export mit Messbericht
- `lib/spell/spell_check.dart` – Rechtschreibprüfung, Rechtsklick-Menü, doppelte Wörter
- `lib/spell/windows_spell.dart` – Anbindung an den Windows-Rechtschreibdienst

## Erkenntnisse

Siehe `ERGEBNISSE.md`.

## Hinweise

- Testschriften: Roboto und Roboto Condensed (Apache 2.0) aus dem Flutter-SDK. Für den MVP durch die
  gewählten OFL-Schriften ersetzen.
- Die Beispielbilder sind generiert.
