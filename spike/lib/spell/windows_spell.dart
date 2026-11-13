import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import 'spell_check.dart';

/// Rechtschreibprüfung über den Windows-Rechtschreibdienst (Spell Checking API, ab Windows 8).
///
/// Nutzt die Wörterbücher des Systems; keine eigenen Dateien und keine Lizenzfragen.
/// Wörter, die der Benutzer hinzufügt, landen im Benutzerwörterbuch von Windows und gelten
/// damit auch in anderen Programmen.
///
/// Speicher: Das Paket win32 (Version 5) gibt jedes COM-Objekt, das in eine Schnittstelle
/// (ISpellChecker, IEnumString, …) verpackt wird, beim Aufräumen selbst frei – samt Zeiger.
/// Diese Zeiger daher immer mit `calloc` anlegen und weder `release()` noch `free()` aufrufen.
/// Ein Verstoss führt zu doppelter Freigabe und einem Absturz (beobachtet im Machbarkeitstest).
class WindowsSpellBackend implements SpellBackend {
  WindowsSpellBackend._(this._checker, this.language);

  final ISpellChecker _checker;

  @override
  final String language;

  /// Gründliche Prüfung (ComprehensiveCheck) statt der schnellen (Check). Bringt für Deutsch
  /// im Test keinen Unterschied (auch doppelte Wörter werden nicht erkannt), ist aber langsamer.
  bool comprehensive = false;

  /// Bevorzugte Sprachen in dieser Reihenfolge. Ergibt null, wenn keine installiert ist.
  static WindowsSpellBackend? create({List<String> languages = const ['de-CH', 'de-DE', 'de-AT', 'de']}) {
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED); // schadet nicht, falls schon geschehen
    final factory = SpellCheckerFactory.createInstance();
    for (final lang in languages) {
      final ok = using((arena) {
        final supported = arena<Int32>();
        return factory.isSupported(lang.toNativeUtf16(allocator: arena), supported) == S_OK && supported.value != 0;
      });
      if (!ok) continue;
      final ppChecker = calloc<COMObject>();
      final hr = using((arena) => factory.createSpellChecker(lang.toNativeUtf16(allocator: arena), ppChecker.cast()));
      if (hr == S_OK) return WindowsSpellBackend._(ISpellChecker(ppChecker), lang);
      free(ppChecker); // nicht verpackt, deshalb hier selbst freigeben
    }
    return null;
  }

  /// Installierte Sprachen für die Rechtschreibprüfung (z. B. «de-CH», «en-US»).
  static List<String> supportedLanguages() {
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    final factory = SpellCheckerFactory.createInstance();
    return _strings(IEnumString(factory.supportedLanguages), 100);
  }

  static List<String> _strings(IEnumString list, int max) {
    final result = <String>[];
    using((arena) {
      final item = arena<Pointer<Utf16>>();
      final fetched = arena<Uint32>();
      while (result.length < max && list.next(1, item, fetched) == S_OK && fetched.value == 1) {
        result.add(item.value.toDartString());
        CoTaskMemFree(item.value);
      }
    });
    return result;
  }

  @override
  List<SpellIssue> checkText(String text) {
    if (text.isEmpty) return const [];
    final ppErrors = calloc<COMObject>();
    final hr = using((arena) {
      final p = text.toNativeUtf16(allocator: arena);
      return comprehensive ? _checker.comprehensiveCheck(p, ppErrors.cast()) : _checker.check(p, ppErrors.cast());
    });
    if (hr != S_OK) {
      free(ppErrors);
      return const [];
    }
    final errors = IEnumSpellingError(ppErrors);
    final issues = <SpellIssue>[];
    while (true) {
      final ppError = calloc<COMObject>();
      if (errors.next(ppError.cast()) != S_OK) {
        free(ppError); // kein Fehler mehr, Zeiger leer
        break;
      }
      final e = ISpellingError(ppError);
      final action = switch (e.correctiveAction) {
        CORRECTIVE_ACTION_REPLACE => SpellAction.replace,
        CORRECTIVE_ACTION_DELETE => SpellAction.delete,
        _ => SpellAction.suggest,
      };
      String? replacement;
      if (action == SpellAction.replace) {
        final r = e.replacement;
        replacement = r.toDartString();
        CoTaskMemFree(r);
      }
      issues.add(SpellIssue(e.startIndex, e.length, action, replacement));
    }
    return issues;
  }

  @override
  bool isCorrect(String word) => checkText(word).isEmpty;

  @override
  List<String> suggestions(String word, {int max = 5}) {
    final ppEnum = calloc<COMObject>();
    final hr = using((arena) => _checker.suggest(word.toNativeUtf16(allocator: arena), ppEnum.cast()));
    if (hr != S_OK && hr != S_FALSE) {
      free(ppEnum);
      return const [];
    }
    return _strings(IEnumString(ppEnum), max);
  }

  @override
  void addWord(String word) => using((arena) => _checker.add(word.toNativeUtf16(allocator: arena)));

  @override
  void ignoreWord(String word) => using((arena) => _checker.ignore(word.toNativeUtf16(allocator: arena)));
}
