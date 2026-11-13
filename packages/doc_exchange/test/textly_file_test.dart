import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:doc_exchange/doc_exchange.dart';
import 'package:doc_model/doc_model.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

Uint8List? _appAsset(String key) {
  final f = File('../../app/$key');
  return f.existsSync() ? f.readAsBytesSync() : null;
}

void main() {
  final png = img.encodePng(img.Image(width: 40, height: 20));
  final own = ImageAsset(id: 'eigen', bytes: png, mimeType: 'image/png', width: 40, height: 20);
  final unused = ImageAsset(id: 'alt', bytes: png, mimeType: 'image/png', width: 40, height: 20);

  TextlyDocument doc() {
    var d = sampleDocument().addAsset(own).addAsset(unused);
    final body = d.page(0).elements.whereType<TextBlock>().firstWhere((t) => t.kind == TextKind.body);
    d = d.replaceElement(0, body.copyWith(runs: [const StyleRun(3, 7, InlineStyle(bold: true, color: 0xFFB4442C))]));
    return d.addElement(1, const ImageBlock(id: 'b', box: Box(20, 100, 40, 20), asset: 'eigen', naturalWidth: 40, naturalHeight: 20, zoom: 1.5, cropX: .2));
  }

  test('Speichern und Öffnen ergibt dasselbe Dokument; Beispielbilder werden eingebettet', () {
    final d = doc();
    final bytes = encodeTextly(d, externalImage: _appAsset);
    final back = decodeTextly(bytes);
    expect(back.toJson()['pages'], d.toJson()['pages']);
    expect(back.assets.keys.toSet(), {'eigen', 'assets/images/glacier.jpg', 'assets/images/lake.jpg'});
    expect(back.assets['eigen']!.bytes, png);
    expect(back.assets['assets/images/glacier.jpg']!.width, 1500);
  });

  test('Aufbau des Pakets: mimetype zuerst, unbenutzte Bilder entfallen', () {
    final zip = ZipDecoder().decodeBytes(encodeTextly(doc(), externalImage: _appAsset));
    expect(zip.files.first.name, 'mimetype');
    expect(String.fromCharCodes(zip.files.first.content), textlyMimeType);
    expect(zip.files.where((f) => f.name.startsWith('media/')).length, 3, reason: '«alt» ist unbenutzt');
  });

  test('Verständliche Meldungen bei kaputten oder fremden Dateien', () {
    expect(() => decodeTextly(Uint8List.fromList([1, 2, 3])), throwsA(isA<TextlyFileException>()));
    final noDoc = Archive()..addFile(ArchiveFile.string('x.txt', 'hallo'));
    expect(() => decodeTextly(ZipEncoder().encodeBytes(noDoc)), throwsA(isA<TextlyFileException>()));
    final bytes = encodeTextly(doc(), externalImage: _appAsset);
    final zip = ZipDecoder().decodeBytes(bytes);
    final newer = Archive();
    for (final f in zip.files) {
      if (f.name == 'document.json') {
        newer.addFile(ArchiveFile.string(f.name, String.fromCharCodes(f.content).replaceFirst('"version": 1', '"version": 99')));
      } else {
        newer.addFile(ArchiveFile(f.name, f.content.length, f.content));
      }
    }
    expect(
      () => decodeTextly(ZipEncoder().encodeBytes(newer)),
      throwsA(isA<TextlyFileException>().having((e) => e.message, 'message', contains('neueren Textly-Version'))),
    );
    expect(() => encodeTextly(sampleDocument()), throwsA(isA<TextlyFileException>()), reason: 'Bild fehlt');
  });

  test('beschädigte Inhalte ergeben immer eine verständliche Meldung', () {
    Uint8List zipWith(Map<String, dynamic> json, {Map<String, List<int>> media = const {}}) {
      final a = Archive()..addFile(ArchiveFile.string('mimetype', 'application/vnd.textly'));
      a.addFile(ArchiveFile.string('document.json', jsonEncode(json)));
      for (final e in media.entries) {
        a.addFile(ArchiveFile(e.key, e.value.length, e.value));
      }
      return Uint8List.fromList(ZipEncoder().encodeBytes(a));
    }

    final base = TextlyDocument(pages: [DocPage(id: 'p', elements: const [])]).toJson();
    final bad = <Uint8List>[
      zipWith({...base, 'assets': [{'id': 'x', 'file': 5}]}),
      zipWith({...base, 'assets': {'a': 1}}),
      zipWith({...base, 'assets': ['oops']}),
      // keine Bilddaten unter dem Bildnamen
      zipWith({...base, 'assets': [{'id': 'x', 'file': 'media/1.png', 'mimeType': 'image/png', 'width': 1, 'height': 1}]},
          media: {'media/1.png': [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]}),
    ];
    for (final b in bad) {
      expect(() => decodeTextly(b), throwsA(isA<TextlyFileException>()));
    }
    // Bild mit Grösse 0
    final img0 = TextlyDocument(pages: [
      DocPage(id: 'p', elements: const [ImageBlock(id: 'i', box: Box(0, 0, 10, 10), asset: 'a', naturalWidth: 0, naturalHeight: 0)]),
    ]).toJson();
    expect(() => decodeTextly(zipWith(img0)), throwsA(isA<TextlyFileException>()));
  });
}
