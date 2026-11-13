import 'dart:typed_data';

import 'package:doc_model/doc_model.dart';
import 'package:test/test.dart';

/// Quadratisches Bild in einem breiten Rahmen: Bei «Fläche füllen» ist die halbe Höhe sichtbar.
const img = ImageBlock(id: 'i', box: Box(0, 0, 100, 50), asset: 'a', naturalWidth: 1000, naturalHeight: 1000);

void main() {
  group('Bildausschnitt', () {
    test('sichtbarer Anteil und Lage', () {
      final w = cropWindow(img);
      expect(w.w, closeTo(1, 1e-9));
      expect(w.h, closeTo(.5, 1e-9));
      expect(w.y, closeTo(.25, 1e-9)); // mittig
    });

    test('verschieben bleibt im Bild', () {
      expect(cropWindow(withCropAt(img, 0, 0)).y, 0);
      expect(cropWindow(withCropAt(img, 0, 5)).y, closeTo(.5, 1e-9));
      expect(withCropAt(img, 0, -1).cropY, 0);
    });

    test('Vergrösserung behält die Mitte', () {
      final z = withCropZoom(withCropCenteredAt(img, .5, .3), 2);
      final w = cropWindow(z);
      expect(w.w, closeTo(.5, 1e-9));
      expect(w.h, closeTo(.25, 1e-9));
      expect(w.y + w.h / 2, closeTo(.3, 1e-9));
      expect(withCropZoom(img, 99).zoom, maxCropZoom);
      expect(withCropZoom(img, .1).zoom, minCropZoom);
    });

    test('Zurücksetzen und Originalform', () {
      expect(withCropReset(withCropZoom(img, 3)).zoom, 1);
      expect(hasChangedShape(img), isTrue);
      final o = withOriginalShape(img);
      expect(o.box.h, 100);
      expect(o.box.centerY, img.box.centerY);
      expect(hasChangedShape(o), isFalse);
    });
  });

  group('Bilddateien im Dokument', () {
    final asset = ImageAsset(id: 'a1', bytes: Uint8List.fromList([1, 2, 3]), mimeType: 'image/png', width: 10, height: 20);

    test('bleiben bei Seitenoperationen erhalten und gehen nicht ins JSON als Daten', () {
      var doc = sampleDocument().addAsset(asset);
      doc = doc.insertPage(0, DocPage(id: 'x')).movePage(0, 1).removePage(1);
      expect(doc.assets['a1'], same(asset));
      final j = doc.toJson();
      expect((j['assets'] as List).single, {'id': 'a1', 'mimeType': 'image/png', 'width': 10, 'height': 20});
    });

    test('JSON hin und zurück mit Bilddaten', () {
      final doc = sampleDocument().addAsset(asset);
      final again = TextlyDocument.fromJson(doc.toJson(), assetBytes: {'a1': asset.bytes});
      expect(again.assets['a1']!.bytes, asset.bytes);
      expect(() => TextlyDocument.fromJson(doc.toJson()), throwsFormatException);
    });

    test('unbenutzte Bilddateien entfernen', () {
      final doc = sampleDocument().addAsset(asset);
      expect(doc.withoutUnusedAssets().assets, isEmpty);
      final used = doc.addElement(0, const ImageBlock(id: 'b', box: Box(0, 0, 10, 20), asset: 'a1', naturalWidth: 10, naturalHeight: 20));
      expect(used.withoutUnusedAssets().assets.keys, ['a1']);
    });
  });

  group('Drehen in 90°-Schritten', () {
    const wide = ImageBlock(id: 'd', box: Box(20, 30, 80, 40), asset: 'a', naturalWidth: 1600, naturalHeight: 800);

    test('Rahmen dreht um die Mitte, Masse werden getauscht', () {
      final r = withQuarterTurn(wide);
      expect(r.quarterTurns, 1);
      expect((r.box.x, r.box.y, r.box.w, r.box.h), (40.0, 10.0, 40.0, 80.0));
      expect((r.naturalWidth, r.naturalHeight), (800, 1600));
      expect(withQuarterTurn(wide, clockwise: false).quarterTurns, 3);
    });

    test('viermal drehen ergibt wieder das Original', () {
      var r = withCropAt(withCropZoom(wide, 2), .1, .6);
      final start = r;
      for (var n = 0; n < 4; n++) {
        r = withQuarterTurn(r);
      }
      void same(ImageBlock a, ImageBlock b) {
        expect((a.box, a.naturalWidth, a.naturalHeight, a.quarterTurns, a.zoom), (b.box, b.naturalWidth, b.naturalHeight, b.quarterTurns, b.zoom));
        expect(a.cropX, closeTo(b.cropX, 1e-12));
        expect(a.cropY, closeTo(b.cropY, 1e-12));
      }

      same(r, start);
      same(withQuarterTurn(withQuarterTurn(start), clockwise: false), start);
    });

    test('Ausschnitt zeigt nach dem Drehen denselben Bildteil', () {
      final start = withCropAt(withCropZoom(wide, 2), .1, .6);
      final before = cropWindow(start);
      var r = start;
      for (var q = 1; q < 4; q++) {
        r = withQuarterTurn(r);
        final src = windowInSource(cropWindow(r), q);
        expect(src.x, closeTo(before.x, 1e-9), reason: '$q');
        expect(src.y, closeTo(before.y, 1e-9), reason: '$q');
        expect(src.w, closeTo(before.w, 1e-9), reason: '$q');
        expect(src.h, closeTo(before.h, 1e-9), reason: '$q');
        final back = windowInDisplay(src, q);
        expect(back.x, closeTo(cropWindow(r).x, 1e-9));
      }
    });

    test('Speichern: Drehung bleibt erhalten, alte Dateien ohne Angabe sind ungedreht', () {
      final r = withQuarterTurn(wide);
      expect(ImageBlock.fromJson(r.toJson()).quarterTurns, 1);
      expect(ImageBlock.fromJson(wide.toJson()..remove('rotation')).quarterTurns, 0);
    });
  });

  group('Zuschneiden an den Rändern', () {
    // ganzes Bild 300 × 200 Bildpunkte in einem Rahmen 60 × 40 mm (0,2 mm pro Bildpunkt)
    const full = ImageBlock(id: 'f', box: Box(10, 20, 60, 40), asset: 'a', naturalWidth: 300, naturalHeight: 200);

    test('links ein Viertel weg: Rahmen schmaler, Bild bleibt gleich gross und an seinem Platz', () {
      final r = withCropRect(full, .25, 0, 1, 1);
      expect(r.box.x, closeTo(25, 1e-9));
      expect(r.box.w, closeTo(45, 1e-9));
      expect((r.box.y, r.box.h), (20, 40));
      final w = cropWindow(r);
      expect(w.x, closeTo(.25, 1e-9));
      expect(w.w, closeTo(.75, 1e-9));
      expect(w.h, closeTo(1, 1e-9));
    });

    test('oben und unten weg, dann wieder ganz: alles wie vorher', () {
      final r = withCropRect(full, 0, .1, 1, .6);
      expect(r.box.y, closeTo(24, 1e-9));
      expect(r.box.h, closeTo(20, 1e-9));
      expect(cropWindow(r).y, closeTo(.1, 1e-9));
      final back = withCropRect(r, 0, 0, 1, 1);
      expect(back.box.x, closeTo(10, 1e-9));
      expect(back.box.y, closeTo(20, 1e-9));
      expect(back.box.w, closeTo(60, 1e-9));
      expect(back.box.h, closeTo(40, 1e-9));
      expect(back.zoom, closeTo(1, 1e-9));
    });

    test('nicht kleiner als ein Viertel, nicht über den Bildrand', () {
      final r = withCropRect(full, .9, -.5, .95, 1.5);
      final w = cropWindow(r);
      expect(w.w, closeTo(minCropPart, 1e-9));
      expect(w.x + w.w, lessThanOrEqualTo(1 + 1e-9));
      expect(w.y, closeTo(0, 1e-9));
      expect(w.h, closeTo(1, 1e-9));
    });
  });

  test('Bild ohne Fläche: ganzes Bild statt NaN', () {
    const z = ImageBlock(id: 'z', box: Box(10, 10, 0, 0), asset: 'a', naturalWidth: 300, naturalHeight: 200);
    final w = cropWindow(z);
    expect([w.x, w.y, w.w, w.h].every((v) => v.isFinite), isTrue);
    expect((w.w, w.h), (1.0, 1.0));
  });
}
