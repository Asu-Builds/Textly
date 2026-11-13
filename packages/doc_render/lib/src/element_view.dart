import 'dart:math' as math;

import 'package:doc_model/doc_model.dart';
import 'package:flutter/widgets.dart';

import 'image_layout.dart';
import 'table_layout.dart';
import 'text_layout.dart';

/// Liefert das Bild zu einem Verweis (vorerst App-Assets, später Dateien im Dokumentpaket).
typedef ImageResolver = ImageProvider Function(String asset);

ImageProvider defaultImageResolver(String asset) => AssetImage(asset);

/// Umrisse in Punkt für die Platzierung auf der Seite.
Rect elementRectPt(DocElement e) {
  final b = renderedBox(e);
  return Rect.fromLTWH(b.x * mmToPt, b.y * mmToPt, b.w * mmToPt, b.h * mmToPt);
}

/// Statische Darstellung eines Elements in Punkt-Einheiten (ohne Position).
class ElementView extends StatelessWidget {
  const ElementView({super.key, required this.element, this.images = defaultImageResolver});
  final DocElement element;
  final ImageResolver images;

  @override
  Widget build(BuildContext context) => switch (element) {
        TextBlock t => TextBlockView(block: t),
        ImageBlock i => _ImageView(block: i, images: images),
        RectShape r => _RectView(shape: r),
        LineShape l => CustomPaint(painter: _LinePainter(l, elementRectPt(l).topLeft), size: elementRectPt(l).size),
        TableBlock t => TableView(table: t),
      };
}

class TextBlockView extends StatelessWidget {
  const TextBlockView({super.key, required this.block});
  final TextBlock block;

  @override
  Widget build(BuildContext context) {
    final tp = layoutText(block);
    return CustomPaint(
      painter: _TextPaint(tp),
      size: Size(block.box.w * mmToPt, textBlockHeightPt(block, tp)),
    );
  }
}

class _TextPaint extends CustomPainter {
  _TextPaint(this.tp);
  final TextPainter tp;
  @override
  void paint(Canvas canvas, Size size) => tp.paint(canvas, const Offset(textPadX, textPadY));
  @override
  bool shouldRepaint(_TextPaint old) => true;
}

/// Tabelle ohne Bearbeitung (Zellen als Textblöcke gesetzt, siehe table_layout.dart).
class TableView extends StatelessWidget {
  const TableView({super.key, required this.table, this.hideCell});
  final TableBlock table;

  /// Zelle, deren Text nicht gezeichnet wird (Eingabefeld darüber).
  final ({int row, int col})? hideCell;

  @override
  Widget build(BuildContext context) => CustomPaint(
        painter: _TablePaint(table, hideCell),
        size: Size(table.width * mmToPt, tableHeightMm(table) * mmToPt),
      );
}

class _TablePaint extends CustomPainter {
  _TablePaint(this.t, this.hideCell);
  final TableBlock t;
  final ({int row, int col})? hideCell;
  @override
  void paint(Canvas canvas, Size size) => paintTable(canvas, t, hideCell: hideCell);
  @override
  bool shouldRepaint(_TablePaint old) => !identical(old.t, t) || old.hideCell != hideCell;
}

class _ImageView extends StatelessWidget {
  const _ImageView({required this.block, required this.images});
  final ImageBlock block;
  final ImageResolver images;

  @override
  Widget build(BuildContext context) {
    final p = imagePlacement(block);
    return ClipRect(
      child: Stack(clipBehavior: Clip.none, children: [
        Positioned.fromRect(
          rect: p,
          // Bilddatei gedreht in die (schon gedrehte) Lage zeichnen
          child: RotatedBox(
            quarterTurns: block.quarterTurns,
            child: Image(image: images(block.asset), fit: BoxFit.fill, filterQuality: FilterQuality.medium),
          ),
        ),
      ]),
    );
  }
}

class _RectView extends StatelessWidget {
  const _RectView({required this.shape});
  final RectShape shape;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: Color(shape.fill),
          borderRadius: shape.round ? BorderRadius.circular(2.5 * mmToPt) : null,
          border: shape.strokeWidth > 0 ? Border.all(color: Color(shape.stroke), width: shape.strokeWidth * mmToPt) : null,
        ),
      );
}

class _LinePainter extends CustomPainter {
  _LinePainter(this.l, this.origin);
  final LineShape l;
  final Offset origin;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Color(l.color)
      ..strokeWidth = math.max(.1, l.width * mmToPt)
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(l.a.x, l.a.y) * mmToPt - origin, Offset(l.b.x, l.b.y) * mmToPt - origin, p);
  }

  @override
  bool shouldRepaint(_LinePainter old) => old.l != l || old.origin != origin;
}

/// Ganze Seite ohne Bearbeitung (Miniaturen, Vorschau). A4 in Punkt (hoch 595 × 842, quer
/// 842 × 595); von aussen skalieren.
class StaticPage extends StatelessWidget {
  const StaticPage({
    super.key,
    required this.page,
    this.images = defaultImageResolver,
    this.widthMm = pageWidthMm,
    this.heightMm = pageHeightMm,
  });
  final DocPage page;
  final ImageResolver images;
  final double widthMm, heightMm;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: widthMm * mmToPt,
        height: heightMm * mmToPt,
        child: ClipRect(
          child: Stack(clipBehavior: Clip.none, children: [
            const Positioned.fill(child: ColoredBox(color: Color(0xFFFFFFFF))),
            for (final e in page.elements)
              Positioned.fromRect(rect: elementRectPt(e), child: ElementView(element: e, images: images)),
          ]),
        ),
      );
}
