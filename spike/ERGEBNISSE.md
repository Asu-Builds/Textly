# Ergebnisse Machbarkeitstest – Stand 10. November 2026

Getestet auf Windows 10 mit Flutter 3.41.6 (stabil), Testschriften Roboto und Roboto Condensed.

| Prüfpunkt | Stand | Ergebnis |
|---|---|---|
| PDF gleich Vorschau | erfüllt | Alle 16 Textblöcke der zwei Beispielseiten liegen im PDF horizontal und vertikal exakt wie am Bildschirm (Messgenauigkeit 0,044 mm). Zeichenpositionen rechnerisch 0,000 mm. |
| Eingabefeld gleich Anzeige | erfüllt | Automatischer Test: jedes Wort aller Blöcke an gleicher Stelle und Zeile. Kein Springen beim Wechsel in die Bearbeitung. |
| Zweiter Klick setzt Cursor | umgesetzt | Cursor an der Klickstelle über den gemeinsamen Textsatz. Von Hand in der App noch zu prüfen. |
| Rechtschreibprüfung (Windows) | erfüllt | Windows-Rechtschreibdienst mit Systemwörterbuch **de-CH** angebunden: rote Unterstreichung, Vorschläge, «Zum Wörterbuch hinzufügen», «Ignorieren». Doppelte Wörter erkennt die App selbst. Automatischer Test inkl. 3000 Prüfungen. |
| Windows-App | erfüllt | Release-Build 34 MB, startet, rund 155 MB Arbeitsspeicher. |
| macOS, Installer, Signatur | offen | Braucht einen Mac bzw. Zertifikate. |

## Was nötig war, damit PDF und Bildschirm übereinstimmen

1. **Seite in Punkt aufbauen und nur skalieren.** Der Zeilenumbruch hängt so nicht vom Zoom ab.
2. **Unterschneidung (Kerning) übernehmen.** Flutter rückt Paare wie «Ve» zusammen, das PDF-Paket nicht.
   Ohne Ausgleich lagen Wortenden bis 0,56 mm daneben. Lösung: Wörter in Stücke teilen und jedes Stück
   an die von Flutter berechnete Position setzen. Der Text bleibt im PDF durchsuchbar.
3. **Grundlinie messen statt berechnen.** Die von Flutter gemeldeten Grundlinien (`LineMetrics.baseline`,
   `computeDistanceToActualBaseline`) liegen je nach Textart bis 0,5 pt (0,18 mm) neben der gezeichneten.
   Lösung: Die App zeichnet einmal pro Stil intern ein «H» in 16-facher Grösse und liest die Grundlinie ab
   (`measuredFirstBaseline`). Danach stimmen alle Blöcke.
4. **Eingabefeld exakt gleich konfigurieren wie die Anzeige:**
   - dieselbe feste Zeilenhöhe (`strutFor`) an Anzeige und Eingabefeld übergeben,
   - `leadingDistribution` ausdrücklich setzen, sonst mischt das Material-Design einen anderen Wert hinein,
   - Eingabefeld um Cursorbreite + 1 pt breiter machen (Flutter reserviert diesen Platz),
   - Textskalierung des Betriebssystems für das Feld abschalten.

Diese Punkte gehören ins Pflichtenheft als technische Vorgaben für den MVP.

## Rechtschreibprüfung unter Windows

- Anbindung über das Paket `win32` (Version 5.15) an die Windows Spell Checking API, ohne nativen Code.
  Auf diesem Rechner installiert: de-CH, de-DE, de-AT, de-LI, de-LU und mehrere fr-Varianten.
  Die App wählt de-CH, sonst de-DE oder de-AT; ohne deutsches Wörterbuch fällt sie auf die Testwortliste zurück.
- Vorteile: Wörterbücher und Benutzerwörterbuch des Systems, keine Lizenzfragen, keine eigenen Dateien.
- Mit de-CH gilt «Grüezi» als korrekt, «mitenand» nicht. Eigennamen wie
  «Aletschgletscher» werden markiert und lassen sich zum Wörterbuch hinzufügen.
- Doppelte Wörter («der der») meldet Windows im Deutschen nicht, auch nicht mit der gründlichen Prüfung.
  Die App erkennt sie selbst und bietet «Doppeltes Wort entfernen» an.
- **Wichtig für den MVP:** `win32` gibt COM-Objekte automatisch frei. Zusätzliches `release()` führte zu
  einem Absturz beim Aufräumen (Speicherzugriffsfehler), der im Test nicht auffiel. Regel und
  Belastungstest sind im Code dokumentiert (`windows_spell.dart`, `windows_spell_test.dart`).

## Offene Punkte

- **Rechtschreibprüfung auf macOS:** gleiches Vorgehen mit `NSSpellChecker` (Plattformkanal oder FFI).
- **Von Hand testen:** Eingabe mit Umlauten über die Tastatur, Rückgängig im Feld und auf der Seite,
  Rechtsklick-Menü mit Vorschlägen, «Zum Wörterbuch hinzufügen», Druckdialog.
- **macOS:** Build, Darstellung und PDF auf einem Mac wiederholen.
- **Auslieferung:** MSIX bzw. Installer, Codesignatur, Update-Funktion.
- **Endgültige Schriften:** Test mit den gewählten OFL-Schriften wiederholen (`flutter test` + `tool/measure_fidelity.py`).

## Messung wiederholen

```
SPIKE_RATIO=8 flutter test
cd build/fidelity
python ../../tool/measure_fidelity.py
```
