import 'document.dart';

/// Verlauf für Rückgängig/Wiederholen.
///
/// Da das Dokument unveränderlich ist, speichert der Verlauf einfach die Dokumentstände.
/// Unveränderte Seiten und Elemente werden zwischen den Ständen geteilt; ein Schritt kostet
/// deshalb nur so viel Speicher wie die tatsächliche Änderung.
class History {
  History(TextlyDocument initial, {this.limit = 200}) : _present = initial;

  final int limit;
  final List<TextlyDocument> _past = [];
  final List<TextlyDocument> _future = [];
  TextlyDocument _present;
  Object? _mergeKey;

  TextlyDocument get present => _present;
  bool get canUndo => _past.isNotEmpty;
  bool get canRedo => _future.isNotEmpty;
  int get undoDepth => _past.length;

  /// Zählt jede Änderung des aktuellen Stands (neuer Schritt, Rückgängig, Wiederholen, Zurücksetzen).
  /// Anders als [undoDepth] auch dann eindeutig, wenn die Schrittliste voll ist.
  int get version => _version;
  var _version = 0;

  /// Übernimmt einen neuen Stand als einen Schritt.
  ///
  /// Mit [mergeKey] werden aufeinanderfolgende Änderungen mit demselben Schlüssel zu einem Schritt
  /// zusammengefasst (z. B. mehrmaliges Verschieben mit den Pfeiltasten).
  void push(TextlyDocument next, {Object? mergeKey}) {
    if (identical(next, _present)) return;
    _version++;
    if (mergeKey != null && mergeKey == _mergeKey && _past.isNotEmpty) {
      _present = next;
      _future.clear();
      return;
    }
    _past.add(_present);
    if (_past.length > limit) _past.removeAt(0);
    _present = next;
    _future.clear();
    _mergeKey = mergeKey;
  }

  /// Beendet eine laufende Zusammenfassung, damit die nächste Änderung ein eigener Schritt wird.
  void breakMerge() => _mergeKey = null;

  bool undo() {
    if (!canUndo) return false;
    _future.add(_present);
    _present = _past.removeLast();
    _mergeKey = null;
    _version++;
    return true;
  }

  bool redo() {
    if (!canRedo) return false;
    _past.add(_present);
    _present = _future.removeLast();
    _mergeKey = null;
    _version++;
    return true;
  }

  /// Ersetzt den Stand ohne Verlaufseintrag (z. B. nach dem Öffnen einer Datei).
  void reset(TextlyDocument doc) {
    _past.clear();
    _future.clear();
    _present = doc;
    _mergeKey = null;
    _version++;
  }
}
