import 'dart:convert';
import 'dart:typed_data';

import 'package:doc_exchange/doc_exchange.dart';
import 'package:doc_model/doc_model.dart';

import '../files/services.dart';

/// Ein Dokument in «Meine Dokumente».
class LibraryEntry {
  const LibraryEntry({required this.id, required this.name, required this.modified, this.customName = false, this.deletedAt, this.templateKind});

  final String id;

  /// Anzeigename. Ohne eigenen Namen ([customName]) folgt er dem Titel im Dokument.
  final String name;
  final bool customName;
  final DateTime modified;

  /// Im Papierkorb seit …; null = nicht gelöscht.
  final DateTime? deletedAt;

  bool get inTrash => deletedAt != null;

  /// Art der Vorlage (z. B. «einladung»); null = gewöhnliches Dokument.
  final String? templateKind;
  bool get isTemplate => templateKind != null;

  LibraryEntry copyWith({String? name, bool? customName, DateTime? modified, DateTime? deletedAt, bool restore = false}) => LibraryEntry(
        id: id,
        name: name ?? this.name,
        customName: customName ?? this.customName,
        modified: modified ?? this.modified,
        deletedAt: restore ? null : (deletedAt ?? this.deletedAt),
        templateKind: templateKind,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (customName) 'customName': true,
        'modified': modified.toIso8601String(),
        if (deletedAt != null) 'deletedAt': deletedAt!.toIso8601String(),
        if (templateKind != null) 'template': templateKind,
      };

  static LibraryEntry? tryFromJson(Object? j) {
    try {
      final m = j! as Map<String, dynamic>;
      return LibraryEntry(
        id: m['id'] as String,
        name: m['name'] as String,
        customName: m['customName'] as bool? ?? false,
        modified: DateTime.parse(m['modified'] as String),
        deletedAt: m['deletedAt'] == null ? null : DateTime.parse(m['deletedAt'] as String),
        templateKind: m['template'] as String?,
      );
    } catch (_) {
      return null; // beschädigter Eintrag: überspringen statt alles zu verlieren
    }
  }
}

/// «Meine Dokumente» ist gerade nicht lesbar (z. B. Ordner offline, Datei gesperrt). Es wird nichts
/// überschrieben; später nochmals versuchen.
class LibraryUnavailableException implements Exception {
  const LibraryUnavailableException();
  @override
  String toString() => '«Meine Dokumente» lässt sich gerade nicht lesen.';
}

/// Name aus dem Inhalt: erste Zeile des Titels, sonst des ersten Textes.
String autoDocumentName(TextlyDocument doc) {
  String? firstLine(TextBlock t) {
    final line = t.text.split('\n').map((l) => l.trim()).firstWhere((l) => l.isNotEmpty, orElse: () => '');
    return line.isEmpty ? null : line;
  }

  final texts = [for (final p in doc.pages) ...p.elements.whereType<TextBlock>()];
  for (final t in texts.where((t) => t.kind == TextKind.title)) {
    final l = firstLine(t);
    if (l != null) return _shorten(l);
  }
  for (final t in texts) {
    final l = firstLine(t);
    if (l != null) return _shorten(l);
  }
  return 'Unbenanntes Dokument';
}

String _shorten(String s) => s.length <= 60 ? s : '${s.substring(0, 57).trimRight()} …';

/// «Meine Dokumente»: alle Dokumente als .textly-Dateien in einem Ordner, dazu ein Verzeichnis
/// (bibliothek.json) mit Namen, Änderungszeit und Papierkorb. Der Ordner liegt sichtbar unter
/// Dokumente\Textly, damit die Dateien auch ohne Textly auffindbar bleiben.
///
/// Schreibvorgänge laufen nacheinander (eine Warteschlange), damit sich das Verzeichnis nie
/// gleichzeitig ändert.
class DocumentLibrary {
  DocumentLibrary(this.files, this.root, {required this.loadAsset, DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final FileAccess files;
  final String root;

  /// Bilder des Beispieldokuments (App-Assets), damit sie in die Datei eingebettet werden.
  final Future<Uint8List?> Function(String key) loadAsset;
  final DateTime Function() _clock;

  /// Wie lange gelöschte Dokumente im Papierkorb bleiben.
  static const trashDays = 30;

  String get _indexPath => '$root/bibliothek.json';
  String pathOf(String id) => '$root/$id.textly';

  Map<String, LibraryEntry>? _entries;
  Future<void> _queue = Future.value();

  /// Führt [job] nach allen vorherigen Schreibvorgängen aus.
  Future<T> _serial<T>(Future<T> Function() job) {
    final result = _queue.then((_) => job());
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// Wurde das Verzeichnis beim Laden aus den Dokumentdateien neu aufgebaut (weil es beschädigt war oder fehlte)?
  bool repaired = false;

  Future<Map<String, LibraryEntry>> _load() async {
    final known = _entries;
    if (known != null) return known;
    final map = <String, LibraryEntry>{};
    final Uint8List? bytes;
    try {
      bytes = await files.exists(_indexPath) ? await files.read(_indexPath) : null;
    } catch (_) {
      // Gerade nicht lesbar (Ordner offline, gesperrt …): nichts annehmen, nichts überschreiben, nichts merken
      throw const LibraryUnavailableException();
    }
    var broken = bytes == null;
    if (bytes != null) {
      try {
        final list = jsonDecode(utf8.decode(bytes)) as List;
        for (final j in list) {
          final e = LibraryEntry.tryFromJson(j);
          if (e != null) map[e.id] = e;
        }
      } catch (_) {
        broken = true;
        // beschädigt: Original zur Sicherheit aufbewahren
        try {
          await files.write('$root/bibliothek.defekt.json', bytes);
        } catch (_) {}
      }
    }
    if (broken) {
      // Verzeichnis fehlt oder ist beschädigt: aus den vorhandenen Dokumentdateien neu aufbauen
      final rebuilt = await _rebuild();
      if (rebuilt.isNotEmpty || bytes != null) {
        map.addAll(rebuilt);
        _entries = map;
        repaired = rebuilt.isNotEmpty;
        await _writeIndex();
      }
    }
    return _entries = map;
  }

  /// Einträge für alle .textly-Dateien im Ordner (Name aus dem Inhalt).
  Future<Map<String, LibraryEntry>> _rebuild() async {
    final out = <String, LibraryEntry>{};
    final List<String> paths;
    try {
      paths = await files.list(root);
    } catch (_) {
      return out;
    }
    for (final p in paths) {
      final name = p.split('/').last;
      if (!name.toLowerCase().endsWith('.textly')) continue;
      final id = name.substring(0, name.length - '.textly'.length);
      try {
        final doc = decodeTextly(await files.read(p));
        out[id] = LibraryEntry(id: id, name: autoDocumentName(doc), modified: _clock());
      } catch (_) {
        // unlesbare Datei: nicht aufnehmen, aber auch nicht löschen
      }
    }
    return out;
  }

  Future<void> _writeIndex() async {
    final list = [for (final e in _entries!.values) e.toJson()];
    await files.write(_indexPath, Uint8List.fromList(utf8.encode(const JsonEncoder.withIndent(' ').convert(list))));
  }

  /// Gibt es das Verzeichnis schon (also nicht der allererste Start)?
  Future<bool> get exists => files.exists(_indexPath);

  /// Dokumente, neueste zuerst; mit [trash] die gelöschten (auch Vorlagen), mit [templates] die Vorlagen.
  Future<List<LibraryEntry>> entries({bool trash = false, bool templates = false}) async {
    final all = await _load();
    final list = all.values.where((e) => e.inTrash == trash && (trash || e.isTemplate == templates)).toList()
      ..sort((a, b) => (trash ? b.deletedAt! : b.modified).compareTo(trash ? a.deletedAt! : a.modified));
    return list;
  }

  Future<LibraryEntry?> entry(String id) async => (await _load())[id];

  Future<TextlyDocument> load(String id) async => decodeTextly(await files.read(pathOf(id)));

  Future<Uint8List> _encode(TextlyDocument doc) async {
    final external = <String, Uint8List>{};
    for (final a in doc.usedAssetIds) {
      if (doc.assets.containsKey(a)) continue;
      final b = await loadAsset(a);
      if (b != null) external[a] = b;
    }
    return encodeTextly(doc, externalImage: (id) => external[id]);
  }

  /// Neues Dokument anlegen (mit [templateKind] eine Vorlage).
  Future<LibraryEntry> create(TextlyDocument doc, {String? name, String? templateKind}) => _serial(() async {
        final all = await _load();
        final e = LibraryEntry(
          id: newId('d'),
          name: name ?? autoDocumentName(doc),
          customName: name != null,
          modified: _clock(),
          templateKind: templateKind,
        );
        await files.write(pathOf(e.id), await _encode(doc));
        all[e.id] = e;
        await _writeIndex();
        return e;
      });

  /// Stand speichern (automatisch). Der Name folgt dem Titel, solange er nicht selbst gewählt ist.
  Future<LibraryEntry> save(String id, TextlyDocument doc) => _serial(() async {
        final all = await _load();
        final old = all[id];
        if (old == null) throw StateError('Dokument $id gibt es nicht');
        await files.write(pathOf(id), await _encode(doc));
        final e = old.copyWith(modified: _clock(), name: old.customName ? null : autoDocumentName(doc));
        all[id] = e;
        await _writeIndex();
        return e;
      });

  /// «Als Kopie verwenden»: neues Dokument mit gleichem Inhalt, das Original bleibt.
  Future<LibraryEntry> duplicate(String id) async {
    final doc = await load(id);
    final old = (await _load())[id];
    return create(doc, name: 'Kopie von ${old?.name ?? autoDocumentName(doc)}');
  }

  /// «Als Vorlage speichern»: Kopie des Dokuments als Vorlage; das Dokument selbst bleibt.
  Future<LibraryEntry> saveAsTemplate(String id, {required String name, required String kind}) async =>
      create(await load(id), name: name.trim().isEmpty ? null : name.trim(), templateKind: kind);

  Future<LibraryEntry> rename(String id, String name) => _serial(() async {
        final all = await _load();
        final trimmed = name.trim();
        final e = all[id]!.copyWith(name: trimmed.isEmpty ? null : trimmed, customName: trimmed.isNotEmpty);
        all[id] = trimmed.isEmpty ? e.copyWith(name: autoDocumentName(await load(id))) : e;
        await _writeIndex();
        return all[id]!;
      });

  Future<void> moveToTrash(String id) => _serial(() async {
        final all = await _load();
        all[id] = all[id]!.copyWith(deletedAt: _clock());
        await _writeIndex();
      });

  Future<void> restore(String id) => _serial(() async {
        final all = await _load();
        all[id] = all[id]!.copyWith(restore: true);
        await _writeIndex();
      });

  /// Endgültig löschen (nur aus dem Papierkorb).
  Future<void> deleteForever(String id) => _serial(() async {
        final all = await _load();
        await files.delete(pathOf(id));
        all.remove(id);
        await _writeIndex();
      });

  /// Dokumente, die länger als [trashDays] im Papierkorb liegen, endgültig entfernen.
  /// Ergibt ihre IDs (z. B. um auch ihren Verlauf zu löschen).
  Future<List<String>> purgeTrash() async {
    final limit = _clock().subtract(const Duration(days: trashDays));
    final old = [for (final e in await entries(trash: true)) if (e.deletedAt!.isBefore(limit)) e.id];
    for (final id in old) {
      await deleteForever(id);
    }
    return old;
  }
}
