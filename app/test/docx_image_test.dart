import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:doc_exchange/doc_exchange.dart';
import 'package:doc_model/doc_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:textly/images/image_import.dart';

/// Word-Datei mit einem Bild in Word-Grösse [wMm] × [hMm].
Uint8List _docxWithImage(List<int> image, double wMm, double hMm) {
  final a = Archive();
  void add(String name, List<int> b) => a.addFile(ArchiveFile(name, b.length, b));
  add('word/document.xml', utf8.encode(
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>'
    '<w:p><w:r><w:drawing><wp:inline xmlns:wp="wp"><wp:extent cx="${(wMm * 36000).round()}" cy="${(hMm * 36000).round()}"/>'
    '<a:graphic xmlns:a="a"><pic:pic xmlns:pic="pic"><a:blip xmlns:r="r" r:embed="rId1"/></pic:pic></a:graphic></wp:inline></w:drawing></w:r></w:p>'
    '</w:body></w:document>',
  ));
  add('word/_rels/document.xml.rels', utf8.encode(
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    '<Relationship Id="rId1" Type="image" Target="media/foto.jpg"/></Relationships>',
  ));
  add('word/media/foto.jpg', image);
  return Uint8List.fromList(ZipEncoder().encode(a));
}

void main() {
  test('Handyfoto mit Drehung in den Kameradaten: Bild aufrecht, Grösse passt zum Rahmen (Eigenschaften, PDF)', () {
    // gespeichert quer (60 × 30), laut Kameradaten 90° gedreht → aufrecht 30 × 60
    final raw = img.Image(width: 60, height: 30);
    raw.exif.imageIfd.orientation = 6;
    final jpg = img.encodeJpg(raw);
    final r = importDocx(
      _docxWithImage(jpg, 30, 60), // in Word so gross, wie Word das Bild zeigt: aufrecht
      heightMm: (e) => e.box.h,
      prepareImage: (b) => prepareImageSync(b),
    );
    final i = r.document.pages.single.elements.whereType<ImageBlock>().single;
    expect((i.naturalWidth, i.naturalHeight), (30, 60), reason: 'wie angezeigt, nicht wie gespeichert');
    expect(i.box.w / i.box.h, closeTo(i.naturalWidth / i.naturalHeight, .01), reason: 'Seitenverhältnis von Rahmen und Bild gleich');
    final asset = r.document.assets[i.asset]!;
    final decoded = img.decodeImage(asset.bytes)!;
    expect((decoded.width, decoded.height), (30, 60), reason: 'Drehung ins Bild übernommen (auch fürs PDF)');
    expect(cropWindow(i).w, closeTo(1, .001), reason: 'ganzes Bild sichtbar');
    expect(r.notes, isEmpty);
  });
}
