import 'dart:async';

import 'package:doc_model/doc_model.dart';
import 'package:doc_render/doc_render.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../spell/spell_check.dart';

/// Eingabefeld-Steuerung mit formatierten Textstellen (fett, kursiv, unterstrichen, Farbe pro Stelle).
///
/// - Bei jeder Textänderung (Tippen, Löschen, Einfügen, Rückgängig im Feld) wird die Formatierung
///   mitgeführt ([runsAfterEdit]).
/// - Die Anzeige im Feld kommt aus [textSpanFor] – genau wie Anzeige und PDF. So bleibt das
///   Eingabefeld deckungsgleich mit der Seite.
/// - Rechtschreibfehler zeichnet das Feld selbst: Flutters eingebaute Anzeige würde sonst den Text
///   neu aufbauen und die Formatierung verwerfen (EditableText.buildTextSpan mit spellCheckResults).
class RichTextController extends TextEditingController {
  RichTextController({this.spell});

  SpellChecker? spell;

  TextBlock? _block;
  List<StyleRun> _runs = const [];
  List<SuggestionSpan> _misspelled = const [];
  Timer? _spellTimer;
  int _spellGeneration = 0;
  bool _disposed = false;

  /// Formatierung früherer Textstände. Flutters Rückgängig im Feld stellt nur den Text wieder her;
  /// so kommt auch die Formatierung zurück (z. B. ein gelöschtes fettes Wort).
  final _formatOf = <String, List<StyleRun>>{};

  /// Formatierung für das nächste getippte Zeichen (Strg+B usw. ohne Markierung).
  InlineStyle? pending;

  /// Der Block, dessen Stil gilt (Schrift, Grösse, Grundfarbe).
  TextBlock? get block => _block;
  List<StyleRun> get runs => _runs;
  List<SuggestionSpan> get misspelled => _misspelled;

  /// Bearbeitung eines Blocks beginnen.
  void load(TextBlock t, TextSelection selection) {
    _block = t;
    _runs = t.runs;
    _misspelled = const [];
    _formatOf.clear();
    pending = null;
    super.value = TextEditingValue(text: t.text, selection: selection);
    _scheduleSpellCheck(immediately: true);
  }

  /// Blockstil hat sich geändert (Eigenschaftenleiste während des Schreibens).
  void updateBlock(TextBlock t) {
    _block = t;
    _runs = t.runs;
    _formatOf.clear(); // frühere Stände hatten eine andere Formatierung
    notifyListeners();
  }

  @override
  set value(TextEditingValue v) {
    final old = super.value;
    if (v.text != old.text) {
      final inserted = pending != null && v.text.length > old.text.length ? pending : null;
      _formatOf.remove(old.text);
      _formatOf[old.text] = _runs;
      if (_formatOf.length > 300) _formatOf.remove(_formatOf.keys.first);
      final known = inserted == null ? _formatOf[v.text] : null;
      _runs = known ??
          runsAfterEdit(old.text, v.text, _runs, inserted: inserted, cursor: v.selection.isCollapsed ? v.selection.baseOffset : null);
      pending = null;
      // Fehlermarkierungen vor der Änderung behalten, alles danach neu prüfen lassen
      var p = 0;
      while (p < old.text.length && p < v.text.length && old.text.codeUnitAt(p) == v.text.codeUnitAt(p)) {
        p++;
      }
      _misspelled = [for (final s in _misspelled) if (s.range.end < p) s];
      _scheduleSpellCheck();
    } else if (v.selection != old.selection) {
      pending = null;
    }
    super.value = v;
  }

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    final b = _block;
    if (b == null) return super.buildTextSpan(context: context, style: style, withComposing: withComposing);
    return textSpanFor(b, text: text, runs: _runs, misspelled: [for (final s in _misspelled) s.range]);
  }

  // ---------- Rechtschreibung ----------

  void _scheduleSpellCheck({bool immediately = false}) {
    _spellTimer?.cancel();
    final s = spell;
    if (s == null || !s.enabled) return;
    final generation = _spellGeneration;
    _spellTimer = Timer(immediately ? Duration.zero : const Duration(milliseconds: 300), () async {
      final checked = text;
      final result = await s.fetchSpellCheckSuggestions(const Locale('de', 'CH'), checked);
      // beendet, geschlossen oder inzwischen weitergetippt: nichts nachliefern
      if (_disposed || generation != _spellGeneration || checked != text || result == null) return;
      _misspelled = result;
      notifyListeners();
    });
  }

  SuggestionSpan? suggestionAt(int index) {
    for (final s in _misspelled) {
      if (index >= s.range.start && index <= s.range.end) return s;
    }
    return null;
  }

  /// Markierung entfernen (nach «Zum Wörterbuch hinzufügen» / «Ignorieren»).
  void dropMisspelled(TextRange range) {
    _misspelled = [for (final s in _misspelled) if (s.range != range) s];
    notifyListeners();
  }

  /// Ende der Bearbeitung: keine Prüfung mehr nachliefern.
  void stopSpellCheck() {
    _spellGeneration++;
    _spellTimer?.cancel();
    _spellTimer = null;
    _misspelled = const [];
  }

  /// Nur für Tests: Rechtschreibprüfung sofort ausführen und abwarten.
  Future<void> checkSpellingNow() async {
    _spellTimer?.cancel();
    final s = spell;
    if (s == null) return;
    final result = await s.fetchSpellCheckSuggestions(const Locale('de', 'CH'), text);
    _misspelled = result ?? const [];
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _spellTimer?.cancel();
    super.dispose();
  }
}
