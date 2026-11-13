import 'dart:async';
import 'dart:convert';

import 'package:doc_model/doc_model.dart';
import 'package:flutter/foundation.dart';

import '../editor/editor_controller.dart';
import '../history/change_label.dart';
import '../history/history_store.dart';
import 'document_library.dart';

enum SaveState { saved, pending, saving, failed }

/// Speichert ein geöffnetes Dokument aus «Meine Dokumente» automatisch – nur wenn sich der Inhalt
/// geändert hat – kurz nach jeder Änderung und sofort beim Verlassen. Es gibt keinen Speichern-Knopf.
///
/// Mit [history] legt sie wenige, verständliche Sicherungspunkte an (nicht jede Kleinigkeit). Jeder Punkt
/// zeigt den Stand *nach* dem Ereignis; Bearbeitetes davor wird vorher ein eigener Punkt:
/// - nach einer **Löschung** (mehrere kurz nacheinander werden ein Punkt; der Stand davor zeigt, was gelöscht wurde),
/// - nach einer **grossen Veränderung** (weit verschoben, andere Seite, Bild ersetzt, Hoch-/Querformat),
/// - nach einer **Arbeitspause** bzw. beim Verlassen: «Bearbeitet: 3 Texte, 1 Bild»,
/// - beim **Weitergeben** und beim **Benennen**.
/// Kleine Schritte macht Rückgängig (Strg+Z) ungeschehen, solange das Dokument offen ist.
class AutosaveSession extends ChangeNotifier {
  AutosaveSession(
    this.library,
    this.entry,
    this.controller, {
    this.delay = const Duration(milliseconds: 1200),
    this.history,
    this.pause = const Duration(minutes: 5),
    this.deleteGroup = const Duration(seconds: 60),
    DateTime Function()? clock,
  })  : _clock = clock ?? DateTime.now,
        _lastSaved = controller.doc,
        _lastSavedKey = _contentKey(controller.doc) {
    controller.untitledName = entry.name;
    controller.addListener(_onChange);
    _ready = _start();
  }

  final DocumentLibrary library;
  final EditorController controller;
  final Duration delay;
  final HistoryStore? history;

  /// Ohne Änderung so lange → angesammelte Bearbeitungen werden ein Sicherungspunkt.
  final Duration pause;

  /// Löschungen innerhalb dieser Zeit werden ein Sicherungspunkt («3 Elemente wurden gelöscht»).
  final Duration deleteGroup;
  final DateTime Function() _clock;

  LibraryEntry entry;
  SaveState state = SaveState.saved;
  TextlyDocument _lastSaved;
  String _lastSavedKey;
  Timer? _timer;
  Timer? _pauseTimer;
  Future<void>? _running;
  late final Future<void> _ready;
  int _session = 1;

  // Angesammelte Bearbeitungen seit dem letzten Sicherungspunkt
  final _edited = <String, String>{};
  int _pagesAdded = 0;
  DateTime? _editFrom;

  // Letzte Löschung (zum Zusammenfassen)
  ({int n, DateTime time, List<String> ids, int pages, TextlyDocument? before, String? subject})? _lastDelete;

  /// Nächste gespeicherte Änderung ist ein Wiederherstellen: keinen eigenen Punkt dafür anlegen.
  bool _skipNext = false;

  /// Zählt hoch, wenn sich der Verlauf ändert (für die Verlaufsansicht).
  int historyVersion = 0;

  String get id => entry.id;
  String get name => entry.name;

  /// Eigener Name; leer: der Name folgt wieder dem ersten Text.
  Future<void> rename(String name) async {
    try {
      entry = await library.rename(id, name);
      controller.untitledName = entry.name;
    } catch (_) {
      // Name bleibt, wie er war
    }
    notifyListeners();
  }

  /// Inhalt ohne Bilddaten als Text: gleich = keine Änderung, nichts zu speichern.
  static String _contentKey(TextlyDocument d) => jsonEncode(d.toJson());

  Future<void> _start() async {
    final h = history;
    if (h == null) return;
    try {
      _session = await h.newSession();
      await h.thin();
      if ((await h.entries()).isEmpty) {
        final empty = controller.doc.pages.every((p) => p.elements.isEmpty);
        await h.record(controller.doc, label: empty ? 'Dokument erstellt' : 'Ausgangsstand', kind: 'start', session: _session);
        _changed();
      }
    } catch (_) {
      // Verlauf ist ein Zusatz; ohne ihn wird trotzdem gespeichert
    }
  }

  void _changed() {
    historyVersion++;
    notifyListeners();
  }

  void _onChange() {
    if (identical(controller.doc, _lastSaved)) return;
    _timer?.cancel();
    _timer = Timer(delay, () => _save());
    if (state != SaveState.pending) {
      state = SaveState.pending;
      notifyListeners();
    }
  }

  Future<void> _save() async {
    // Läuft schon ein Speichervorgang: danach den neuesten Stand nachziehen
    while (_running != null) {
      await _running;
    }
    final doc = controller.doc;
    if (identical(doc, _lastSaved)) {
      if (_timer?.isActive != true && state != SaveState.saved) {
        state = SaveState.saved;
        notifyListeners();
      }
      return;
    }
    final key = _contentKey(doc);
    if (key == _lastSavedKey) {
      // gleicher Inhalt (z. B. Auswahl, Rückgängig auf den gespeicherten Stand): nichts schreiben
      _lastSaved = doc;
      state = SaveState.saved;
      notifyListeners();
      return;
    }
    state = SaveState.saving;
    notifyListeners();
    final prev = _lastSaved;
    final run = () async {
      try {
        entry = await library.save(id, doc);
        _lastSaved = doc;
        _lastSavedKey = key;
        controller.untitledName = entry.name; // Name folgt dem Titel
        state = identical(controller.doc, doc) ? SaveState.saved : SaveState.pending;
        await _checkpoint(prev, doc);
      } catch (_) {
        state = SaveState.failed;
        _timer?.cancel();
        _timer = Timer(const Duration(seconds: 5), () => _save()); // später erneut versuchen
      }
    }();
    _running = run;
    await run;
    _running = null;
    notifyListeners();
  }

  /// Entscheidet, ob die gespeicherte Änderung einen Sicherungspunkt bekommt.
  Future<void> _checkpoint(TextlyDocument prev, TextlyDocument doc) async {
    final h = history;
    if (h == null) return;
    try {
      await _ready;
      final now = _clock();
      if (_skipNext) {
        _skipNext = false;
        _resetEdits();
        return;
      }
      final goneElements = deletedElements(prev, doc);
      final gone = [for (final e in goneElements) e.id];
      final pagesGone = [for (final p in prev.pages) if (!doc.pages.any((q) => q.id == p.id)) p.id];
      final big = gone.isEmpty && pagesGone.isEmpty ? bigChange(prev, doc) : null;
      // Dazwischen bearbeitet? Dann keine Löschungen zusammenfassen (Reihenfolge in der Liste bleibt richtig)
      final editedBetween = _editFrom != null;
      if (gone.isNotEmpty || pagesGone.isNotEmpty || big != null) {
        // Vorher Bearbeitetes nicht verlieren: als eigener Punkt (Stand direkt vor diesem Ereignis)
        await _recordEdits(prev);
      }
      if (gone.isNotEmpty || pagesGone.isNotEmpty) {
        final last = _lastDelete;
        final before = last?.before;
        if (last != null &&
            before != null &&
            !editedBetween &&
            now.difference(last.time) < deleteGroup &&
            pagesGone.isEmpty &&
            last.pages == 0 &&
            gone.every((id) => before.pages.any((p) => p.find(id) != null))) {
          // weitere Löschung kurz danach: gleicher Punkt (sein Stand enthält auch das jetzt Gelöschte)
          final ids = [...last.ids, ...gone];
          final subject = subjectOf([?last.subject, ...goneElements.map(elementCategory)]);
          await h.relabel(last.n, '${ids.length} Elemente wurden gelöscht', deleted: ids, doc: doc, subject: subject);
          _lastDelete = (n: last.n, time: now, ids: ids, pages: 0, before: before, subject: subject);
        } else {
          final subject = pagesGone.isNotEmpty ? 'page' : subjectOf(goneElements.map(elementCategory));
          final e = await h.record(doc,
              label: deletionLabel(prev, doc),
              kind: 'delete',
              session: _session,
              deleted: gone,
              deletedPages: pagesGone,
              subject: subject,
              before: prev);
          _lastDelete = (n: e.n, time: now, ids: gone, pages: pagesGone.length, before: prev, subject: subject);
        }
        _resetEdits();
        _changed();
        return;
      }
      if (big != null) {
        await h.record(doc, label: big.label, kind: 'big', session: _session, subject: big.subject);
        _lastDelete = null;
        _resetEdits();
        _changed();
        return;
      }
      // Kleine Bearbeitung: sammeln, nach einer Pause als ein Punkt ablegen
      _edited.addAll(editedElements(prev, doc));
      _pagesAdded += doc.pages.where((p) => !prev.pages.any((q) => q.id == p.id)).length;
      _editFrom ??= now;
      _pauseTimer?.cancel();
      _pauseTimer = Timer(pause, () => _recordEdits());
    } catch (_) {
      // Verlauf ist ein Zusatz; Speichern bleibt gültig
    }
  }

  void _resetEdits() {
    _pauseTimer?.cancel();
    _edited.clear();
    _pagesAdded = 0;
    _editFrom = null;
  }

  /// Angesammelte Bearbeitungen als Sicherungspunkt ablegen («Bearbeitet: 3 Texte, 1 Bild»).
  Future<void> _recordEdits([TextlyDocument? state]) async {
    final h = history;
    final from = _editFrom;
    if (h == null || from == null) return;
    final label = editSummary(_edited, pagesAdded: _pagesAdded);
    final subject = subjectOf([..._edited.values, if (_pagesAdded > 0) 'page']);
    _resetEdits();
    try {
      await h.record(state ?? _lastSaved, label: label, kind: 'edit', session: _session, from: from, subject: subject);
      _changed();
    } catch (_) {}
  }

  /// Sofort speichern (Strg+S, vor dem Weitergeben).
  Future<void> flush() async {
    _timer?.cancel();
    await _save();
  }

  /// Dokument wird verlassen: speichern und angesammelte Bearbeitungen als Punkt ablegen.
  Future<void> finish() async {
    await flush();
    await _recordEdits();
  }

  /// Weitergegeben (PDF, E-Mail, Datei): diesen Stand als Punkt festhalten.
  Future<void> recordShare(String label) async {
    final h = history;
    if (h == null) return;
    await flush();
    await _ready;
    _resetEdits();
    try {
      await h.record(_lastSaved, label: label, kind: 'share', session: _session);
      _changed();
    } catch (_) {}
  }

  /// Aktuellen Stand benennen («Entwurf für den Vorstand»).
  Future<void> nameCurrent(String name) async {
    final h = history;
    if (h == null || name.trim().isEmpty) return;
    await flush();
    await _ready;
    _resetEdits();
    await h.record(_lastSaved, label: 'Benannter Stand', kind: 'named', session: _session, name: name.trim());
    _changed();
  }

  /// Gespeicherten Punkt umbenennen bzw. Namen entfernen (leer).
  Future<void> renameEntry(int n, String name) async {
    await history?.mark(n, name: name);
    _changed();
  }

  /// Älteren Stand wiederherstellen: Bearbeitetes davor wird ein eigener Punkt, dann wird der alte Stand
  /// zum neuesten (Eintrag [label], z. B. «Stand vor «Titel wurde gelöscht» wiederhergestellt»; Strg+Z möglich).
  Future<void> restore(TextlyDocument old, String label) async {
    final h = history;
    await flush();
    await _ready;
    await _recordEdits();
    _lastDelete = null;
    _skipNext = true;
    controller.commit(old);
    await flush();
    // falls nichts gespeichert werden musste (gleicher Inhalt), wurde der Punkt nicht übersprungen
    _skipNext = false;
    if (h != null && state != SaveState.failed) {
      await h.record(old, label: label, kind: 'restore', session: _session);
      _changed();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pauseTimer?.cancel();
    controller.removeListener(_onChange);
    super.dispose();
  }
}
