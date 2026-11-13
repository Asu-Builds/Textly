import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show AppExitResponse;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:doc_exchange/doc_exchange.dart';
import 'package:doc_model/doc_model.dart';
import 'package:doc_render/doc_render.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:printing/printing.dart';

import '../files/file_commands.dart';
import '../files/services.dart';
import '../images/image_import.dart';
import '../images/windows_clipboard.dart';
import '../history/history_view.dart';
import '../library/autosave.dart';
import '../library/template_dialog.dart';
import '../links.dart';

import 'doc_name.dart';
import 'editor_canvas.dart';
import 'editor_controller.dart';
import 'preview_page.dart';
import 'properties_panel.dart';
import 'toolbar_widgets.dart';

const _line = Ui.line;

/// Hauptansicht: Werkzeugleiste oben, Seiten links, Arbeitsfläche Mitte, Eigenschaften rechts
/// (Spezifikation 6).
class EditorPage extends StatefulWidget {
  EditorPage({super.key, required this.controller, AppServices? services, this.fitOnStart = false, this.startupFile, this.session})
    : services = services ?? AppServices();

  /// Dokument aus «Meine Dokumente»: speichert automatisch, kein Speichern-Knopf, Teilen statt Datei-Menü.
  /// Ohne Sitzung arbeitet der Editor mit Dateien (Speichern, Öffnen, Wiederherstellung).
  final AutosaveSession? session;

  /// Beim Start zu öffnende Datei (Doppelklick im Explorer, «Öffnen mit»).
  final String? startupFile;

  /// Beim Start so zoomen, dass die ganze Seite sichtbar ist (in der App; Tests rechnen mit 120 %).
  final bool fitOnStart;
  final EditorController controller;

  /// Dateidialoge, Dateizugriff, Wiederherstellung (in Tests Attrappen).
  final AppServices services;

  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  EditorController get c => widget.controller;
  double zoom = 1.2;

  /// Ganze Seite zeigen, auch nach Grössenänderungen – bis von Hand gezoomt wird.
  late bool _autoFit = widget.fitOnStart;
  Size? _lastArea;

  /// Arbeitsfläche: scrollt zu neu eingefügten Elementen.
  final _canvasScroll = ScrollController();
  int _seenInserts = 0;

  /// Neues Element sichtbar machen (nur wenn es ausserhalb des sichtbaren Bereichs liegt).
  void _revealSelected() {
    final e = c.selected;
    if (e == null || !_canvasScroll.hasClients) return;
    final r = elementRectPt(e);
    final pos = _canvasScroll.position;
    final top = 32 + r.top * zoom, bottom = 32 + r.bottom * zoom;
    if (top >= pos.pixels && bottom <= pos.pixels + pos.viewportDimension) return;
    final target = (top - pos.viewportDimension / 3).clamp(0.0, pos.maxScrollExtent);
    _canvasScroll.animateTo(target, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
  }
  bool busy = false;
  final _rootFocus = FocusNode(debugLabel: 'Editor');
  bool _wasEditing = false;

  /// Zeitstrahl des Verlaufs unten eingeblendet.
  bool _history = false;
  late PageOrientation _orientation = c.doc.orientation;
  late PaperSize _paper = c.doc.paper;
  final _canvasKey = GlobalKey();
  bool _dropHover = false;
  /// Laufende Bild-Importe (mehrere gleichzeitig möglich).
  int _imports = 0;
  bool get _importing => _imports > 0;

  /// Arbeitsbereich; seine Grösse braucht «Ganze Seite».
  final _areaKey = GlobalKey();
  Size? get _viewport => _areaKey.currentContext?.size;
  // Das Element selbst weitergeben: Nach dem Schliessen meldet es mounted == false,
  // während State.context dann eine Ausnahme wirft.
  late final BuildContext _self;
  late final FileCommands files = FileCommands(c, widget.services, () => _self);
  late final AppLifecycleListener _exitListener;
  String _title = '';

  @override
  void initState() {
    super.initState();
    _self = context;
    c.addListener(_onDocumentChanged);
    _onDocumentChanged();
    c.onDeleted = (e) {
      if (!mounted) return;
      c.offerUndo();
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          key: const ValueKey('deleted-snack'),
          content: Text('${switch (e) {
            TextBlock _ => 'Text',
            ImageBlock _ => 'Bild',
            TableBlock _ => 'Tabelle',
            RectShape _ => 'Fläche',
            LineShape _ => 'Linie',
          }} gelöscht.'),
          action: SnackBarAction(label: 'Rückgängig', onPressed: c.undoOffered),
          persist: false,
          duration: const Duration(seconds: 6),
        ));
    };
    // Fenster schliessen: bei ungespeicherten Änderungen fragen (Spezifikation 7.3)
    _exitListener = AppLifecycleListener(
      onExitRequested: () async {
        if (widget.session != null) {
          // gespeichert wird automatisch; nur wenn das nicht geklappt hat, nachfragen
          return await _ensureSaved() ? AppExitResponse.exit : AppExitResponse.cancel;
        }
        final ok = await files.confirmDiscard();
        if (ok) await files.clearRecovery();
        return ok ? AppExitResponse.exit : AppExitResponse.cancel;
      },
    );
    // Beim Start: ganze Seite zeigen, Sicherung nach Absturz anbieten
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (widget.fitOnStart && mounted) _fitPage();
      final f = widget.startupFile;
      if (f != null) {
        await files.openPath(f);
        if (widget.fitOnStart && mounted) _fitPage(); // Format der Datei kann quer sein
      }
      if (widget.session == null) await files.offerRecovery();
    });
    widget.session?.addListener(_onSessionChanged);
  }

  void _onSessionChanged() {
    if (mounted) setState(() {});
    _updateTitle();
  }

  void _onDocumentChanged() {
    // Meldung mit «Rückgängig» gilt nur, solange nichts anderes geändert wurde
    if (c.undoOfferStale) {
      c.clearUndoOffer();
      if (mounted) ScaffoldMessenger.of(context).hideCurrentSnackBar();
    }
    if (widget.session == null) files.scheduleRecovery();
    // Schreiben beendet (Esc, Klick auf ein anderes Element …): Tastatur zurück an den Editor,
    // sonst wirken Entf, Pfeile und Strg-Kürzel erst nach einem Klick auf eine leere Stelle.
    final editing = c.editingId != null;
    if (_wasEditing && !editing) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || c.editingId != null || c.textFocus.hasFocus) return;
        if (!(ModalRoute.of(context)?.isCurrent ?? true)) return; // Dialog oder Vorschau offen
        _rootFocus.requestFocus();
      });
    }
    _wasEditing = editing;
    // Hoch-/Querformat gewechselt (auch per Rückgängig): ganze Seite zeigen
    if (c.doc.orientation != _orientation || c.doc.paper != _paper) {
      _orientation = c.doc.orientation;
      _paper = c.doc.paper;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _fitPage();
      });
    }
    _updateTitle();
  }

  void _updateTitle() {
    final s = widget.session;
    final title = s != null ? '${s.name} – Textly' : '${c.displayName}${c.isDirty ? ' •' : ''} – Textly';
    if (title != _title) {
      _title = title;
      widget.services.setWindowTitle(title);
    }
  }

  void _snack(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  /// Bild aufbereiten (im Hintergrund) und einfügen bzw. das ausgewählte ersetzen.
  Future<void> _insertPrepared(Future<ImageAsset> Function() prepare, {Pt? at, bool replace = false}) async {
    if (!mounted) return;
    // Beim Ersetzen das Bild merken, für das der Dialog geöffnet wurde (die Auswahl kann sich ändern)
    final target = replace ? c.selectedId : null;
    setState(() => _imports++);
    try {
      final asset = await prepare();
      if (!mounted) return;
      if (!replace && c.editingId != null) {
        // Wer inzwischen schreibt, wird nicht unterbrochen: das Bild kommt, sobald das Schreiben endet
        _snack('Das Bild ist bereit. Es erscheint, sobald du mit dem Schreiben fertig bist.');
        await _untilNotWriting();
        if (!mounted) return;
      }
      if (replace) {
        if (target != null && c.page.find(target) is ImageBlock) {
          c.select(target);
          c.replaceSelectedImage(asset);
        } else {
          _snack('Das Bild, das ersetzt werden sollte, gibt es nicht mehr.');
        }
      } else {
        c.insertImage(asset, center: at);
      }
    } on ImageImportException catch (e) {
      _snack(e.message);
    } on FileSystemException {
      _snack('Die Bilddatei lässt sich nicht lesen (gesperrt, verschoben oder Netzlaufwerk nicht erreichbar).');
    } catch (e) {
      debugPrint('Bild einfügen: $e');
      _snack('Das Bild konnte nicht eingefügt werden. Vielleicht ist die Datei beschädigt – bitte ein anderes Bild versuchen.');
    } finally {
      if (mounted) setState(() => _imports--);
      // Tastatur zurück an den Editor, aber nicht mitten aus dem Schreiben reissen
      if (mounted && c.editingId == null) _rootFocus.requestFocus();
    }
  }

  /// Knopf «Bild» bzw. «Anderes Bild wählen»: Dateidialog von Windows/macOS.
  Future<void> pickImage({bool replace = false}) async {
    c.finishEditing();
    final file = await openFile(
      acceptedTypeGroups: const [XTypeGroup(label: 'Bilder', extensions: imageExtensions)],
    );
    if (file == null) return;
    await _insertPrepared(() async => prepareImage(await file.readAsBytes()), replace: replace);
  }

  /// Strg+V: Bild oder kopierte Bilddateien aus der Zwischenablage.
  Future<void> _paste() async {
    if (!Platform.isWindows) return; // macOS folgt
    switch (readWindowsClipboard()) {
      case ClipboardImageBytes b:
        await _insertPrepared(() => prepareImage(b.bytes, opaque: b.fromBitmap));
      case ClipboardFiles f:
        await _insertFiles(f.paths);
      case null:
        _snack('In der Zwischenablage ist kein Bild.');
    }
  }

  /// Mehrere Dateien (Ziehen aus dem Explorer, kopierte Dateien). Weitere Bilder leicht versetzt.
  Future<void> _insertFiles(List<String> paths, {Pt? at}) async {
    final images = paths.where(looksLikeImageFile).toList();
    if (images.isEmpty) {
      _snack('Nur Bilddateien lassen sich einfügen (JPG, PNG, GIF, BMP, TIFF, WebP).');
      return;
    }
    var p = at;
    for (final path in images.take(20)) {
      await _insertPrepared(() async => prepareImage(await File(path).readAsBytes()), at: p);
      if (p != null) p = Pt(p.x + 5, p.y + 5);
    }
  }

  /// Bildschirmposition → Punkt auf der Seite in mm (null ausserhalb der Seite).
  Pt? _pagePoint(Offset global) {
    final box = _canvasKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return null;
    final local = box.globalToLocal(global);
    if (!(Offset.zero & box.size).contains(local)) return null;
    return Pt(local.dx / zoom / mmToPt, local.dy / zoom / mmToPt);
  }

  @override
  void dispose() {
    widget.session?.removeListener(_onSessionChanged);
    c.removeListener(_onDocumentChanged);
    _exitListener.dispose();
    for (final w in [..._waiting]) {
      if (!w.isCompleted) w.complete();
    }
    files.dispose();
    _rootFocus.dispose();
    _canvasScroll.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final k = HardwareKeyboard.instance;
    final mod = k.isControlPressed || k.isMetaPressed;
    final key = event.logicalKey;
    // Dateibefehle gelten auch während des Schreibens; gedrückt halten wiederholt sie nicht.
    final repeat = event is KeyRepeatEvent;
    // Zoom: Strg+Plus / Strg+Minus / Strg+0 (ganze Seite) – auch während des Schreibens
    if (mod && (key == LogicalKeyboardKey.add || key == LogicalKeyboardKey.equal || key == LogicalKeyboardKey.numpadAdd)) {
      _zoomBy(1.2);
      return KeyEventResult.handled;
    }
    if (mod && (key == LogicalKeyboardKey.minus || key == LogicalKeyboardKey.numpadSubtract)) {
      _zoomBy(1 / 1.2);
      return KeyEventResult.handled;
    }
    if (mod && (key == LogicalKeyboardKey.digit0 || key == LogicalKeyboardKey.numpad0)) {
      _fitPageAuto();
      return KeyEventResult.handled;
    }
    if (repeat && mod && (key == LogicalKeyboardKey.keyS || key == LogicalKeyboardKey.keyO || key == LogicalKeyboardKey.keyN || key == LogicalKeyboardKey.keyV || key == LogicalKeyboardKey.keyD)) {
      return KeyEventResult.handled;
    }
    final s = widget.session;
    if (s != null && mod && (key == LogicalKeyboardKey.keyS || key == LogicalKeyboardKey.keyO || key == LogicalKeyboardKey.keyN)) {
      // Speichern geschieht automatisch; Strg+S bestätigt es nur, Strg+O führt zu «Meine Dokumente»
      if (key == LogicalKeyboardKey.keyS) {
        s.flush().then(
          (_) => _snack(
            s.state == SaveState.failed
                ? 'Speichern hat gerade nicht geklappt (Datei gesperrt oder Speicher voll?). Textly versucht es weiter.'
                : 'Alles gespeichert. Textly speichert jede Änderung automatisch.',
          ),
        );
      } else if (key == LogicalKeyboardKey.keyO) {
        _goHome();
      }
      return KeyEventResult.handled;
    }
    if (mod && key == LogicalKeyboardKey.keyS) {
      files.save(saveAs: k.isShiftPressed);
      return KeyEventResult.handled;
    }
    if (mod && key == LogicalKeyboardKey.keyO) {
      files.open();
      return KeyEventResult.handled;
    }
    if (mod && key == LogicalKeyboardKey.keyN) {
      files.newDocument();
      return KeyEventResult.handled;
    }
    if (c.editingId != null) {
      return KeyEventResult.ignored; // das Textfeld bearbeitet selbst
    }
    if (_history && _previewing) {
      return KeyEventResult.ignored; // früherer Stand wird nur angesehen: nichts am (verdeckten) Dokument ändern
    }
    if (FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<EditableText>() != null) {
      return KeyEventResult.ignored; // z. B. Dokumentname wird gerade geändert
    }
    if (mod && key == LogicalKeyboardKey.keyZ) {
      k.isShiftPressed ? c.redo() : c.undo();
    } else if (mod && key == LogicalKeyboardKey.keyY) {
      c.redo();
    } else if (mod && key == LogicalKeyboardKey.keyV) {
      _paste();
    } else if (mod &&
        (key == LogicalKeyboardKey.keyB || key == LogicalKeyboardKey.keyI || key == LogicalKeyboardKey.keyU) &&
        c.selected is TextBlock) {
      // ausgewählter Textblock ohne Schreiben: wirkt auf den ganzen Block
      c.toggleInline(
        key == LogicalKeyboardKey.keyB
            ? InlineAttr.bold
            : key == LogicalKeyboardKey.keyI
            ? InlineAttr.italic
            : InlineAttr.underline,
      );
    } else if (mod && key == LogicalKeyboardKey.keyR && c.selected is ImageBlock) {
      c.rotateSelectedImage(clockwise: !k.isShiftPressed);
    } else if (mod && key == LogicalKeyboardKey.keyD) {
      c.duplicateSelected();
    } else if (key == LogicalKeyboardKey.delete || key == LogicalKeyboardKey.backspace) {
      c.deleteSelected();
    } else if (key == LogicalKeyboardKey.escape) {
      c.select(null);
    } else if (key == LogicalKeyboardKey.enter && c.selected is TextBlock) {
      final t = c.selected as TextBlock;
      c.startEditing(t, t.text.length);
    } else if (key == LogicalKeyboardKey.enter && c.selected is TableBlock) {
      // Eingabetaste: in die zuletzt gewählte Zelle schreiben
      final t = c.selected as TableBlock;
      final cell = c.activeCell;
      c.startCellEditing(t, (cell?.row ?? 0).clamp(0, t.rowCount - 1), (cell?.col ?? 0).clamp(0, t.columnCount - 1));
    } else if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown) {
      final step = k.isShiftPressed ? 5.0 : 1.0;
      c.nudgeSelected(
        key == LogicalKeyboardKey.arrowLeft
            ? -step
            : key == LogicalKeyboardKey.arrowRight
            ? step
            : 0,
        key == LogicalKeyboardKey.arrowUp
            ? -step
            : key == LogicalKeyboardKey.arrowDown
            ? step
            : 0,
      );
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  /// Wartet, bis nicht mehr geschrieben wird (oder der Editor geschlossen wird).
  Future<void> _untilNotWriting() {
    final done = Completer<void>();
    void check() {
      if (c.editingId == null || !mounted) {
        c.removeListener(check);
        if (!done.isCompleted) done.complete();
      }
    }

    c.addListener(check);
    _waiting.add(done);
    return done.future.whenComplete(() => _waiting.remove(done));
  }

  /// Offene Wartevorgänge (beim Schliessen des Editors beendet).
  final _waiting = <Completer<void>>[];

  /// Eine längere Aktion (PDF, Drucken, Kopie …) ausführen. [failed] sagt in Alltagssprache, was nicht
  /// geklappt hat; [locked], wenn die Zieldatei gesperrt oder nicht erreichbar ist.
  Future<void> _run(Future<void> Function() job, {required String failed, String? locked}) async {
    if (busy) return; // Doppelklick: nicht zweimal erzeugen
    c.finishEditing();
    setState(() => busy = true);
    try {
      await job();
    } on FileSystemException catch (e) {
      debugPrint('$failed $e');
      _snack(locked ?? '$failed Ist die Datei noch in einem anderen Programm geöffnet?');
    } catch (e) {
      debugPrint('$failed $e'); // Einzelheiten nur für die Fehlersuche
      _snack('$failed Bitte nochmals versuchen.');
    }
    if (mounted) setState(() => busy = false);
  }

  /// «Fertigstellen» öffnen: prüfen, dann drucken oder weitergeben. Wählt der Benutzer dort einen Hinweis,
  /// wird das Element im Editor ausgewählt.
  Future<void> _openPreview() async {
    c.finishEditing();
    final issue = await Navigator.of(context).push<PrintIssue>(
      MaterialPageRoute(
        builder: (_) => PreviewPage(
          doc: c.doc,
          name: widget.session?.name ?? c.displayName,
          onPrint: _print,
          onPdf: _savePdf,
          onEmail: _emailPdf,
          onTextly: _exportTextly,
          onTemplate: widget.session == null ? null : _saveAsTemplate,
          onPowerPoint: files.exportPowerPoint,
        ),
      ),
    );
    if (issue != null && issue.pageIndex < c.doc.pages.length) {
      c.goToPage(issue.pageIndex);
      if (c.page.find(issue.elementId) != null) c.select(issue.elementId);
    }
    _rootFocus.requestFocus();
  }

  Future<void> _toggleHistory() async {
    c.finishEditing();
    if (!_history) await widget.session?.flush(); // aktueller Stand zuerst in den Verlauf
    if (!mounted) return;
    setState(() => _history = !_history);
    if (!_history) _rootFocus.requestFocus();
  }

  Widget _historyView() => HistoryView(
    session: widget.session!,
    controller: c,
    builder: _workArea,
    zoom: zoom,
    onClose: () {
      setState(() => _history = false);
      _rootFocus.requestFocus();
    },
  );

  final _tableMenu = MenuController();
  int _tableRows = 3;
  bool _tableHeader = true;

  /// «Tabelle»: öffnet die Auswahl «Wie viele Spalten?»; ein Klick fügt die Tabelle ein.
  Widget _tableTool(double tileW) => MenuAnchor(
    controller: _tableMenu,
    alignmentOffset: const Offset(0, 6),
    style: MenuStyle(
      backgroundColor: const WidgetStatePropertyAll(Colors.white),
      elevation: const WidgetStatePropertyAll(8),
      shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: const BorderSide(color: Ui.line))),
      side: const WidgetStatePropertyAll(BorderSide(color: Ui.line)),
      padding: const WidgetStatePropertyAll(EdgeInsets.zero),
    ),
    menuChildren: [
      StatefulBuilder(
        builder: (context, setMenu) => Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
          child: SizedBox(
            width: 480,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Tabelle einfügen – wie viele Spalten?', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Ui.ink)),
                const SizedBox(height: 3),
                const Text(
                  'Ein Klick fügt die Tabelle ein. Zeilen und Spalten kannst du danach jederzeit ergänzen.',
                  style: TextStyle(fontSize: 12, color: Ui.muted),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    for (var n = 2; n <= 6; n++) ...[
                      if (n > 2) const SizedBox(width: 8),
                      Expanded(
                        child: _ColumnChoice(
                          key: ValueKey('table-cols-$n'),
                          columns: n,
                          rows: _tableRows,
                          header: _tableHeader,
                          onTap: () {
                            _tableMenu.close();
                            c.addTable(n, rows: _tableRows, headerRow: _tableHeader);
                          },
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 12),
                const Divider(height: 1, color: Ui.line),
                const SizedBox(height: 10),
                Row(
                  children: [
                    const Flexible(child: Text('Zeilen am Anfang:', style: TextStyle(fontSize: 12.5, color: Ui.muted))),
                    const SizedBox(width: 8),
                    SegmentedButton<int>(
                      key: const ValueKey('table-rows'),
                      showSelectedIcon: false,
                      style: SegmentedButton.styleFrom(visualDensity: VisualDensity.compact, textStyle: const TextStyle(fontFamily: Ui.fontFamily, fontSize: 12.5)),
                      segments: const [
                        ButtonSegment(value: 2, label: Text('2')),
                        ButtonSegment(value: 3, label: Text('3')),
                        ButtonSegment(value: 5, label: Text('5')),
                      ],
                      selected: {_tableRows},
                      onSelectionChanged: (v) => setMenu(() => _tableRows = v.first),
                    ),
                  ],
                ),
                Row(
                  children: [
                    const Expanded(child: Text('Erste Zeile als Überschrift', style: TextStyle(fontSize: 12.5, color: Ui.muted))),
                    Switch(
                      key: const ValueKey('table-header'),
                      value: _tableHeader,
                      activeTrackColor: Ui.accent,
                      onChanged: (v) => setMenu(() => _tableHeader = v),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ],
    builder: (context, menu, _) => ToolTile(
      width: tileW,
      prominent: true,
      key: const ValueKey('tool-table'),
      icon: const Icon(Icons.table_chart_outlined),
      label: 'Tabelle',
      selected: menu.isOpen ? true : null,
      onPressed: () {
        c.finishEditing();
        menu.isOpen ? menu.close() : menu.open();
      },
      tooltip: 'Tabelle einfügen – Anzahl Spalten wählen',
    ),
  );

  /// «Meine Dokumente»: speichern und zur Startseite zurück.
  Future<void> _goHome() async {
    if (!await _ensureSaved()) return;
    if (mounted) await Navigator.of(context).maybePop();
  }

  /// Vor dem Verlassen oder Beenden: alles gespeichert? Klappt das Speichern nicht (Datei gesperrt,
  /// Speicher voll …), wird gefragt: nochmals versuchen, eine Kopie sichern oder ohne Speichern schliessen.
  /// Ergibt true, wenn geschlossen werden darf.
  Future<bool> _ensureSaved() async {
    final s = widget.session;
    if (s == null) return true;
    c.finishEditing();
    while (true) {
      await s.finish();
      if (s.state != SaveState.failed) return true;
      if (!mounted) return false;
      final choice = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          key: const ValueKey('save-failed'),
          icon: const Icon(Icons.error_outline_rounded, color: Ui.warnFg, size: 32),
          title: const Text('Das Dokument konnte nicht gespeichert werden'),
          content: const SizedBox(
            width: 460,
            child: Text(
              'Textly kommt gerade nicht an den Ordner «Dokumente\\Textly», zum Beispiel weil die Datei '
              'von einem anderen Programm gesperrt oder der Speicher voll ist.\n\n'
              'Deine letzten Änderungen sind noch nicht gesichert. Versuche es nochmals oder speichere eine Kopie '
              'an einem anderen Ort, z. B. auf dem Desktop oder einem USB-Stick.',
              style: TextStyle(height: 1.45),
            ),
          ),
          actions: [
            TextButton(
              key: const ValueKey('save-failed-discard'),
              onPressed: () => Navigator.pop(ctx, 'discard'),
              style: TextButton.styleFrom(foregroundColor: Ui.danger),
              child: const Text('Ohne Speichern schliessen'),
            ),
            TextButton(key: const ValueKey('save-failed-stay'), onPressed: () => Navigator.pop(ctx, 'stay'), child: const Text('Abbrechen')),
            OutlinedButton(key: const ValueKey('save-failed-copy'), onPressed: () => Navigator.pop(ctx, 'copy'), child: const Text('Kopie speichern unter …')),
            FilledButton(key: const ValueKey('save-failed-retry'), onPressed: () => Navigator.pop(ctx, 'retry'), child: const Text('Nochmals versuchen')),
          ],
        ),
      );
      switch (choice) {
        case 'retry':
          continue;
        case 'copy':
          if (await _saveCopyTo()) return true;
        case 'discard':
          return true;
        default:
          return false;
      }
    }
  }

  /// Kopie als .textly-Datei an einen gewählten Ort; true, wenn sie geschrieben wurde.
  Future<bool> _saveCopyTo() async {
    var path = await widget.services.picker.pickSave(
      suggestedName: '${widget.session?.name ?? c.displayName}.textly',
      label: 'Textly-Dokument',
      extensions: const ['textly'],
    );
    if (path == null) return false;
    if (!path.toLowerCase().endsWith('.textly')) path = '$path.textly';
    try {
      final doc = c.doc;
      final external = <String, Uint8List>{};
      for (final id in doc.usedAssetIds) {
        if (doc.assets.containsKey(id)) continue;
        final b = await widget.services.loadAsset(id);
        if (b != null) external[id] = b;
      }
      await widget.services.files.write(path, encodeTextly(doc, externalImage: (id) => external[id]));
      return true;
    } catch (_) {
      _snack('Auch dort liess sich die Kopie nicht speichern. Bitte einen anderen Ort wählen.');
      return false;
    }
  }

  Widget _homeButton() => Tooltip(
    message: 'Zu allen Dokumenten (alles ist gespeichert)',
    child: TextButton.icon(
      key: const ValueKey('go-home'),
      onPressed: _goHome,
      style: TextButton.styleFrom(
        foregroundColor: const Color(0xFF344054),
        minimumSize: const Size(0, 32),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: const TextStyle(fontFamily: Ui.fontFamily, fontSize: 13, fontWeight: FontWeight.w500),
      ),
      icon: const Icon(Icons.folder_outlined, size: 18),
      label: const Text('Meine Dokumente'),
    ),
  );

  /// «Als Vorlage speichern»: zuerst alles speichern, dann eine Kopie als Vorlage in «Meine Dokumente».
  Future<void> _saveAsTemplate() async {
    final s = widget.session;
    if (s == null) return;
    await s.flush();
    if (!mounted) return;
    final r = await showSaveTemplateDialog(context, name: s.name);
    if (r == null || !mounted) return;
    try {
      final t = await s.library.saveAsTemplate(s.id, name: r.name, kind: r.kind.name);
      _snack('Vorlage «${t.name}» gespeichert. Sie steht auf der Startseite unter «Neu beginnen».');
    } catch (e) {
      debugPrint('Vorlage speichern: $e');
      _snack('Die Vorlage konnte nicht gespeichert werden. Bitte nochmals versuchen.');
    }
  }

  /// «Per E-Mail senden»: PDF im Ordner «Textly zum Versenden» bereitlegen und im Explorer zeigen.
  /// (Ein E-Mail-Programm mit Anhang lässt sich unter Windows nicht zuverlässig direkt öffnen.)
  Future<void> _emailPdf() => _run(() async {
    await widget.session?.recordShare('PDF für E-Mail bereitgelegt');
    final r = await exportPdf(c.doc, rootBundle.load);
    final dir = '${Directory.systemTemp.path}${Platform.pathSeparator}Textly zum Versenden';
    final name = (widget.session?.name ?? c.displayName).replaceAll(RegExp(r'[<>:"/\\|?*]'), ' ').trim();
    final path = '$dir${Platform.pathSeparator}${name.isEmpty ? 'Dokument' : name}.pdf';
    await Directory(dir).create(recursive: true);
    await widget.services.files.write(path, r.bytes);
    if (Platform.isWindows) await Process.run('explorer.exe', ['/select,', path]);
    _snack('Das PDF liegt bereit. Ziehe es in deine E-Mail oder hänge es dort über «Anhängen» an.');
  }, failed: 'Das PDF für die E-Mail konnte nicht bereitgelegt werden.');

  /// «Zum Weiterbearbeiten»: Kopie als .textly-Datei (ohne Verlauf) an einen gewählten Ort.
  Future<void> _exportTextly() async {
    var path = await widget.services.picker.pickSave(
      suggestedName: '${widget.session?.name ?? c.displayName}.textly',
      label: 'Textly-Dokument',
      extensions: const ['textly'],
    );
    if (path == null) return;
    await widget.session?.recordShare('Als Datei weitergegeben');
    if (!path.toLowerCase().endsWith('.textly')) path = '$path.textly';
    final target = path;
    await _run(() async {
      final doc = c.doc;
      final external = <String, Uint8List>{};
      for (final id in doc.usedAssetIds) {
        if (doc.assets.containsKey(id)) continue;
        final b = await widget.services.loadAsset(id);
        if (b != null) external[id] = b;
      }
      await widget.services.files.write(target, encodeTextly(doc, externalImage: (id) => external[id]));
      _snack('Kopie gespeichert: ${target.split(RegExp(r'[\\/]')).last}');
    }, failed: 'Die Kopie konnte nicht gespeichert werden.', locked: 'Die Kopie lässt sich dort nicht speichern. Ist der USB-Stick noch eingesteckt?');
  }

  /// «PDF speichern»: Ort und Namen wählen (Vorschlag: Name des Dokuments), danach öffnen.
  Future<void> _savePdf() async {
    if (busy) return;
    c.finishEditing();
    await widget.session?.recordShare('Als PDF gespeichert');
    if (!mounted) return;
    var path = await widget.services.picker.pickSave(suggestedName: '${c.displayName}.pdf', label: 'PDF-Dokument', extensions: const ['pdf']);
    if (path == null) return;
    if (!path.toLowerCase().endsWith('.pdf')) path = '$path.pdf';
    final target = path;
    await _run(() async {
      final r = await exportPdf(c.doc, rootBundle.load);
      await widget.services.files.write(target, r.bytes);
      _snack('PDF gespeichert: ${target.split(RegExp(r'[\\/]')).last}');
      // Mit dem Standardprogramm öffnen; ohne Umweg über cmd (Sonderzeichen wie & im Pfad)
      if (Platform.isWindows) {
        await Process.run('explorer.exe', [target]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [target]);
      }
    }, failed: 'Das PDF konnte nicht gespeichert werden.', locked: 'Das PDF lässt sich nicht speichern. Ist die Datei noch in einem anderen Programm geöffnet?');
  }

  Future<void> _print() => _run(() async {
    final r = await exportPdf(c.doc, rootBundle.load);
    await Printing.layoutPdf(name: 'Textly', onLayout: (_) async => r.bytes);
  }, failed: 'Drucken hat nicht geklappt. Ist ein Drucker eingerichtet?');

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _rootFocus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: ListenableBuilder(
        listenable: c,
        builder: (context, _) {
          if (c.insertCount != _seenInserts) {
            _seenInserts = c.insertCount;
            WidgetsBinding.instance.addPostFrameCallback((_) => _revealSelected());
          }
          return Scaffold(
          backgroundColor: const Color(0xFFE8EBEF),
          body: Column(
            children: [
              _toolbar(),
              const Divider(height: 1, color: Ui.line),
              Expanded(child: _history ? _historyView() : _workArea(null)),
            ],
          ),
          );
        },
      ),
    );
  }

  /// Seitenübersicht, Arbeitsfläche und Eigenschaften. Im Verlauf ersetzt [preview] (ein früherer Stand)
  /// nur die Arbeitsfläche; alles andere bleibt, wie es ist.
  /// Zeigt die Arbeitsfläche gerade einen früheren Stand (Verlauf)?
  bool _previewing = false;

  Widget _workArea(Widget? preview) {
    _previewing = preview != null;
    return _workAreaRow(preview);
  }

  Widget _workAreaRow(Widget? preview) => Row(
                    children: [
                      SizedBox(width: c.doc.pages.length == 1 ? 76 : 168, child: _pages()),
                      const VerticalDivider(width: 1, color: _line),
                      Expanded(
                        child: preview ??
                            // Bilddateien aus dem Explorer auf die Seite ziehen
                            DropTarget(
                          key: _areaKey,
                          onDragEntered: (_) => setState(() => _dropHover = true),
                          onDragExited: (_) => setState(() => _dropHover = false),
                          onDragDone: (d) {
                            setState(() => _dropHover = false);
                            _insertFiles([for (final f in d.files) f.path], at: _pagePoint(d.globalPosition));
                          },
                          // Solange nicht von Hand gezoomt wurde: bei jeder Grössenänderung der Arbeitsfläche
                          // (z. B. Fenster wird nach dem Start maximiert) wieder die ganze Seite zeigen.
                          child: LayoutBuilder(
                            builder: (context, area) {
                              if (_autoFit && area.biggest != _lastArea) {
                                _lastArea = area.biggest;
                                WidgetsBinding.instance.addPostFrameCallback((_) {
                                  if (mounted && _autoFit) _fitPage();
                                });
                              }
                              return Stack(
                            children: [
                              Positioned.fill(
                                child: GestureDetector(
                                  // Klick neben die Seite hebt die Auswahl auf und holt den Fokus zurück.
                                  // Bewusst onTap (beim Loslassen) und nicht onTapDown: onTapDown feuert nach 0,1 s
                                  // auch dann, wenn der Klick eigentlich einem Text oder Griff gilt, und hob so
                                  // mitten im Ziehen oder Schreiben die Auswahl auf.
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () {
                                    c.select(null);
                                    _rootFocus.requestFocus();
                                  },
                                  child: SingleChildScrollView(
                                    controller: _canvasScroll,
                                    padding: const EdgeInsets.all(32),
                                    // Strg+Mausrad zoomt (statt zu scrollen)
                                    child: Listener(
                                      onPointerSignal: (ev) {
                                        if (ev is PointerScrollEvent && HardwareKeyboard.instance.isControlPressed) {
                                          GestureBinding.instance.pointerSignalResolver.register(ev, (e) {
                                            if (e is PointerScrollEvent) _zoomBy(e.scrollDelta.dy < 0 ? 1.1 : 1 / 1.1);
                                          });
                                        }
                                      },
                                      child: Center(
                                      child: Material(
                                        elevation: 3,
                                        child: Listener(
                                          onPointerDown: (_) {
                                            if (c.editingId == null) {
                                              _rootFocus.requestFocus();
                                            }
                                          },
                                          child: EditorCanvas(key: _canvasKey, controller: c, zoom: zoom, onPickImage: _importing ? null : () => pickImage()),
                                        ),
                                      ),
                                    ),
                                    ),
                                  ),
                                ),
                              ),
                              if (_dropHover)
                                Positioned.fill(
                                  child: IgnorePointer(
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: const Color(0x142F5BD3),
                                        border: Border.all(color: Ui.accent, width: 2),
                                      ),
                                      alignment: Alignment.topCenter,
                                      padding: const EdgeInsets.only(top: 12),
                                      child: const Chip(label: Text('Bild hier loslassen, um es einzufügen')),
                                    ),
                                  ),
                                ),
                              Positioned(right: 16, bottom: 16, child: _zoomControl()),
                              if (_importing) const Positioned(left: 0, right: 0, top: 0, child: LinearProgressIndicator(minHeight: 3)),
                            ],
                          );
                            },
                          ),
                        ),
                      ),
                      const VerticalDivider(width: 1, color: _line),
                      SizedBox(
                        width: 300,
                        // Während ein früherer Stand angesehen wird: Leiste sichtbar, aber gesperrt
                        child: IgnorePointer(
                          ignoring: preview != null,
                          child: AnimatedOpacity(
                            duration: const Duration(milliseconds: 150),
                            opacity: preview != null ? .4 : 1,
                            child: PropertiesPanel(controller: c, onReplaceImage: () => pickImage(replace: true)),
                          ),
                        ),
                      ),
                    ],
                  );

  /// Werkzeugleiste; in kleinen Fenstern (Laptop) schmalere Kacheln, Symbole statt Beschriftungen.
  Widget _toolbar() => LayoutBuilder(builder: (context, box) => _toolbarFor(box.maxWidth));

  Widget _toolbarFor(double width) {
    final compact = width < 1360; // z. B. Laptop mit 1280 Bildpunkten
    final tileW = compact ? 60.0 : 72.0;
    final s = widget.session;
    // Speichern geschieht still; nur wenn es nicht klappt, erscheint ein Hinweis.
    final Widget? saveHint = s != null
        ? (s.state == SaveState.failed ? AutosaveStatus(state: s.state) : null)
        : (c.isDirty || c.filePath != null ? SaveStatus(dirty: c.isDirty, hasFile: c.filePath != null) : null);
    final insert = ToolGroup(
      caption: 'Einfügen',
      children: [
        ToolTile(
          width: tileW + 10,
          prominent: true,
          key: const ValueKey('tool-text'),
          icon: const Icon(Icons.title_rounded),
          label: 'Text',
          onPressed: c.addText,
          tooltip: 'Textblock einfügen',
        ),
        ToolTile(
          width: tileW + 10,
          prominent: true,
          key: const ValueKey('tool-image'),
          icon: const Icon(Icons.image_outlined),
          label: 'Bild',
          onPressed: _importing ? null : () => pickImage(),
          tooltip: 'Bild einfügen – oder eine Bilddatei auf die Seite ziehen, oder Strg+V',
        ),
        _tableTool(tileW + 10),
        _shapeTool(tileW),
      ],
    );
    final edit = ToolGroup(
      caption: 'Bearbeiten',
      children: [
        ToolTile(
          width: tileW,
          key: const ValueKey('tool-undo'),
          icon: const Icon(Icons.undo_rounded),
          label: 'Rückgängig',
          onPressed: c.canUndo ? c.undo : null,
          tooltip: 'Letzten Schritt rückgängig machen (Strg+Z)',
        ),
        ToolTile(
          width: tileW,
          key: const ValueKey('tool-redo'),
          icon: const Icon(Icons.redo_rounded),
          label: 'Wiederholen',
          onPressed: c.canRedo ? c.redo : null,
          tooltip: 'Rückgängig Gemachtes wiederholen (Strg+Y)',
        ),
        if (s?.history != null)
          ToolTile(
            width: tileW + 18,
            key: const ValueKey('tool-history'),
            icon: const Icon(Icons.history_rounded),
            label: 'Frühere Stände',
            selected: _history,
            onPressed: _toggleHistory,
            tooltip: 'Frühere Stände ansehen und zurückholen (Zeitstrahl ein/aus)',
          ),
      ],
    );
    // «Einfügen» steht mittig über der Seite (zwischen Seitenübersicht und Eigenschaften).
    final pagesW = c.doc.pages.length == 1 ? 77.0 : 169.0;
    const panelW = 301.0;
    final insertW = 4 * (tileW + 10) + 12 + 16;
    const editW = 290.0;
    final pageCenter = pagesW + (width - pagesW - panelW) / 2;
    final centred = pageCenter + insertW / 2 + 12 < width - editW && pageCenter - insertW / 2 > 8;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Zeile 1: links Logo und «Meine Dokumente», mittig der Name, rechts Hilfe und Drucken
        Container(
          height: 52,
          color: Ui.bar,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              Expanded(
                child: Row(children: [
                  // App-Icon «T mit Punkt» (tool/make_icon.py)
                  Image.asset('assets/branding/textly_icon_256.png', width: 30, height: 30, filterQuality: FilterQuality.medium, semanticLabel: 'Textly'),
                  const SizedBox(width: 8),
                  Flexible(child: s != null ? _homeButton() : _fileMenu()),
                ]),
              ),
              const SizedBox(width: 12),
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: width * .42),
                child: DocName(
                  name: s?.name ?? c.displayName,
                  onRename: s == null ? null : (v) => s.rename(v),
                  tooltip: s == null ? (c.filePath ?? 'Noch nicht gespeichert') : null,
                  trailing: saveHint,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Tooltip(
                      message: 'Hilfe und Tastenkürzel',
                      child: OutlinedButton(
                        key: const ValueKey('tool-help'),
                        onPressed: _showHelp,
                        style: OutlinedButton.styleFrom(
                          shape: const CircleBorder(),
                          side: const BorderSide(color: Ui.line),
                          minimumSize: const Size(32, 32),
                          padding: EdgeInsets.zero,
                          foregroundColor: Ui.muted,
                        ),
                        child: const Text('?', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                      ),
                    ),
                    const SizedBox(width: 10),
                    // Betrifft das ganze Dokument: im Kopf ganz rechts
                    Flexible(
                      child: Tooltip(
                        message: 'Zuerst prüfen, dann drucken, als PDF speichern, per E-Mail senden oder weitergeben',
                        child: FilledButton.icon(
                          key: const ValueKey('tool-finish'),
                          onPressed: busy ? null : _openPreview,
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(0, 38),
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            backgroundColor: Ui.accent,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            textStyle: const TextStyle(fontFamily: Ui.fontFamily, fontSize: 13.5, fontWeight: FontWeight.w600),
                          ),
                          icon: const Icon(Icons.print_outlined, size: 19),
                          label: Text(compact ? 'Drucken & PDF …' : 'Drucken, PDF, E-Mail …', overflow: TextOverflow.ellipsis),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        // Zeile 2: mittig das Häufige (Einfügen), rechts Bearbeiten mit Rückgängig und früheren Ständen
        const Divider(height: 1, color: Color(0xFFEDEFF3)),
        Container(
          height: 92,
          color: Ui.bar,
          padding: const EdgeInsets.fromLTRB(0, 6, 12, 4),
          child: centred
              ? Stack(children: [
                  Positioned(left: pageCenter - insertW / 2, top: 0, bottom: 0, child: insert),
                  Positioned(right: 0, top: 0, bottom: 0, child: edit),
                ])
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(width: 8),
                    // Scrollt seitlich, falls das Fenster sehr schmal ist; «Bearbeiten» bleibt sichtbar.
                    Expanded(child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: insert)),
                    const GroupDivider(),
                    edit,
                  ],
                ),
        ),
      ],
    );
  }

  /// Zoom unten rechts an der Arbeitsfläche – immer da, auch wenn ein Element ausgewählt ist.
  Widget _zoomControl() => Material(
    key: const ValueKey('zoom-control'),
    color: Colors.white,
    elevation: 3,
    shadowColor: const Color(0x40101828),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: const BorderSide(color: Ui.line)),
    child: Padding(
      padding: const EdgeInsets.all(4),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        _zoomButton('zoom-out', Icons.remove_rounded, 'Verkleinern (Strg+Minus)', () => zoom / 1.2),
        SizedBox(
          width: 50,
          child: Text(
            '${(zoom * 100).round()} %',
            key: const ValueKey('zoom-label'),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Ui.ink),
          ),
        ),
        _zoomButton('zoom-in', Icons.add_rounded, 'Vergrössern (Strg+Plus)', () => zoom * 1.2),
        Container(width: 1, height: 20, margin: const EdgeInsets.symmetric(horizontal: 4), color: Ui.line),
        Tooltip(
          message: 'Die ganze Seite zeigen (Strg+0)',
          child: TextButton.icon(
            key: const ValueKey('zoom-fit'),
            onPressed: _fitPageAuto,
            style: TextButton.styleFrom(
              backgroundColor: _autoFit ? Ui.accentSoft : Ui.field,
              foregroundColor: _autoFit ? Ui.accent : Ui.ink,
              minimumSize: const Size(0, 30),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
              textStyle: const TextStyle(fontFamily: Ui.fontFamily, fontSize: 12, fontWeight: FontWeight.w500),
            ),
            icon: const Icon(Icons.fit_screen_outlined, size: 17),
            label: const Text('Ganze Seite'),
          ),
        ),
      ]),
    ),
  );

  Widget _zoomButton(String key, IconData icon, String tip, double Function() next) => Tooltip(
    message: tip,
    child: InkWell(
      key: ValueKey(key),
      borderRadius: BorderRadius.circular(15),
      onTap: () => _zoomBy(next() / zoom),
      child: SizedBox(width: 34, height: 34, child: Icon(icon, size: 19, color: Ui.ink)),
    ),
  );

  /// Von Hand zoomen (Knöpfe, Strg+Plus/Minus, Strg+Mausrad); «Ganze Seite» gilt danach nicht mehr.
  void _zoomBy(double factor) => setState(() {
    _autoFit = false;
    zoom = (zoom * factor).clamp(.4, 4);
  });

  final _shapeMenu = MenuController();

  /// «Form ▾»: seltene Elemente (Fläche, Linie) mit kurzer Erklärung.
  Widget _shapeTool(double tileW) {
    Widget item(String key, Widget sample, String title, String hint, VoidCallback onTap) => MenuItemButton(
      key: ValueKey(key),
      onPressed: onTap,
      style: MenuItemButton.styleFrom(minimumSize: const Size(250, 52), padding: const EdgeInsets.symmetric(horizontal: 14)),
      leadingIcon: SizedBox(width: 34, child: Center(child: sample)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(title, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: Ui.ink)),
        Text(hint, style: const TextStyle(fontSize: 12, color: Ui.muted)),
      ]),
    );
    return MenuAnchor(
      controller: _shapeMenu,
      alignmentOffset: const Offset(0, 6),
      style: MenuStyle(
        backgroundColor: const WidgetStatePropertyAll(Colors.white),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: Ui.line))),
        side: const WidgetStatePropertyAll(BorderSide(color: Ui.line)),
      ),
      menuChildren: [
        item(
          'tool-rect',
          Container(width: 28, height: 18, decoration: BoxDecoration(color: const Color(0xFFE8EEF7), border: Border.all(color: Ui.accent, width: 1.5), borderRadius: BorderRadius.circular(4))),
          'Fläche',
          'Hintergrund, Balken oder Kasten',
          c.addRect,
        ),
        item('tool-line', Container(width: 28, height: 2, color: Ui.accent), 'Linie', 'Trennlinie', c.addLine),
      ],
      builder: (context, menu, _) => ToolTile(
        width: tileW,
        key: const ValueKey('tool-shape'),
        icon: const Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.category_outlined), Icon(Icons.expand_more_rounded, size: 14)]),
        label: 'Form',
        selected: menu.isOpen ? true : null,
        onPressed: () {
          c.finishEditing();
          menu.isOpen ? menu.close() : menu.open();
        },
        tooltip: 'Fläche oder Linie einfügen',
      ),
    );
  }

  /// «Ganze Seite»: anpassen und dabei bleiben, auch wenn das Fenster seine Grösse ändert.
  void _fitPageAuto() {
    _autoFit = true;
    _fitPage();
  }

  /// Zoom so, dass die ganze Seite in den Arbeitsbereich passt.
  void _fitPage() {
    final v = _viewport;
    if (v == null) return;
    final z = math.min((v.width - 64) / (c.doc.pageWidth * mmToPt), (v.height - 64) / (c.doc.pageHeight * mmToPt));
    setState(() => zoom = z.clamp(.4, 4));
  }

  void _showHelp() {
    final session = widget.session != null;
    final tips = [
      (
        'Einfügen',
        'Oben in der Mitte Text, Bild oder Tabelle anklicken; Fläche und Linie findest du unter «Form». '
            'Bilder kannst du auch aus dem Explorer auf die Seite ziehen oder mit Strg+V einfügen.',
      ),
      (
        'Schreiben',
        'Ein Klick in einen Text oder eine Tabellenzelle setzt den Cursor – du kannst sofort schreiben. '
            'Über dem Text erscheint eine Leiste für Schrift, Grösse, Farbe und Ausrichtung.',
      ),
      (
        'Verschieben und Grösse',
        'Bilder und Formen direkt ziehen, Texte und Tabellen am Griff «Verschieben». An den Griffen am Rand die Grösse ändern. '
            'Beim Ziehen rasten Elemente am Raster und an anderen Elementen ein – mit gedrückter Alt-Taste nicht.',
      ),
      (
        'Tabellen',
        'In eine Zelle klicken: «+ Zeile» und «+ Spalte» erscheinen direkt daneben, «löschen» am Rand der Tabelle. '
            'Tab springt in die nächste Zelle. Rechtsklick in eine Zelle: «Zeile darüber einfügen», «Spalte links einfügen».',
      ),
      (
        'Eigenschaften',
        'Rechts siehst du alles, was du am ausgewählten Element ändern kannst. Ist nichts ausgewählt: '
            'Papiergrösse, Hoch- oder Querformat und Raster der Seite.',
      ),
      ('Ansicht', 'Unten rechts: verkleinern, vergrössern und «Ganze Seite». Oder Strg+Mausrad, Strg+Plus/Minus und Strg+0.'),
      if (session && widget.session!.history != null)
        (
          'Frühere Stände',
          'Textly merkt sich wichtige Zwischenstände. «Frühere Stände» (oben rechts) zeigt sie auf einem Zeitstrahl; '
              'geändert wird nichts, bis du «Mit diesem Stand weiterarbeiten» wählst.',
        ),
      (
        'Drucken, PDF, E-Mail',
        '«Drucken, PDF, E-Mail …» oben rechts zeigt die Seiten so, wie sie gedruckt werden, weist auf Probleme hin '
            'und bietet Drucken, PDF, E-Mail und Weitergeben an.',
      ),
    ];
    final keys = [
      ('Strg+Z / Strg+Y', 'Rückgängig / Wiederholen'),
      if (session) ('Strg+S', 'Speichern bestätigen (Textly speichert ohnehin automatisch)') else ('Strg+S', 'Speichern'),
      ('Strg+V', 'Bild aus der Zwischenablage einfügen'),
      ('Strg+D', 'Ausgewähltes Element verdoppeln'),
      ('Entf', 'Ausgewähltes Element löschen'),
      ('Pfeiltasten', 'Ausgewähltes Element verschieben (mit Umschalt in grösseren Schritten)'),
      ('Strg+B / I / U', 'Fett / Kursiv / Unterstrichen'),
      ('Strg+R', 'Bild nach rechts drehen (mit Umschalt nach links)'),
      ('Tab', 'In der Tabelle: nächste Zelle (mit Umschalt: vorherige)'),
      ('Alt beim Ziehen', 'Nicht einrasten'),
      ('Esc', 'Schreiben beenden'),
      if (session) ('Strg+O', 'Zu «Meine Dokumente»'),
    ];
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('So funktioniert Textly'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final (t, d) in tips)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(t, style: const TextStyle(fontWeight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        Text(d, style: const TextStyle(color: Ui.muted, height: 1.35)),
                      ],
                    ),
                  ),
                const Divider(height: 20),
                const Text('Tastenkürzel', style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                for (final (k, d) in keys)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 140,
                          child: Text(k, style: const TextStyle(fontWeight: FontWeight.w500)),
                        ),
                        Expanded(
                          child: Text(d, style: const TextStyle(color: Ui.muted)),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton.icon(
            key: const ValueKey('help-guide'),
            // Öffnet die Anleitung im Browser (Windows: explorer.exe öffnet Adressen mit dem Standardbrowser)
            onPressed: () => Platform.isWindows ? Process.run('explorer.exe', [anleitungUrl]) : null,
            icon: const Icon(Icons.menu_book_outlined, size: 18),
            label: const Text('Ausführliche Anleitung mit Bildern'),
          ),
          FilledButton(key: const ValueKey('help-close'), onPressed: () => Navigator.pop(context), child: const Text('Verstanden')),
        ],
      ),
    );
  }

  /// Nur eine Seite: schmale Leiste (kleine Miniatur und «Neue Seite»), damit die Seite mehr Platz hat.
  Widget _pagesCompact() {
    const thumbW = 44.0;
    final s = thumbW / (c.doc.pageWidth * mmToPt);
    return Container(
      color: Ui.panel,
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        children: [
          InkWell(
            key: const ValueKey('page-thumb-0'),
            onTap: () => c.goToPage(0),
            child: Container(
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(3), border: Border.all(color: Ui.accent, width: 2)),
              child: SizedBox(
                width: thumbW,
                height: c.doc.pageHeight * mmToPt * s,
                child: FittedBox(
                  child: IgnorePointer(
                    child: StaticPage(page: c.doc.page(0), images: documentImages(c.doc), widthMm: c.doc.pageWidth, heightMm: c.doc.pageHeight),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          const Text('1', style: TextStyle(fontSize: 12, color: Ui.muted)),
          const SizedBox(height: 12),
          Tooltip(
            message: 'Leere Seite nach der aktuellen einfügen',
            child: InkWell(
              key: const ValueKey('page-add'),
              onTap: c.addPage,
              borderRadius: BorderRadius.circular(8),
              child: const DashedBorder(
                child: SizedBox(width: 48, height: 44, child: Icon(Icons.add_rounded, size: 22, color: Ui.muted)),
              ),
            ),
          ),
          const SizedBox(height: 4),
          const Text('Neue\nSeite', textAlign: TextAlign.center, style: TextStyle(fontSize: 12, height: 1.2, color: Ui.muted)),
        ],
      ),
    );
  }

  Widget _pages() {
    if (c.doc.pages.length == 1) return _pagesCompact();
    const thumbW = 112.0;
    // Querformat: Miniatur gleich breit, dafür niedriger
    final s = thumbW / (c.doc.pageWidth * mmToPt);
    final n = c.doc.pages.length;
    return Container(
      color: Ui.panel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 10),
            child: Text(
              'Seiten',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Ui.muted),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 16),
              children: [
                for (var i = 0; i < n; i++) ...[
                  Center(
                    child: InkWell(
                      key: ValueKey('page-thumb-$i'),
                      onTap: () => c.goToPage(i),
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(3),
                          border: Border.all(color: i == c.pageIndex ? Ui.accent : const Color(0xFFD9DDE3), width: i == c.pageIndex ? 2 : 1),
                        ),
                        child: SizedBox(
                          width: thumbW,
                          height: c.doc.pageHeight * mmToPt * s,
                          child: FittedBox(
                            child: IgnorePointer(
                              child: StaticPage(
                                page: c.doc.page(i),
                                images: documentImages(c.doc),
                                widthMm: c.doc.pageWidth,
                                heightMm: c.doc.pageHeight,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      Text(
                        '${i + 1}',
                        style: TextStyle(
                          color: i == c.pageIndex ? Ui.ink : Ui.muted,
                          fontSize: 12,
                          fontWeight: i == c.pageIndex ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                      const Spacer(),
                      _mini(Icons.arrow_upward, 'Seite nach vorne', i > 0 ? () => c.movePage(i, i - 1) : null),
                      _mini(Icons.arrow_downward, 'Seite nach hinten', i < n - 1 ? () => c.movePage(i, i + 1) : null),
                      _mini(Icons.delete_outline, 'Seite löschen', n > 1 ? () => _removePage(i) : null),
                    ],
                  ),
                  const SizedBox(height: 8),
                ],
                // «Neue Seite» direkt unter der letzten Seite
                Center(
                  child: Tooltip(
                    message: 'Leere Seite nach der aktuellen einfügen',
                    child: InkWell(
                      key: const ValueKey('page-add'),
                      onTap: c.addPage,
                      borderRadius: BorderRadius.circular(6),
                      child: const DashedBorder(
                        child: SizedBox(
                          width: thumbW,
                          height: 76,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.add_rounded, size: 22, color: Ui.ink),
                              SizedBox(height: 4),
                              Text(
                                'Neue Seite',
                                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Ui.ink),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Seite löschen und sofort «Rückgängig» anbieten (ein Fehlklick auf den Papierkorb ist leicht).
  void _removePage(int index) {
    c.removePage(index);
    if (!mounted) return;
    c.offerUndo();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('Seite ${index + 1} gelöscht.'),
          action: SnackBarAction(label: 'Rückgängig', onPressed: c.undoOffered),
          persist: false,
          duration: const Duration(seconds: 6),
        ),
      );
  }

  /// Menü «Datei».
  Widget _fileMenu() {
    MenuItemButton item(String key, IconData icon, String label, VoidCallback onPressed, [SingleActivator? shortcut]) =>
        MenuItemButton(key: ValueKey(key), leadingIcon: Icon(icon, size: 18), shortcut: shortcut, onPressed: onPressed, child: Text(label));
    return MenuAnchor(
      menuChildren: [
        item('menu-new', Icons.note_add_outlined, 'Neu', files.newDocument, const SingleActivator(LogicalKeyboardKey.keyN, control: true)),
        item('menu-open', Icons.folder_open_outlined, 'Öffnen …', files.open, const SingleActivator(LogicalKeyboardKey.keyO, control: true)),
        item('menu-save', Icons.save_outlined, 'Speichern', () => files.save(), const SingleActivator(LogicalKeyboardKey.keyS, control: true)),
        item(
          'menu-save-as',
          Icons.save_as_outlined,
          'Speichern unter …',
          () => files.save(saveAs: true),
          const SingleActivator(LogicalKeyboardKey.keyS, control: true, shift: true),
        ),
        const Divider(height: 8),
        item('menu-pptx-open', Icons.slideshow_outlined, 'PowerPoint-Datei öffnen …', files.importPowerPoint),
        item('menu-pptx-export', Icons.ios_share_outlined, 'Als PowerPoint speichern …', files.exportPowerPoint),
      ],
      builder: (context, menu, _) => TextButton(
        key: const ValueKey('menu-file'),
        onPressed: () => menu.isOpen ? menu.close() : menu.open(),
        style: TextButton.styleFrom(
          backgroundColor: Ui.field,
          foregroundColor: Ui.ink,
          minimumSize: const Size(0, 32),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          textStyle: const TextStyle(fontFamily: Ui.fontFamily, fontSize: 13, fontWeight: FontWeight.w500),
        ),
        child: const Row(mainAxisSize: MainAxisSize.min, children: [Text('Datei'), SizedBox(width: 4), Icon(Icons.expand_more_rounded, size: 16)]),
      ),
    );
  }

  Widget _mini(IconData icon, String tip, VoidCallback? onTap) => IconButton(
    tooltip: tip,
    onPressed: onTap,
    icon: Icon(icon, size: 18),
    visualDensity: VisualDensity.compact,
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
  );
}

/// Wahl der Spaltenzahl mit kleinem Bild der Tabelle.
class _ColumnChoice extends StatelessWidget {
  const _ColumnChoice({super.key, required this.columns, required this.rows, required this.header, required this.onTap});
  final int columns, rows;
  final bool header;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: Ui.line)),
    child: InkWell(
      borderRadius: BorderRadius.circular(12),
      hoverColor: Ui.accentSoft,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 10),
        child: Column(
          children: [
            SizedBox(
              width: 58,
              height: 9.0 * rows,
              child: CustomPaint(painter: _MiniTablePainter(columns, rows, header)),
            ),
            const SizedBox(height: 8),
            Text('$columns', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Ui.ink)),
          ],
        ),
      ),
    ),
  );
}

class _MiniTablePainter extends CustomPainter {
  _MiniTablePainter(this.cols, this.rows, this.header);
  final int cols, rows;
  final bool header;

  @override
  void paint(Canvas canvas, Size size) {
    final rh = size.height / rows, cw = size.width / cols;
    if (header) canvas.drawRect(Rect.fromLTWH(0, 0, size.width, rh), Paint()..color = const Color(0xFF1F7A5A));
    final p = Paint()
      ..color = const Color(0xFF98A2B3)
      ..strokeWidth = 1;
    for (var r = 0; r <= rows; r++) {
      canvas.drawLine(Offset(0, r * rh), Offset(size.width, r * rh), p);
    }
    for (var c = 0; c <= cols; c++) {
      canvas.drawLine(Offset(c * cw, 0), Offset(c * cw, size.height), p);
    }
  }

  @override
  bool shouldRepaint(_MiniTablePainter old) => old.cols != cols || old.rows != rows || old.header != header;
}
