import 'dart:io';

import 'package:doc_exchange/doc_exchange.dart';
import 'package:doc_model/doc_model.dart';
import 'package:doc_render/doc_render.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<ByteData> _fromDisk(String key) async => ByteData.sublistView(await File(key).readAsBytes());

/// Beispieldokument mit formatierten Wörtern, Bildausschnitt, Rahmen und Linien.
TextlyDocument exchangeDocument() {
  var doc = sampleDocument();
  final p1 = doc.page(0);
  final body = p1.elements.whereType<TextBlock>().firstWhere((t) => t.kind == TextKind.body);
  var runs = applyInlineStyle(const [], body.text.length, 13, 21, const InlineStyle(bold: true));
  runs = applyInlineStyle(runs, body.text.length, 25, 31, const InlineStyle(italic: true, color: 0xFFB4442C));
  runs = applyInlineStyle(runs, body.text.length, 40, 52, const InlineStyle(underline: true));
  doc = doc.replaceElement(0, body.copyWith(runs: runs));
  final glacier = p1.elements.whereType<ImageBlock>().first;
  doc = doc.replaceElement(0, withCropAt(withCropZoom(glacier, 1.6), .1, .7));
  final rect = doc.page(1).elements.whereType<RectShape>().first;
  doc = doc.replaceElement(1, rect.copyWith(strokeWidth: 1.2, stroke: 0xFFB4442C));
  return doc;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    for (final (family, prefix) in [('TextlySans', 'Sans'), ('TextlyCondensed', 'Cond')]) {
      final loader = FontLoader(family);
      for (final style in ['Regular', 'Bold', 'Italic', 'BoldItalic']) {
        loader.addFont(_fromDisk('assets/fonts/$prefix-$style.ttf'));
      }
      await loader.load();
    }
  });

  test('PPTX mit gemessenen Texthöhen und Textly-PDF zum Vergleich', () async {
    final doc = exchangeDocument();
    final pptx = exportPptx(doc, boxOf: renderedBox, externalImage: (k) => File(k).readAsBytesSync());
    final dir = Directory('build/pptx')..createSync(recursive: true);
    File('${dir.path}/textly.pptx').writeAsBytesSync(pptx);
    final pdf = await exportPdf(doc, _fromDisk);
    File('${dir.path}/textly.pdf').writeAsBytesSync(pdf.bytes);

    // Hin und zurück mit gemessenen Höhen
    final back = importPptx(pptx);
    expect(back.notes, isEmpty);
    expect(back.document.pages.length, 2);
  });
}
