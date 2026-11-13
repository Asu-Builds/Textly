import 'dart:convert';
import 'dart:io' show FileSystemException, gzip;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:doc_model/doc_model.dart';

import '../files/services.dart';

/// Ein gespeicherter Stand im Verlauf.
class HistoryEntry {
  const HistoryEntry({
    required this.n,
    required this.time,
    required this.label,
    required this.kind,
    required this.session,
    this.milestone,
    this.name,
    this.assets = const [],
    this.from,
    this.deleted = const [],
    this.deletedPages = const [],
    this.subject,
  });

  /// Was betroffen ist: «text», «image», «rect», «line», «page», «doc» (Format) oder «mixed»; sonst null.
  final String? subject;

  /// Bei Löschungen: welche Elemente bzw. Seiten dieser Punkt betrifft (gestrichelt in der Vorschau).
  final List<String> deleted;
  final List<String> deletedPages;

  /// Beginn eines Arbeitsabschnitts («Bearbeitet … 14:05 – 14:30»); sonst null.
  final DateTime? from;

  /// Laufende Nummer (aufsteigend, nie wiederverwendet).
  final int n;
  final DateTime time;

  /// Was sich gegenüber dem vorherigen Stand geändert hat («Text «Anmeldung» gelöscht»).
  final String label;

  /// Art der Änderung (ChangeKind.name), z. B. «delete» für rote Markierung.
  final String kind;

  /// Sitzung (einmal Öffnen bis Schliessen).
  final int session;

  /// Automatischer Meilenstein («Vor dem Drucken», «Geöffnet»).
  final String? milestone;

  /// Vom Benutzer vergebener Name («Entwurf für den Vorstand»).
  final String? name;

  /// Bilddateien, die dieser Stand braucht (zum Aufräumen beim Ausdünnen).
  final List<String> assets;

  bool get kept => milestone != null || name != null;

  HistoryEntry copyWith(
          {String? milestone,
          String? name,
          bool clearName = false,
          String? label,
          List<String>? deleted,
          List<String>? assets,
          String? subject}) =>
      HistoryEntry(
        n: n,
        time: time,
        from: from,
        label: label ?? this.label,
        kind: kind,
        session: session,
        milestone: milestone ?? this.milestone,
        name: clearName ? null : (name ?? this.name),
        assets: assets ?? this.assets,
        deleted: deleted ?? this.deleted,
        deletedPages: deletedPages,
        subject: subject ?? this.subject,
      );

  Map<String, dynamic> toJson() => {
        'n': n,
        't': time.toIso8601String(),
        'label': label,
        'kind': kind,
        's': session,
        if (milestone != null) 'milestone': milestone,
        if (name != null) 'name': name,
        if (assets.isNotEmpty) 'assets': assets,
        if (from != null) 'from': from!.toIso8601String(),
        if (deleted.isNotEmpty) 'del': deleted,
        if (deletedPages.isNotEmpty) 'delp': deletedPages,
        if (subject != null) 'sub': subject,
      };

  static HistoryEntry? tryFromJson(Object? j) {
    try {
      final m = j! as Map<String, dynamic>;
      return HistoryEntry(
        n: m['n'] as int,
        time: DateTime.parse(m['t'] as String),
        label: m['label'] as String,
        kind: m['kind'] as String? ?? 'other',
        session: m['s'] as int,
        milestone: m['milestone'] as String?,
        name: m['name'] as String?,
        assets: [for (final a in (m['assets'] as List?) ?? const []) a as String],
        from: m['from'] == null ? null : DateTime.parse(m['from'] as String),
        deleted: [for (final a in (m['del'] as List?) ?? const []) a as String],
        deletedPages: [for (final a in (m['delp'] as List?) ?? const []) a as String],
        subject: m['sub'] as String?,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Verlauf eines Dokuments, ausserhalb des Dokuments gespeichert (unter `%LOCALAPPDATA%\Textly\Verlauf\<id>`):
/// - verzeichnis.json: alle Stände,
/// - `staende/<n>.json.gz`: der Stand *nach* dem Ereignis als komprimiertes JSON (ohne Bilddaten),
/// - `staende/<n>.vorher.json.gz`: bei Löschungen der Stand davor (zeigt, was gelöscht wurde),
/// - `bilder/<id>`: jede Bilddatei einmal.
///
/// So gelangt nichts aus dem Verlauf in weitergegebene Dateien, und jeder Stand lässt sich
/// direkt lesen (keine Kette von Änderungen, die bei einem Fehler bräche).
class HistoryStore {
  HistoryStore(this.files, this.dir, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final FileAccess files;
  final String dir;
  final DateTime Function() _clock;

  String get _indexPath => '$dir/verzeichnis.json';
  String _statePath(int n) => '$dir/staende/$n.json.gz';
  String _beforePath(int n) => '$dir/staende/$n.vorher.json.gz';
  String _blobPath(String asset) => '$dir/bilder/${asset.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_')}';

  List<HistoryEntry>? _entries;
  Future<void> _queue = Future.value();

  Future<T> _serial<T>(Future<T> Function() job) {
    final r = _queue.then((_) => job());
    _queue = r.then((_) {}, onError: (_) {});
    return r;
  }

  /// Kleinste Nummer für den nächsten Stand (nach einem beschädigten Verzeichnis: hinter allen vorhandenen
  /// Ständen, damit keiner überschrieben wird).
  int _minNext = 1;

  Future<List<HistoryEntry>> _load() async {
    final known = _entries;
    if (known != null) return known;
    final list = <HistoryEntry>[];
    final Uint8List? raw;
    try {
      raw = await files.exists(_indexPath) ? await files.read(_indexPath) : null;
    } catch (_) {
      // gerade nicht lesbar: nichts merken und nichts überschreiben (der Verlauf ist ein Zusatz)
      throw const FileSystemException('Verlauf gerade nicht lesbar');
    }
    if (raw != null) {
      try {
        final json = jsonDecode(utf8.decode(raw));
        if (json is List || json is Map && json['v'] != 3) {
          // ältere Formate (Stand davor statt danach): ersetzt, alte Stände entfernen
          for (final j in json is List ? json : (json as Map)['entries'] as List) {
            final e = HistoryEntry.tryFromJson(j);
            if (e == null) continue;
            await files.delete(_statePath(e.n));
            await files.delete(_beforePath(e.n));
            for (final a in e.assets) {
              await files.delete(_blobPath(a));
            }
          }
          await files.delete(_indexPath);
        } else {
          for (final j in (json as Map<String, dynamic>)['entries'] as List) {
            final e = HistoryEntry.tryFromJson(j);
            if (e != null) list.add(e);
          }
        }
      } catch (_) {
        // beschädigtes Verzeichnis: Original aufbewahren; neue Stände hinter allen vorhandenen nummerieren
        try {
          await files.write('$dir/verzeichnis.defekt.json', raw);
        } catch (_) {}
        try {
          for (final p in await files.list('$dir/staende')) {
            final n = int.tryParse(p.split('/').last.split('.').first);
            if (n != null && n >= _minNext) _minNext = n + 1;
          }
        } catch (_) {}
      }
    }
    list.sort((a, b) => a.n.compareTo(b.n));
    return _entries = list;
  }

  Future<void> _writeIndex() => files.write(
        _indexPath,
        Uint8List.fromList(utf8.encode(jsonEncode({'v': 3, 'entries': [for (final e in _entries!) e.toJson()]}))),
      );

  /// Alle Stände, ältester zuerst.
  Future<List<HistoryEntry>> entries() async => List.unmodifiable(await _load());

  /// Nächste Sitzungsnummer (beim Öffnen).
  Future<int> newSession() async {
    final all = await _load();
    return all.isEmpty ? 1 : all.map((e) => e.session).reduce((a, b) => a > b ? a : b) + 1;
  }

  /// Neuen Stand ablegen: [doc] ist der Stand nach dem Ereignis; [before] (bei Löschungen) der Stand davor.
  Future<HistoryEntry> record(TextlyDocument doc,
          {required String label,
          required String kind,
          required int session,
          String? milestone,
          String? name,
          DateTime? from,
          List<String> deleted = const [],
          List<String> deletedPages = const [],
          String? subject,
          TextlyDocument? before}) =>
      _serial(() async {
        final all = await _load();
        final n = math.max(all.isEmpty ? 1 : all.last.n + 1, _minNext);
        await _writeState(_statePath(n), doc);
        if (before != null) await _writeState(_beforePath(n), before);
        final e = HistoryEntry(
          n: n,
          time: _clock(),
          label: label,
          kind: kind,
          session: session,
          milestone: milestone,
          name: name,
          from: from,
          deleted: deleted,
          deletedPages: deletedPages,
          subject: subject,
          assets: {...doc.assets.keys, ...?before?.assets.keys}.toList(),
        );
        all.add(e);
        await _writeIndex();
        return e;
      });

  Future<void> _writeState(String path, TextlyDocument doc) async {
    for (final a in doc.assets.values) {
      final p = _blobPath(a.id);
      if (!await files.exists(p)) await files.write(p, a.bytes);
    }
    await files.write(path, Uint8List.fromList(gzip.encode(utf8.encode(jsonEncode(doc.toJson())))));
  }

  /// Einen Stand lesen (mit seinen Bildern).
  Future<TextlyDocument> load(int n) => _read(_statePath(n));

  /// Bei Löschungen: der Stand davor (sonst null).
  Future<TextlyDocument?> loadBefore(int n) async => await files.exists(_beforePath(n)) ? _read(_beforePath(n)) : null;

  Future<TextlyDocument> _read(String path) async {
    final json = jsonDecode(utf8.decode(gzip.decode(await files.read(path)))) as Map<String, dynamic>;
    final bytes = <String, Uint8List>{};
    for (final a in (json['assets'] as List?) ?? const []) {
      final id = (a as Map<String, dynamic>)['id'] as String;
      bytes[id] = await files.read(_blobPath(id));
    }
    return TextlyDocument.fromJson(json, assetBytes: bytes);
  }

  /// Meilenstein bzw. Namen setzen; mit leerem [name] wird der Name entfernt.
  Future<void> mark(int n, {String? milestone, String? name}) => _serial(() async {
        final all = await _load();
        final i = all.indexWhere((e) => e.n == n);
        if (i < 0) return;
        final clear = name != null && name.trim().isEmpty;
        all[i] = all[i].copyWith(milestone: milestone, name: clear ? null : name?.trim(), clearName: clear);
        await _writeIndex();
      });

  /// Beschriftung ändern, bei mehreren Löschungen kurz nacheinander auch den Stand danach ersetzen
  /// («3 Elemente wurden gelöscht»).
  Future<void> relabel(int n, String label, {List<String>? deleted, TextlyDocument? doc, String? subject}) => _serial(() async {
        final all = await _load();
        final i = all.indexWhere((e) => e.n == n);
        if (i < 0) return;
        if (doc != null) await _writeState(_statePath(n), doc);
        all[i] = all[i].copyWith(
          label: label,
          deleted: deleted,
          subject: subject,
          assets: doc == null ? null : {...all[i].assets, ...doc.assets.keys}.toList(),
        );
        await _writeIndex();
      });

  /// Sicherungspunkte älter als [keepDays] Tage entfernen; benannte Stände und der neueste bleiben.
  /// Ergibt die Zahl der entfernten Stände.
  Future<int> thin({int keepDays = 30}) => _serial(() async {
        final all = await _load();
        if (all.isEmpty) return 0;
        final limit = _clock().subtract(Duration(days: keepDays));
        final newest = all.last.n;
        final removed = [for (final e in all) if (e.n != newest && e.name == null && e.time.isBefore(limit)) e];
        if (removed.isEmpty) return 0;
        for (final e in removed) {
          await files.delete(_statePath(e.n));
          await files.delete(_beforePath(e.n));
        }
        all.removeWhere((e) => removed.contains(e));
        final used = {for (final e in all) ...e.assets};
        for (final a in {for (final e in removed) ...e.assets}.difference(used)) {
          await files.delete(_blobPath(a));
        }
        await _writeIndex();
        return removed.length;
      });

  /// Ganzen Verlauf löschen (Dokument endgültig gelöscht).
  Future<void> deleteAll() => _serial(() async {
        final all = await _load();
        for (final e in all) {
          await files.delete(_statePath(e.n));
          await files.delete(_beforePath(e.n));
        }
        for (final a in {for (final e in all) ...e.assets}) {
          await files.delete(_blobPath(a));
        }
        await files.delete(_indexPath);
        all.clear();
      });
}
