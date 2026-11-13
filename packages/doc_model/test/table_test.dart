import 'package:doc_model/doc_model.dart';
import 'package:test/test.dart';

TableBlock _table() => TableBlock(
      id: 't',
      x: 15,
      y: 100,
      columns: const [40, 60, 80],
      cells: const [
        ['Datum', 'Anlass', 'Treffpunkt'],
        ['12. März', 'Generalversammlung', 'Linde'],
      ],
    );

void main() {
  test('neue Tabelle: gleich breite Spalten, leere Zellen, Vorlage', () {
    final t = TableBlock.empty(id: 'n', x: 15, y: 50, width: 180, cols: 4, rows: 3, style: TableStyle.grid);
    expect(t.columns, [45, 45, 45, 45]);
    expect(t.cells, hasLength(3));
    expect(t.cells.every((r) => r.length == 4 && r.every((c) => c.isEmpty)), isTrue);
    expect((t.style, t.lineColor), (TableStyle.grid, 0xFF475467));
    expect(t.box, const Box(15, 50, 180, 20));
  });

  test('Zeilen und Spalten einfügen und entfernen; Breite bleibt', () {
    final t = _table();
    final c = t.insertColumn(1);
    expect(c.columnCount, 4);
    expect(c.width, closeTo(180, 1e-9));
    expect(c.cells[0], ['Datum', '', 'Anlass', 'Treffpunkt']);
    expect(c.align, hasLength(4));
    final r = t.insertRow(2);
    expect(r.cells.last, ['', '', '']);
    expect(t.removeColumn(0).cells[1], ['Generalversammlung', 'Linde']);
    expect(t.removeColumn(0).width, closeTo(180, 1e-9));
    expect(t.removeRow(0).rowCount, 1);
    expect(t.removeRow(0).removeRow(0).rowCount, 1, reason: 'die letzte Zeile bleibt');
  });

  test('Spaltenlinie ziehen: Nachbarn tauschen Breite, Mindestbreite', () {
    final t = _table().moveColumnBorder(1, 10);
    expect(t.columns, [50, 50, 80]);
    expect(_table().moveColumnBorder(1, 100).columns[1], 5, reason: 'mindestens 5 mm');
    expect(_table().moveColumnBorder(0, 10).columns, [40, 60, 80], reason: 'Aussenkante nicht');
    expect(_table().withEqualColumns().columns, [60, 60, 60]);
    expect(_table().withWidth(90).columns, [20, 30, 40]);
  });

  test('Zelle ändern, Farben der Kopfzeile, gestreifte Zeilen', () {
    final t = _table().withCell(1, 2, 'Restaurant Linde');
    expect(t.cells[1][2], 'Restaurant Linde');
    expect(t.cellTextColor(0), 0xFFFFFFFF);
    expect(t.rowFill(0), t.headerColor);
    final grid = t.withStyle(TableStyle.grid);
    expect((grid.cellTextColor(0), grid.rowFill(0)), (0xFF1D2733, null));
    final z = t.insertRow(2).insertRow(3).copyWith(zebra: true);
    expect([for (var r = 0; r < z.rowCount; r++) z.rowFill(r)], [t.headerColor, null, tableZebraColor, null]);
  });

  test('JSON hin und zurück; beschädigte Tabelle wird erkannt', () {
    final t = _table().copyWith(lines: TableLines.horizontal, zebra: true, align: const [TextAlignment.left, TextAlignment.center, TextAlignment.right]).withFont(TextFont.lora);
    final back = DocElement.fromJson(t.toJson()) as TableBlock;
    expect(back.toJson(), t.toJson());
    expect(() => DocElement.fromJson({...t.toJson(), 'columns': <double>[]}), throwsFormatException);
  });

  test('Spaltenlinie bei sehr schmalen Spalten: keine Ausnahme, Breite bleibt', () {
    final t = TableBlock(id: 't', x: 0, y: 0, columns: const [4, 5, 50], cells: const [['a', 'b', 'c']]);
    for (final dx in [-10.0, -1.0, 1.0, 10.0]) {
      final m = t.moveColumnBorder(1, dx);
      expect(m.width, closeTo(t.width, 1e-9));
      expect(m.columns.every((c) => c >= 4 - 1e-9), isTrue, reason: 'nicht schmaler als die schmalere Spalte');
    }
  });
}
