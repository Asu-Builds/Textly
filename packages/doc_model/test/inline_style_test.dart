import 'package:doc_model/doc_model.dart';
import 'package:test/test.dart';

const bold = InlineStyle(bold: true);
const red = InlineStyle(color: 0xFFB4442C);

void main() {
  const text = 'Anmeldung bis 10. Oktober';

  test('Formatierung auf eine Stelle anwenden; Nachbarn werden zusammengefasst', () {
    var runs = applyInlineStyle(const [], text.length, 0, 9, bold);
    expect(runs, [const StyleRun(0, 9, bold)]);
    runs = applyInlineStyle(runs, text.length, 9, 13, bold);
    expect(runs, [const StyleRun(0, 13, bold)]);
    runs = applyInlineStyle(runs, text.length, 4, 6, red);
    expect(runs.length, 3);
    expect(styleAt(runs, 5), const InlineStyle(bold: true, color: 0xFFB4442C));
  });

  test('Abschnitte decken den ganzen Text ab', () {
    final runs = applyInlineStyle(const [], text.length, 10, 13, bold);
    final segs = segmentsOf(text.length, runs);
    expect(segs.map((s) => (s.start, s.end)), [(0, 10), (10, 13), (13, text.length)]);
    expect(segs[1].style, bold);
  });

  test('Tippen hinter einem fetten Wort bleibt fett, am Anfang übernimmt es das erste Zeichen', () {
    final runs = [const StyleRun(0, 9, bold)];
    expect(runsAfterEdit('Anmeldung', 'Anmeldungen', runs), [const StyleRun(0, 11, bold)]);
    expect(runsAfterEdit('Anmeldung', 'Die Anmeldung', runs), [const StyleRun(0, 13, bold)]);
    expect(runsAfterEdit('Anmeldung bis', 'Anmeldung bis jetzt', runs), [const StyleRun(0, 9, bold)]);
  });

  test('Löschen und Ersetzen verschieben die Formatierung', () {
    final runs = [const StyleRun(10, 13, bold)]; // «bis»
    expect(runsAfterEdit(text, text.replaceFirst('Anmeldung ', ''), runs), [const StyleRun(0, 3, bold)]);
    expect(runsAfterEdit(text, text.replaceFirst('bis', 'vor'), runs), [const StyleRun(10, 13, bold)]);
    expect(runsAfterEdit(text, 'x', runs), isEmpty);
  });

  test('vorgegebene Formatierung für neu Getipptes (Strg+B ohne Markierung)', () {
    expect(runsAfterEdit('ab', 'aXb', const [], inserted: bold), [const StyleRun(1, 2, bold)]);
  });

  test('Abweichung entfernen, wenn der ganze Block die Eigenschaft bekommt', () {
    final runs = [const StyleRun(0, 4, InlineStyle(bold: true, color: 0xFF000001))];
    expect(clearInlineAttribute(runs, 10, color: true), [const StyleRun(0, 4, bold)]);
    expect(clearInlineAttribute(runs, 10, bold: true, color: true), isEmpty);
  });

  test('Textblock: wirksame Formatierung und JSON hin und zurück', () {
    final t = TextBlock.ofKind(id: 't', box: const Box(0, 0, 50, 10), text: text)
        .copyWith(runs: [const StyleRun(0, 9, InlineStyle(bold: true, underline: true))]);
    expect(t.effectiveAt(0).bold, isTrue);
    expect(t.effectiveAt(0).underline, isTrue);
    expect(t.effectiveAt(12).bold, isFalse);
    final again = TextBlock.fromJson(t.toJson());
    expect(again.runs, t.runs);
    expect(TextBlock.fromJson(t.copyWith(runs: const []).toJson()).runs, isEmpty);
  });

  test('Leerzeichen hinter einem fetten Wort: Cursor bestimmt die Lage', () {
    final runs = [const StyleRun(0, 4, bold)]; // «fett»
    // ohne Cursor mehrdeutig: das neue Leerzeichen könnte das zweite sein
    expect(runsAfterEdit('fett Wort', 'fett  Wort', runs, cursor: 5), [const StyleRun(0, 5, bold)]);
  });

  test('Abweichungen gleich dem Blockstil werden entfernt', () {
    final runs = [const StyleRun(0, 3, InlineStyle(bold: false, color: 1)), const StyleRun(3, 5, InlineStyle(underline: false))];
    expect(simplifyRuns(runs, 5, bold: false, italic: false, color: 1), isEmpty);
    expect(simplifyRuns(runs, 5, bold: true, italic: false, color: 1), [const StyleRun(0, 3, InlineStyle(bold: false))]);
  });

  group('Emoji (Ersatzpaare) werden nie geteilt', () {
    const bold = InlineStyle(bold: true);
    bool whole(String text, List<StyleRun> runs) => runs.every((r) =>
        (r.start == 0 || r.start >= text.length || text.codeUnitAt(r.start) < 0xDC00 || text.codeUnitAt(r.start) > 0xDFFF) &&
        (r.end >= text.length || text.codeUnitAt(r.end) < 0xDC00 || text.codeUnitAt(r.end) > 0xDFFF));

    test('erstes von zwei Emoji mit gleicher erster Hälfte löschen', () {
      final r = runsAfterEdit('😀😃', '😃', const [StyleRun(0, 2, bold)]);
      expect(whole('😃', r), isTrue, reason: '$r');
      expect(r, isEmpty, reason: 'das fette 😀 ist weg, 😃 war nie fett');
    });

    test('Emoji einfügen, ersetzen und löschen in formatiertem Text', () {
      final cases = [
        ('a😀b', 'a😃b', const [StyleRun(1, 3, bold)]),
        ('😀😃x', '😀x', const [StyleRun(2, 4, bold)]),
        ('x😃', 'x😀😃', const [StyleRun(1, 3, bold)]),
        ('😃😃😃', '😃😃', const [StyleRun(2, 4, bold)]),
      ];
      for (final (o, n, runs) in cases) {
        final r = runsAfterEdit(o, n, runs);
        expect(whole(n, r), isTrue, reason: '$o → $n: $r');
      }
    });
  });
}
