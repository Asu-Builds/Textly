import 'dart:async';
import 'dart:io';

import 'package:doc_model/doc_model.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:textly/editor/editor_canvas.dart';
import 'package:textly/editor/editor_controller.dart';
import 'package:textly/editor/editor_page.dart';
import 'package:textly/editor/preview_page.dart';
import 'package:textly/spell/spell_check.dart';

Future<ByteData> _fromDisk(String key) async => ByteData.sublistView(await File(key).readAsBytes());

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

  Future<EditorController> pumpEditor(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = EditorController(sampleDocument(), spell: SpellChecker(WordListBackend(const [])));
    await tester.pumpWidget(MaterialApp(home: EditorPage(controller: c)));
    await tester.pump();
    return c;
  }

  Future<void> click(WidgetTester tester, Finder f) async {
    final g = await tester.startGesture(tester.getCenter(f), kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 150));
    await g.up();
    await tester.pumpAndSettle();
  }

  testWidgets('Fertigstellen ohne Probleme: Seiten, grüne Meldung, alle Möglichkeiten, zurück zum Bearbeiten', (tester) async {
    await pumpEditor(tester);
    await click(tester, find.byKey(const ValueKey('tool-finish')));
    expect(find.byType(PreviewPage), findsOneWidget);
    expect(find.textContaining('2 Seiten · A4 Hochformat'), findsOneWidget);
    for (final k in ['preview-print', 'preview-pdf', 'finish-email', 'finish-textly', 'finish-pptx']) {
      expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
    }
    expect(find.byKey(const ValueKey('preview-page-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('preview-ok')), findsOneWidget);
    expect(find.byType(EditorCanvas), findsNothing, reason: 'Vorschau ohne Raster, Griffe und Auswahl');
    await click(tester, find.byKey(const ValueKey('preview-close')));
    expect(find.byType(PreviewPage), findsNothing);
    expect(find.byType(EditorCanvas), findsOneWidget);
  });

  testWidgets('Hinweis anklicken: zurück im Editor, richtige Seite, Element ausgewählt', (tester) async {
    final c = await pumpEditor(tester);
    // Seite 2: Textblock über den rechten Papierrand schieben
    c.goToPage(1);
    final t = c.page.elements.whereType<TextBlock>().firstWhere((e) => e.kind == TextKind.body); // langer Text
    c.commit(c.doc.replaceElement(1, t.translated(60, 0)));
    // Seite 1: Linie bis 2 mm an den linken Rand
    c.goToPage(0);
    final l = c.page.elements.whereType<LineShape>().first;
    c.commit(c.doc.replaceElement(0, l.copyWith(a: const Pt(2, 45))));
    await tester.pump();

    await click(tester, find.byKey(const ValueKey('tool-finish')));
    expect(find.text('2 Hinweise. Klicke auf einen Hinweis, um das Element zu bearbeiten.'), findsOneWidget);
    expect(find.textContaining('liegt sehr nah am Papierrand'), findsOneWidget);
    expect(find.textContaining('ragt über den Papierrand'), findsOneWidget);

    await click(tester, find.textContaining('ragt über den Papierrand'));
    expect(find.byType(PreviewPage), findsNothing);
    expect(c.pageIndex, 1);
    expect(c.selectedId, t.id);
  });

  testWidgets('Fertigstellen: während das PDF entsteht, Fortschritt zeigen und andere Optionen sperren', (tester) async {
    tester.view.physicalSize = const Size(1600, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final pdf = Completer<void>();
    var pdfCalls = 0, printCalls = 0;
    await tester.pumpWidget(MaterialApp(
      home: PreviewPage(
        doc: TextlyDocument(pages: [DocPage(id: 'p')]),
        onPdf: () {
          pdfCalls++;
          return pdf.future;
        },
        onPrint: () async => printCalls++,
      ),
    ));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('preview-pdf')));
    await tester.pump();
    expect(find.text('Wird vorbereitet … einen Moment.'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('preview-pdf')));
    await tester.tap(find.byKey(const ValueKey('preview-print')));
    await tester.pump();
    expect((pdfCalls, printCalls), (1, 0), reason: 'kein zweites PDF, Drucken gesperrt');
    pdf.complete();
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.tap(find.byKey(const ValueKey('preview-print')));
    await tester.pump();
    expect(printCalls, 1);
  });
}
