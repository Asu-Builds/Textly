import 'package:meta/meta.dart';

import 'fonts.dart';
import 'geometry.dart';
import 'inline_style.dart';

part 'table.dart';

enum TextKind { title, subtitle, heading, body, caption }

enum TextAlignment { left, center, right }

enum ImageFit { cover, contain }

/// Vorgaben einer Textart (Spezifikation 4.1). Schrift und Zeilenhöhe legt die Darstellung fest.
@immutable
class TextKindPreset {
  const TextKindPreset(this.label, this.size, this.bold, this.italic, this.color);
  final String label;
  final double size;
  final bool bold, italic;
  final int color;
}

const Map<TextKind, TextKindPreset> textKindPresets = {
  TextKind.title: TextKindPreset('Titel', 26, true, false, 0xFF1D2733),
  TextKind.subtitle: TextKindPreset('Untertitel', 13, false, false, 0xFF5B6773),
  TextKind.heading: TextKindPreset('Zwischentitel', 13, true, false, 0xFF1D2733),
  TextKind.body: TextKindPreset('Fliesstext', 10.5, false, false, 0xFF1D2733),
  TextKind.caption: TextKindPreset('Bildunterschrift', 8.5, false, true, 0xFF5B6773),
};

/// Ein Element auf einer Seite. Alle Klassen sind unveränderlich; Änderungen erzeugen neue Objekte.
/// Masse in Millimetern, Schriftgrössen in Punkt.
@immutable
sealed class DocElement {
  const DocElement(this.id, this.locked);
  final String id;
  final bool locked;

  /// Gespeicherte Umrisse. Bei Textblöcken mit automatischer Höhe ist die Höhe ein Richtwert;
  /// die Darstellung misst die tatsächliche Höhe.
  Box get box;

  DocElement translated(double dx, double dy);
  DocElement withLocked(bool locked);
  DocElement withId(String id);
  Map<String, dynamic> toJson();

  static DocElement fromJson(Map<String, dynamic> j) => switch (j['type']) {
        'text' => TextBlock.fromJson(j),
        'image' => ImageBlock.fromJson(j),
        'rect' => RectShape.fromJson(j),
        'line' => LineShape.fromJson(j),
        'table' => TableBlock.fromJson(j),
        final t => throw FormatException('Unbekannter Elementtyp: $t'),
      };
}

class TextBlock extends DocElement {
  const TextBlock({
    required String id,
    required this.box,
    required this.text,
    this.kind = TextKind.body,
    this.size = 10.5,
    this.color = 0xFF1D2733,
    this.bold = false,
    this.italic = false,
    this.align = TextAlignment.left,
    this.runs = const [],
    this.font,
    bool locked = false,
  }) : super(id, locked);

  /// Neuer Textblock mit den Vorgaben der Textart.
  factory TextBlock.ofKind({required String id, required Box box, required String text, TextKind kind = TextKind.body}) {
    final p = textKindPresets[kind]!;
    return TextBlock(id: id, box: box, text: text, kind: kind, size: p.size, color: p.color, bold: p.bold, italic: p.italic);
  }

  @override
  final Box box;
  final String text;
  final TextKind kind;
  final double size;
  final int color;
  final bool bold, italic;
  final TextAlignment align;

  /// Formatierte Textstellen (Abweichungen vom Blockstil), sortiert und ohne Überschneidung.
  final List<StyleRun> runs;

  /// Gewählte Schriftart; `null` = Vorgabe der Textart.
  final TextFont? font;

  /// Schrift, mit der der Block tatsächlich gesetzt wird.
  TextFont get effectiveFont => font ?? defaultFontForKind(kind);

  /// Tatsächliche Formatierung eines Zeichens (Blockstil plus Abweichung).
  ({bool bold, bool italic, bool underline, int color}) effectiveAt(int index) {
    final s = styleAt(runs, index);
    return (bold: s.bold ?? bold, italic: s.italic ?? italic, underline: s.underline ?? false, color: s.color ?? color);
  }

  TextBlock copyWith({
    Box? box,
    String? text,
    TextKind? kind,
    double? size,
    int? color,
    bool? bold,
    bool? italic,
    TextAlignment? align,
    List<StyleRun>? runs,
    bool? locked,
    String? id,
  }) =>
      TextBlock(
        id: id ?? this.id,
        box: box ?? this.box,
        text: text ?? this.text,
        kind: kind ?? this.kind,
        size: size ?? this.size,
        color: color ?? this.color,
        bold: bold ?? this.bold,
        italic: italic ?? this.italic,
        align: align ?? this.align,
        runs: runs ?? this.runs,
        font: font,
        locked: locked ?? this.locked,
      );

  /// Schriftart setzen; `null` stellt die Vorgabe der Textart wieder her.
  TextBlock withFont(TextFont? f) => TextBlock(
        id: id, box: box, text: text, kind: kind, size: size, color: color, bold: bold, italic: italic,
        align: align, runs: runs, font: f, locked: locked,
      );

  /// Textart wechseln: übernimmt Grösse, Farbe und Stil der Vorgabe.
  TextBlock withKind(TextKind k) {
    final p = textKindPresets[k]!;
    return copyWith(kind: k, size: p.size, color: p.color, bold: p.bold, italic: p.italic);
  }

  @override
  TextBlock translated(double dx, double dy) => copyWith(box: box.translate(dx, dy));
  @override
  TextBlock withLocked(bool locked) => copyWith(locked: locked);
  @override
  TextBlock withId(String id) => copyWith(id: id);

  factory TextBlock.fromJson(Map<String, dynamic> j) => TextBlock(
        id: j['id'] as String,
        box: Box.fromJson(j['box'] as Map<String, dynamic>),
        text: j['text'] as String,
        kind: TextKind.values.byName(j['kind'] as String),
        size: (j['size'] as num).toDouble(),
        color: j['color'] as int,
        bold: j['bold'] as bool,
        italic: j['italic'] as bool,
        align: TextAlignment.values.byName(j['align'] as String),
        // 'autoHeight' früherer Versionen wird übergangen: Die Höhe folgt immer dem Text.
        runs: [for (final r in (j['runs'] as List?) ?? const []) StyleRun.fromJson(r as Map<String, dynamic>)],
        // unbekannte Schrift (neuere Textly-Version) → Vorgabe der Textart
        font: TextFont.values.asNameMap()[j['font']],
        locked: j['locked'] as bool? ?? false,
      );

  @override
  Map<String, dynamic> toJson() => {
        'type': 'text', 'id': id, 'locked': locked, 'box': box.toJson(), 'text': text, 'kind': kind.name,
        'size': size, 'color': color, 'bold': bold, 'italic': italic, 'align': align.name,
        if (runs.isNotEmpty) 'runs': [for (final r in runs) r.toJson()],
        if (font != null) 'font': font!.name,
      };
}

class ImageBlock extends DocElement {
  const ImageBlock({
    required String id,
    required this.box,
    required this.asset,
    required this.naturalWidth,
    required this.naturalHeight,
    this.fit = ImageFit.cover,
    this.cropX = .5,
    this.cropY = .5,
    this.zoom = 1,
    this.quarterTurns = 0,
    bool locked = false,
  }) : super(id, locked);

  @override
  final Box box;

  /// Verweis auf die Bilddatei (im Dokumentpaket bzw. vorerst ein App-Asset).
  final String asset;
  /// Grösse des Bildes in Bildpunkten, so wie es gezeigt wird – bei [quarterTurns] 1 oder 3 also
  /// Breite und Höhe der Bilddatei vertauscht. Ausschnitt und Rahmen rechnen nur damit.
  final int naturalWidth, naturalHeight;
  final ImageFit fit;

  /// Drehung der Bilddatei in Vierteldrehungen im Uhrzeigersinn (0…3).
  final int quarterTurns;

  /// Lage des Ausschnitts (0 = links/oben, 1 = rechts/unten) und Vergrösserung (1 = Rahmen gerade gefüllt).
  final double cropX, cropY, zoom;

  double get naturalAspect => naturalWidth / naturalHeight;

  ImageBlock copyWith({
    Box? box,
    String? asset,
    int? naturalWidth,
    int? naturalHeight,
    ImageFit? fit,
    double? cropX,
    double? cropY,
    double? zoom,
    int? quarterTurns,
    bool? locked,
    String? id,
  }) =>
      ImageBlock(
        id: id ?? this.id,
        box: box ?? this.box,
        asset: asset ?? this.asset,
        naturalWidth: naturalWidth ?? this.naturalWidth,
        naturalHeight: naturalHeight ?? this.naturalHeight,
        fit: fit ?? this.fit,
        cropX: cropX ?? this.cropX,
        cropY: cropY ?? this.cropY,
        zoom: zoom ?? this.zoom,
        quarterTurns: quarterTurns ?? this.quarterTurns,
        locked: locked ?? this.locked,
      );

  @override
  ImageBlock translated(double dx, double dy) => copyWith(box: box.translate(dx, dy));
  @override
  ImageBlock withLocked(bool locked) => copyWith(locked: locked);
  @override
  ImageBlock withId(String id) => copyWith(id: id);

  factory ImageBlock.fromJson(Map<String, dynamic> j) {
    if ((j['naturalWidth'] as int) <= 0 || (j['naturalHeight'] as int) <= 0) {
      throw const FormatException('Ein Bild hat eine ungültige Grösse.');
    }
    return ImageBlock._fromJson(j);
  }

  factory ImageBlock._fromJson(Map<String, dynamic> j) => ImageBlock(
        id: j['id'] as String,
        box: Box.fromJson(j['box'] as Map<String, dynamic>),
        asset: j['asset'] as String,
        naturalWidth: j['naturalWidth'] as int,
        naturalHeight: j['naturalHeight'] as int,
        fit: ImageFit.values.byName(j['fit'] as String),
        cropX: (j['cropX'] as num).toDouble(),
        cropY: (j['cropY'] as num).toDouble(),
        zoom: (j['zoom'] as num).toDouble(),
        quarterTurns: ((j['rotation'] as int? ?? 0) ~/ 90) % 4,
        locked: j['locked'] as bool? ?? false,
      );

  @override
  Map<String, dynamic> toJson() => {
        'type': 'image', 'id': id, 'locked': locked, 'box': box.toJson(), 'asset': asset,
        'naturalWidth': naturalWidth, 'naturalHeight': naturalHeight, 'fit': fit.name,
        'cropX': cropX, 'cropY': cropY, 'zoom': zoom, 'rotation': quarterTurns * 90,
      };
}

class RectShape extends DocElement {
  const RectShape({
    required String id,
    required this.box,
    this.fill = 0xFFE8EEF7,
    this.stroke = 0xFF2F5BD3,
    this.strokeWidth = 0,
    this.round = true,
    bool locked = false,
  }) : super(id, locked);

  @override
  final Box box;
  final int fill, stroke;
  final double strokeWidth;
  final bool round;

  RectShape copyWith({Box? box, int? fill, int? stroke, double? strokeWidth, bool? round, bool? locked, String? id}) => RectShape(
        id: id ?? this.id,
        box: box ?? this.box,
        fill: fill ?? this.fill,
        stroke: stroke ?? this.stroke,
        strokeWidth: strokeWidth ?? this.strokeWidth,
        round: round ?? this.round,
        locked: locked ?? this.locked,
      );

  @override
  RectShape translated(double dx, double dy) => copyWith(box: box.translate(dx, dy));
  @override
  RectShape withLocked(bool locked) => copyWith(locked: locked);
  @override
  RectShape withId(String id) => copyWith(id: id);

  factory RectShape.fromJson(Map<String, dynamic> j) => RectShape(
        id: j['id'] as String,
        box: Box.fromJson(j['box'] as Map<String, dynamic>),
        fill: j['fill'] as int,
        stroke: j['stroke'] as int,
        strokeWidth: (j['strokeWidth'] as num).toDouble(),
        round: j['round'] as bool,
        locked: j['locked'] as bool? ?? false,
      );

  @override
  Map<String, dynamic> toJson() => {
        'type': 'rect', 'id': id, 'locked': locked, 'box': box.toJson(),
        'fill': fill, 'stroke': stroke, 'strokeWidth': strokeWidth, 'round': round,
      };
}

class LineShape extends DocElement {
  const LineShape({
    required String id,
    required this.a,
    required this.b,
    this.color = 0xFF2F5BD3,
    this.width = .6,
    bool locked = false,
  }) : super(id, locked);

  final Pt a, b;
  final int color;
  final double width;

  @override
  Box get box => Box.fromPoints(a, b);

  LineShape copyWith({Pt? a, Pt? b, int? color, double? width, bool? locked, String? id}) => LineShape(
        id: id ?? this.id,
        a: a ?? this.a,
        b: b ?? this.b,
        color: color ?? this.color,
        width: width ?? this.width,
        locked: locked ?? this.locked,
      );

  @override
  LineShape translated(double dx, double dy) => copyWith(a: Pt(a.x + dx, a.y + dy), b: Pt(b.x + dx, b.y + dy));
  @override
  LineShape withLocked(bool locked) => copyWith(locked: locked);
  @override
  LineShape withId(String id) => copyWith(id: id);

  factory LineShape.fromJson(Map<String, dynamic> j) => LineShape(
        id: j['id'] as String,
        a: Pt.fromJson(j['a'] as Map<String, dynamic>),
        b: Pt.fromJson(j['b'] as Map<String, dynamic>),
        color: j['color'] as int,
        width: (j['width'] as num).toDouble(),
        locked: j['locked'] as bool? ?? false,
      );

  @override
  Map<String, dynamic> toJson() =>
      {'type': 'line', 'id': id, 'locked': locked, 'a': a.toJson(), 'b': b.toJson(), 'color': color, 'width': width};
}
