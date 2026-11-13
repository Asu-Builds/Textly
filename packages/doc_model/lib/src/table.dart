part of 'elements.dart';

/// Vorlage einer Tabelle: setzt Linien, Farben und Kopfzeile auf einmal.
enum TableStyle {
  /// Kopfzeile farbig hinterlegt mit weisser Schrift, feine helle Linien.
  header,

  /// Gitter: dunkle Linien um alle Zellen, Kopfzeile nur fett.
  grid,
}

/// Welche Linien gezeichnet werden.
enum TableLines { all, horizontal, outer, none }

/// Hintergrund gestreifter Zeilen.
const int tableZebraColor = 0xFFF0F2F5;

/// Linienstärken (Fein, Kräftig) in mm.
const double tableLineFine = .25, tableLineStrong = .6;

/// Tabelle: Spalten mit festen Breiten, Zeilen wachsen mit dem Text. Zellen enthalten Text ohne
/// eigene Formatierung; die Kopfzeile ist fett. Einfach gehalten, damit sie sich verlustfrei als
/// PowerPoint-Tabelle speichern und wieder öffnen lässt.
class TableBlock extends DocElement {
  TableBlock({
    required String id,
    required this.x,
    required this.y,
    required List<double> columns,
    required List<List<String>> cells,
    this.heightHint = 20,
    this.headerRow = true,
    this.style = TableStyle.header,
    this.size = 10.5,
    this.font,
    List<TextAlignment>? align,
    this.lines = TableLines.all,
    this.lineColor = 0xFFC4CBD6,
    this.lineWidth = tableLineFine,
    this.headerColor = 0xFF1F7A5A,
    this.zebra = false,
    bool locked = false,
  })  : assert(columns.isNotEmpty && cells.isNotEmpty),
        columns = List.unmodifiable(columns),
        cells = List.unmodifiable([
          for (final r in cells) List<String>.unmodifiable([for (var c = 0; c < columns.length; c++) c < r.length ? r[c] : '']),
        ]),
        align = List.unmodifiable([
          for (var c = 0; c < columns.length; c++) (align != null && c < align.length) ? align[c] : TextAlignment.left,
        ]),
        super(id, locked);

  /// Neue Tabelle mit [cols] gleich breiten Spalten über [width] mm und [rows] leeren Zeilen.
  factory TableBlock.empty({
    required String id,
    required double x,
    required double y,
    required double width,
    int cols = 3,
    int rows = 3,
    bool headerRow = true,
    TableStyle style = TableStyle.header,
  }) =>
      TableBlock(
        id: id,
        x: x,
        y: y,
        columns: List.filled(cols, width / cols),
        cells: List.generate(rows, (_) => List.filled(cols, '')),
        headerRow: headerRow,
      ).withStyle(style);

  final double x, y;

  /// Spaltenbreiten in mm (ergeben zusammen die Breite der Tabelle).
  final List<double> columns;

  /// Zellen zeilenweise; jede Zeile hat genau so viele Einträge wie es Spalten gibt.
  final List<List<String>> cells;

  /// Richtwert der Höhe in mm (die Darstellung misst die Zeilen).
  final double heightHint;

  /// Erste Zeile als Überschrift (fett, bei «Kopfzeile farbig» farbig hinterlegt).
  final bool headerRow;
  final TableStyle style;
  final double size;
  final TextFont? font;

  /// Ausrichtung je Spalte.
  final List<TextAlignment> align;
  final TableLines lines;
  final int lineColor;

  /// Linienstärke in mm.
  final double lineWidth;
  final int headerColor;

  /// Zeilen abwechselnd hellgrau hinterlegen.
  final bool zebra;

  int get rowCount => cells.length;
  int get columnCount => columns.length;
  double get width => columns.fold(0.0, (a, b) => a + b);

  /// Schrift, mit der die Zellen gesetzt werden.
  TextFont get effectiveFont => font ?? defaultFontForKind(TextKind.body);

  /// Ist die Zelle in Zeile [row] Teil der Kopfzeile?
  bool isHeader(int row) => headerRow && row == 0;

  /// Schriftfarbe in Zeile [row]: weiss auf farbiger Kopfzeile, sonst dunkel. Fett ist nur die Kopfzeile.
  int cellTextColor(int row) => isHeader(row) && style == TableStyle.header ? 0xFFFFFFFF : 0xFF1D2733;

  /// Hintergrund der Zeile [row] oder null.
  int? rowFill(int row) {
    if (isHeader(row) && style == TableStyle.header) return headerColor;
    final body = row - (headerRow ? 1 : 0);
    if (zebra && body >= 0 && body.isOdd) return tableZebraColor;
    return null;
  }

  @override
  Box get box => Box(x, y, width, heightHint);

  TableBlock copyWith({
    double? x,
    double? y,
    List<double>? columns,
    List<List<String>>? cells,
    double? heightHint,
    bool? headerRow,
    TableStyle? style,
    double? size,
    List<TextAlignment>? align,
    TableLines? lines,
    int? lineColor,
    double? lineWidth,
    int? headerColor,
    bool? zebra,
    bool? locked,
    String? id,
  }) =>
      TableBlock(
        id: id ?? this.id,
        x: x ?? this.x,
        y: y ?? this.y,
        columns: columns ?? this.columns,
        cells: cells ?? this.cells,
        heightHint: heightHint ?? this.heightHint,
        headerRow: headerRow ?? this.headerRow,
        style: style ?? this.style,
        size: size ?? this.size,
        font: font,
        align: align ?? this.align,
        lines: lines ?? this.lines,
        lineColor: lineColor ?? this.lineColor,
        lineWidth: lineWidth ?? this.lineWidth,
        headerColor: headerColor ?? this.headerColor,
        zebra: zebra ?? this.zebra,
        locked: locked ?? this.locked,
      );

  /// Schriftart setzen; `null` = wie Fliesstext.
  TableBlock withFont(TextFont? f) => TableBlock(
        id: id, x: x, y: y, columns: columns, cells: cells, heightHint: heightHint, headerRow: headerRow,
        style: style, size: size, font: f, align: align, lines: lines, lineColor: lineColor,
        lineWidth: lineWidth, headerColor: headerColor, zebra: zebra, locked: locked,
      );

  /// Vorlage anwenden: Linien, Farben und Kopfzeile wie vorgegeben.
  TableBlock withStyle(TableStyle s) => switch (s) {
        TableStyle.header => copyWith(style: s, lines: TableLines.all, lineColor: 0xFFC4CBD6, lineWidth: tableLineFine),
        TableStyle.grid => copyWith(style: s, lines: TableLines.all, lineColor: 0xFF475467, lineWidth: tableLineFine),
      };

  TableBlock withCell(int row, int col, String text) => copyWith(cells: [
        for (var r = 0; r < rowCount; r++)
          [for (var c = 0; c < columnCount; c++) r == row && c == col ? text : cells[r][c]],
      ]);

  /// Neue leere Zeile vor Zeile [at] (0 … [rowCount]).
  TableBlock insertRow(int at) {
    final i = at.clamp(0, rowCount);
    return copyWith(cells: [...cells.take(i), List.filled(columnCount, ''), ...cells.skip(i)]);
  }

  /// Neue Spalte vor Spalte [at] (0 … [columnCount]). Die Tabelle behält ihre Breite;
  /// alle Spalten werden dafür etwas schmaler.
  TableBlock insertColumn(int at) {
    final i = at.clamp(0, columnCount);
    final total = width;
    final added = total / (columnCount + 1);
    final f = (total - added) / total;
    return copyWith(
      columns: [for (final w in columns.take(i)) w * f, added, for (final w in columns.skip(i)) w * f],
      cells: [for (final r in cells) [...r.take(i), '', ...r.skip(i)]],
      align: [...align.take(i), TextAlignment.left, ...align.skip(i)],
    );
  }

  /// Zeile entfernen (die letzte bleibt).
  TableBlock removeRow(int row) {
    if (rowCount < 2 || row < 0 || row >= rowCount) return this;
    return copyWith(cells: [for (var r = 0; r < rowCount; r++) if (r != row) cells[r]]);
  }

  /// Spalte entfernen (die letzte bleibt); die übrigen verteilen ihre Breite neu.
  TableBlock removeColumn(int col) {
    if (columnCount < 2 || col < 0 || col >= columnCount) return this;
    final total = width;
    final rest = total - columns[col];
    return copyWith(
      columns: [for (var c = 0; c < columnCount; c++) if (c != col) columns[c] * total / rest],
      cells: [for (final r in cells) [for (var c = 0; c < columnCount; c++) if (c != col) r[c]]],
      align: [for (var c = 0; c < columnCount; c++) if (c != col) align[c]],
    );
  }

  /// Alle Spalten gleich breit.
  TableBlock withEqualColumns() => copyWith(columns: List.filled(columnCount, width / columnCount));

  /// Linie zwischen Spalte [border]-1 und [border] um [dx] mm verschieben; die Nachbarspalten
  /// tauschen Breite, die Tabelle bleibt gleich breit. Jede Spalte bleibt mindestens [minWidth] breit.
  TableBlock moveColumnBorder(int border, double dx, {double minWidth = 5}) {
    if (border <= 0 || border >= columnCount) return this;
    final a = columns[border - 1], b = columns[border];
    // Sind beide Spalten zusammen schmaler als zweimal die Mindestbreite (z. B. aus Word oder nach A4→A5),
    // gilt die schmalere als Mindestbreite – sonst wäre die untere Grenze grösser als die obere.
    final m = minWidth < a && minWidth < b ? minWidth : (a < b ? a : b);
    final d = dx.clamp(m - a, b - m);
    return copyWith(columns: [
      for (var c = 0; c < columnCount; c++) c == border - 1 ? a + d : c == border ? b - d : columns[c],
    ]);
  }

  /// Ganze Tabelle auf [w] mm Breite bringen (Spalten im gleichen Verhältnis).
  TableBlock withWidth(double w) {
    final f = w / width;
    return copyWith(columns: [for (final c in columns) c * f]);
  }

  @override
  TableBlock translated(double dx, double dy) => copyWith(x: x + dx, y: y + dy);
  @override
  TableBlock withLocked(bool locked) => copyWith(locked: locked);
  @override
  TableBlock withId(String id) => copyWith(id: id);

  factory TableBlock.fromJson(Map<String, dynamic> j) {
    final columns = [for (final w in j['columns'] as List) (w as num).toDouble()];
    final cells = [for (final r in j['cells'] as List) [for (final c in r as List) c as String]];
    if (columns.isEmpty || cells.isEmpty || columns.any((w) => w <= 0)) {
      throw const FormatException('Eine Tabelle ist beschädigt.');
    }
    return TableBlock(
      id: j['id'] as String,
      x: (j['x'] as num).toDouble(),
      y: (j['y'] as num).toDouble(),
      columns: columns,
      cells: cells,
      heightHint: (j['h'] as num?)?.toDouble() ?? 20,
      headerRow: j['headerRow'] as bool? ?? true,
      style: TableStyle.values.asNameMap()[j['style']] ?? TableStyle.header,
      size: (j['size'] as num?)?.toDouble() ?? 10.5,
      font: TextFont.values.asNameMap()[j['font']],
      align: [for (final a in (j['align'] as List?) ?? const []) TextAlignment.values.asNameMap()[a] ?? TextAlignment.left],
      lines: TableLines.values.asNameMap()[j['lines']] ?? TableLines.all,
      lineColor: j['lineColor'] as int? ?? 0xFFC4CBD6,
      lineWidth: (j['lineWidth'] as num?)?.toDouble() ?? tableLineFine,
      headerColor: j['headerColor'] as int? ?? 0xFF1F7A5A,
      zebra: j['zebra'] as bool? ?? false,
      locked: j['locked'] as bool? ?? false,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'table', 'id': id, 'locked': locked, 'x': x, 'y': y, 'h': heightHint,
        'columns': columns, 'cells': cells, 'headerRow': headerRow, 'style': style.name, 'size': size,
        if (font != null) 'font': font!.name,
        'align': [for (final a in align) a.name], 'lines': lines.name, 'lineColor': lineColor,
        'lineWidth': lineWidth, 'headerColor': headerColor, 'zebra': zebra,
      };
}
