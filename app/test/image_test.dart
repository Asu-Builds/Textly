import 'dart:io';
import 'dart:typed_data';

import 'package:doc_model/doc_model.dart';
import 'package:doc_render/doc_render.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:textly/editor/editor_controller.dart';
import 'package:textly/editor/editor_page.dart';
import 'package:textly/editor/properties_panel.dart';
import 'package:textly/images/image_import.dart';
import 'package:textly/images/windows_clipboard.dart';
import 'package:textly/spell/spell_check.dart';

Future<ByteData> _fromDisk(String key) async => ByteData.sublistView(await File(key).readAsBytes());

EditorController _controller() => EditorController(sampleDocument(), spell: SpellChecker(WordListBackend(const [])));

img.Image _picture(int w, int h, {bool alpha = false}) {
  final image = img.Image(width: w, height: h, numChannels: alpha ? 4 : 3);
  for (final p in image) {
    p
      ..r = p.x * 255 ~/ w
      ..g = p.y * 255 ~/ h
      ..b = 120;
    if (alpha) p.a = p.x < w / 2 ? 0 : 255;
  }
  return image;
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

  group('Bild aufbereiten', () {
    test('kleines PNG wird unverändert übernommen', () {
      final png = img.encodePng(_picture(300, 200));
      final a = prepareImageSync(png);
      expect(a.bytes, same(png));
      expect((a.mimeType, a.width, a.height), ('image/png', 300, 200));
    });

    test('grosses Foto wird auf 3000 Pixel verkleinert', () {
      final a = prepareImageSync(img.encodeJpg(_picture(4000, 2000), quality: 80));
      expect((a.mimeType, a.width, a.height), ('image/jpeg', 3000, 1500));
    });

    test('Drehangabe eines Kamerafotos wird ins Bild übernommen', () {
      final photo = _picture(400, 200);
      photo.exif.imageIfd.orientation = 6; // 90° im Uhrzeigersinn
      final bytes = img.encodeJpg(photo);
      expect(img.decodeJpgExif(bytes)?.imageIfd.orientation, 6, reason: 'Testbild enthält die Drehangabe');
      final a = prepareImageSync(bytes);
      expect((a.width, a.height), (200, 400));
      expect(img.decodeJpgExif(a.bytes)?.imageIfd.orientation ?? 1, 1);
    });

    test('grosses PNG mit Transparenz bleibt PNG', () {
      final a = prepareImageSync(img.encodePng(_picture(3200, 1000, alpha: true)));
      expect(a.mimeType, 'image/png');
      expect(a.width, 3000);
      expect(img.decodePng(a.bytes)!.hasAlpha, isTrue);
    });

    test('andere Formate werden JPG', () {
      final a = prepareImageSync(img.encodeBmp(_picture(100, 80)));
      expect(a.mimeType, 'image/jpeg');
    });

    test('keine Bilddatei ergibt eine verständliche Meldung', () {
      expect(
        () => prepareImageSync(Uint8List.fromList(List.filled(100, 7))),
        throwsA(isA<ImageImportException>().having((e) => e.message, 'message', contains('JPG, PNG'))),
      );
    });

    test('Windows-Bitmap aus der Zwischenablage mit leerem Alphakanal wird undurchsichtig', () {
      // 2 × 2 Pixel, 32 Bit, BI_RGB, Alpha 0 – so liefern viele Programme Bildschirmfotos
      final dib = ByteData(40 + 16)
        ..setUint32(0, 40, Endian.little)
        ..setInt32(4, 2, Endian.little)
        ..setInt32(8, 2, Endian.little)
        ..setUint16(12, 1, Endian.little)
        ..setUint16(14, 32, Endian.little);
      for (var i = 0; i < 4; i++) {
        dib.setUint8(40 + i * 4 + 2, 220); // Rot (BGRA)
      }
      final bmp = bmpFromDib(dib.buffer.asUint8List())!;
      final a = prepareImageSync(bmp, opaque: true);
      expect(a.mimeType, 'image/jpeg');
      final px = img.decodeJpg(a.bytes)!.getPixel(0, 0);
      expect(px.r, greaterThan(180));
      expect(px.g, lessThan(60));
    });
  });

  group('Bilder im Editor', () {
    final asset = prepareImageSync(img.encodePng(_picture(400, 300)));

    test('Einfügen ist ein Schritt; Grösse und Lage', () {
      final c = _controller();
      final b = c.insertImage(asset, center: const Pt(60, 100));
      expect(c.doc.assets[asset.id], same(asset));
      expect(c.selectedId, b.id);
      expect(b.box.w, 110);
      expect(b.box.h, closeTo(110 * 300 / 400, 1e-9));
      expect(b.box.centerX, closeTo(60, 1e-9));
      c.undo();
      expect(c.page.find(b.id), isNull);
      expect(c.doc.assets.containsKey(asset.id), isFalse);
    });

    test('Einfügen am Rand bleibt ganz auf der Seite; Hochformat höchstens 130 mm hoch', () {
      final c = _controller();
      final tall = prepareImageSync(img.encodePng(_picture(100, 400)));
      final b = c.insertImage(tall, center: const Pt(205, 290));
      expect(b.box.h, 130);
      expect(b.box.right, lessThanOrEqualTo(pageWidthMm));
      expect(b.box.bottom, lessThanOrEqualTo(pageHeightMm));
    });

    test('anderes Bild wählen behält den Rahmen und setzt den Ausschnitt zurück', () {
      final c = _controller();
      final b = c.insertImage(asset);
      c.updateSelectedImage((i) => withCropZoom(i, 2));
      final other = prepareImageSync(img.encodePng(_picture(200, 200)));
      c.replaceSelectedImage(other);
      final r = c.selected! as ImageBlock;
      expect(r.box, b.box);
      expect((r.asset, r.naturalWidth, r.zoom), (other.id, 200, 1.0));
    });

    test('PDF mit eingefügtem PNG (mit Transparenz) und JPG', () async {
      final c = _controller();
      c.insertImage(prepareImageSync(img.encodePng(_picture(400, 300, alpha: true))));
      c.insertImage(prepareImageSync(img.encodeJpg(_picture(400, 300))), center: const Pt(100, 250));
      final result = await exportPdf(c.doc, _fromDisk);
      expect(String.fromCharCodes(result.bytes.take(5)), '%PDF-');
    });
  });

  group('Eigenschaftenleiste Bild mit echter Maus', () {
    Future<EditorController> pumpEditor(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = _controller();
      await tester.pumpWidget(MaterialApp(home: EditorPage(controller: c)));
      await tester.pump();
      return c;
    }

    Future<void> click(WidgetTester tester, Offset at) async {
      final g = await tester.startGesture(at, kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 180));
      await g.up();
      await tester.pump(const Duration(milliseconds: 400));
    }

    Future<void> drag(WidgetTester tester, Offset from, Offset by) async {
      final g = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 200));
      for (var i = 1; i <= 10; i++) {
        await g.moveTo(from + by * (i / 10));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await tester.pump();
    }

    Future<void> clickKey(WidgetTester tester, String key) => click(tester, tester.getCenter(find.byKey(ValueKey(key))));

    ImageBlock sel(EditorController c) => c.selected! as ImageBlock;

    testWidgets('Vorschau «Ausschnitt wählen» behält das Seitenverhältnis, auch im Hochformat', (tester) async {
      final c = await pumpEditor(tester);
      final b = c.page.elements.whereType<ImageBlock>().first;
      await click(tester, tester.getCenter(find.byKey(ValueKey('element-${b.id}'))));
      for (final (w, h) in [(297, 502), (1536, 1024)]) {
        c.updateSelectedImage((i) => i.copyWith(naturalWidth: w, naturalHeight: h));
        await tester.pump();
        final area = tester.getRect(find.byKey(const ValueKey('crop-area')));
        expect(area.width / area.height, closeTo(w / h, .01), reason: '$w × $h nicht in die Breite gezogen');
        final panel = tester.getRect(find.byType(PropertiesPanel));
        expect(area.center.dx, closeTo(panel.center.dx, 1), reason: 'mittig in der Leiste');
      }
    });

    testWidgets('Zuschneiden an den Griffen der Vorschau, auch wenn das ganze Bild sichtbar ist (z. B. aus Word)', (tester) async {
      final c = await pumpEditor(tester);
      final b = c.page.elements.whereType<ImageBlock>().first;
      await click(tester, tester.getCenter(find.byKey(ValueKey('element-${b.id}'))));
      // Rahmen genau in Bildform: ganzes Bild sichtbar
      c.updateSelectedImage((i) => i.copyWith(box: i.box.copyWith(h: i.box.w / i.naturalAspect)));
      await tester.pump();
      final before = sel(c);
      expect(cropWindow(before).w, closeTo(1, .001));
      final depth = c.history.undoDepth;
      final area = tester.getRect(find.byKey(const ValueKey('crop-area')));
      // linken Rand um ein Viertel nach rechts ziehen
      await drag(tester, Offset(area.left + 3, area.center.dy), Offset(area.width / 4, 0));
      final after = sel(c);
      expect(cropWindow(after).x, closeTo(.25, .02), reason: 'links ein Viertel abgeschnitten');
      expect(after.box.w, closeTo(before.box.w * .75, before.box.w * .02), reason: 'Rahmen auf der Seite schmaler');
      expect(after.box.right, closeTo(before.box.right, .01), reason: 'rechter Rand bleibt, Bild bleibt an seinem Platz');
      expect(after.box.h, closeTo(before.box.h, .01));
      expect(c.history.undoDepth, depth + 1, reason: 'ein Schritt');
      // unteren Rand nach oben
      final area2 = tester.getRect(find.byKey(const ValueKey('crop-area')));
      await drag(tester, Offset(area2.center.dx + 30, area2.bottom - 3), Offset(0, -area2.height / 5));
      expect(cropWindow(sel(c)).h, closeTo(.8, .03));
      c.undo();
      c.undo();
      expect(sel(c).box, before.box, reason: 'rückgängig macht es ungeschehen');
    });

    testWidgets('Ausschnitt ziehen, näher heran, zurücksetzen; ganzes Bild', (tester) async {
      final c = await pumpEditor(tester);
      final b = c.page.elements.whereType<ImageBlock>().first; // 170 × 90 mm, Bild 3:2 → oben/unten abgeschnitten
      await click(tester, tester.getCenter(find.byKey(ValueKey('element-${b.id}'))));
      expect(find.byKey(const ValueKey('crop-area')), findsOneWidget);
      final depth = c.history.undoDepth;

      final area = tester.getRect(find.byKey(const ValueKey('crop-area')));
      await drag(tester, area.center, const Offset(0, 40));
      expect(sel(c).cropY, greaterThan(.9), reason: 'Rahmen nach unten gezogen');
      expect(c.history.undoDepth, depth + 1, reason: 'Ziehen ist ein Schritt');

      await clickKey(tester, 'crop-zoom-in');
      await clickKey(tester, 'crop-zoom-in');
      expect(sel(c).zoom, closeTo(1.5625, 1e-9));
      expect(c.history.undoDepth, depth + 2, reason: 'mehrmals «Näher heran» ist ein Schritt');

      // Klick auf eine Stelle im Bild legt den Ausschnitt dorthin
      await click(tester, area.topLeft + const Offset(10, 10));
      final w = cropWindow(sel(c));
      expect(w.x, closeTo(0, .02));
      expect(w.y, closeTo(0, .02));

      await clickKey(tester, 'crop-reset');
      expect((sel(c).zoom, sel(c).cropX, sel(c).cropY), (1.0, .5, .5));

      await click(tester, tester.getCenter(find.text('Ganzes Bild')));
      expect(sel(c).fit, ImageFit.contain);
      expect(find.byKey(const ValueKey('crop-area')), findsNothing);
    });

    testWidgets('Seitengriff ändert die Form; «Ursprüngliche Bildform» stellt sie wieder her', (tester) async {
      final c = await pumpEditor(tester);
      final b = c.page.elements.whereType<ImageBlock>().last; // See-Bild, Originalform
      await click(tester, tester.getCenter(find.byKey(ValueKey('element-${b.id}'))));
      expect(find.byKey(const ValueKey('img-original-shape')), findsNothing);
      await drag(tester, tester.getCenter(find.byKey(const ValueKey('handle-s'))), const Offset(0, -100));
      expect(hasChangedShape(sel(c)), isTrue);
      await clickKey(tester, 'img-original-shape');
      expect(hasChangedShape(sel(c)), isFalse);
    });

    testWidgets('Drehen: Knöpfe und Strg+R, rückgängig, gesperrtes Bild bleibt', (tester) async {
      final c = await pumpEditor(tester);
      final b = c.page.elements.whereType<ImageBlock>().last; // See-Bild hochkant
      await click(tester, tester.getCenter(find.byKey(ValueKey('element-${b.id}'))));
      await tester.ensureVisible(find.byKey(const ValueKey('img-rotate-right')));
      await tester.pump();
      await clickKey(tester, 'img-rotate-right');
      expect(sel(c).quarterTurns, 1);
      expect((sel(c).box.w, sel(c).box.h), (b.box.h, b.box.w), reason: 'Rahmen wird quer');
      expect((sel(c).box.centerX, sel(c).box.centerY), (b.box.centerX, b.box.centerY));
      expect(find.byType(RotatedBox), findsWidgets);

      await tester.ensureVisible(find.byKey(const ValueKey('img-rotate-left')));
      await tester.pump();
      await clickKey(tester, 'img-rotate-left');
      expect(sel(c).quarterTurns, 0);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(sel(c).quarterTurns, 3, reason: 'rechts, dann zweimal links');

      c.undo();
      expect(sel(c).quarterTurns, 0);

      c.commit(c.doc.replaceElement(0, sel(c).withLocked(true)));
      c.rotateSelectedImage();
      expect(sel(c).quarterTurns, 0, reason: 'gesperrt');
    });
  });
}
