import 'dart:math' as math;

import 'package:doc_model/doc_model.dart';
import 'package:doc_render/doc_render.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'editor_controller.dart';

/// Wahl des Bildausschnitts (Prototyp v3): Das ganze Bild wird klein gezeigt, ein heller Rahmen
/// markiert den sichtbaren Teil, der Rest ist abgedunkelt. Rahmen ziehen oder auf eine Stelle klicken.
/// Keine Zahlenwerte und kein eigener Modus auf der Seite.
class CropEditor extends StatefulWidget {
  const CropEditor({super.key, required this.controller, required this.block});
  final EditorController controller;
  final ImageBlock block;

  @override
  State<CropEditor> createState() => _CropEditorState();
}

class _CropEditorState extends State<CropEditor> {
  ImageBlock? _base;
  CropWindow? _startWindow;
  Offset? _startPos;

  /// Beim Zuschneiden: die angefassten Ränder; sonst null (Rahmen verschieben).
  ({bool l, bool t, bool r, bool b})? _edges;
  MouseCursor _cursor = SystemMouseCursors.move;

  Size _size() {
    final r = widget.block.naturalAspect;
    final w = math.min(248.0, 170.0 * r);
    return Size(w, w / r);
  }

  /// Punkt im Vorschaubild → Anteil am ganzen Bild.
  Offset _fraction(Offset local, Size s) => Offset(local.dx / s.width, local.dy / s.height);

  bool _inside(CropWindow w, Offset f) => f.dx >= w.x && f.dx <= w.x + w.w && f.dy >= w.y && f.dy <= w.y + w.h;

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final b = widget.block;
    final s = _size();
    final window = cropWindow(b);
    // Mittig in der Leiste und in eigener Grösse: Die Leiste gibt ihren Kindern die volle Breite vor,
    // sonst würde ein hochformatiges Bild in die Breite gezogen.
    return Center(child: _area(c, b, s, window));
  }

  /// Ränder des Rahmens unter dem Zeiger (Griffbereich [_grip] Bildpunkte); bei schmalem Rahmen der nähere.
  ({bool l, bool t, bool r, bool b}) _edgesAt(Offset p, CropWindow w, Size s) {
    final rect = Rect.fromLTWH(w.x * s.width, w.y * s.height, w.w * s.width, w.h * s.height);
    final inY = p.dy > rect.top - _grip && p.dy < rect.bottom + _grip;
    final inX = p.dx > rect.left - _grip && p.dx < rect.right + _grip;
    var l = inY && (p.dx - rect.left).abs() < _grip, r = inY && (p.dx - rect.right).abs() < _grip;
    var t = inX && (p.dy - rect.top).abs() < _grip, b = inX && (p.dy - rect.bottom).abs() < _grip;
    if (l && r) (l, r) = ((p.dx - rect.left).abs() <= (p.dx - rect.right).abs(), (p.dx - rect.left).abs() > (p.dx - rect.right).abs());
    if (t && b) (t, b) = ((p.dy - rect.top).abs() <= (p.dy - rect.bottom).abs(), (p.dy - rect.top).abs() > (p.dy - rect.bottom).abs());
    return (l: l, t: t, r: r, b: b);
  }

  static const _grip = 9.0;

  static bool _any(({bool l, bool t, bool r, bool b}) e) => e.l || e.t || e.r || e.b;

  static MouseCursor _cursorFor(({bool l, bool t, bool r, bool b}) e) {
    if ((e.l && e.t) || (e.r && e.b)) return SystemMouseCursors.resizeUpLeftDownRight;
    if ((e.r && e.t) || (e.l && e.b)) return SystemMouseCursors.resizeUpRightDownLeft;
    if (e.l || e.r) return SystemMouseCursors.resizeLeftRight;
    if (e.t || e.b) return SystemMouseCursors.resizeUpDown;
    return SystemMouseCursors.move;
  }

  Widget _area(EditorController c, ImageBlock b, Size s, CropWindow window) {
    return GestureDetector(
      key: const ValueKey('crop-area'),
      dragStartBehavior: DragStartBehavior.down,
      // Klick: Ausschnitt dorthin legen (ein Schritt); Klick auf einen Rand tut nichts
      onTapUp: (d) {
        if (_any(_edgesAt(d.localPosition, window, s))) return;
        final f = _fraction(d.localPosition, s);
        c.updateSelectedImage((i) => withCropCenteredAt(i, f.dx, f.dy));
      },
      onPanStart: (d) {
        c.beginPreview();
        var base = b;
        final edges = _edgesAt(d.localPosition, window, s);
        final f = _fraction(d.localPosition, s);
        if (_any(edges)) {
          // am Rand angefasst: zuschneiden
          _edges = edges;
        } else if (!_inside(window, f)) {
          // ausserhalb des Rahmens angefasst: Rahmen springt dorthin, dann weiterziehen
          base = withCropCenteredAt(b, f.dx, f.dy);
          c.previewSelected(base);
        }
        _base = base;
        _startWindow = cropWindow(base);
        _startPos = d.localPosition;
      },
      onPanUpdate: (d) {
        final base = _base, w0 = _startWindow, p0 = _startPos;
        if (base == null || w0 == null || p0 == null) return;
        final dx = (d.localPosition - p0).dx / s.width, dy = (d.localPosition - p0).dy / s.height;
        final e = _edges;
        if (e != null) {
          c.previewSelected(withCropRect(
            base,
            w0.x + (e.l ? dx : 0),
            w0.y + (e.t ? dy : 0),
            w0.x + w0.w + (e.r ? dx : 0),
            w0.y + w0.h + (e.b ? dy : 0),
          ));
        } else {
          c.previewSelected(withCropAt(base, w0.x + dx, w0.y + dy));
        }
      },
      onPanEnd: (_) => _end(),
      onPanCancel: _end,
      child: MouseRegion(
        cursor: _cursor,
        onHover: (h) {
          final cur = _cursorFor(_edgesAt(h.localPosition, window, s));
          if (cur != _cursor) setState(() => _cursor = cur);
        },
        onExit: (_) => setState(() => _cursor = SystemMouseCursors.move),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            width: s.width,
            height: s.height,
            child: Stack(fit: StackFit.expand, children: [
              RotatedBox(
                quarterTurns: b.quarterTurns,
                child: Image(image: documentImages(c.doc)(b.asset), fit: BoxFit.fill, filterQuality: FilterQuality.medium),
              ),
              CustomPaint(painter: _WindowPainter(window)),
            ]),
          ),
        ),
      ),
    );
  }

  void _end() {
    if (_base == null) return;
    _base = null;
    _edges = null;
    _startWindow = null;
    _startPos = null;
    widget.controller.endPreview();
  }
}

class _WindowPainter extends CustomPainter {
  _WindowPainter(this.w);
  final CropWindow w;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Rect.fromLTWH(w.x * size.width, w.y * size.height, w.w * size.width, w.h * size.height);
    final shade = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRect(r);
    canvas.drawPath(shade, Paint()..color = const Color(0x8C0A0F19));
    canvas.drawRect(
      r.deflate(1),
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    // Griffe: Mitte jeder Seite und Ecken (dort lässt sich zuschneiden)
    final fill = Paint()..color = Colors.white;
    final edge = Paint()
      ..color = const Color(0x990A0F19)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    void grip(Rect g) {
      final rr = RRect.fromRectAndRadius(g, const Radius.circular(2));
      canvas.drawRRect(rr, fill);
      canvas.drawRRect(rr, edge);
    }

    final i = r.deflate(2);
    grip(Rect.fromCenter(center: Offset(i.left + 1.5, i.center.dy), width: 5, height: 18));
    grip(Rect.fromCenter(center: Offset(i.right - 1.5, i.center.dy), width: 5, height: 18));
    grip(Rect.fromCenter(center: Offset(i.center.dx, i.top + 1.5), width: 18, height: 5));
    grip(Rect.fromCenter(center: Offset(i.center.dx, i.bottom - 1.5), width: 18, height: 5));
    for (final c in [i.topLeft, i.topRight, i.bottomLeft, i.bottomRight]) {
      grip(Rect.fromCenter(center: c + Offset(c.dx == i.left ? 2.5 : -2.5, c.dy == i.top ? 2.5 : -2.5), width: 7, height: 7));
    }
  }

  @override
  bool shouldRepaint(_WindowPainter old) => old.w.x != w.x || old.w.y != w.y || old.w.w != w.w || old.w.h != w.h;
}
