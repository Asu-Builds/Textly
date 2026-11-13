import 'package:doc_model/doc_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:textly/history/change_label.dart';

void main() {
  final t = TextBlock.ofKind(id: 't', box: const Box(20, 20, 100, 10), text: 'Anmeldung bis 10. Oktober');
  const img = ImageBlock(id: 'i', box: Box(20, 50, 80, 60), asset: 'a', naturalWidth: 800, naturalHeight: 600);
  final base = TextlyDocument(pages: [DocPage(id: 'p', elements: [t, img])]);
  String label(TextlyDocument after) => summarize(describeChanges(base, after));

  test('Text gelöscht, eingefügt, geändert, verschoben', () {
    expect(label(base.removeElement(0, 't')), 'Fliesstext gelöscht');
    expect(mainKind(describeChanges(base, base.removeElement(0, 't'))), ChangeKind.delete);
    expect(label(base.addElement(0, TextBlock.ofKind(id: 'n', box: const Box(0, 0, 50, 10), text: 'Neu'))), 'Fliesstext eingefügt');
    expect(label(base.replaceElement(0, t.copyWith(text: 'Anmeldung bis 12. Oktober'))), 'Fliesstext geändert');
    expect(label(base.replaceElement(0, t.translated(5, 0))), 'Fliesstext verschoben');
    expect(label(base.replaceElement(0, t.copyWith(bold: true))), 'Fliesstext formatiert');
  });

  test('Bild vergrössert, verkleinert, gedreht, Ausschnitt', () {
    expect(label(base.replaceElement(0, img.copyWith(box: const Box(20, 50, 120, 90)))), 'Bild vergrössert');
    expect(label(base.replaceElement(0, img.copyWith(box: const Box(20, 50, 40, 30)))), 'Bild verkleinert');
    expect(label(base.replaceElement(0, img.translated(0, 10))), 'Bild verschoben');
    expect(label(base.replaceElement(0, withQuarterTurn(img))), 'Bild gedreht');
    expect(label(base.replaceElement(0, withCropZoom(img, 2))), 'Bildausschnitt geändert');
  });

  test('Seiten, Format, Sperren, mehrere Änderungen', () {
    expect(label(base.insertPage(1, DocPage(id: 'q'))), 'Seite hinzugefügt');
    expect(label(base.withOrientation(PageOrientation.landscape)), 'Auf Querformat umgestellt');
    expect(label(base.replaceElement(0, img.withLocked(true))), 'Bild gesperrt');
    final many = base.removeElement(0, 't').replaceElement(0, img.translated(5, 5)).insertPage(1, DocPage(id: 'q'));
    expect(label(many), contains('und 2 weitere Änderungen'));
    expect(label(base), 'Keine sichtbare Änderung');
  });

  test('Tabelle im Verlauf: gelöscht, verschoben, Zeile eingefügt, Zusammenfassung', () {
    final tab = TableBlock.empty(id: 'tab', x: 15, y: 150, width: 180, cols: 3, rows: 2);
    final withTable = base.addElement(0, tab);
    expect(deletionLabel(withTable, base), 'Tabelle wurde gelöscht');
    expect(bigChange(withTable, withTable.replaceElement(0, tab.translated(0, 50)))?.label, 'Tabelle wurde verschoben');
    expect(label2(withTable, withTable.replaceElement(0, tab.insertRow(2))), 'Tabellenzeile eingefügt');
    expect(editSummary(editedElements(withTable, withTable.replaceElement(0, tab.withCell(1, 1, 'x')))), 'Bearbeitet: 1 Tabelle');
  });
}

String label2(TextlyDocument a, TextlyDocument b) => summarize(describeChanges(a, b));
