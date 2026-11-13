// Dokumentmodell des Machbarkeitstests.
// Masse in Millimetern, Schriftgrössen in Punkt (wie in der Spezifikation).
// Für den Test bewusst einfach und veränderbar; der MVP nutzt unveränderliche Klassen.

const double kMmToPt = 72 / 25.4;
const double kPageWidthMm = 210;
const double kPageHeightMm = 297;
const double kPageWidthPt = kPageWidthMm * kMmToPt;
const double kPageHeightPt = kPageHeightMm * kMmToPt;
const int kFormatVersion = 1;

enum TextKind { title, subtitle, heading, body, caption }

enum TextAlignment { left, center, right }

enum ImageFit { cover, contain }

sealed class DocElement {
  DocElement(this.id, {this.locked = false});
  final String id;
  bool locked;

  Map<String, dynamic> toJson();

  static DocElement fromJson(Map<String, dynamic> j) => switch (j['type']) {
        'text' => TextElement.fromJson(j),
        'image' => ImageElement.fromJson(j),
        'rect' => RectElement.fromJson(j),
        'line' => LineElement.fromJson(j),
        _ => throw FormatException('Unbekannter Elementtyp: ${j['type']}'),
      };
}

class TextElement extends DocElement {
  TextElement({
    required String id,
    required this.x,
    required this.y,
    required this.w,
    required this.kind,
    required this.size,
    required this.color,
    required this.text,
    this.h = 10,
    this.autoHeight = true,
    this.bold = false,
    this.italic = false,
    this.align = TextAlignment.left,
    super.locked,
  }) : super(id);

  double x, y, w, h;
  bool autoHeight;
  TextKind kind;
  double size;
  int color;
  bool bold, italic;
  TextAlignment align;
  String text;

  factory TextElement.fromJson(Map<String, dynamic> j) => TextElement(
        id: j['id'],
        x: (j['x'] as num).toDouble(),
        y: (j['y'] as num).toDouble(),
        w: (j['w'] as num).toDouble(),
        h: (j['h'] as num).toDouble(),
        autoHeight: j['autoH'] as bool,
        kind: TextKind.values.byName(j['kind']),
        size: (j['size'] as num).toDouble(),
        color: j['color'] as int,
        bold: j['bold'] as bool,
        italic: j['italic'] as bool,
        align: TextAlignment.values.byName(j['align']),
        text: j['text'] as String,
        locked: j['locked'] as bool? ?? false,
      );

  @override
  Map<String, dynamic> toJson() => {
        'type': 'text', 'id': id, 'locked': locked,
        'x': x, 'y': y, 'w': w, 'h': h, 'autoH': autoHeight,
        'kind': kind.name, 'size': size, 'color': color,
        'bold': bold, 'italic': italic, 'align': align.name, 'text': text,
      };
}

class ImageElement extends DocElement {
  ImageElement({
    required String id,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.asset,
    required this.nw,
    required this.nh,
    this.fit = ImageFit.cover,
    this.px = .5,
    this.py = .5,
    this.zoom = 1,
    super.locked,
  }) : super(id);

  double x, y, w, h;
  String asset;
  int nw, nh;
  ImageFit fit;

  /// Lage des Ausschnitts (0 = links/oben, 1 = rechts/unten) und Vergrösserung (1 = Rahmen gerade gefüllt).
  double px, py, zoom;

  factory ImageElement.fromJson(Map<String, dynamic> j) => ImageElement(
        id: j['id'],
        x: (j['x'] as num).toDouble(),
        y: (j['y'] as num).toDouble(),
        w: (j['w'] as num).toDouble(),
        h: (j['h'] as num).toDouble(),
        asset: j['asset'] as String,
        nw: j['nw'] as int,
        nh: j['nh'] as int,
        fit: ImageFit.values.byName(j['fit']),
        px: (j['px'] as num).toDouble(),
        py: (j['py'] as num).toDouble(),
        zoom: (j['zoom'] as num).toDouble(),
        locked: j['locked'] as bool? ?? false,
      );

  @override
  Map<String, dynamic> toJson() => {
        'type': 'image', 'id': id, 'locked': locked,
        'x': x, 'y': y, 'w': w, 'h': h, 'asset': asset, 'nw': nw, 'nh': nh,
        'fit': fit.name, 'px': px, 'py': py, 'zoom': zoom,
      };
}

class RectElement extends DocElement {
  RectElement({
    required String id,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.fill,
    this.stroke = 0xFF2F5BD3,
    this.strokeWidth = 0,
    this.round = true,
    super.locked,
  }) : super(id);

  double x, y, w, h;
  int fill, stroke;
  double strokeWidth;
  bool round;

  factory RectElement.fromJson(Map<String, dynamic> j) => RectElement(
        id: j['id'],
        x: (j['x'] as num).toDouble(),
        y: (j['y'] as num).toDouble(),
        w: (j['w'] as num).toDouble(),
        h: (j['h'] as num).toDouble(),
        fill: j['fill'] as int,
        stroke: j['stroke'] as int,
        strokeWidth: (j['sw'] as num).toDouble(),
        round: j['round'] as bool,
        locked: j['locked'] as bool? ?? false,
      );

  @override
  Map<String, dynamic> toJson() => {
        'type': 'rect', 'id': id, 'locked': locked,
        'x': x, 'y': y, 'w': w, 'h': h,
        'fill': fill, 'stroke': stroke, 'sw': strokeWidth, 'round': round,
      };
}

class LineElement extends DocElement {
  LineElement({
    required String id,
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
    this.color = 0xFF2F5BD3,
    this.width = .6,
    super.locked,
  }) : super(id);

  double x1, y1, x2, y2;
  int color;
  double width;

  factory LineElement.fromJson(Map<String, dynamic> j) => LineElement(
        id: j['id'],
        x1: (j['x1'] as num).toDouble(),
        y1: (j['y1'] as num).toDouble(),
        x2: (j['x2'] as num).toDouble(),
        y2: (j['y2'] as num).toDouble(),
        color: j['color'] as int,
        width: (j['sw'] as num).toDouble(),
        locked: j['locked'] as bool? ?? false,
      );

  @override
  Map<String, dynamic> toJson() => {
        'type': 'line', 'id': id, 'locked': locked,
        'x1': x1, 'y1': y1, 'x2': x2, 'y2': y2, 'color': color, 'sw': width,
      };
}

class DocPage {
  DocPage(this.id, this.elements);
  final String id;
  final List<DocElement> elements;

  factory DocPage.fromJson(Map<String, dynamic> j) => DocPage(
        j['id'] as String,
        [for (final e in j['elements'] as List) DocElement.fromJson(e as Map<String, dynamic>)],
      );

  Map<String, dynamic> toJson() => {'id': id, 'elements': [for (final e in elements) e.toJson()]};
}

class TextlyDocument {
  TextlyDocument(this.pages);
  final List<DocPage> pages;

  factory TextlyDocument.fromJson(Map<String, dynamic> j) {
    if (j['format'] != 'appdoc') throw const FormatException('Kein Textly-Dokument');
    final v = j['version'] as int;
    if (v > kFormatVersion) throw FormatException('Formatversion $v ist neuer als diese App');
    return TextlyDocument([for (final p in j['pages'] as List) DocPage.fromJson(p as Map<String, dynamic>)]);
  }

  Map<String, dynamic> toJson() =>
      {'format': 'appdoc', 'version': kFormatVersion, 'pages': [for (final p in pages) p.toJson()]};
}
