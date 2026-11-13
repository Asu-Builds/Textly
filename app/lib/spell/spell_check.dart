import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'windows_spell.dart';

/// Rechtschreibprüfung für das Desktop-Textfeld.
///
/// Flutter hat auf Windows und macOS keinen eingebauten Prüfdienst. Die App liefert ihn
/// über [SpellCheckService] selbst. Die eigentliche Prüfung steckt hinter [SpellBackend]:
/// - [WindowsSpellBackend]: Windows-Rechtschreibdienst mit den Wörterbüchern des Systems,
/// - [WordListBackend]: kleine Testwortliste als Rückfall (z. B. ohne deutsches Wörterbuch).

enum SpellAction { suggest, replace, delete }

class SpellIssue {
  const SpellIssue(this.start, this.length, this.action, [this.replacement]);
  final int start, length;
  final SpellAction action;
  final String? replacement;
}

abstract interface class SpellBackend {
  /// Sprache bzw. Herkunft für die Anzeige, z. B. «de-CH».
  String get language;
  List<SpellIssue> checkText(String text);
  bool isCorrect(String word);
  List<String> suggestions(String word);
  void addWord(String word);
  void ignoreWord(String word);
}

class WordListBackend implements SpellBackend {
  WordListBackend(Iterable<String> words) : _words = {for (final w in words) w.toLowerCase()};
  final Set<String> _words;

  static Future<WordListBackend> fromAsset(String key) async {
    final text = await rootBundle.loadString(key);
    return WordListBackend(text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty));
  }

  static final _word = RegExp(r"[A-Za-zÀ-ÖØ-öø-ÿ]+(?:-[A-Za-zÀ-ÖØ-öø-ÿ]+)*");

  @override
  String get language => 'Testwortliste';

  @override
  List<SpellIssue> checkText(String text) => [
        for (final m in _word.allMatches(text))
          if (m.group(0)!.length >= 3 && !m.group(0)!.split('-').every(isCorrect))
            SpellIssue(m.start, m.end - m.start, SpellAction.suggest),
      ];

  @override
  bool isCorrect(String word) => _words.contains(word.toLowerCase());

  @override
  void addWord(String word) => _words.add(word.toLowerCase());

  @override
  void ignoreWord(String word) => _words.add(word.toLowerCase());

  @override
  List<String> suggestions(String word) {
    final lw = word.toLowerCase();
    final scored = <(int, String)>[];
    for (final w in _words) {
      if ((w.length - lw.length).abs() > 2) continue;
      final d = _distance(lw, w);
      if (d <= 2) scored.add((d, w));
    }
    scored.sort((a, b) => a.$1.compareTo(b.$1));
    final upper = word.isNotEmpty && word[0] == word[0].toUpperCase();
    return [
      for (final s in scored.take(4)) upper ? s.$2[0].toUpperCase() + s.$2.substring(1) : s.$2,
    ];
  }

  static int _distance(String a, String b) {
    var prev = List<int>.generate(b.length + 1, (i) => i);
    for (var i = 1; i <= a.length; i++) {
      final cur = [i, ...List<int>.filled(b.length, 0)];
      for (var j = 1; j <= b.length; j++) {
        cur[j] = math.min(math.min(cur[j - 1] + 1, prev[j] + 1), prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1));
      }
      prev = cur;
    }
    return prev[b.length];
  }
}

/// Wählt das beste verfügbare Backend: Windows-Dienst, sonst Testwortliste.
Future<SpellBackend> defaultSpellBackend() async {
  if (Platform.isWindows) {
    try {
      final w = WindowsSpellBackend.create();
      if (w != null) return w;
    } catch (_) {
      // Dienst nicht verfügbar: Rückfall auf die Testwortliste
    }
  }
  return WordListBackend.fromAsset('assets/spell/de_demo.txt');
}

class SpellChecker implements SpellCheckService {
  SpellChecker(this.backend);
  final SpellBackend backend;
  bool enabled = true;

  /// Leerer Vorschlag bedeutet: Wort löschen (z. B. doppeltes Wort).
  static const deleteMarker = '';

  @override
  Future<List<SuggestionSpan>?> fetchSpellCheckSuggestions(Locale locale, String text) async {
    if (!enabled) return const [];
    // Doppelte Wörter prüft die App selbst; der Windows-Dienst erkennt sie im Deutschen nicht.
    final issues = [...backend.checkText(text), ...repeatedWords(text)]..sort((a, b) => a.start.compareTo(b.start));
    return [
      for (final i in issues)
        SuggestionSpan(
          TextRange(start: i.start, end: i.start + i.length),
          switch (i.action) {
            SpellAction.replace => [i.replacement ?? ''],
            SpellAction.delete => const [deleteMarker],
            // Vorschläge erst beim Rechtsklick holen (Windows braucht rund 3,5 ms pro Wort)
            SpellAction.suggest => const [],
          },
        ),
    ];
  }

  static final _repeat = RegExp(r"(?<![\p{L}])(\p{L}+)\s+(\1)(?![\p{L}])", unicode: true, caseSensitive: false);

  /// Findet direkt wiederholte Wörter («der der»); markiert wird jeweils das zweite.
  static List<SpellIssue> repeatedWords(String text) => [
        for (final m in _repeat.allMatches(text))
          SpellIssue(m.start + m.group(0)!.length - m.group(2)!.length, m.group(2)!.length, SpellAction.delete),
      ];

  SpellCheckConfiguration configuration() => SpellCheckConfiguration(
        spellCheckService: this,
        misspelledTextStyle: const TextStyle(
          decoration: TextDecoration.underline,
          decorationColor: Color(0xFFD32F2F),
          decorationStyle: TextDecorationStyle.wavy,
        ),
      );

  /// Kontextmenü (Rechtsklick) mit Korrekturvorschlägen vor den üblichen Befehlen.
  ///
  /// [lookup] findet den markierten Fehler an einer Textstelle, [drop] entfernt seine Markierung.
  /// (Die Fehler verwaltet das Eingabefeld selbst, siehe RichTextController.)
  Widget contextMenu(
    BuildContext context,
    EditableTextState state, {
    required SuggestionSpan? Function(int index) lookup,
    required void Function(TextRange range) drop,
  }) {
    final value = state.currentTextEditingValue;
    final span = lookup(value.selection.extentOffset);
    final items = <ContextMenuButtonItem>[];
    if (span != null && span.range.end <= value.text.length) {
      final word = value.text.substring(span.range.start, span.range.end);
      final suggestions = span.suggestions.isEmpty ? backend.suggestions(word) : span.suggestions;
      if (suggestions.isEmpty) items.add(const ContextMenuButtonItem(label: 'Keine Vorschläge', onPressed: null));
      for (final s in suggestions) {
        items.add(ContextMenuButtonItem(
          label: s == deleteMarker ? 'Doppeltes Wort entfernen' : s,
          onPressed: () {
            var start = span.range.start;
            if (s == deleteMarker && start > 0 && value.text[start - 1] == ' ') start--;
            final text = value.text.replaceRange(start, span.range.end, s);
            state.userUpdateTextEditingValue(
              TextEditingValue(text: text, selection: TextSelection.collapsed(offset: start + s.length)),
              SelectionChangedCause.toolbar,
            );
            state.hideToolbar();
          },
        ));
      }
      items.add(ContextMenuButtonItem(
        label: 'Zum Wörterbuch hinzufügen',
        onPressed: () {
          backend.addWord(word);
          drop(span.range);
          state.hideToolbar();
        },
      ));
      items.add(ContextMenuButtonItem(
        label: 'Ignorieren',
        onPressed: () {
          backend.ignoreWord(word);
          drop(span.range);
          state.hideToolbar();
        },
      ));
    }
    items.addAll(state.contextMenuButtonItems);
    return AdaptiveTextSelectionToolbar.buttonItems(anchors: state.contextMenuAnchors, buttonItems: items);
  }
}
