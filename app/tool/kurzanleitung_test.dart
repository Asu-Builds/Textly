// Kurzanleitung als A4-PDF (docs/kurzanleitung.pdf) – gesetzt mit Textly selbst.
//
// Aufruf aus dem Ordner app:   flutter test tool/kurzanleitung_test.dart
//
// Vorher tool/docs_screenshots_test.dart laufen lassen (das Bild der App kommt aus docs/bilder).
import 'dart:io';

import 'package:doc_model/doc_model.dart';
import 'package:doc_render/doc_render.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:textly/links.dart';

Future<ByteData> _disk(String p) async => ByteData.sublistView(await File(p).readAsBytes());

const _blue = 0xFF2457D6, _ink = 0xFF1D2733, _muted = 0xFF5D6876, _white = 0xFFFFFFFF, _soft = 0xFFEAF0FD, _amber = 0xFFFFB547;

class _B {
  var _n = 0;
  String id() => 'k${_n++}';

  TextBlock text(double x, double y, double w, String text,
      {TextKind kind = TextKind.body, double size = 10, int color = _ink, bool bold = false, TextAlignment align = TextAlignment.left}) {
    final p = textKindPresets[kind]!;
    return TextBlock(id: id(), box: Box(x, y, w, 10), text: text, kind: kind, size: size, color: color, bold: bold, italic: p.italic, align: align);
  }

  RectShape rect(double x, double y, double w, double h, int fill, {bool round = false}) =>
      RectShape(id: id(), box: Box(x, y, w, h), fill: fill, stroke: fill, strokeWidth: 0, round: round);
}

TextlyDocument kurzanleitung() {
  final b = _B();
  const l = 18.0, lw = 84.0, r = 110.0, rw = 82.0;
  final steps = [
    ('Vorlage wählen', '«Neues Dokument» oben links, dann unter «Neu beginnen» eine Vorlage oder das leere Blatt anklicken.'),
    ('Text überschreiben', 'In einen Text klicken und lostippen. Über dem Text: Schrift, Grösse, Farbe. «Esc» beendet.'),
    ('Bild ersetzen', 'Bild anklicken, rechts «Ersetzen». Oder ein Foto aus dem Explorer auf die Seite ziehen.'),
    ('Namen geben', 'Oben in der Mitte auf «Dokument: …» klicken. Speichern musst du nicht – das geht automatisch.'),
    ('Drucken oder PDF', '«Drucken & PDF …» oben rechts: Textly prüft die Seite, dann Drucken, PDF oder E-Mail.'),
  ];
  return TextlyDocument(pages: [
    DocPage(id: 'p1', elements: [
      // Kopf
      b.rect(0, 0, 210, 38, _blue),
      b.text(l, 10, 150, 'Textly – Kurzanleitung', kind: TextKind.title, size: 26, color: _white, bold: true),
      b.text(l, 23, 150, 'Alles Wichtige auf einer Seite. Zum Ausdrucken und neben den Computer legen.', size: 11, color: 0xFFDCE6FF),
      b.rect(178, 11, 14, 14, _white, round: true),
      b.text(178, 12.2, 14, 'T', size: 18, color: _blue, bold: true, align: TextAlignment.center),

      // Links: fünf Schritte
      b.text(l, 48, lw, 'In 5 Schritten zur Einladung', kind: TextKind.heading, size: 14, bold: true),
      for (final (i, (t, d)) in steps.indexed) ...[
        b.rect(l, 58 + i * 23.0, 7, 7, _amber, round: true),
        b.text(l, 58.6 + i * 23.0, 7, '${i + 1}', size: 10, bold: true, align: TextAlignment.center),
        b.text(l + 10, 58 + i * 23.0, lw - 10, t, size: 11, bold: true),
        b.text(l + 10, 63.5 + i * 23.0, lw - 10, d, size: 9.5, color: _muted),
      ],

      // Rechts: Bild der App und «Nichts geht verloren»
      ImageBlock(id: b.id(), box: const Box(r, 49, rw, rw * 1140 / 1920), asset: '../docs/bilder/vorlage-offen.png', naturalWidth: 1920, naturalHeight: 1140),
      b.text(r, 49 + rw * 1140 / 1920 + 1.5, rw, 'Oben: Einfügen und «Drucken & PDF …». Rechts: alles zum ausgewählten Element.',
          kind: TextKind.caption, size: 8.5, color: _muted),
      b.text(r, 109, rw, 'Nichts geht verloren', kind: TextKind.heading, size: 14, bold: true),
      b.text(r, 118, rw,
          '• Textly speichert jede Änderung sofort.\n'
          '• «Rückgängig» oben rechts nimmt Schritt für Schritt zurück.\n'
          '• «Frühere Stände» zeigt ältere Fassungen auf einem Zeitstrahl.\n'
          '• Gelöschte Dokumente bleiben 30 Tage im Papierkorb.\n'
          '• Deine Dateien liegen unter «Dokumente\\Textly».',
          size: 9.5),

      // Tasten
      b.text(l, 180, 170, 'Praktische Tasten', kind: TextKind.heading, size: 14, bold: true),
      TableBlock(id: b.id(), x: l, y: 190, columns: [32, 53, 32, 57], headerRow: false, cells: [
        ['Strg + Z', 'Rückgängig', 'Strg + Y', 'Wiederholen'],
        ['Entf', 'Ausgewähltes löschen', 'Esc', 'Schreiben beenden'],
        ['Strg + V', 'Bild einfügen', 'Strg + D', 'Verdoppeln'],
        ['Strg + Mausrad', 'Vergrössern, verkleinern', 'Strg + 0', 'Ganze Seite zeigen'],
      ]).withStyle(TableStyle.grid),

      // Hilfe
      b.rect(l, 234, 174, 26, _soft, round: true),
      b.text(l + 6, 238, 162, 'Hilfe', size: 12, bold: true, color: 0xFF1D3A85),
      b.text(l + 6, 244.5, 162,
          'In Textly: das «?» oben rechts. Ausführliche Anleitung mit Bildern:\n$anleitungUrl',
          size: 10, color: 0xFF1D3A85),

      // Fuss
      b.text(l, 279, 174, 'Textly · kostenlos · für Windows 10 und 11 · Deine Dokumente bleiben auf deinem Computer',
          kind: TextKind.caption, size: 8.5, color: _muted, align: TextAlignment.center),
    ]),
  ]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Kurzanleitung als PDF', () async {
    // Schriften für den Textsatz (wie in der App)
    for (final (family, prefix) in [('TextlySans', 'Sans'), ('TextlyCondensed', 'Cond')]) {
      final l = FontLoader(family);
      for (final s in ['Regular', 'Bold', 'Italic', 'BoldItalic']) {
        l.addFont(_disk('assets/fonts/$prefix-$s.ttf'));
      }
      await l.load();
    }
    final doc = kurzanleitung();
    expect(printIssues(doc).where((i) => i.kind != PrintIssueKind.nearEdge), isEmpty, reason: 'nichts darf abgeschnitten sein');
    final r = await exportPdf(doc, _disk);
    File('../docs/kurzanleitung.pdf').writeAsBytesSync(r.bytes);
  });
}
