import 'dart:async';
import 'dart:typed_data';

import 'package:doc_exchange/doc_exchange.dart';
import 'package:doc_model/doc_model.dart';
import 'package:doc_render/doc_render.dart';
import 'package:flutter/material.dart';

import '../editor/editor_controller.dart';
import '../images/image_import.dart';
import 'services.dart';

/// Datei-Befehle der Hauptansicht: Neu, Öffnen, Speichern, Speichern unter, PowerPoint öffnen
/// und exportieren, Wiederherstellung nach Absturz, Rückfrage bei ungespeicherten Änderungen.
class FileCommands {
  FileCommands(this.c, this.services, this._context);

  final EditorController c;
  final AppServices services;
  final BuildContext Function() _context;

  Timer? _recoveryTimer;
  TextlyDocument? _recoveredDoc;

  BuildContext get context => _context();

  void _snack(String text) {
    final ctx = context;
    if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(text)));
  }

  /// Bilder, die nicht im Dokument liegen (Beispieldokument), für das Einbetten vorladen.
  Future<Map<String, Uint8List>> _externalImages(TextlyDocument doc) async {
    final out = <String, Uint8List>{};
    for (final id in doc.usedAssetIds) {
      if (doc.assets.containsKey(id)) continue;
      final b = await services.loadAsset(id);
      if (b != null) out[id] = b;
    }
    return out;
  }

  // ---------- Speichern ----------

  /// Speichern; ohne Dateiname oder mit [saveAs] erst Dateidialog. Ergibt false bei Abbruch oder Fehler.
  Future<bool> save({bool saveAs = false}) async {
    // Nur ein Speichervorgang zur Zeit (z. B. gedrückt gehaltenes Strg+S)
    if (_saving) return false;
    _saving = true;
    try {
      return await _save(saveAs: saveAs);
    } finally {
      _saving = false;
    }
  }

  bool _saving = false;

  Future<bool> _save({required bool saveAs}) async {
    c.finishEditing();
    var path = c.filePath;
    if (saveAs || path == null) {
      path = await services.picker.pickSave(
        suggestedName: '${c.displayName}.$textlyExtension',
        label: 'Textly-Dokument',
        extensions: const [textlyExtension],
      );
      if (path == null) return false;
      if (!path.toLowerCase().endsWith('.$textlyExtension')) path = '$path.$textlyExtension';
    }
    try {
      final doc = c.doc;
      final external = await _externalImages(doc);
      final bytes = encodeTextly(doc, externalImage: (id) => external[id]);
      await services.files.write(path, bytes);
      c.markSaved(path, doc);
      // Sicherung nur löschen, wenn während des Schreibens nichts mehr geändert wurde
      if (!c.isDirty) await services.recovery?.clear();
      _snack('Gespeichert: ${c.displayName}');
      return true;
    } catch (e) {
      debugPrint('Speichern: $e');
      _snack('Das Dokument konnte nicht gespeichert werden. Ist die Datei noch in einem anderen Programm geöffnet?');
      return false;
    }
  }

  // ---------- Rückfrage ----------

  /// Vor dem Verwerfen des aktuellen Dokuments: bei ungespeicherten Änderungen fragen.
  /// Ergibt true, wenn weitergemacht werden darf (gespeichert oder bewusst verworfen).
  Future<bool> confirmDiscard() async {
    c.finishEditing();
    if (!c.isDirty) return true;
    final choice = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text('Änderungen an «${c.displayName}» speichern?'),
        content: const Text('Sonst gehen die Änderungen seit dem letzten Speichern verloren.'),
        actions: [
          TextButton(key: const ValueKey('discard-cancel'), onPressed: () => Navigator.pop(ctx, 'cancel'), child: const Text('Abbrechen')),
          TextButton(key: const ValueKey('discard-no'), onPressed: () => Navigator.pop(ctx, 'discard'), child: const Text('Nicht speichern')),
          FilledButton(key: const ValueKey('discard-save'), onPressed: () => Navigator.pop(ctx, 'save'), child: const Text('Speichern')),
        ],
      ),
    );
    return switch (choice) {
      'save' => await save(),
      'discard' => true,
      _ => false,
    };
  }

  // ---------- Neu, Öffnen ----------

  Future<void> newDocument() async {
    if (!await confirmDiscard()) return;
    c.replaceDocument(TextlyDocument(pages: [DocPage(id: newId('p'))]));
    await services.recovery?.clear();
  }

  Future<void> open() async {
    if (!await confirmDiscard()) return;
    final path = await services.picker.pickOpen(label: 'Textly-Dokument', extensions: const [textlyExtension]);
    if (path == null) return;
    await openPath(path);
  }

  /// Öffnet [path] ohne Dialog (z. B. Doppelklick auf eine .textly-Datei im Explorer).
  Future<void> openPath(String path) async {
    try {
      final doc = decodeTextly(await services.files.read(path));
      c.replaceDocument(doc, path: path);
      await services.recovery?.clear();
    } on TextlyFileException catch (e) {
      _snack(e.message);
    } catch (e) {
      debugPrint('Öffnen: $e');
      _snack('Die Datei lässt sich nicht öffnen. Vielleicht ist sie beschädigt oder keine Textly-Datei.');
    }
  }

  // ---------- PowerPoint ----------

  Future<void> importPowerPoint() async {
    if (!await confirmDiscard()) return;
    final path = await services.picker.pickOpen(label: 'PowerPoint-Präsentation', extensions: const ['pptx']);
    if (path == null) return;
    try {
      final r = importPptx(await services.files.read(path), prepareImage: (b) => prepareImageSync(b));
      final name = path.split(RegExp(r'[\\/]')).last.replaceFirst(RegExp(r'\.pptx$', caseSensitive: false), '');
      // Ungespeichert: Beim Speichern entsteht eine .textly-Datei, die PowerPoint-Datei bleibt unberührt.
      c.replaceDocument(r.document, untitled: name, dirty: true);
      if (r.notes.isNotEmpty && context.mounted) {
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('PowerPoint-Datei geöffnet'),
            content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Nicht alles liess sich übernehmen:'),
              const SizedBox(height: 8),
              for (final n in r.notes) Text('• $n'),
            ]),
            actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
          ),
        );
      }
    } on PptxImportException catch (e) {
      _snack(e.message);
    } catch (e) {
      debugPrint('PowerPoint öffnen: $e');
      _snack('Die PowerPoint-Datei lässt sich nicht öffnen. Vielleicht ist sie beschädigt.');
    }
  }

  Future<void> exportPowerPoint() async {
    c.finishEditing();
    final path = await services.picker.pickSave(
      suggestedName: '${c.displayName}.pptx',
      label: 'PowerPoint-Präsentation',
      extensions: const ['pptx'],
    );
    if (path == null) return;
    final target = path.toLowerCase().endsWith('.pptx') ? path : '$path.pptx';
    try {
      final doc = c.doc;
      final external = await _externalImages(doc);
      final bytes = exportPptx(doc, boxOf: renderedBox, externalImage: (id) => external[id], rowHeightsOf: tableRowHeights);
      await services.files.write(target, bytes);
      _snack('Als PowerPoint gespeichert');
    } catch (e) {
      debugPrint('PowerPoint speichern: $e');
      _snack('Die PowerPoint-Datei konnte nicht gespeichert werden. Ist sie noch in PowerPoint geöffnet?');
    }
  }

  // ---------- Wiederherstellung ----------

  /// Nach jeder Änderung: einige Sekunden später ungespeicherte Änderungen sichern.
  void scheduleRecovery({Duration delay = const Duration(seconds: 3)}) {
    final store = services.recovery;
    if (store == null) return;
    _recoveryTimer?.cancel();
    if (!c.isDirty) return;
    _recoveryTimer = Timer(delay, () async {
      final doc = c.history.present;
      if (identical(doc, _recoveredDoc) || !c.isDirty) return;
      try {
        final external = await _externalImages(doc);
        await store.write(encodeTextly(doc, externalImage: (id) => external[id]), originalPath: c.filePath);
        _recoveredDoc = doc;
      } catch (_) {
        // Sicherung ist ein Zusatz; Fehler hier dürfen die Arbeit nicht stören.
      }
    });
  }

  /// Beim Start: Gibt es eine Sicherung (App wurde nicht normal beendet)? Dann fragen.
  Future<void> offerRecovery() async {
    final store = services.recovery;
    if (store == null) return;
    final info = await store.read();
    if (info == null || !context.mounted) return;
    final restore = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Ungespeicherte Änderungen gefunden'),
        content: Text(
          'Textly wurde nicht normal beendet. Es gibt einen gesicherten Stand vom '
          '${_time(info.savedAt)}${info.originalPath == null ? '' : ' für «${info.originalPath!.split(RegExp(r'[\\/]')).last}»'}.\n\n'
          'Soll dieser Stand wiederhergestellt werden?',
        ),
        actions: [
          TextButton(key: const ValueKey('recovery-discard'), onPressed: () => Navigator.pop(ctx, false), child: const Text('Verwerfen')),
          FilledButton(key: const ValueKey('recovery-restore'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Wiederherstellen')),
        ],
      ),
    );
    if (restore == true) {
      try {
        c.replaceDocument(decodeTextly(info.bytes), path: info.originalPath, untitled: 'Wiederhergestellt', dirty: true);
        return; // Sicherung bleibt, bis gespeichert wird
      } catch (_) {
        _snack('Der gesicherte Stand ist beschädigt und konnte nicht wiederhergestellt werden.');
      }
    }
    await store.clear();
  }

  /// Beim Beenden ohne ungespeicherte Änderungen: Sicherung entfernen.
  Future<void> clearRecovery() async {
    _recoveryTimer?.cancel();
    await services.recovery?.clear();
  }

  static String _time(DateTime t) =>
      '${t.day}.${t.month}.${t.year}, ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')} Uhr';

  void dispose() => _recoveryTimer?.cancel();
}
