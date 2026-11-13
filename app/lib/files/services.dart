import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:win32/win32.dart';

/// Dateidialoge des Betriebssystems (austauschbar für Tests).
abstract interface class FilePicker {
  Future<String?> pickOpen({required String label, required List<String> extensions});
  Future<String?> pickSave({required String suggestedName, required String label, required List<String> extensions});
}

class SystemFilePicker implements FilePicker {
  const SystemFilePicker();

  @override
  Future<String?> pickOpen({required String label, required List<String> extensions}) async =>
      (await openFile(acceptedTypeGroups: [XTypeGroup(label: label, extensions: extensions)]))?.path;

  @override
  Future<String?> pickSave({required String suggestedName, required String label, required List<String> extensions}) async =>
      (await getSaveLocation(suggestedName: suggestedName, acceptedTypeGroups: [XTypeGroup(label: label, extensions: extensions)]))
          ?.path;
}

/// Dateizugriff (austauschbar für Tests).
abstract interface class FileAccess {
  Future<Uint8List> read(String path);

  /// Schreibt sicher: zuerst in eine temporäre Datei, dann umbenennen. Bricht etwas ab,
  /// bleibt die bisherige Datei unversehrt.
  Future<void> write(String path, Uint8List bytes);
  Future<void> delete(String path);
  Future<bool> exists(String path);

  /// Pfade der Dateien direkt in [dir] (ohne Unterordner); leer, wenn es den Ordner nicht gibt.
  Future<List<String>> list(String dir);
}

class RealFileAccess implements FileAccess {
  const RealFileAccess();

  @override
  Future<Uint8List> read(String path) => File(path).readAsBytes();

  @override
  Future<void> write(String path, Uint8List bytes) async {
    final tmp = File('$path.speichern');
    await tmp.parent.create(recursive: true);
    try {
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(path);
    } catch (_) {
      // Hilfsdatei nicht liegen lassen (Ziel gesperrt, schreibgeschützt, Platte voll …)
      try {
        if (tmp.existsSync()) await tmp.delete();
      } catch (_) {}
      rethrow;
    }
  }

  @override
  Future<void> delete(String path) async {
    final f = File(path);
    if (await f.exists()) await f.delete();
  }

  @override
  Future<bool> exists(String path) => File(path).exists();

  @override
  Future<List<String>> list(String dir) async {
    final d = Directory(dir);
    if (!await d.exists()) return const [];
    return [await for (final e in d.list()) if (e is File) e.path.replaceAll('\\', '/')];
  }
}

/// Dateisystem im Speicher (Tests).
class MemoryFileAccess implements FileAccess {
  final files = <String, Uint8List>{};

  @override
  Future<Uint8List> read(String path) async {
    final b = files[path];
    if (b == null) throw FileSystemException('Datei nicht gefunden', path);
    return b;
  }

  @override
  Future<void> write(String path, Uint8List bytes) async => files[path] = bytes;
  @override
  Future<void> delete(String path) async => files.remove(path);
  @override
  Future<bool> exists(String path) async => files.containsKey(path);

  @override
  Future<List<String>> list(String dir) async =>
      [for (final p in files.keys) if (p.startsWith('$dir/') && !p.substring(dir.length + 1).contains('/')) p];
}

/// Stand zum Wiederherstellen nach einem Absturz.
class RecoveryInfo {
  RecoveryInfo(this.bytes, this.originalPath, this.savedAt);
  final Uint8List bytes;
  final String? originalPath;
  final DateTime savedAt;
}

/// Sicherung im Hintergrund: Textly schreibt ungespeicherte Änderungen regelmässig in den
/// Datenordner der App. Wird die App normal beendet oder das Dokument gespeichert, wird die
/// Sicherung gelöscht. Ist sie beim Start noch da, ist die App abgestürzt.
class RecoveryStore {
  RecoveryStore(this.files, this.directory);
  final FileAccess files;
  final String directory;

  String get _doc => '$directory${Platform.pathSeparator}wiederherstellung.textly';
  String get _meta => '$directory${Platform.pathSeparator}wiederherstellung.json';

  Future<void> write(Uint8List bytes, {String? originalPath}) async {
    await files.write(_doc, bytes);
    await files.write(
      _meta,
      Uint8List.fromList(utf8.encode(jsonEncode({'path': originalPath, 'savedAt': DateTime.now().toIso8601String()}))),
    );
  }

  Future<RecoveryInfo?> read() async {
    if (!await files.exists(_doc) || !await files.exists(_meta)) return null;
    try {
      final meta = jsonDecode(utf8.decode(await files.read(_meta))) as Map<String, dynamic>;
      return RecoveryInfo(await files.read(_doc), meta['path'] as String?, DateTime.parse(meta['savedAt'] as String));
    } catch (_) {
      return null;
    }
  }

  Future<void> clear() async {
    await files.delete(_doc);
    await files.delete(_meta);
  }
}

/// Sicherungsordner für dieses Fenster. Jede laufende Textly-Instanz hält einen eigenen Unterordner
/// (1, 2, …) mit einer Dateisperre fest, damit sich zwei Fenster nicht gegenseitig Sicherungen
/// anbieten, überschreiben oder löschen. Der erste freie Ordner gehört diesem Fenster; liegt dort
/// eine Sicherung, stammt sie von einer abgestürzten Instanz.
Future<String> claimRecoveryDirectory(String base) async {
  final sep = Platform.pathSeparator;
  for (var i = 1; i <= 50; i++) {
    final dir = Directory('$base$sep$i');
    try {
      await dir.create(recursive: true);
      final lock = await File('${dir.path}${sep}belegt.lock').open(mode: FileMode.append);
      try {
        await lock.lock(FileLock.exclusive);
        _heldRecoveryLocks.add(lock); // bleibt offen, bis das Programm endet
        return dir.path;
      } on FileSystemException {
        await lock.close(); // von einem anderen Fenster belegt
      }
    } on FileSystemException {
      continue;
    }
  }
  return base;
}

final _heldRecoveryLocks = <RandomAccessFile>[];

/// Alles, was die App von aussen braucht – in Tests durch Attrappen ersetzt.
class AppServices {
  AppServices({
    this.picker = const SystemFilePicker(),
    FileAccess? files,
    this.recovery,
    Future<Uint8List?> Function(String key)? loadAsset,
    this.setWindowTitle = setNativeWindowTitle,
  })  : files = files ?? const RealFileAccess(),
        loadAsset = loadAsset ?? _bundleAsset;

  final FilePicker picker;
  final FileAccess files;
  final RecoveryStore? recovery;

  /// Bilder des Beispieldokuments (App-Assets) zum Einbetten beim Speichern.
  final Future<Uint8List?> Function(String key) loadAsset;
  final void Function(String title) setWindowTitle;

  static Future<Uint8List?> _bundleAsset(String key) async {
    try {
      final d = await rootBundle.load(key);
      return d.buffer.asUint8List(d.offsetInBytes, d.lengthInBytes);
    } catch (_) {
      return null;
    }
  }
}

/// Fenstertitel unter Windows setzen («Name • – Textly»). Sucht das eigene Flutter-Fenster.
void setNativeWindowTitle(String title) {
  if (!Platform.isWindows) return;
  using((arena) {
    final cls = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16(allocator: arena);
    final pid = arena<Uint32>();
    var hwnd = 0;
    while (true) {
      hwnd = FindWindowEx(0, hwnd, cls, nullptr);
      if (hwnd == 0) return;
      GetWindowThreadProcessId(hwnd, pid);
      if (pid.value == GetCurrentProcessId()) {
        SetWindowText(hwnd, title.toNativeUtf16(allocator: arena));
        return;
      }
    }
  });
}
