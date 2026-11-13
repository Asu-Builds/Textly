@TestOn('windows')
library;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:textly_spike/spell/spell_check.dart';
import 'package:textly_spike/spell/windows_spell.dart';

void main() {
  test('Windows-Rechtschreibdienst: Sprachen, Fehler, Vorschläge', () async {
    final langs = WindowsSpellBackend.supportedLanguages();
    // ignore: avoid_print
    print('SPRACHEN $langs');
    final backend = WindowsSpellBackend.create();
    if (backend == null) {
      markTestSkipped('Kein deutsches Wörterbuch installiert (vorhanden: $langs)');
      return;
    }
    const text = 'Die Wandrung zum Aletschgletscher war der der schönste Tag. Grüezi mitenand!';
    final issues = backend.checkText(text);
    final found = [for (final i in issues) '${text.substring(i.start, i.start + i.length)}:${i.action.name}'];
    // ignore: avoid_print
    print('SPRACHE ${backend.language} FEHLER $found');
    expect(found.any((f) => f.startsWith('Wandrung')), isTrue);
    expect(backend.isCorrect('Gletscher'), isTrue);
    final s = backend.suggestions('Wandrung');
    // ignore: avoid_print
    print('VORSCHLAEGE Wandrung: $s');
    expect(s, contains('Wanderung'));

    // Belastung: viele Prüfungen erzeugen Abfall, damit die automatische Freigabe sicher läuft.
    // Mit doppelter Freigabe stürzte der Prozess hier ab.
    for (var i = 0; i < 3000; i++) {
      backend.checkText(text);
      if (i % 100 == 0) backend.suggestions('Wandrung');
    }
    final spans = await SpellChecker(backend).fetchSpellCheckSuggestions(const Locale('de', 'CH'), text);
    expect(spans!.first.suggestions, contains('Wanderung'));
    final dup = spans.where((s) => s.suggestions.length == 1 && s.suggestions.first == SpellChecker.deleteMarker).toList();
    expect(dup.length, 1, reason: 'doppeltes «der» wird von der App erkannt');
    expect(text.substring(dup.first.range.start, dup.first.range.end), 'der');
  });
}
