import 'dart:math' as math;

import 'package:doc_model/doc_model.dart';
import 'package:flutter/painting.dart';

import 'text_layout.dart';

/// Satz einer Tabelle. Jede Zelle wird als kleiner Textblock gesetzt – derselbe Textsatz wie bei
/// Textblöcken, damit Bildschirm, Eingabefeld und PDF übereinstimmen. Längen in mm, wo nicht anders vermerkt.

/// Zusätzlicher Innenabstand einer Zelle (zum Abstand des Textblocks hinzu).
const double tableCellPadXMm = .9, tableCellPadYMm = .7;

/// Mindesthöhe einer Zeile (mm), damit leere Zeilen anklickbar bleiben.
const double tableMinRowMm = 6;

/// Linke Kante jeder Spalte relativ zur Tabelle (mm); ein Eintrag mehr als Spalten (rechte Kante).
List<double> tableColumnEdges(TableBlock t) {
  final out = <double>[0];
  for (final w in t.columns) {
    out.add(out.last + w);
  }
  return out;
}

/// Zelle als Textblock an ihrer Stelle auf der Seite ([top] = Oberkante der Zeile in mm).
TextBlock tableCellBlock(TableBlock t, int row, int col, {double? top, String? text}) {
  final edges = tableColumnEdges(t);
  final y = top ?? (t.y + tableRowTops(t)[row]);
  return TextBlock(
    id: '${t.id}#$row:$col',
    box: Box(t.x + edges[col] + tableCellPadXMm, y + tableCellPadYMm, math.max(1, t.columns[col] - 2 * tableCellPadXMm), 5),
    text: text ?? t.cells[row][col],
    kind: TextKind.body,
    size: t.size,
    color: t.cellTextColor(row),
    bold: t.isHeader(row),
    align: t.align[col],
    font: t.font,
  );
}

/// Höhen der Zeilen in mm (gemessen am Text jeder Zelle).
List<double> tableRowHeights(TableBlock t) => [
      for (var r = 0; r < t.rowCount; r++)
        [
          tableMinRowMm,
          for (var c = 0; c < t.columnCount; c++) textBlockHeightPt(tableCellBlock(t, r, c, top: 0)) / mmToPt + 2 * tableCellPadYMm,
        ].reduce(math.max),
    ];

/// Oberkante jeder Zeile relativ zur Tabelle (mm); ein Eintrag mehr als Zeilen (Unterkante).
List<double> tableRowTops(TableBlock t) {
  final out = <double>[0];
  for (final h in tableRowHeights(t)) {
    out.add(out.last + h);
  }
  return out;
}

/// Höhe der ganzen Tabelle in mm.
double tableHeightMm(TableBlock t) => tableRowTops(t).last;

/// Eine Linie der Tabelle (relativ zur Tabelle, mm).
typedef TableSegment = ({double x1, double y1, double x2, double y2});

/// Zu zeichnende Linien je nach Einstellung.
List<TableSegment> tableSegments(TableBlock t, List<double> rowTops) {
  final cols = tableColumnEdges(t);
  final w = cols.last, h = rowTops.last;
  final out = <TableSegment>[];
  void hLine(double y) => out.add((x1: 0, y1: y, x2: w, y2: y));
  void vLine(double x) => out.add((x1: x, y1: 0, x2: x, y2: h));
  switch (t.lines) {
    case TableLines.all:
      rowTops.forEach(hLine);
      cols.forEach(vLine);
    case TableLines.horizontal:
      rowTops.forEach(hLine);
    case TableLines.outer:
      hLine(0);
      hLine(h);
      vLine(0);
      vLine(w);
    case TableLines.none:
      break;
  }
  return out;
}

/// Zeichnet die Tabelle in Punkt-Koordinaten, Ursprung oben links der Tabelle.
/// [hideCell]: Text dieser Zelle weglassen (dort liegt beim Schreiben das Eingabefeld).
void paintTable(Canvas canvas, TableBlock t, {({int row, int col})? hideCell}) {
  final tops = tableRowTops(t);
  final edges = tableColumnEdges(t);
  final w = edges.last * mmToPt;
  for (var r = 0; r < t.rowCount; r++) {
    final fill = t.rowFill(r);
    if (fill != null) {
      canvas.drawRect(Rect.fromLTRB(0, tops[r] * mmToPt, w, tops[r + 1] * mmToPt), Paint()..color = Color(fill));
    }
  }
  for (var r = 0; r < t.rowCount; r++) {
    for (var c = 0; c < t.columnCount; c++) {
      if (hideCell != null && hideCell.row == r && hideCell.col == c) continue;
      final cell = tableCellBlock(t, r, c, top: tops[r]);
      layoutText(cell).paint(
        canvas,
        Offset((edges[c] + tableCellPadXMm) * mmToPt + textPadX, (tops[r] + tableCellPadYMm) * mmToPt + textPadY),
      );
    }
  }
  final line = Paint()
    ..color = Color(t.lineColor)
    ..strokeWidth = t.lineWidth * mmToPt
    ..strokeCap = StrokeCap.square;
  for (final s in tableSegments(t, tops)) {
    canvas.drawLine(Offset(s.x1, s.y1) * mmToPt, Offset(s.x2, s.y2) * mmToPt, line);
  }
}
