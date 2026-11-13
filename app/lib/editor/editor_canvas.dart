import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:doc_model/doc_model.dart';
import 'package:doc_render/doc_render.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'editor_controller.dart';
import 'floating_bars.dart';
import 'toolbar_widgets.dart';

const _selectionBlue = Ui.accent;

/// Die bearbeitbare Seite. Intern in Punkt (595 × 842) aufgebaut und mit [zoom] skaliert:
/// 1 Punkt der Seite entspricht [zoom] logischen Bildschirmpunkten.
class EditorCanvas extends StatelessWidget {
  const EditorCanvas({super.key, required this.controller, required this.zoom, this.onPickImage});
  final EditorController controller;
  final double zoom;

  /// «Bild» auf der leeren Seite (öffnet die Dateiauswahl der Hauptansicht).
  final VoidCallback? onPickImage;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        controller.viewZoom = zoom; // Einrast-Distanz in mm hängt vom Zoom ab
        final page = controller.page;
        final sel = controller.selected;
        final pw = controller.doc.pageWidth, ph = controller.doc.pageHeight; // Hoch- oder Querformat
        return SizedBox(
          width: pw * mmToPt * zoom,
          height: ph * mmToPt * zoom,
          child: FittedBox(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: pw * mmToPt,
              height: ph * mmToPt,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: GestureDetector(
                      key: const ValueKey('page-background'),
                      behavior: HitTestBehavior.opaque,
                      onTap: () => controller.select(null), // nicht onTapDown, siehe editor_page.dart
                      child: const ColoredBox(color: Colors.white),
                    ),
                  ),
                  // Seitenrand 15 mm als Hilfslinie (wird nicht gedruckt)
                  if (controller.showGrid)
                    Positioned.fill(
                      child: IgnorePointer(child: CustomPaint(painter: _GridPainter(controller.gridSize))),
                    ),
                  const Positioned.fill(
                    child: IgnorePointer(child: CustomPaint(painter: _MarginPainter())),
                  ),
                  Positioned.fill(
                    child: ClipRect(
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [for (final e in page.elements) _ElementLayer(controller: controller, element: e, zoom: zoom)],
                      ),
                    ),
                  ),
                  // Überdeckte Elemente orange markieren (Spezifikation 5)
                  for (final o in controller.overlapsOfSelected())
                    Positioned.fromRect(
                      rect: elementRectPt(o),
                      child: IgnorePointer(
                        child: DecoratedBox(
                          key: ValueKey('overlap-${o.id}'),
                          decoration: BoxDecoration(
                            color: const Color(0x12D98A00),
                            border: Border.all(color: const Color(0xFFD98A00), width: 2 / zoom),
                          ),
                        ),
                      ),
                    ),
                  // Leere Seite: klarer Anfang mit Startknöpfen (verschwinden mit dem ersten Element)
                  if (page.elements.isEmpty)
                    Positioned(
                      left: 0,
                      right: 0,
                      top: pw > ph ? 70 : 130,
                      child: Center(
                        // Gleich gross auf dem Bildschirm, egal wie weit herausgezoomt ist – aber nie breiter als die Seite
                        child: Transform.scale(
                          scale: math.min(1 / zoom, pw * mmToPt * .92 / _StartPanel.width),
                          alignment: Alignment.topCenter,
                          child: _StartPanel(controller: controller, onPickImage: onPickImage),
                        ),
                      ),
                    ),
                  if (sel != null) ..._selection(sel),
                  // Ausrichtungslinien während des Ziehens
                  if (controller.guides.isNotEmpty)
                    Positioned.fill(
                      child: IgnorePointer(child: CustomPaint(painter: _GuidePainter(controller.guides, zoom))),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// Auswahl ohne Schreiben: Kopie, Drehen, Löschen, … direkt unter dem Element (Tabellen haben eigene Knöpfe).
  Widget _selectionBar(DocElement e, Rect r) => Positioned.fill(
    child: FloatingAnchor(
      key: const ValueKey('float-selection-anchor'),
      at: Offset(r.left, (e is LineShape ? r.bottom + 6 / zoom : r.bottom) + 10 / zoom),
      align: Alignment.topLeft,
      zoom: zoom,
      child: SelectionBar(controller: controller, element: e),
    ),
  );

  List<Widget> _selection(DocElement e) {
    final r = elementRectPt(e);
    final editing = controller.editingId == e.id;
    final hs = 14 / zoom; // Griffe immer gleich gross auf dem Bildschirm
    final widgets = <Widget>[
      Positioned.fromRect(
        rect: e is LineShape ? r.inflate(4 / zoom) : r,
        child: IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: _selectionBlue, width: (editing ? 1 : 1.5) / zoom),
            ),
          ),
        ),
      ),
    ];
    if (e.locked) {
      widgets.add(
        Positioned(
          left: r.left,
          top: r.top - 18 / zoom,
          child: IgnorePointer(
            child: _Badge(text: 'Gesperrt', zoom: zoom),
          ),
        ),
      );
      widgets.add(_selectionBar(e, r)); // nur «Entsperren»
      return widgets;
    }
    if (e is LineShape) {
      for (final (endA, p) in [(true, e.a), (false, e.b)]) {
        widgets.add(
          _HandleWidget(
            key: ValueKey('handle-${endA ? 'a' : 'b'}'),
            center: Offset(p.x, p.y) * mmToPt,
            size: hs,
            zoom: zoom,
            round: true,
            cursor: SystemMouseCursors.precise,
            onStart: () => controller.beginGesture(e.id),
            onUpdate: (dx, dy, free) => controller.updateLineEnd(endA, dx, dy, free: free),
            onEnd: controller.endGesture,
          ),
        );
      }
      widgets.add(_selectionBar(e, r));
      return widgets;
    }
    final handles = switch (e) {
      TextBlock _ || TableBlock _ => const [Handle.w, Handle.e],
      _ => Handle.values,
    };
    for (final h in handles) {
      final c = Offset(
        h.movesLeft
            ? r.left
            : h.movesRight
            ? r.right
            : r.center.dx,
        h.movesTop
            ? r.top
            : h.movesBottom
            ? r.bottom
            : r.center.dy,
      );
      widgets.add(
        _HandleWidget(
          key: ValueKey('handle-${h.name}'),
          center: c,
          size: hs,
          zoom: zoom,
          round: h.isCorner,
          horizontalBar: h == Handle.n || h == Handle.s,
          cursor: switch (h) {
            Handle.nw || Handle.se => SystemMouseCursors.resizeUpLeftDownRight,
            Handle.ne || Handle.sw => SystemMouseCursors.resizeUpRightDownLeft,
            Handle.n || Handle.s => SystemMouseCursors.resizeUpDown,
            Handle.e || Handle.w => SystemMouseCursors.resizeLeftRight,
          },
          onStart: () => controller.beginGesture(e.id),
          onUpdate: (dx, dy, free) => controller.updateResize(h, dx, dy, free: free),
          onEnd: controller.endGesture,
        ),
      );
    }
    if (e is TextBlock || e is TableBlock) {
      // Griff zum Verschieben, damit ein Klick in den Text keinen Drag auslöst (Spezifikation 7.1).
      final above = r.top > 36 / zoom;
      widgets.add(
        Positioned(
          left: r.left,
          top: above ? r.top - 32 / zoom : r.bottom + 4 / zoom,
          child: _DragArea(
            key: const ValueKey('move-grip'),
            zoom: zoom,
            cursor: SystemMouseCursors.grab,
            onStart: () => controller.beginGesture(e.id),
            onUpdate: (dx, dy, free) => controller.updateMove(dx, dy, free: free),
            onEnd: controller.endGesture,
            child: _Badge(text: 'Verschieben', zoom: zoom, icon: Icons.open_with_rounded, filled: true, large: true),
          ),
        ),
      );
    }
    // Schreiben: Textleiste über dem Text (unter dem Text, wenn oben kein Platz ist)
    if (e is TextBlock && editing) {
      // darüber, auch über den Seitenrand hinaus (die Leiste liegt in der obersten Ebene); nur ganz oben darunter
      final above = r.top * zoom > 30;
      widgets.add(
        Positioned.fill(
          child: FloatingAnchor(
            key: const ValueKey('float-text-anchor'),
            at: above ? Offset(r.left, r.top - 28 / zoom) : Offset(r.left, r.bottom + 8 / zoom),
            align: above ? Alignment.bottomLeft : Alignment.topLeft,
            zoom: zoom,
            child: TextBar(controller: controller, block: e),
          ),
        ),
      );
    }
    if (!editing && e is! TableBlock) widgets.add(_selectionBar(e, r));
    // Tabelle: Löschen (und vorne/hinten bei Überdeckung) unten rechts, weg von «+ Zeile»/«+ Spalte»
    if (e is TableBlock) {
      widgets.add(
        Positioned.fill(
          child: FloatingAnchor(
            key: const ValueKey('float-table-anchor'),
            at: Offset(r.right, r.bottom + 34 / zoom),
            align: Alignment.topRight,
            zoom: zoom,
            child: SelectionBar(controller: controller, element: e),
          ),
        ),
      );
    }
    if (e is TableBlock) {
      final cell = controller.editingId == e.id ? controller.editingCell : controller.activeCell;
      if (cell != null && cell.row < e.rowCount && cell.col < e.columnCount) {
        widgets.add(
          Positioned.fromRect(
            rect: r,
            child: _TableControls(key: ValueKey('table-controls-${e.id}'), controller: controller, table: e, cell: cell, zoom: zoom),
          ),
        );
      }
    }
    return widgets;
  }
}

/// Ein Element auf der Seite mit seiner Bedienung.
class _ElementLayer extends StatelessWidget {
  const _ElementLayer({required this.controller, required this.element, required this.zoom});
  final EditorController controller;
  final DocElement element;
  final double zoom;

  @override
  Widget build(BuildContext context) {
    final e = element;
    final r = elementRectPt(e);
    if (e is TextBlock) return Positioned.fromRect(rect: r, child: _text(context, e));
    if (e is TableBlock) {
      return Positioned.fromRect(
        rect: r,
        child: _TableLayer(controller: controller, table: e, zoom: zoom),
      );
    }
    final hit = e is LineShape ? r.inflate(6 / zoom) : r;
    final images = documentImages(controller.doc);
    final view = e is LineShape
        ? Padding(
            padding: EdgeInsets.all(6 / zoom),
            child: ElementView(element: e, images: images),
          )
        : ElementView(element: e, images: images);
    return Positioned.fromRect(
      rect: hit,
      child: _DragArea(
        key: ValueKey('element-${e.id}'),
        zoom: zoom,
        cursor: e.locked ? SystemMouseCursors.basic : SystemMouseCursors.move,
        onTap: () => controller.select(e.id),
        onStart: () => controller.beginGesture(e.id),
        onUpdate: (dx, dy, free) => controller.updateMove(dx, dy, free: free),
        onEnd: controller.endGesture,
        child: view,
      ),
    );
  }

  Widget _text(BuildContext context, TextBlock t) {
    if (controller.editingId == t.id) return _TextEditor(controller: controller, block: t);
    return MouseRegion(
      cursor: t.locked ? SystemMouseCursors.basic : SystemMouseCursors.text,
      child: GestureDetector(
        key: ValueKey('element-${t.id}'),
        behavior: HitTestBehavior.opaque,
        onTapUp: (d) {
          // Ein Klick setzt den Cursor an die Klickstelle (wie in Word); verschoben wird am Griff.
          final pos = layoutText(t).getPositionForOffset(d.localPosition - const Offset(textPadX, textPadY));
          controller.startEditing(t, pos.offset);
        },
        child: TextBlockView(block: t),
      ),
    );
  }
}

/// Tabelle auf der Seite: Klick wählt aus bzw. schreibt in die Zelle, Rechtsklick zeigt die Befehle
/// für Zeile und Spalte. Innere senkrechte Linien lassen sich ziehen (Spaltenbreite, Mauszeiger ↔).
class _TableLayer extends StatefulWidget {
  const _TableLayer({required this.controller, required this.table, required this.zoom});
  final EditorController controller;
  final TableBlock table;
  final double zoom;

  @override
  State<_TableLayer> createState() => _TableLayerState();
}

class _TableLayerState extends State<_TableLayer> {
  int? _hoverBorder;
  int? _dragging;
  Offset? _dragStart;

  EditorController get c => widget.controller;
  TableBlock get t => widget.table;

  /// Innere senkrechte Linie in der Nähe von [p] (Index der rechten Spalte) oder null.
  int? _borderAt(Offset p) {
    final tol = 4 / widget.zoom;
    final cols = tableColumnEdges(t);
    for (var i = 1; i < t.columnCount; i++) {
      if ((p.dx - cols[i] * mmToPt).abs() <= tol) return i;
    }
    return null;
  }

  /// Zelle an [p] (Punkt relativ zur Tabelle).
  ({int row, int col}) _cellAt(Offset p) {
    final cols = tableColumnEdges(t), rows = tableRowTops(t);
    var col = t.columnCount - 1, row = t.rowCount - 1;
    for (var i = 0; i < t.columnCount; i++) {
      if (p.dx < cols[i + 1] * mmToPt) {
        col = i;
        break;
      }
    }
    for (var i = 0; i < t.rowCount; i++) {
      if (p.dy < rows[i + 1] * mmToPt) {
        row = i;
        break;
      }
    }
    return (row: row, col: col);
  }

  /// Ein Klick schreibt direkt in die Zelle (wie bei Text).
  void _tap(Offset p) {
    final cell = _cellAt(p);
    final rows = tableRowTops(t), cols = tableColumnEdges(t);
    final local = p - Offset((cols[cell.col] + tableCellPadXMm) * mmToPt + textPadX, (rows[cell.row] + tableCellPadYMm) * mmToPt + textPadY);
    final pos = layoutText(tableCellBlock(t, cell.row, cell.col, top: 0)).getPositionForOffset(local);
    c.startCellEditing(t, cell.row, cell.col, pos.offset);
  }

  /// Rechtsklick: Zelle wählen und alle Befehle für Zeile und Spalte anbieten.
  Future<void> _menu(TapUpDetails d) async {
    final cell = _cellAt(d.localPosition);
    c.selectCell(t, cell.row, cell.col);
    if (t.locked) return;
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final pos = overlay.globalToLocal(d.globalPosition);
    PopupMenuItem<VoidCallback> item(String key, IconData icon, String label, VoidCallback action, {bool danger = false}) => PopupMenuItem(
      key: ValueKey(key),
      value: action,
      height: 38,
      child: Row(
        children: [
          Icon(icon, size: 18, color: danger ? Ui.danger : _selectionBlue),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: danger ? Ui.danger : Ui.ink),
            ),
          ),
        ],
      ),
    );
    final action = await showMenu<VoidCallback>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, overlay.size.width - pos.dx, overlay.size.height - pos.dy),
      items: [
        item('menu-row-above', Icons.north_rounded, 'Zeile darüber einfügen', () => c.insertTableRow(cell.row)),
        item('menu-row-below', Icons.south_rounded, 'Zeile darunter einfügen', () => c.insertTableRow(cell.row + 1)),
        item('menu-col-left', Icons.west_rounded, 'Spalte links einfügen', () => c.insertTableColumn(cell.col)),
        item('menu-col-right', Icons.east_rounded, 'Spalte rechts einfügen', () => c.insertTableColumn(cell.col + 1)),
        if (t.rowCount > 1 || t.columnCount > 1) const PopupMenuDivider(),
        if (t.rowCount > 1) item('menu-row-delete', Icons.delete_outline_rounded, 'Zeile löschen', c.deleteTableRow, danger: true),
        if (t.columnCount > 1) item('menu-col-delete', Icons.delete_outline_rounded, 'Spalte löschen', c.deleteTableColumn, danger: true),
      ],
    );
    action?.call();
  }

  @override
  Widget build(BuildContext context) {
    final selected = c.selectedId == t.id;
    final editing = c.editingId == t.id ? c.editingCell : null;
    final rows = [for (final y in tableRowTops(t)) y * mmToPt];
    final cols = [for (final x in tableColumnEdges(t)) x * mmToPt];
    final z = widget.zoom;
    final resize = selected && !t.locked && _hoverBorder != null;
    return MouseRegion(
      cursor: resize ? SystemMouseCursors.resizeColumn : SystemMouseCursors.text,
      onHover: (e) {
        final b = selected && !t.locked && editing == null ? _borderAt(e.localPosition) : null;
        if (b != _hoverBorder) setState(() => _hoverBorder = b);
      },
      onExit: (_) => setState(() => _hoverBorder = null),
      child: GestureDetector(
        key: ValueKey('element-${t.id}'),
        behavior: HitTestBehavior.opaque,
        dragStartBehavior: DragStartBehavior.down,
        onTapUp: (d) => _tap(d.localPosition),
        onSecondaryTapUp: _menu,
        // innere senkrechte Linie ziehen: Spaltenbreite (nicht beim Schreiben, damit Markieren mit der Maus geht)
        onHorizontalDragStart: editing != null
            ? null
            : (d) {
                final b = selected && !t.locked ? _borderAt(d.localPosition) : null;
                if (b != null && c.beginGesture(t.id)) {
                  _dragging = b;
                  _dragStart = d.globalPosition;
                }
              },
        onHorizontalDragUpdate: editing != null
            ? null
            : (d) {
                final b = _dragging, start = _dragStart;
                if (b == null || start == null) return;
                c.updateColumnBorder(b, (d.globalPosition.dx - start.dx) / z / mmToPt);
              },
        onHorizontalDragEnd: (_) {
          if (_dragging != null) c.endGesture();
          _dragging = null;
        },
        onHorizontalDragCancel: () {
          if (_dragging != null) c.endGesture();
          _dragging = null;
        },
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: TableView(table: t, hideCell: editing),
            ),
            if (editing != null && editing.row < t.rowCount && editing.col < t.columnCount)
              Positioned(
                left: (cols[editing.col] / mmToPt + tableCellPadXMm) * mmToPt,
                top: (rows[editing.row] / mmToPt + tableCellPadYMm) * mmToPt,
                width: tableCellBlock(t, editing.row, editing.col, top: 0).box.w * mmToPt,
                // feste Höhe (Rest der Zeile): das Eingabefeld darf darüber hinaus wachsen, braucht aber eine Grenze
                height: rows[editing.row + 1] - rows[editing.row] - tableCellPadYMm * mmToPt,
                child: _TextEditor(
                  controller: c,
                  block: tableCellBlock(t, editing.row, editing.col, top: 0),
                  extraBindings: {
                    const SingleActivator(LogicalKeyboardKey.tab): () => c.moveToCell(1),
                    const SingleActivator(LogicalKeyboardKey.tab, shift: true): () => c.moveToCell(-1),
                  },
                ),
              ),
            // gewählte Zelle (ohne zu schreiben) leicht hervorheben
            if (selected && editing == null && c.activeCell != null && c.activeCell!.row < t.rowCount && c.activeCell!.col < t.columnCount)
              Positioned.fromRect(
                rect: Rect.fromLTRB(cols[c.activeCell!.col], rows[c.activeCell!.row], cols[c.activeCell!.col + 1], rows[c.activeCell!.row + 1]),
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(color: _selectionBlue, width: 2 / z),
                    ),
                  ),
                ),
              ),
            if (resize)
              Positioned.fromRect(
                rect: Rect.fromLTWH(cols[_hoverBorder!] - 1.5 / z, 0, 3 / z, rows.last),
                child: const IgnorePointer(child: ColoredBox(color: _selectionBlue)),
              ),
          ],
        ),
      ),
    );
  }
}

/// Was die Maus gerade an den Knöpfen der Tabelle zeigt (für die Vorschau).
enum _TableHover { addRow, addColumn, deleteRow, deleteColumn }

/// Knöpfe für Zeilen und Spalten der aktuellen Zelle:
/// einfügen direkt an der Zelle («+ Spalte» am rechten Rand, «+ Zeile» knapp unter dem unteren Rand),
/// löschen am Rand der Tabelle («Zeile löschen» rechts auf Höhe der Zeile, «Spalte löschen» über der Spalte).
/// Die Knöpfe liegen teils ausserhalb der Tabelle und der Seite; damit sie dort anklickbar sind, werden
/// sie in der obersten Ebene gezeichnet und folgen der Tabelle (auch beim Scrollen und Zoomen).
class _TableControls extends StatefulWidget {
  const _TableControls({super.key, required this.controller, required this.table, required this.cell, required this.zoom});
  final EditorController controller;
  final TableBlock table;
  final ({int row, int col}) cell;
  final double zoom;

  @override
  State<_TableControls> createState() => _TableControlsState();
}

class _TableControlsState extends State<_TableControls> {
  final _portal = OverlayPortalController();
  final _links = {for (final h in _TableHover.values) h: LayerLink()};
  _TableHover? _hover;

  @override
  void initState() {
    super.initState();
    _portal.show();
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.table, cell = widget.cell, z = widget.zoom;
    final rows = [for (final y in tableRowTops(t)) y * mmToPt];
    final cols = [for (final x in tableColumnEdges(t)) x * mmToPt];
    final r0 = rows[cell.row], r1 = rows[cell.row + 1], c0 = cols[cell.col], c1 = cols[cell.col + 1];
    final w = cols.last, h = rows.last;
    // Ankerpunkte (relativ zur Tabelle)
    final anchors = <_TableHover, Offset>{
      _TableHover.addColumn: Offset(c1, (r0 + r1) / 2),
      _TableHover.addRow: Offset((c0 + c1) / 2, r1 + 20 / z),
      if (t.rowCount > 1) _TableHover.deleteRow: Offset(w + 10 / z, (r0 + r1) / 2),
      // über der Spalte; nicht unter den Griff «Verschieben» links oben
      if (t.columnCount > 1) _TableHover.deleteColumn: Offset(((c0 + c1) / 2).clamp(205 / z, double.infinity), -20 / z),
    };
    const band = 14.0;
    final preview = switch (_hover) {
      _TableHover.addRow => (Rect.fromLTWH(0, r1 - band / 2 / z, w, band / z), false),
      _TableHover.addColumn => (Rect.fromLTWH(c1 - band / 2 / z, 0, band / z, h), false),
      _TableHover.deleteRow => (Rect.fromLTRB(0, r0, w, r1), true),
      _TableHover.deleteColumn => (Rect.fromLTRB(c0, 0, c1, h), true),
      null => null,
    };
    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: (_) => Stack(
        children: [
          for (final MapEntry(key: what, value: _) in anchors.entries)
            CompositedTransformFollower(
              link: _links[what]!,
              showWhenUnlinked: false,
              targetAnchor: Alignment.center,
              followerAnchor: switch (what) {
                _TableHover.addColumn || _TableHover.addRow || _TableHover.deleteColumn => Alignment.center,
                _TableHover.deleteRow => Alignment.centerLeft,
              },
              child: _button(what),
            ),
        ],
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (final MapEntry(key: what, value: at) in anchors.entries)
            Positioned(
              left: at.dx,
              top: at.dy,
              child: CompositedTransformTarget(link: _links[what]!, child: const SizedBox.shrink()),
            ),
          if (preview != null)
            Positioned.fromRect(
              rect: preview.$1,
              child: IgnorePointer(
                child: CustomPaint(
                  key: ValueKey('table-preview-${_hover!.name}'),
                  painter: _PreviewPainter(danger: preview.$2, zoom: z),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _button(_TableHover what) {
    final c = widget.controller, cell = widget.cell, z = widget.zoom;
    final add = what == _TableHover.addRow || what == _TableHover.addColumn;
    final hot = _hover == what;
    final (key, label, icon, action) = switch (what) {
      _TableHover.addColumn => ('table-add-col', 'Spalte', Icons.add_rounded, () => c.insertTableColumn(cell.col + 1)),
      _TableHover.addRow => ('table-add-row', 'Zeile', Icons.add_rounded, () => c.insertTableRow(cell.row + 1)),
      _TableHover.deleteRow => ('table-del-row', 'Zeile löschen', Icons.delete_outline_rounded, c.deleteTableRow),
      _TableHover.deleteColumn => ('table-del-col', 'Spalte löschen', Icons.delete_outline_rounded, c.deleteTableColumn),
    };
    const danger = Ui.danger;
    final bg = add ? (hot ? const Color(0xFF1A43A8) : _selectionBlue) : (hot ? danger : Colors.white);
    final fg = add || hot ? Colors.white : danger;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = what),
      onExit: (_) => setState(() => _hover = null),
      // Klicks gehören zum Textfeld-Bereich: beim Schreiben schliesst ein Klick das Feld nicht vorher
      child: TextFieldTapRegion(
        child: GestureDetector(
          key: ValueKey(key),
          behavior: HitTestBehavior.opaque,
          onTap: () {
            setState(() => _hover = null);
            action();
          },
          child: Container(
            height: 30 / z,
            padding: EdgeInsets.symmetric(horizontal: 11 / z),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(add ? 15 / z : 8 / z),
              border: add ? null : Border.all(color: hot ? danger : const Color(0xFFF0C9BD), width: 1 / z),
              boxShadow: [BoxShadow(color: const Color(0x33101828), blurRadius: 6 / z, offset: Offset(0, 1.5 / z))],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16 / z, color: fg),
                SizedBox(width: 4 / z),
                Text(
                  label,
                  style: TextStyle(fontSize: 12.5 / z, fontWeight: FontWeight.w700, color: fg, height: 1.1),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Vorschau: gestrichelt blau (neue Zeile/Spalte) bzw. rot hinterlegt (wird gelöscht).
class _PreviewPainter extends CustomPainter {
  const _PreviewPainter({required this.danger, required this.zoom});
  final bool danger;
  final double zoom;

  @override
  void paint(Canvas canvas, Size size) {
    final color = danger ? const Color(0xFFC2410C) : _selectionBlue;
    canvas.drawRect(Offset.zero & size, Paint()..color = color.withValues(alpha: danger ? .18 : .12));
    final p = Paint()
      ..color = color
      ..strokeWidth = 1.5 / zoom
      ..style = PaintingStyle.stroke;
    if (danger) {
      canvas.drawRect(Offset.zero & size, p);
      return;
    }
    final dash = 4 / zoom;
    final path = Path()..addRect(Offset.zero & size);
    for (final m in path.computeMetrics()) {
      for (var d = 0.0; d < m.length; d += dash * 2) {
        canvas.drawPath(m.extractPath(d, d + dash), p);
      }
    }
  }

  @override
  bool shouldRepaint(_PreviewPainter old) => old.danger != danger || old.zoom != zoom;
}

/// Eingabefeld, das exakt wie die Anzeige setzt (siehe doc_render/text_layout.dart).
class _TextEditor extends StatelessWidget {
  const _TextEditor({required this.controller, required this.block, this.extraBindings = const {}});
  final EditorController controller;
  final TextBlock block;

  /// Weitere Tasten (z. B. Tab in Tabellenzellen).
  final Map<ShortcutActivator, VoidCallback> extraBindings;

  @override
  Widget build(BuildContext context) {
    final w = textLayoutWidth(block) + caretMargin;
    return Padding(
      padding: const EdgeInsets.fromLTRB(textPadX, textPadY, 0, 0),
      child: OverflowBox(
        alignment: Alignment.topLeft,
        minWidth: w,
        maxWidth: w,
        maxHeight: double.infinity,
        child: MediaQuery.withNoTextScaling(
          child: CallbackShortcuts(
            bindings: {
              ...extraBindings,
              const SingleActivator(LogicalKeyboardKey.escape): controller.finishEditing,
              // Pfeil hoch/runter selbst bewegen (Flutter-Fehler bei zentriertem Text, siehe moveCaretVertically)
              const SingleActivator(LogicalKeyboardKey.arrowUp): () => controller.moveCaretVertically(-1),
              const SingleActivator(LogicalKeyboardKey.arrowDown): () => controller.moveCaretVertically(1),
              const SingleActivator(LogicalKeyboardKey.arrowUp, shift: true): () => controller.moveCaretVertically(-1, extend: true),
              const SingleActivator(LogicalKeyboardKey.arrowDown, shift: true): () => controller.moveCaretVertically(1, extend: true),
              const SingleActivator(LogicalKeyboardKey.keyB, control: true): () => controller.toggleInline(InlineAttr.bold, fromKeyboard: true),
              const SingleActivator(LogicalKeyboardKey.keyI, control: true): () => controller.toggleInline(InlineAttr.italic, fromKeyboard: true),
              const SingleActivator(LogicalKeyboardKey.keyU, control: true): () => controller.toggleInline(InlineAttr.underline, fromKeyboard: true),
            },
            child: TextField(
              key: const ValueKey('text-editor'),
              controller: controller.textController,
              focusNode: controller.textFocus,
              style: textStyleFor(block),
              strutStyle: strutFor(block),
              textAlign: textAlignFor(block),
              maxLines: null,
              cursorWidth: cursorWidth,
              cursorColor: _selectionBlue,
              selectionHeightStyle: ui.BoxHeightStyle.tight,
              decoration: const InputDecoration.collapsed(hintText: null),
              keyboardType: TextInputType.multiline,
              onChanged: (_) => controller.onEditingChanged(),
              // Rechtschreibfehler zeichnet das Feld selbst (siehe RichTextController); Flutters eigene
              // Anzeige würde die Formatierung einzelner Wörter verwerfen.
              spellCheckConfiguration: const SpellCheckConfiguration.disabled(),
              contextMenuBuilder: (context, state) => controller.spell.contextMenu(
                context,
                state,
                lookup: controller.textController.suggestionAt,
                drop: controller.textController.dropMisspelled,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Zieh- und Klickfläche. Meldet die Gesamtverschiebung seit Beginn in Millimetern.
class _DragArea extends StatefulWidget {
  const _DragArea({
    super.key,
    required this.zoom,
    required this.child,
    required this.onStart,
    required this.onUpdate,
    required this.onEnd,
    this.onTap,
    this.cursor = SystemMouseCursors.move,
  });
  final double zoom;
  final Widget child;
  final bool Function() onStart;

  /// Gesamtverschiebung seit Beginn in mm; [free] = Alt-Taste gedrückt (nicht einrasten).
  final void Function(double dxMm, double dyMm, bool free) onUpdate;
  final VoidCallback onEnd;
  final VoidCallback? onTap;
  final MouseCursor cursor;

  @override
  State<_DragArea> createState() => _DragAreaState();
}

class _DragAreaState extends State<_DragArea> {
  Offset? _start;

  double _toMm(double logical) => logical / widget.zoom / mmToPt;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: widget.cursor,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      // Startpunkt ist die Stelle des Klicks, nicht die Stelle nach der Mindestdistanz:
      // so folgt das Element exakt der Maus.
      dragStartBehavior: DragStartBehavior.down,
      onTapDown: widget.onTap == null ? null : (_) => widget.onTap!(),
      onPanStart: (d) {
        _start = widget.onStart() ? d.globalPosition : null;
      },
      onPanUpdate: (d) {
        final s = _start;
        if (s == null) return;
        final delta = d.globalPosition - s;
        widget.onUpdate(_toMm(delta.dx), _toMm(delta.dy), HardwareKeyboard.instance.isAltPressed);
      },
      onPanEnd: (_) {
        if (_start != null) widget.onEnd();
        _start = null;
      },
      onPanCancel: () {
        if (_start != null) widget.onEnd();
        _start = null;
      },
      child: widget.child,
    ),
  );
}

class _HandleWidget extends StatelessWidget {
  const _HandleWidget({
    super.key,
    required this.center,
    required this.size,
    required this.zoom,
    required this.onStart,
    required this.onUpdate,
    required this.onEnd,
    required this.cursor,
    this.round = false,
    this.horizontalBar = false,
  });
  final Offset center;
  final double size, zoom;
  final bool Function() onStart;
  final void Function(double, double, bool) onUpdate;
  final VoidCallback onEnd;
  final MouseCursor cursor;
  final bool round, horizontalBar;

  @override
  Widget build(BuildContext context) {
    // Runde Eckgriffe = Grösse, längliche Seitengriffe = Form (Prototyp v3)
    final w = round ? size : (horizontalBar ? size * 2 : size * .7);
    final h = round ? size : (horizontalBar ? size * .7 : size * 2);
    final hit = size * 2; // grössere, unsichtbare Trefferfläche
    return Positioned(
      left: center.dx - hit / 2,
      top: center.dy - hit / 2,
      width: hit,
      height: hit,
      child: _DragArea(
        zoom: zoom,
        cursor: cursor,
        onStart: onStart,
        onUpdate: onUpdate,
        onEnd: onEnd,
        child: Center(
          child: Container(
            width: w,
            height: h,
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: _selectionBlue, width: 1.5 / zoom),
              borderRadius: BorderRadius.circular(round ? size : 3 / zoom),
            ),
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text, required this.zoom, this.icon, this.filled = false, this.large = false});
  final String text;
  final double zoom;
  final IconData? icon;
  final bool filled;

  /// Grösser (zum Anfassen, z. B. «Verschieben»): rund 28 Bildpunkte hoch.
  final bool large;

  @override
  Widget build(BuildContext context) {
    final fg = filled ? Colors.white : const Color(0xFF1D2733);
    final font = large ? 13.0 : 11.0;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: (large ? 10 : 7) / zoom, vertical: (large ? 6 : 3) / zoom),
      decoration: BoxDecoration(
        color: filled ? _selectionBlue : const Color(0xFFE8EBEF),
        borderRadius: BorderRadius.circular((large ? 14 : 9) / zoom),
        boxShadow: large ? [BoxShadow(color: const Color(0x33101828), blurRadius: 6 / zoom, offset: Offset(0, 1.5 / zoom))] : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: (large ? 16 : 11) / zoom, color: fg), SizedBox(width: (large ? 5 : 3) / zoom)],
          Text(
            text,
            style: TextStyle(fontSize: font / zoom, fontWeight: large ? FontWeight.w600 : FontWeight.w400, color: fg, height: 1.1),
          ),
        ],
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  const _GridPainter(this.stepMm);
  final double stepMm;

  @override
  void paint(Canvas canvas, Size size) {
    final minor = Paint()
      ..color = const Color(0x1A2F5BD3)
      ..strokeWidth = .4;
    final major = Paint()
      ..color = const Color(0x332F5BD3)
      ..strokeWidth = .5;
    final step = stepMm * mmToPt;
    var i = 0;
    for (var x = 0.0; x <= size.width + .01; x += step, i++) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), (i * stepMm) % 50 == 0 ? major : minor);
    }
    i = 0;
    for (var y = 0.0; y <= size.height + .01; y += step, i++) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), (i * stepMm) % 50 == 0 ? major : minor);
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) => old.stepMm != stepMm;
}

class _GuidePainter extends CustomPainter {
  _GuidePainter(this.guides, this.zoom);
  final List<Guide> guides;
  final double zoom;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = const Color(0xFFD6336C)
      ..strokeWidth = 1 / zoom;
    final dash = 4 / zoom;
    for (final g in guides) {
      final v = g.position * mmToPt;
      if (g.axis == SnapAxis.vertical) {
        for (var y = 0.0; y < size.height; y += dash * 2) {
          canvas.drawLine(Offset(v, y), Offset(v, y + dash), p);
        }
      } else {
        for (var x = 0.0; x < size.width; x += dash * 2) {
          canvas.drawLine(Offset(x, v), Offset(x + dash, v), p);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_GuidePainter old) => true;
}

class _MarginPainter extends CustomPainter {
  const _MarginPainter();
  @override
  void paint(Canvas canvas, Size size) {
    const m = 15 * mmToPt;
    final p = Paint()
      ..color = const Color(0x405D6876)
      ..style = PaintingStyle.stroke
      ..strokeWidth = .5;
    final r = Rect.fromLTWH(m, m, size.width - 2 * m, size.height - 2 * m);
    const dash = 3.0;
    for (var x = r.left; x < r.right; x += dash * 2) {
      canvas.drawLine(Offset(x, r.top), Offset(x + dash, r.top), p);
      canvas.drawLine(Offset(x, r.bottom), Offset(x + dash, r.bottom), p);
    }
    for (var y = r.top; y < r.bottom; y += dash * 2) {
      canvas.drawLine(Offset(r.left, y), Offset(r.left, y + dash), p);
      canvas.drawLine(Offset(r.right, y), Offset(r.right, y + dash), p);
    }
  }

  @override
  bool shouldRepaint(_MarginPainter old) => false;
}

/// Startknöpfe auf der leeren Seite: Titel, Text, Bild, Tabelle.
class _StartPanel extends StatelessWidget {
  const _StartPanel({required this.controller, required this.onPickImage});

  /// Breite des Felds (Bildschirmpunkte bei Zoom 1).
  static const width = 330.0;
  final EditorController controller;
  final VoidCallback? onPickImage;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    Widget button(String key, Widget icon, String title, String hint, VoidCallback? onTap) => Material(
      color: const Color(0xFFF5F8FF),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: Color(0xFFDCE5FB), width: 1.5),
      ),
      child: InkWell(
        key: ValueKey(key),
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: SizedBox(
          width: 150,
          height: 118,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconTheme(
                data: const IconThemeData(size: 28, color: _selectionBlue),
                child: icon,
              ),
              const SizedBox(height: 8),
              Text(
                title,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF1D2733)),
              ),
              const SizedBox(height: 2),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  hint,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5, height: 1.2, color: Color(0xFF5B6475)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return SizedBox(
      key: const ValueKey('start-panel'),
      width: width,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Womit möchtest du beginnen?',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: Color(0xFF1D2733)),
          ),
          const SizedBox(height: 6),
          const SizedBox(
            width: width,
            child: Text(
              'Ein Klick setzt das Element auf die Seite. Alles lässt sich danach verschieben.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13.5, height: 1.4, color: Color(0xFF5B6475)),
            ),
          ),
          const SizedBox(height: 26),
          SizedBox(
            width: 2 * 150 + 14,
            child: Wrap(
              spacing: 14,
              runSpacing: 14,
              children: [
                button(
                  'start-title',
                  const Text(
                    'Aa',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: _selectionBlue),
                  ),
                  'Titel',
                  'gross, für oben',
                  () => c.addText(kind: TextKind.title),
                ),
                button('start-text', const Icon(Icons.notes_rounded), 'Text', 'für Absätze', c.addText),
                button('start-image', const Icon(Icons.image_outlined), 'Bild', 'oder hierher ziehen', onPickImage),
                button('start-table', const Icon(Icons.table_chart_outlined), 'Tabelle', 'z. B. Programm', () => c.addTable(3)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
