import 'package:doc_model/doc_model.dart';
import 'package:doc_render/doc_render.dart';
import 'package:flutter/widgets.dart';

import '../spell/spell_check.dart';
import 'rich_text_controller.dart';

/// Laufende Geste (Verschieben, Griff ziehen). Änderungen bleiben bis zum Loslassen eine Vorschau
/// und werden dann als ein einziger Schritt in den Verlauf übernommen.
class _Gesture {
  _Gesture(this.start, this.element, this.startBox, this.targets);
  final TextlyDocument start;
  final DocElement element;
  final Box startBox;

  /// Ziele zum Einrasten, einmal zu Beginn berechnet (die anderen Elemente bewegen sich nicht).
  final SnapTargets targets;
}

/// Zustand des Editors: Dokument mit Verlauf, aktuelle Seite, Auswahl, Textbearbeitung.
///
/// Jede Änderung am Dokument läuft über [commit] (ein Rückgängig-Schritt) oder während einer
/// Geste bzw. Textbearbeitung über eine Vorschau, die am Ende als ein Schritt übernommen wird.
/// Eigenschaften, die sich für einzelne Textstellen ein- und ausschalten lassen.
enum InlineAttr { bold, italic, underline }

class EditorController extends ChangeNotifier {
  EditorController(TextlyDocument doc, {required this.spell, this.untitledName = 'Unbenannt'})
      : history = History(doc),
        _savedDoc = doc {
    // Beim Schreiben zeigt die Eigenschaftenleiste den Stil der Markierung: bei jeder Änderung
    // der Markierung neu zeichnen.
    textController.addListener(() {
      final sel = textController.selection;
      if (_editingId != null && sel != _lastTextSelection) {
        _lastTextSelection = sel;
        notifyListeners();
      }
    });
  }

  TextSelection? _lastTextSelection;

  final History history;
  final SpellChecker spell;

  TextlyDocument? _preview;
  _Gesture? _gesture;

  int _pageIndex = 0;
  String? _selectedId;
  String? _editingId;
  TextlyDocument? _editStart;

  /// Zelle, die gerade geschrieben wird (dann ist [editingId] die Tabelle).
  ({int row, int col})? _cell;

  /// Zuletzt gewählte Zelle der ausgewählten Tabelle (für «Zeile löschen», Ausrichtung der Spalte).
  ({int row, int col})? _activeCell;

  /// Eingabefeld mit formatierten Textstellen und eigener Rechtschreib-Anzeige.
  late final RichTextController textController = RichTextController(spell: spell);
  final FocusNode textFocus = FocusNode(debugLabel: 'Textblock');

  /// Das angezeigte Dokument (inkl. laufender Vorschau).
  TextlyDocument get doc => _preview ?? history.present;
  int get pageIndex => _pageIndex;
  DocPage get page => doc.page(_pageIndex);
  String? get selectedId => _selectedId;
  String? get editingId => _editingId;
  ({int row, int col})? get editingCell => _cell;
  ({int row, int col})? get activeCell => _activeCell;
  DocElement? get selected => _selectedId == null ? null : page.find(_selectedId!);
  bool get canUndo => history.canUndo || _editingId != null;
  bool get canRedo => history.canRedo;

  // ---------- Datei ----------

  /// Pfad der .textly-Datei; null, solange das Dokument nie gespeichert wurde.
  String? filePath;

  /// Anzeigename für unbenannte Dokumente (z. B. Name einer geöffneten PowerPoint-Datei).
  String untitledName;
  TextlyDocument? _savedDoc;

  /// Gibt es Änderungen seit dem letzten Speichern (bzw. Öffnen)?
  bool get isDirty => !identical(history.present, _savedDoc) || _preview != null;

  /// Name ohne Ordner und Endung, z. B. «Vereinsausflug».
  String get displayName {
    final p = filePath;
    if (p == null) return untitledName;
    final name = p.split(RegExp(r'[\\/]')).last; // Windows-Pfade mit \ und /
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  /// Anderes Dokument laden (Neu, Öffnen, Import, Wiederherstellung). Verlauf beginnt neu.
  /// Mit [dirty] gilt es als ungespeichert (Import, Wiederherstellung).
  void replaceDocument(TextlyDocument doc, {String? path, String untitled = 'Unbenannt', bool dirty = false}) {
    finishEditing();
    cancelGesture();
    history.reset(doc);
    _preview = null;
    _pageIndex = 0;
    _selectedId = null;
    filePath = path;
    untitledName = untitled;
    _savedDoc = dirty ? null : doc;
    notifyListeners();
  }

  /// Nach erfolgreichem Speichern.
  /// [saved] ist der Stand, der tatsächlich geschrieben wurde; Änderungen während des Schreibens
  /// bleiben ungespeichert.
  void markSaved(String path, [TextlyDocument? saved]) {
    filePath = path;
    _savedDoc = saved ?? history.present;
    // Der nächste Schritt (z. B. Pfeiltaste) darf nicht mit dem gespeicherten verschmelzen.
    history.breakMerge();
    notifyListeners();
  }

  // ---------- Verlauf ----------

  void commit(TextlyDocument next, {Object? mergeKey}) {
    _preview = null;
    history.push(next, mergeKey: mergeKey);
    _fixSelection();
    notifyListeners();
  }

  void undo() {
    finishEditing();
    cancelGesture();
    _cancelPreview();
    if (history.undo()) {
      _fixSelection();
      notifyListeners();
    }
  }

  void redo() {
    finishEditing();
    cancelGesture();
    _cancelPreview();
    if (history.redo()) {
      _fixSelection();
      notifyListeners();
    }
  }

  void _fixSelection() {
    if (_pageIndex >= doc.pages.length) _pageIndex = doc.pages.length - 1;
    if (_selectedId != null && page.find(_selectedId!) == null) _selectedId = null;
  }

  // ---------- Auswahl und Seiten ----------

  void select(String? id) {
    if (id == _selectedId && _editingId == null) return;
    finishEditing();
    history.breakMerge();
    if (id != _selectedId) _activeCell = null;
    _selectedId = id;
    if (id != null) _lastTouchedId = id;
    notifyListeners();
  }

  void goToPage(int index) {
    finishEditing();
    _pageIndex = index.clamp(0, doc.pages.length - 1);
    _selectedId = null;
    notifyListeners();
  }

  void addPage() {
    _settle();
    commit(doc.insertPage(_pageIndex + 1, DocPage(id: newId('p'))));
    goToPage(_pageIndex + 1);
  }

  void removePage(int index) {
    if (doc.pages.length < 2) return;
    _settle();
    _selectedId = null;
    if (_pageIndex >= index && _pageIndex > 0) _pageIndex--;
    commit(doc.removePage(index));
  }

  /// Hoch- oder Querformat für das ganze Dokument (ein Rückgängig-Schritt).
  void setOrientation(PageOrientation o) {
    if (doc.orientation == o) return;
    _settle();
    commit(doc.withOrientation(o));
  }

  /// Papiergrösse für das ganze Dokument; alles wird mitskaliert (ein Rückgängig-Schritt).
  void setPaper(PaperSize p) {
    if (doc.paper == p) return;
    _settle();
    commit(doc.withPaper(p));
  }

  void movePage(int from, int to) {
    if (to < 0 || to >= doc.pages.length || from == to) return;
    _settle();
    // Die angezeigte Seite bleibt dieselbe, auch wenn eine andere Seite an ihr vorbeiwandert.
    if (_pageIndex == from) {
      _pageIndex = to;
    } else if (from < _pageIndex && to >= _pageIndex) {
      _pageIndex--;
    } else if (from > _pageIndex && to <= _pageIndex) {
      _pageIndex++;
    }
    commit(doc.movePage(from, to));
  }

  // ---------- Raster und Einrasten ----------

  /// Raster anzeigen bzw. am Raster einrasten (getrennt schaltbar, Spezifikation 5).
  bool showGrid = true;
  bool snapToGrid = true;

  /// Rasterabstand in mm (5 oder 10).
  double gridSize = 5;

  /// Aktueller Zoom der Arbeitsfläche; bestimmt, wie nah (in mm) eine Kante zum Einrasten kommen muss.
  double viewZoom = 1.2;

  /// Einrasten, sobald eine Kante näher als 6 Bildschirmpunkte an einem Ziel ist.
  double get snapThresholdMm => 6 / viewZoom / mmToPt;

  List<Guide> _guides = const [];

  /// Ausrichtungslinien der laufenden Geste.
  List<Guide> get guides => _guides;

  void setShowGrid(bool v) {
    showGrid = v;
    notifyListeners();
  }

  void setSnapToGrid(bool v) {
    snapToGrid = v;
    notifyListeners();
  }

  void setGridSize(double mm) {
    gridSize = mm;
    notifyListeners();
  }

  SnapSettings _snapSettings() => SnapSettings(threshold: snapThresholdMm, grid: snapToGrid ? gridSize : null);

  /// Tatsächliche Umrisse aller Elemente der Seite ausser [exceptId].
  List<({DocElement element, Box box})> otherBoxes(String exceptId, [TextlyDocument? from]) => [
        for (final e in (from ?? doc).page(_pageIndex).elements)
          if (e.id != exceptId) (element: e, box: renderedBox(e)),
      ];

  // ---------- Überlappungen ----------

  /// Text- und Bildblöcke, die vom ausgewählten Text- oder Bildblock überdeckt werden (Spezifikation 5).
  /// Linien und Rechtecke zählen nicht: Sie dienen oft bewusst als Hintergrund.
  List<DocElement> overlapsOfSelected() {
    final sel = selected;
    if (sel is! TextBlock && sel is! ImageBlock) return const [];
    final box = renderedBox(sel!);
    return [
      for (final o in otherBoxes(sel.id))
        if ((o.element is TextBlock || o.element is ImageBlock) && box.overlaps(o.box)) o.element,
    ];
  }

  /// Liegt ein anderes Element, das sich mit dem ausgewählten überdeckt, darüber bzw. darunter?
  /// (Nur dann ergeben «Nach vorne holen» bzw. «Nach hinten legen» einen Sinn.)
  ({bool above, bool below}) stackingOfSelected() {
    final sel = selected;
    if (sel == null) return (above: false, below: false);
    final els = page.elements;
    final i = els.indexWhere((e) => e.id == sel.id);
    final box = renderedBox(sel);
    var above = false, below = false;
    for (var j = 0; j < els.length; j++) {
      if (j == i || !box.overlaps(renderedBox(els[j]))) continue;
      if (j > i) {
        above = true;
      } else {
        below = true;
      }
    }
    return (above: above, below: below);
  }

  /// «Darunter verschieben»: unter das unterste überdeckte Element, mit 4 mm Abstand, aufs Raster gerundet.
  /// Ergibt false, wenn der Block danach über den unteren Seitenrand hinausragt (er wird trotzdem verschoben).
  bool moveSelectedBelowOverlaps() {
    final sel = selected;
    final overlaps = overlapsOfSelected();
    if (sel == null || overlaps.isEmpty || sel.locked) return true;
    _settle();
    final bottom = overlaps.map((e) => renderedBox(e).bottom).reduce((a, b) => a > b ? a : b);
    final y = ((bottom + 4) / gridSize).ceil() * gridSize;
    final b = renderedBox(sel);
    commit(doc.replaceElement(_pageIndex, sel.translated(0, y - b.y)));
    return y + b.h <= doc.pageHeight - pageMarginMm;
  }

  // ---------- Gesten ----------

  /// Beginnt eine Geste am Element [id] (wählt es dabei aus).
  bool beginGesture(String id) {
    finishEditing();
    final e = page.find(id);
    _selectedId = id;
    if (e == null || e.locked) {
      notifyListeners();
      return false;
    }
    history.breakMerge();
    _gesture = _Gesture(
      history.present,
      e,
      renderedBox(e),
      SnapTargets.forPage(otherBoxes(id, history.present).map((o) => o.box), width: doc.pageWidth, height: doc.pageHeight),
    );
    return true;
  }

  void _previewElement(DocElement e, [List<Guide> guides = const []]) {
    _guides = guides;
    _preview = _gesture!.start.replaceElement(_pageIndex, e);
    notifyListeners();
  }

  /// Verschieben um die Gesamtverschiebung ([dx], [dy]) mm seit Beginn der Geste.
  /// Mit [free] (Alt-Taste) wird nicht eingerastet.
  void updateMove(double dx, double dy, {bool free = false}) {
    final g = _gesture;
    if (g == null) return;
    var moved = g.startBox.translate(dx, dy);
    var guides = const <Guide>[];
    if (!free) {
      final r = snapMove(moved, g.targets, _snapSettings());
      moved = r.box;
      guides = r.guides;
    }
    _previewElement(g.element.translated(moved.x - g.startBox.x, moved.y - g.startBox.y), guides);
  }

  /// Griff ziehen um ([dx], [dy]) mm seit Beginn der Geste. Die gezogene Kante rastet ein.
  void updateResize(Handle handle, double dx, double dy, {bool free = false}) {
    final g = _gesture;
    if (g == null) return;
    final s = g.startBox;
    final guides = <Guide>[];
    double snapEdge(double edge, SnapAxis axis) {
      if (free) return edge;
      final r = snapValue(edge, axis, g.targets, _snapSettings());
      if (r.guide != null) guides.add(r.guide!);
      return r.value;
    }

    final keepAspect = g.element is ImageBlock && handle.isCorner;
    Box box;
    if (keepAspect) {
      // Bilder an der Ecke: Seitenverhältnis bleibt; eingerastet wird die gezogene senkrechte Kante.
      final raw = resizeBox(s, handle, dx, dy, keepAspect: true);
      final edge = handle.movesRight ? raw.right : raw.x;
      final snapped = snapEdge(edge, SnapAxis.vertical);
      final w = handle.movesRight ? snapped - s.x : s.right - snapped;
      box = resizeBox(s, handle, (w - s.w) * (handle.movesRight ? 1 : -1), 0, keepAspect: true);
    } else {
      var ddx = dx, ddy = dy;
      if (handle.movesLeft) ddx = snapEdge(s.x + dx, SnapAxis.vertical) - s.x;
      if (handle.movesRight) ddx = snapEdge(s.right + dx, SnapAxis.vertical) - s.right;
      if (handle.movesTop) ddy = snapEdge(s.y + dy, SnapAxis.horizontal) - s.y;
      if (handle.movesBottom) ddy = snapEdge(s.bottom + dy, SnapAxis.horizontal) - s.bottom;
      box = resizeBox(s, handle, ddx, ddy);
    }
    switch (g.element) {
      case TextBlock t:
        // Nur die Breite ist einstellbar; die Höhe folgt dem Text.
        _previewElement(t.copyWith(box: box.copyWith(h: t.box.h)), guides);
      case ImageBlock i:
        // Ecken: Grösse mit Seitenverhältnis. Seiten: Form ändern, das Bild füllt den Rahmen.
        _previewElement(i.copyWith(box: box), guides);
      case RectShape r:
        _previewElement(r.copyWith(box: box), guides);
      case LineShape _:
        break;
      case TableBlock t:
        // Breite ändern: alle Spalten im gleichen Verhältnis, die Höhe folgt dem Text
        _previewElement(t.copyWith(x: box.x).withWidth(box.w.clamp(5.0 * t.columnCount, 1000.0)), guides);
    }
  }

  /// Linie zwischen zwei Spalten ziehen ([border] = Index der rechten Spalte), [dx] mm seit Beginn.
  void updateColumnBorder(int border, double dx) {
    final g = _gesture;
    if (g == null || g.element is! TableBlock) return;
    _previewElement((g.element as TableBlock).moveColumnBorder(border, dx));
  }

  /// Endpunkt einer Linie ziehen. In der Nähe der Waagrechten oder Senkrechten rastet sie gerade ein,
  /// sonst an Zielen bzw. am Raster.
  void updateLineEnd(bool endA, double dx, double dy, {bool free = false}) {
    final g = _gesture;
    if (g == null || g.element is! LineShape) return;
    final l = g.element as LineShape;
    final moving = endA ? l.a : l.b;
    final fixed = endA ? l.b : l.a;
    var x = moving.x + dx, y = moving.y + dy;
    final guides = <Guide>[];
    if (!free) {
      const straight = 2.0; // mm
      final s = _snapSettings();
      void add(SnapResult r) {
        if (r.guide != null) guides.add(r.guide!);
      }

      if ((y - fixed.y).abs() < straight) {
        y = fixed.y;
        final r = snapValue(x, SnapAxis.vertical, g.targets, s);
        x = r.value;
        add(r);
      } else if ((x - fixed.x).abs() < straight) {
        x = fixed.x;
        final r = snapValue(y, SnapAxis.horizontal, g.targets, s);
        y = r.value;
        add(r);
      } else {
        final rx = snapValue(x, SnapAxis.vertical, g.targets, s);
        final ry = snapValue(y, SnapAxis.horizontal, g.targets, s);
        x = rx.value;
        y = ry.value;
        add(rx);
        add(ry);
      }
    }
    final p = Pt(x, y);
    _previewElement(endA ? l.copyWith(a: p) : l.copyWith(b: p), guides);
  }

  void endGesture() {
    final next = _preview;
    _gesture = null;
    _guides = const [];
    if (next != null) {
      commit(next);
    } else {
      notifyListeners();
    }
  }

  void cancelGesture() {
    if (_gesture == null) return;
    _gesture = null;
    _guides = const [];
    _preview = null;
    notifyListeners();
  }

  bool get isGestureActive => _gesture != null;

  // ---------- Textbearbeitung ----------

  /// Klick in den Text: Bearbeitung starten, Cursor an [caret] (gesperrte Blöcke werden nur ausgewählt).
  void startEditing(TextBlock t, int caret) {
    finishEditing();
    _selectedId = t.id;
    if (t.locked) {
      notifyListeners(); // gesperrt: nur auswählen
      return;
    }
    _editingId = t.id;
    _lastTouchedId = t.id;
    _editStart = history.present;
    textController.load(t, TextSelection.collapsed(offset: caret));
    notifyListeners();
    WidgetsBinding.instance.addPostFrameCallback((_) => textFocus.requestFocus());
  }

  /// In eine Tabellenzelle schreiben, Cursor an [caret].
  void startCellEditing(TableBlock t, int row, int col, [int? caret]) {
    finishEditing();
    _selectedId = t.id;
    _activeCell = (row: row, col: col);
    if (t.locked) {
      notifyListeners();
      return;
    }
    _editingId = t.id;
    _cell = (row: row, col: col);
    _editStart = history.present;
    final text = t.cells[row][col];
    textController.load(tableCellBlock(t, row, col, top: 0), TextSelection.collapsed(offset: caret ?? text.length));
    notifyListeners();
    WidgetsBinding.instance.addPostFrameCallback((_) => textFocus.requestFocus());
  }

  /// Tab bzw. Umschalt+Tab: nächste bzw. vorherige Zelle. Nach der letzten Zelle entsteht eine neue Zeile.
  void moveToCell(int direction) {
    final cell = _cell;
    final id = _editingId;
    if (cell == null || id == null) return;
    finishEditing();
    var t = page.find(id);
    if (t is! TableBlock) return;
    var index = cell.row * t.columnCount + cell.col + direction;
    if (index < 0) index = 0;
    if (index >= t.rowCount * t.columnCount) {
      t = t.insertRow(t.rowCount);
      commit(doc.replaceElement(_pageIndex, t));
    }
    startCellEditing(t, index ~/ t.columnCount, index % t.columnCount, 0);
    textController.selection = TextSelection(baseOffset: 0, extentOffset: textController.text.length);
  }

  /// Text während der Bearbeitung: Vorschau, damit Höhe und Auswahlrahmen mitwachsen.
  void onEditingChanged() {
    final id = _editingId;
    final start = _editStart;
    if (id == null || start == null) return;
    final cell = _cell;
    if (cell != null) {
      final t = start.page(_pageIndex).find(id);
      if (t is! TableBlock) return;
      _preview = start.replaceElement(_pageIndex, t.withCell(cell.row, cell.col, textController.text));
      notifyListeners();
      return;
    }
    final t = start.page(_pageIndex).find(id);
    if (t is! TextBlock) return;
    _preview = start.replaceElement(_pageIndex, t.copyWith(text: textController.text, runs: textController.runs));
    notifyListeners();
  }

  /// Beendet die Bearbeitung; die Änderung wird ein einziger Rückgängig-Schritt.
  /// Ein leerer Textblock wird entfernt (Spezifikation 4.1).
  void finishEditing() {
    final id = _editingId;
    final start = _editStart;
    if (id == null || start == null) return;
    _editingId = null;
    _editStart = null;
    _preview = null;
    textController.stopSpellCheck();
    textFocus.unfocus();
    final cell = _cell;
    _cell = null;
    if (cell != null) {
      final tb = start.page(_pageIndex).find(id);
      final text = textController.text;
      if (tb is TableBlock && cell.row < tb.rowCount && cell.col < tb.columnCount && tb.cells[cell.row][cell.col] != text) {
        commit(start.replaceElement(_pageIndex, tb.withCell(cell.row, cell.col, text)));
        return;
      }
      notifyListeners();
      return;
    }
    final t = start.page(_pageIndex).find(id);
    if (t is TextBlock) {
      final text = textController.text;
      if (text.trim().isEmpty) {
        if (_selectedId == id) _selectedId = null;
        commit(start.removeElement(_pageIndex, id));
        return;
      }
      final runs = textController.runs;
      if (text != t.text || !_sameRuns(runs, t.runs)) {
        commit(start.replaceElement(_pageIndex, t.copyWith(text: text, runs: runs)));
        return;
      }
    }
    notifyListeners();
  }

  // ---------- Elemente ----------

  /// Zuletzt ausgewähltes oder bearbeitetes Element (Bezugspunkt für das nächste Einfügen).
  String? _lastTouchedId;

  /// Zählt jedes Einfügen (die Ansicht scrollt dann zum neuen Element).
  int insertCount = 0;

  /// Platz für ein neues Element ([w] × [h] mm): unter dem zuletzt bearbeiteten Element, sonst unter dem
  /// untersten; nie über Bestehendem. Ist dort kein Platz, die erste freie Stelle von oben, zuletzt ganz unten.
  Box placeNew(double w, double h, {double? x}) {
    final ph = doc.pageHeight;
    final left = x ?? pageMarginMm;
    final boxes = [for (final e in page.elements) renderedBox(e)];
    bool free(double y) {
      final b = Box(left, y, w, h);
      return boxes.every((o) => !b.overlaps(o, tolerance: .1));
    }

    final anchor = _lastTouchedId == null ? null : page.find(_lastTouchedId!);
    final start = anchor != null
        ? renderedBox(anchor).bottom + 4
        : boxes.isEmpty
            ? pageMarginMm
            : boxes.map((b) => b.bottom).reduce((a, b) => a > b ? a : b) + 4;
    final last = ph - pageMarginMm - h;
    for (var y = start; y <= last; y += 2) {
      if (free(y)) return Box(left, y, w, h);
    }
    for (var y = pageMarginMm; y <= last; y += 2) {
      if (free(y)) return Box(left, y, w, h);
    }
    return Box(left, start.clamp(pageMarginMm, ph - h).toDouble(), w, h);
  }

  void _add(DocElement e, {bool edit = false}) {
    _settle();
    commit(doc.addElement(_pageIndex, e));
    _selectedId = e.id;
    _lastTouchedId = e.id;
    insertCount++;
    if (edit && e is TextBlock) {
      startEditing(e, 0);
      textController.selection = TextSelection(baseOffset: 0, extentOffset: e.text.length);
    }
    notifyListeners();
  }

  void addText({TextKind kind = TextKind.body}) {
    final w = doc.pageWidth - 2 * pageMarginMm;
    final probe = TextBlock.ofKind(id: newId(), box: Box(0, 0, w, 10), text: kind == TextKind.title ? 'Titel' : 'Neuer Text', kind: kind);
    final h = renderedBox(probe).h;
    _add(probe.copyWith(box: placeNew(w, h).copyWith(h: h)), edit: true);
  }

  void addRect() => _add(RectShape(id: newId(), box: placeNew(100, 50)));
  void addLine() {
    final b = placeNew(doc.pageWidth - 2 * pageMarginMm, 4);
    _add(LineShape(id: newId(), a: Pt(b.x, b.y + 2), b: Pt(b.right, b.y + 2)));
  }

  /// Neue Tabelle über die Breite zwischen den Seitenrändern; danach wird in die erste Zelle geschrieben.
  void addTable(int columns, {int rows = 3, bool headerRow = true}) {
    final w = doc.pageWidth - 2 * pageMarginMm;
    final probe = TableBlock.empty(id: newId(), x: pageMarginMm, y: 0, width: w, cols: columns, rows: rows, headerRow: headerRow);
    final t = probe.copyWith(y: placeNew(w, renderedBox(probe).h).y);
    _add(t);
    startCellEditing(t, 0, 0, 0);
  }

  /// Ändert die ausgewählte Tabelle (Eigenschaftenleiste). Eine laufende Zellbearbeitung wird zuerst übernommen.
  void updateSelectedTable(TableBlock Function(TableBlock t) change, {Object? mergeKey}) {
    final sel = selected;
    if (sel is! TableBlock || sel.locked) return;
    _settle();
    final current = page.find(sel.id);
    if (current is! TableBlock) return;
    commit(doc.replaceElement(_pageIndex, change(current)), mergeKey: mergeKey == null ? null : '$mergeKey:${sel.id}');
  }

  /// Zelle wählen, ohne zu schreiben (z. B. Rechtsklick): Knöpfe für Zeile und Spalte erscheinen dort.
  void selectCell(TableBlock t, int row, int col) {
    finishEditing();
    history.breakMerge();
    _selectedId = t.id;
    _activeCell = (row: row, col: col);
    notifyListeners();
  }

  /// Neue Zeile vor Zeile [at]; danach wird gleich in die neue Zeile geschrieben (gleiche Spalte).
  void insertTableRow(int at) {
    final col = _activeCell?.col ?? 0;
    updateSelectedTable((t) => t.insertRow(at));
    final t = selected;
    if (t is TableBlock) startCellEditing(t, at.clamp(0, t.rowCount - 1), col.clamp(0, t.columnCount - 1), 0);
  }

  /// Neue Spalte vor Spalte [at]; danach wird gleich in die neue Spalte geschrieben (gleiche Zeile).
  void insertTableColumn(int at) {
    final row = _activeCell?.row ?? 0;
    updateSelectedTable((t) => t.insertColumn(at));
    final t = selected;
    if (t is TableBlock) startCellEditing(t, row.clamp(0, t.rowCount - 1), at.clamp(0, t.columnCount - 1), 0);
  }

  /// Zeile bzw. Spalte der gewählten Zelle löschen.
  void deleteTableRow() {
    final c = _activeCell;
    if (c == null) return;
    updateSelectedTable((t) => t.removeRow(c.row));
    final t = selected;
    if (t is TableBlock) _activeCell = (row: c.row.clamp(0, t.rowCount - 1), col: c.col);
    notifyListeners();
  }

  void deleteTableColumn() {
    final c = _activeCell;
    if (c == null) return;
    updateSelectedTable((t) => t.removeColumn(c.col));
    final t = selected;
    if (t is TableBlock) _activeCell = (row: c.row, col: c.col.clamp(0, t.columnCount - 1));
    notifyListeners();
  }

  void deleteSelected() {
    final id = _selectedId;
    final e = selected;
    if (id == null || e == null || e.locked) return;
    _settle();
    _selectedId = null;
    commit(doc.removeElement(_pageIndex, id));
    onDeleted?.call(e);
  }

  /// Ein Element wurde gelöscht (für die Meldung mit «Rückgängig»).
  void Function(DocElement deleted)? onDeleted;

  /// Stand des Verlaufs (Änderungszähler), als eine Meldung «Rückgängig» anbot (null: keine Meldung).
  int? _offerVersion;

  /// Eine Meldung bietet «Rückgängig» für den gerade gemachten Schritt an.
  void offerUndo() => _offerVersion = history.version;

  /// Gibt es ein Angebot, das inzwischen nicht mehr gilt (weil weitergearbeitet wurde)?
  bool get undoOfferStale => _offerVersion != null && _offerVersion != history.version;
  void clearUndoOffer() => _offerVersion = null;

  /// «Rückgängig» aus einer Meldung: nur, wenn seither nichts anderes geändert wurde.
  void undoOffered() {
    if (_offerVersion != null && _offerVersion == history.version) undo();
    _offerVersion = null;
  }

  void duplicateSelected() {
    final e = selected;
    if (e == null) return;
    _settle();
    final copy = e.withId(newId()).translated(5, 5).withLocked(false);
    commit(doc.addElement(_pageIndex, copy));
    _selectedId = copy.id;
    notifyListeners();
  }

  /// Pfeiltasten: aufeinanderfolgende Schritte am selben Element sind ein Rückgängig-Schritt.
  void nudgeSelected(double dx, double dy) {
    final e = selected;
    if (e == null || e.locked) return;
    _settle();
    commit(doc.replaceElement(_pageIndex, e.translated(dx, dy)), mergeKey: 'nudge:${e.id}');
  }

  void toggleLockSelected() {
    _settle();
    final e = selected;
    if (e == null) return;
    commit(doc.replaceElement(_pageIndex, e.withLocked(!e.locked)));
  }

  void bringSelectedToFront() {
    _settle();
    if (_selectedId != null) commit(doc.bringToFront(_pageIndex, _selectedId!));
  }

  void sendSelectedToBack() {
    _settle();
    if (_selectedId != null) commit(doc.sendToBack(_pageIndex, _selectedId!));
  }

  void replaceSelected(DocElement e) {
    _settle();
    commit(doc.replaceElement(_pageIndex, e));
  }

  /// Ändert Stil oder Einstellungen des ausgewählten Textblocks (Eigenschaftenleiste).
  ///
  /// Während des Schreibens bleibt die Bearbeitung offen: Der bisher getippte Text und die
  /// Stiländerung werden ein Schritt, danach geht das Schreiben nahtlos weiter.
  /// Mit [mergeKey] werden wiederholte Klicks (z. B. Schriftgrösse +) zu einem Schritt.
  void updateSelectedText(TextBlock Function(TextBlock t) change, {Object? mergeKey}) {
    final sel = selected;
    if (sel is! TextBlock || sel.locked) return;
    _settleGesture();
    final start = _editStart;
    if (_editingId == sel.id && start != null) {
      final base = start.page(_pageIndex).find(sel.id);
      if (base is! TextBlock) return;
      final next = change(base.copyWith(text: textController.text, runs: textController.runs));
      _preview = null;
      history.push(start.replaceElement(_pageIndex, next));
      _editStart = history.present;
      textController.updateBlock(next);
      notifyListeners();
      return;
    }
    commit(doc.replaceElement(_pageIndex, change(sel)), mergeKey: mergeKey == null ? null : '$mergeKey:${sel.id}');
  }

  /// Ändert Einstellungen eines ausgewählten Rechtecks bzw. einer Linie (Eigenschaftenleiste).
  void updateSelectedRect(RectShape Function(RectShape r) change) {
    final sel = selected;
    if (sel is! RectShape || sel.locked) return;
    _settle();
    commit(doc.replaceElement(_pageIndex, change(sel)));
  }

  void updateSelectedLine(LineShape Function(LineShape l) change) {
    final sel = selected;
    if (sel is! LineShape || sel.locked) return;
    _settle();
    commit(doc.replaceElement(_pageIndex, change(sel)));
  }

  // ---------- Bilder ----------

  /// Fügt ein aufbereitetes Bild ein: Bilddatei und Bildblock sind ein Rückgängig-Schritt.
  /// [center] in mm (z. B. Stelle, an die eine Datei gezogen wurde), sonst Seitenmitte.
  /// Grösse: höchstens 110 × 130 mm, Seitenverhältnis wie das Original, ganz auf der Seite.
  ImageBlock insertImage(ImageAsset asset, {Pt? center}) {
    _settle();
    final aspect = asset.width / asset.height;
    var w = 110.0, h = w / aspect;
    if (h > 130) {
      h = 130;
      w = h * aspect;
    }
    final pw = doc.pageWidth, ph = doc.pageHeight;
    if (h > ph - 2 * pageMarginMm) {
      // Querformat: nicht höher als die Seite
      h = ph - 2 * pageMarginMm;
      w = h * aspect;
    }
    // gezogen: an die Stelle der Maus; sonst wie jedes neue Element an der Arbeitsstelle
    final Box box;
    if (center != null) {
      box = Box((center.x - w / 2).clamp(0.0, pw - w).toDouble(), (center.y - h / 2).clamp(0.0, ph - h).toDouble(), w, h);
    } else {
      box = placeNew(w, h);
    }
    final block = ImageBlock(
      id: newId(),
      box: box,
      asset: asset.id,
      naturalWidth: asset.width,
      naturalHeight: asset.height,
    );
    commit(doc.addAsset(asset).addElement(_pageIndex, block));
    _selectedId = block.id;
    _lastTouchedId = block.id;
    insertCount++;
    notifyListeners();
    return block;
  }

  /// «Anderes Bild wählen»: Rahmen bleibt, Ausschnitt wird zurückgesetzt.
  void replaceSelectedImage(ImageAsset asset) {
    final sel = selected;
    if (sel is! ImageBlock || sel.locked) return;
    _settle();
    commit(doc.addAsset(asset).replaceElement(
          _pageIndex,
          sel.copyWith(asset: asset.id, naturalWidth: asset.width, naturalHeight: asset.height, cropX: .5, cropY: .5, zoom: 1, quarterTurns: 0),
        ));
  }

  /// Ausgewähltes Bild um 90° drehen (gesperrte Bilder bleiben).
  void rotateSelectedImage({bool clockwise = true}) {
    final sel = selected;
    if (sel is ImageBlock && !sel.locked) updateSelectedImage((i) => withQuarterTurn(i, clockwise: clockwise));
  }

  void updateSelectedImage(ImageBlock Function(ImageBlock i) change, {Object? mergeKey}) {
    final sel = selected;
    if (sel is! ImageBlock || sel.locked) return;
    // Während eines Ausschnitt-Ziehens ändert die Vorschau das Bild; eine Änderung von aussen beendet sie.
    _settle();
    final current = page.find(sel.id);
    if (current is! ImageBlock) return;
    commit(doc.replaceElement(_pageIndex, change(current)), mergeKey: mergeKey == null ? null : '$mergeKey:${sel.id}');
  }

  TextlyDocument? _previewStart;

  void _cancelPreview() {
    if (_previewStart == null) return;
    _previewStart = null;
    _preview = null;
    notifyListeners();
  }

  /// Laufende Geste bzw. Vorschau übernehmen, bevor ein anderer Befehl das Dokument ändert.
  /// Sonst setzt das Ende der Geste den alten Stand zurück (z. B. Entf während des Ziehens).
  void _settleGesture() {
    if (_gesture != null) endGesture();
    if (_previewStart != null) endPreview();
  }

  /// Wie [_settleGesture], zusätzlich das Schreiben beenden.
  void _settle() {
    finishEditing();
    _settleGesture();
  }

  /// Vorschau ohne Verlaufseintrag, z. B. während der Bildausschnitt gezogen wird.
  /// [endPreview] übernimmt das Ergebnis als einen Schritt.
  void beginPreview() {
    _settle();
    history.breakMerge();
    _previewStart = history.present;
  }

  void previewSelected(DocElement e) {
    final start = _previewStart;
    if (start == null) return;
    _preview = start.replaceElement(_pageIndex, e);
    notifyListeners();
  }

  void endPreview() {
    final next = _preview;
    _previewStart = null;
    if (next != null) {
      commit(next);
    } else {
      notifyListeners();
    }
  }

  // ---------- Formatierung einzelner Textstellen ----------

  /// Beim Schreiben ist Text markiert: Formatierung wirkt auf die Markierung, sonst auf den ganzen Block.
  bool get hasTextSelection {
    final sel = textController.selection;
    return _editingId != null && _editingId == _selectedId && sel.isValid && !sel.isCollapsed;
  }

  /// Bereich, auf den Formatierung wirkt (Markierung oder ganzer Text).
  (int, int) _formatRange(TextBlock t) {
    if (hasTextSelection) {
      final sel = textController.selection;
      return (sel.start, sel.end);
    }
    return (0, _editingId == t.id ? textController.text.length : t.text.length);
  }

  bool _attrOf(TextBlock t, InlineAttr a, int i) {
    final e = t.effectiveAt(i);
    return switch (a) { InlineAttr.bold => e.bold, InlineAttr.italic => e.italic, InlineAttr.underline => e.underline };
  }

  /// Hat jedes Zeichen im wirksamen Bereich die Eigenschaft? (für die Anzeige in der Leiste)
  bool inlineActive(InlineAttr a) {
    final t = _currentText();
    if (t == null) return false;
    final (from, to) = _formatRange(t);
    if (from >= to) return a == InlineAttr.bold ? t.bold : a == InlineAttr.italic ? t.italic : false;
    for (var i = from; i < to; i++) {
      if (!_attrOf(t, a, i)) return false;
    }
    return true;
  }

  /// Einheitliche Farbe im wirksamen Bereich, sonst null.
  int? inlineColor() {
    final t = _currentText();
    if (t == null) return null;
    final (from, to) = _formatRange(t);
    if (from >= to) return t.color;
    final c = t.effectiveAt(from).color;
    for (var i = from + 1; i < to; i++) {
      if (t.effectiveAt(i).color != c) return null;
    }
    return c;
  }

  /// Ausgewählter Textblock mit dem aktuellen Stand des Eingabefelds.
  TextBlock? _currentText() {
    final sel = selected;
    if (sel is! TextBlock) return null;
    if (_editingId == sel.id) return sel.copyWith(text: textController.text, runs: textController.runs);
    return sel;
  }

  /// Was gerade geschrieben wird, als Textblock (bei Tabellen die Zelle).
  TextBlock? _editingTextBlock() {
    final cell = _cell;
    final sel = selected;
    if (cell != null && sel is TableBlock && cell.row < sel.rowCount && cell.col < sel.columnCount) {
      return tableCellBlock(sel, cell.row, cell.col, top: 0, text: textController.text);
    }
    final t = _currentText();
    return t != null && _editingId == t.id ? t : null;
  }

  InlineStyle _patch(InlineAttr a, bool v) => switch (a) {
        InlineAttr.bold => InlineStyle(bold: v),
        InlineAttr.italic => InlineStyle(italic: v),
        InlineAttr.underline => InlineStyle(underline: v),
      };

  /// Fett/Kursiv/Unterstrichen umschalten: für die Markierung, sonst für den ganzen Block.
  ///
  /// [fromKeyboard] (Strg+B/I/U) ohne Markierung beim Schreiben: gilt für das als Nächstes Getippte.
  void toggleInline(InlineAttr a, {bool fromKeyboard = false}) {
    final t = _currentText();
    if (t == null) return;
    final on = inlineActive(a);
    if (_editingId == t.id && !hasTextSelection && fromKeyboard) {
      final caret = textController.selection.baseOffset;
      final here = caret > 0 ? t.effectiveAt(caret - 1) : (bold: t.bold, italic: t.italic, underline: false, color: t.color);
      final current = switch (a) { InlineAttr.bold => here.bold, InlineAttr.italic => here.italic, InlineAttr.underline => here.underline };
      final base = textController.pending ?? (caret > 0 ? styleAt(textController.runs, caret - 1) : InlineStyle.none);
      textController.pending = base.merge(_patch(a, !current));
      notifyListeners();
      return;
    }
    if (hasTextSelection) {
      final (from, to) = _formatRange(t);
      _setRunsWhileEditing(applyInlineStyle(textController.runs, textController.text.length, from, to, _patch(a, !on)));
      return;
    }
    // ganzer Block: Blockstil setzen und Abweichungen dieser Eigenschaft entfernen
    updateSelectedText((b) {
      final len = b.text.length;
      return switch (a) {
        InlineAttr.bold => b.copyWith(bold: !on, runs: clearInlineAttribute(b.runs, len, bold: true)),
        InlineAttr.italic => b.copyWith(italic: !on, runs: clearInlineAttribute(b.runs, len, italic: true)),
        InlineAttr.underline => b.copyWith(
            runs: on
                ? clearInlineAttribute(b.runs, len, underline: true)
                : applyInlineStyle(b.runs, len, 0, len, const InlineStyle(underline: true)),
          ),
      };
    });
  }

  /// Schriftfarbe für die Markierung, sonst für den ganzen Block.
  void setInlineColor(int color) {
    final t = _currentText();
    if (t == null) return;
    if (hasTextSelection) {
      final (from, to) = _formatRange(t);
      _setRunsWhileEditing(applyInlineStyle(textController.runs, textController.text.length, from, to, InlineStyle(color: color)));
      return;
    }
    updateSelectedText((b) => b.copyWith(color: color, runs: clearInlineAttribute(b.runs, b.text.length, color: true)));
  }

  /// Formatierung beim Schreiben ändern: ein Rückgängig-Schritt, Markierung und Cursor bleiben.
  void _setRunsWhileEditing(List<StyleRun> runs) => updateSelectedText(
        (b) => b.copyWith(runs: simplifyRuns(runs, b.text.length, bold: b.bold, italic: b.italic, color: b.color)),
      );

  static bool _sameRuns(List<StyleRun> a, List<StyleRun> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  // ---------- Cursor nach oben/unten ----------

  double? _goalX;
  TextSelection? _goalSelection;

  /// Cursor eine Zeile nach oben ([dir] = -1) oder unten (+1); mit [extend] wird markiert.
  ///
  /// Ersetzt Flutters eigene Bewegung: Diese bricht bei zentriertem oder rechtsbündigem Text ab
  /// (VerticalCaretMovementRun.isValid vergleicht Zeilenlisten auf Identität, TextPainter liefert
  /// bei Ausrichtungsversatz aber jedes Mal eine neue Liste) – der Cursor blieb stehen.
  /// Grundlage ist der gemeinsame Textsatz, der deckungsgleich mit dem Eingabefeld ist.
  void moveCaretVertically(int dir, {bool extend = false}) {
    final t = _editingTextBlock();
    if (t == null) return;
    final sel = textController.selection;
    if (!sel.isValid) return;
    final tp = layoutText(t);
    final lines = tp.computeLineMetrics();
    if (lines.isEmpty) return;
    final caret = tp.getOffsetForCaret(sel.extent, Rect.zero);
    if (_goalSelection != sel) _goalX = null;
    final x = _goalX ?? caret.dx;
    var line = 0;
    for (var i = 0; i < lines.length; i++) {
      if (caret.dy >= lines[i].baseline - lines[i].ascent - .5) line = i;
    }
    final target = line + dir;
    final TextPosition pos;
    if (target < 0) {
      pos = const TextPosition(offset: 0);
    } else if (target >= lines.length) {
      pos = TextPosition(offset: textController.text.length);
    } else {
      final l = lines[target];
      pos = tp.getPositionForOffset(Offset(x, l.baseline - l.ascent / 2));
    }
    final next = extend ? sel.extendTo(pos) : TextSelection.fromPosition(pos);
    textController.selection = next;
    _goalX = x;
    _goalSelection = next;
  }

  @override
  void dispose() {
    textController.dispose();
    textFocus.dispose();
    super.dispose();
  }
}
