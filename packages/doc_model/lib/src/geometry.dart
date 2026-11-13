import 'dart:math' as math;

import 'package:meta/meta.dart';

/// Umrechnung Millimeter → Punkt (1 pt = 1/72 Zoll).
const double mmToPt = 72 / 25.4;

/// A4 Hochformat in Millimetern (im Querformat vertauscht, siehe TextlyDocument.pageWidth).
const double pageWidthMm = 210;
const double pageHeightMm = 297;

/// Ausrichtung der Seiten eines Dokuments.
enum PageOrientation { portrait, landscape }

/// Papiergrösse (ISO 216). Masse im Hochformat, in Millimetern.
enum PaperSize {
  a5(148, 210, 'A5'),
  a4(210, 297, 'A4'),
  a3(297, 420, 'A3');

  const PaperSize(this.shortMm, this.longMm, this.label);
  final double shortMm, longMm;
  final String label;
}

/// Ein Punkt auf der Seite in Millimetern.
@immutable
class Pt {
  const Pt(this.x, this.y);
  final double x, y;

  Pt operator +(Pt o) => Pt(x + o.x, y + o.y);
  Pt operator -(Pt o) => Pt(x - o.x, y - o.y);

  Map<String, dynamic> toJson() => {'x': x, 'y': y};
  factory Pt.fromJson(Map<String, dynamic> j) => Pt((j['x'] as num).toDouble(), (j['y'] as num).toDouble());

  @override
  bool operator ==(Object other) => other is Pt && other.x == x && other.y == y;
  @override
  int get hashCode => Object.hash(x, y);
  @override
  String toString() => 'Pt($x, $y)';
}

/// Ein achsenparalleles Rechteck auf der Seite in Millimetern.
@immutable
class Box {
  const Box(this.x, this.y, this.w, this.h);
  factory Box.fromPoints(Pt a, Pt b) =>
      Box(math.min(a.x, b.x), math.min(a.y, b.y), (a.x - b.x).abs(), (a.y - b.y).abs());

  final double x, y, w, h;

  double get right => x + w;
  double get bottom => y + h;
  double get centerX => x + w / 2;
  double get centerY => y + h / 2;

  Box translate(double dx, double dy) => Box(x + dx, y + dy, w, h);
  Box copyWith({double? x, double? y, double? w, double? h}) => Box(x ?? this.x, y ?? this.y, w ?? this.w, h ?? this.h);

  /// Überlappen sich die Flächen (mit kleiner Toleranz, damit Berühren nicht zählt)?
  bool overlaps(Box o, {double tolerance = .5}) =>
      x + tolerance < o.right && o.x + tolerance < right && y + tolerance < o.bottom && o.y + tolerance < bottom;

  Map<String, dynamic> toJson() => {'x': x, 'y': y, 'w': w, 'h': h};
  factory Box.fromJson(Map<String, dynamic> j) => Box(
        (j['x'] as num).toDouble(),
        (j['y'] as num).toDouble(),
        (j['w'] as num).toDouble(),
        (j['h'] as num).toDouble(),
      );

  @override
  bool operator ==(Object other) => other is Box && other.x == x && other.y == y && other.w == w && other.h == h;
  @override
  int get hashCode => Object.hash(x, y, w, h);
  @override
  String toString() => 'Box($x, $y, $w × $h)';
}

/// Griffe am Auswahlrahmen.
enum Handle {
  nw, n, ne, e, se, s, sw, w;

  bool get isCorner => this == nw || this == ne || this == se || this == sw;
  bool get movesLeft => this == nw || this == w || this == sw;
  bool get movesRight => this == ne || this == e || this == se;
  bool get movesTop => this == nw || this == n || this == ne;
  bool get movesBottom => this == sw || this == s || this == se;
}

/// Kleinste Kantenlänge eines Elements in mm.
const double minElementSize = 3;

/// Ändert ein Rechteck über einen Griff um ([dx], [dy]) mm, ausgehend von [start].
///
/// Mit [keepAspect] (Eckgriffe bei Bildern) bleibt das Seitenverhältnis erhalten; die gegenüberliegende
/// Ecke bleibt fest. Massgebend ist die Richtung, in welche die Maus weiter gezogen wurde.
Box resizeBox(Box start, Handle handle, double dx, double dy, {bool keepAspect = false, double minSize = minElementSize}) {
  if (keepAspect && handle.isCorner && start.h > 0) {
    final ratio = start.w / start.h;
    final sx = handle.movesRight ? 1.0 : -1.0;
    final sy = handle.movesBottom ? 1.0 : -1.0;
    final byX = start.w + sx * dx;
    final byY = (start.h + sy * dy) * ratio;
    var w = (byX - start.w).abs() >= (byY - start.w).abs() ? byX : byY;
    final minW = ratio >= 1 ? minSize * ratio : minSize;
    w = math.max(w, minW);
    final h = w / ratio;
    return Box(
      handle.movesRight ? start.x : start.right - w,
      handle.movesBottom ? start.y : start.bottom - h,
      w,
      h,
    );
  }
  var left = start.x, right = start.right, top = start.y, bottom = start.bottom;
  if (handle.movesLeft) left = math.min(start.x + dx, right - minSize);
  if (handle.movesRight) right = math.max(start.right + dx, left + minSize);
  if (handle.movesTop) top = math.min(start.y + dy, bottom - minSize);
  if (handle.movesBottom) bottom = math.max(start.bottom + dy, top + minSize);
  return Box(left, top, right - left, bottom - top);
}
