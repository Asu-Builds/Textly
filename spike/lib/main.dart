import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:printing/printing.dart';

import 'model/document.dart';
import 'model/sample.dart';
import 'pdf/pdf_export.dart';
import 'render/page_canvas.dart';
import 'spell/spell_check.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final backend = await defaultSpellBackend();
  runApp(TextlySpikeApp(state: EditorState(sampleDocument(), SpellChecker(backend))));
}

class TextlySpikeApp extends StatelessWidget {
  const TextlySpikeApp({super.key, required this.state});
  final EditorState state;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Textly – Machbarkeitstest',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: const Color(0xFF2F5BD3), useMaterial3: true, visualDensity: VisualDensity.compact),
        home: SpikeHome(state: state),
      );
}

enum CompareMode { off, overlay, difference }

class SpikeHome extends StatefulWidget {
  const SpikeHome({super.key, required this.state});
  final EditorState state;
  @override
  State<SpikeHome> createState() => _SpikeHomeState();
}

class _SpikeHomeState extends State<SpikeHome> {
  EditorState get s => widget.state;
  double zoom = 1.2;
  PdfExportResult? lastExport;
  int exportedRevision = -1;
  String? savedPath;
  CompareMode compare = CompareMode.off;
  ui.Image? raster;
  int rasterPage = -1;
  bool busy = false;
  String? error;

  @override
  void initState() {
    super.initState();
    s.addListener(_onChange);
  }

  void _onChange() => setState(() {});

  Future<PdfExportResult> _export() async {
    if (lastExport != null && exportedRevision == s.revision) return lastExport!;
    final r = await exportPdf(s.doc, rootBundle.load);
    exportedRevision = s.revision;
    raster = null;
    return lastExport = r;
  }

  Future<void> _run(Future<void> Function() job) async {
    s.finishEditing();
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await job();
    } catch (e) {
      error = '$e';
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> _savePdf() => _run(() async {
        final r = await _export();
        final dir = Directory('${(await getApplicationDocumentsDirectory()).path}${Platform.pathSeparator}Textly');
        await dir.create(recursive: true);
        final f = File('${dir.path}${Platform.pathSeparator}textly-machbarkeitstest.pdf');
        await f.writeAsBytes(r.bytes);
        savedPath = f.path;
        if (Platform.isWindows) {
          await Process.run('cmd', ['/c', 'start', '', f.path]);
        } else if (Platform.isMacOS) {
          await Process.run('open', [f.path]);
        }
      });

  Future<void> _print() => _run(() async {
        final r = await _export();
        await Printing.layoutPdf(name: 'Textly Machbarkeitstest', onLayout: (_) async => r.bytes);
      });

  Future<void> _setCompare(CompareMode m) => _run(() async {
        compare = m;
        if (m == CompareMode.off) return;
        final r = await _export();
        if (raster == null || rasterPage != s.pageIndex) {
          await for (final page in Printing.raster(r.bytes, pages: [s.pageIndex], dpi: 216)) {
            raster = await page.toImage();
          }
          rasterPage = s.pageIndex;
        }
      });

  @override
  Widget build(BuildContext context) {
    final page = s.page;
    final compareActive = compare != CompareMode.off && raster != null && rasterPage == s.pageIndex && exportedRevision == s.revision;
    return Scaffold(
      backgroundColor: const Color(0xFFE8EBEF),
      appBar: AppBar(
        title: const Text('Textly · Machbarkeitstest'),
        backgroundColor: const Color(0xFFF8F9FB),
        actions: [
          IconButton(tooltip: 'Verkleinern', onPressed: () => setState(() => zoom = (zoom / 1.2).clamp(.4, 4)), icon: const Icon(Icons.zoom_out)),
          Center(child: Text('${(zoom * 100).round()} %')),
          IconButton(tooltip: 'Vergrössern', onPressed: () => setState(() => zoom = (zoom * 1.2).clamp(.4, 4)), icon: const Icon(Icons.zoom_in)),
          const SizedBox(width: 12),
          FilledButton.tonalIcon(onPressed: busy ? null : _print, icon: const Icon(Icons.print), label: const Text('Drucken')),
          const SizedBox(width: 8),
          FilledButton.icon(onPressed: busy ? null : _savePdf, icon: const Icon(Icons.picture_as_pdf), label: const Text('PDF erzeugen')),
          const SizedBox(width: 12),
        ],
      ),
      body: Row(children: [
        SizedBox(
          width: 150,
          child: ListView(padding: const EdgeInsets.all(12), children: [
            for (var i = 0; i < s.doc.pages.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: ChoiceChip(
                  label: Text('Seite ${i + 1}'),
                  selected: s.pageIndex == i,
                  onSelected: (_) {
                    s.goToPage(i);
                    if (compare != CompareMode.off) _setCompare(compare);
                  },
                ),
              ),
          ]),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: Center(
              child: Material(
                elevation: 3,
                child: SizedBox(
                  width: kPageWidthPt * zoom,
                  height: kPageHeightPt * zoom,
                  child: FittedBox(
                    alignment: Alignment.topLeft,
                    child: Stack(children: [
                      PageCanvas(state: s, page: page, interactive: !compareActive),
                      if (compareActive)
                        Positioned.fill(
                          child: IgnorePointer(
                            child: CustomPaint(painter: _RasterPainter(raster!, compare == CompareMode.difference)),
                          ),
                        ),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        ),
        SizedBox(width: 320, child: _sidePanel(compareActive)),
      ]),
    );
  }

  Widget _sidePanel(bool compareActive) {
    final r = lastExport?.report;
    final stale = lastExport != null && exportedRevision != s.revision;
    final th = Theme.of(context).textTheme;
    return Container(
      color: const Color(0xFFF8F9FB),
      child: ListView(padding: const EdgeInsets.all(16), children: [
        Text('1 · PDF gleich Vorschau', style: th.titleSmall),
        const SizedBox(height: 6),
        Text('Das PDF übernimmt jedes Wort an die Position, die Flutter auf dem Bildschirm berechnet. '
            'Gemessen wird, wie stark die Wortbreite im PDF abweicht.', style: th.bodySmall),
        const SizedBox(height: 8),
        if (r == null)
          const Text('Noch kein PDF erzeugt.')
        else ...[
          _kv('Wörter / Zeilen', '${r.words} / ${r.lines}'),
          _kv('Max. Abweichung', '${r.maxDeviationMm.toStringAsFixed(3)} mm'),
          _kv('Mittlere Abweichung', '${r.meanDeviationMm.toStringAsFixed(4)} mm'),
          _kv('Grösste bei', '«${r.worstWord}»'),
          _kv('Ziel', '< 0,100 mm', ok: r.maxDeviationMm < .1),
          if (stale) Text('Dokument seither geändert.', style: th.bodySmall?.copyWith(color: Colors.orange.shade800)),
          if (savedPath != null) SelectableText(savedPath!, style: th.bodySmall),
        ],
        const SizedBox(height: 10),
        SegmentedButton<CompareMode>(
          segments: const [
            ButtonSegment(value: CompareMode.off, label: Text('Aus')),
            ButtonSegment(value: CompareMode.overlay, label: Text('PDF zeigen')),
            ButtonSegment(value: CompareMode.difference, label: Text('Differenz')),
          ],
          selected: {compare},
          onSelectionChanged: busy ? null : (v) => _setCompare(v.first),
        ),
        const SizedBox(height: 6),
        Text('«Differenz» legt das PDF über die Bildschirmseite. Wo beide übereinstimmen, wird es schwarz; '
            'Abweichungen leuchten hell.', style: th.bodySmall),
        if (compareActive) Text('Vergleich aktiv: Bearbeiten ist gesperrt.', style: th.bodySmall),
        const Divider(height: 32),
        Text('2 · Textbearbeitung', style: th.titleSmall),
        const SizedBox(height: 6),
        Text('Einmal klicken wählt einen Textblock, nochmals klicken setzt den Cursor an die Klickstelle. '
            'Esc oder Klick daneben beendet. Eingabetaste = neue Zeile im selben Block. '
            'Textblöcke am Griff «Verschieben» ziehen, Bilder und Formen direkt.', style: th.bodySmall),
        const Divider(height: 32),
        Text('3 · Rechtschreibprüfung', style: th.titleSmall),
        const SizedBox(height: 6),
        Text('Unbekannte Wörter werden rot unterstrichen; Rechtsklick zeigt Vorschläge, '
            '«Zum Wörterbuch hinzufügen» und «Ignorieren». Tippe zum Beispiel «Wandrung» oder «der der».', style: th.bodySmall),
        const SizedBox(height: 6),
        _kv('Wörterbuch', s.spell.backend.language),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Rechtschreibprüfung'),
          value: s.spell.enabled,
          onChanged: (v) => setState(() => s.spell.enabled = v),
        ),
        if (error != null) ...[
          const Divider(height: 32),
          Text('Fehler', style: th.titleSmall?.copyWith(color: Colors.red)),
          SelectableText(error!, style: th.bodySmall),
        ],
      ]),
    );
  }

  Widget _kv(String k, String v, {bool? ok}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          Expanded(child: Text(k, style: const TextStyle(color: Color(0xFF5D6876)))),
          Text(v, style: TextStyle(fontWeight: FontWeight.w600, color: ok == null ? null : ok ? Colors.green.shade700 : Colors.red.shade700)),
        ]),
      );
}

class _RasterPainter extends CustomPainter {
  _RasterPainter(this.image, this.difference);
  final ui.Image image;
  final bool difference;

  @override
  void paint(Canvas canvas, Size size) {
    final src = Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
    final paint = Paint()
      ..filterQuality = FilterQuality.medium
      ..blendMode = difference ? BlendMode.difference : BlendMode.srcOver
      ..color = Color.fromRGBO(0, 0, 0, difference ? 1 : .55);
    canvas.drawImageRect(image, src, Offset.zero & size, paint);
  }

  @override
  bool shouldRepaint(_RasterPainter old) => old.image != image || old.difference != difference;
}
