import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:textly_spike/model/document.dart';
import 'package:textly_spike/model/sample.dart';
import 'package:textly_spike/pdf/pdf_export.dart';
import 'package:textly_spike/render/page_canvas.dart';
import 'package:textly_spike/render/text_layout.dart';
import 'package:textly_spike/spell/spell_check.dart';

Future<ByteData> _fromDisk(String key) async => ByteData.sublistView(await File(key).readAsBytes());

Future<void> _loadFonts() async {
  for (final (family, prefix) in [('TextlySans', 'Sans'), ('TextlyCondensed', 'Cond')]) {
    final loader = FontLoader(family);
    for (final style in ['Regular', 'Bold', 'Italic', 'BoldItalic']) {
      loader.addFont(_fromDisk('assets/fonts/$prefix-$style.ttf'));
    }
    await loader.load();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(_loadFonts);

  test('Dokument übersteht JSON hin und zurück', () {
    final doc = sampleDocument();
    final again = TextlyDocument.fromJson(doc.toJson());
    expect(again.toJson(), doc.toJson());
  });

  test('PDF: Wortbreiten weichen weniger als 0,1 mm vom Bildschirm ab', () async {
    final result = await exportPdf(sampleDocument(), _fromDisk);
    final out = Directory('build/fidelity')..createSync(recursive: true);
    File('${out.path}/textly-spike.pdf').writeAsBytesSync(result.bytes);
    final r = result.report;
    // ignore: avoid_print
    print('FIDELITY $r');
    // Umrisse der Textblöcke (in pt) für die Pixelmessung pro Block
    final blocks = [
      for (final (i, p) in sampleDocument().pages.indexed)
        for (final t in p.elements.whereType<TextElement>())
          {
            'page': i + 1, 'kind': t.kind.name, 'text': t.text.substring(0, t.text.length.clamp(0, 24)),
            'x': t.x * kMmToPt, 'y': t.y * kMmToPt, 'w': t.w * kMmToPt, 'h': textBlockHeight(t, layoutText(t)),
          },
    ];
    File('${out.path}/blocks.json').writeAsStringSync(jsonEncode(blocks));
    expect(r.words, greaterThan(300));
    expect(r.maxDeviationMm, lessThan(.1));
  });

  testWidgets('Bildschirmseiten als PNG für den Pixelvergleich', (tester) async {
    tester.view.physicalSize = const Size(kPageWidthPt * 3, kPageHeightPt * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final doc = sampleDocument();
    final state = EditorState(doc, SpellChecker(WordListBackend(const [])));
    for (var i = 0; i < doc.pages.length; i++) {
      final key = GlobalKey();
      await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Align(
          alignment: Alignment.topLeft,
          child: RepaintBoundary(key: key, child: PageCanvas(state: state, page: doc.pages[i], interactive: false)),
        ),
      ));
      // Bilder dekodieren
      await tester.runAsync(() async {
        for (final el in tester.widgetList<Image>(find.byType(Image))) {
          await precacheImage(el.image, tester.element(find.byType(PageCanvas)));
        }
      });
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: double.parse(Platform.environment["SPIKE_RATIO"] ?? "3"));
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        File('build/fidelity/screen-p${i + 1}.png').writeAsBytesSync(png!.buffer.asUint8List());
      });
    }
  });
}
