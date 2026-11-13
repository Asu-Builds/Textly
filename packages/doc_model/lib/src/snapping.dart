import 'package:meta/meta.dart';

import 'geometry.dart';

/// Seitenrand, an dem ausgerichtet wird (Spezifikation 3: 15 mm).
const double pageMarginMm = 15;

enum SnapAxis { vertical, horizontal }

/// Eine Ausrichtungslinie: senkrecht bei x = [position] oder waagrecht bei y = [position] (mm).
@immutable
class Guide {
  const Guide(this.axis, this.position);
  final SnapAxis axis;
  final double position;

  @override
  bool operator ==(Object other) => other is Guide && other.axis == axis && other.position == position;
  @override
  int get hashCode => Object.hash(axis, position);
  @override
  String toString() => 'Guide(${axis.name}, $position)';
}

/// Ziele zum Ausrichten: Papierrand, Seitenrand, Seitenmitte sowie Kanten und Mitten anderer Elemente.
class SnapTargets {
  SnapTargets(this.xs, this.ys);

  factory SnapTargets.forPage(Iterable<Box> others, {double width = pageWidthMm, double height = pageHeightMm}) {
    final xs = <double>[0, pageMarginMm, width / 2, width - pageMarginMm, width];
    final ys = <double>[0, pageMarginMm, height / 2, height - pageMarginMm, height];
    for (final b in others) {
      xs.addAll([b.x, b.centerX, b.right]);
      ys.addAll([b.y, b.centerY, b.bottom]);
    }
    return SnapTargets(xs, ys);
  }

  final List<double> xs, ys;
}

/// Einstellungen fürs Einrasten. [threshold] in mm (aus dem Zoom: gleiche Bildschirmdistanz).
@immutable
class SnapSettings {
  const SnapSettings({required this.threshold, this.grid});
  final double threshold;

  /// Rasterabstand in mm; null = nicht am Raster einrasten.
  final double? grid;
}

class SnapResult {
  SnapResult(this.value, this.guide);
  final double value;
  final Guide? guide;
}

/// Rastet einen einzelnen Wert ein (z. B. die gezogene Kante beim Ändern der Grösse).
/// Ausrichtung an Zielen hat Vorrang vor dem Raster.
SnapResult snapValue(double v, SnapAxis axis, SnapTargets targets, SnapSettings s) {
  final list = axis == SnapAxis.vertical ? targets.xs : targets.ys;
  double? best;
  for (final t in list) {
    if ((t - v).abs() <= s.threshold && (best == null || (t - v).abs() < (best - v).abs())) best = t;
  }
  if (best != null) return SnapResult(best, Guide(axis, best));
  final g = s.grid;
  if (g != null && g > 0) return SnapResult((v / g).round() * g, null);
  return SnapResult(v, null);
}

/// Rastet ein verschobenes Rechteck ein. Geprüft werden linke Kante, Mitte und rechte Kante
/// (bzw. oben, Mitte, unten); die nächstgelegene Übereinstimmung gewinnt.
/// Ohne Übereinstimmung rastet die linke bzw. obere Kante am Raster ein.
({Box box, List<Guide> guides}) snapMove(Box box, SnapTargets targets, SnapSettings s) {
  final guides = <Guide>[];
  double axisShift(List<double> edges, List<double> ts, SnapAxis axis) {
    double? bestD, bestT;
    for (final e in edges) {
      for (final t in ts) {
        final d = t - e;
        if (d.abs() <= s.threshold && (bestD == null || d.abs() < bestD.abs())) {
          bestD = d;
          bestT = t;
        }
      }
    }
    if (bestD != null) {
      guides.add(Guide(axis, bestT!));
      return bestD;
    }
    final g = s.grid;
    if (g != null && g > 0) return (edges.first / g).round() * g - edges.first;
    return 0;
  }

  final dx = axisShift([box.x, box.centerX, box.right], targets.xs, SnapAxis.vertical);
  final dy = axisShift([box.y, box.centerY, box.bottom], targets.ys, SnapAxis.horizontal);
  return (box: box.translate(dx, dy), guides: guides);
}

/// Welche Rechtecke werden von [box] überdeckt? (Berühren zählt nicht.)
List<int> overlappingIndices(Box box, List<Box> others) => [
      for (var i = 0; i < others.length; i++)
        if (box.overlaps(others[i])) i,
    ];
