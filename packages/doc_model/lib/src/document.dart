import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'assets.dart';
import 'elements.dart';
import 'geometry.dart';

/// Aktuelle Version des Dateiformats. Jede Formatänderung erhöht sie und bringt eine Migration mit.
const int formatVersion = 1;

@immutable
class DocPage {
  DocPage({required this.id, List<DocElement> elements = const []}) : elements = List.unmodifiable(elements);
  final String id;

  /// Stapelreihenfolge: das letzte Element liegt vorne.
  final List<DocElement> elements;

  DocElement? find(String id) {
    for (final e in elements) {
      if (e.id == id) return e;
    }
    return null;
  }

  int indexOf(String id) => elements.indexWhere((e) => e.id == id);

  DocPage withElements(List<DocElement> elements) => DocPage(id: id, elements: elements);

  factory DocPage.fromJson(Map<String, dynamic> j) => DocPage(
        id: j['id'] as String,
        elements: [for (final e in j['elements'] as List) DocElement.fromJson(e as Map<String, dynamic>)],
      );

  Map<String, dynamic> toJson() => {'id': id, 'elements': [for (final e in elements) e.toJson()]};
}

/// Das Dokument. Unveränderlich: Jede Operation liefert ein neues Dokument; unveränderte Seiten
/// und Elemente werden geteilt. Das macht Rückgängig/Wiederholen einfach und günstig.
@immutable
class TextlyDocument {
  TextlyDocument({
    required List<DocPage> pages,
    Map<String, ImageAsset> assets = const {},
    this.orientation = PageOrientation.portrait,
    this.paper = PaperSize.a4,
  })
      : pages = List.unmodifiable(pages),
        assets = Map.unmodifiable(assets) {
    if (pages.isEmpty) throw ArgumentError('Ein Dokument hat mindestens eine Seite');
  }

  final List<DocPage> pages;

  /// Hoch- oder Querformat; gilt für alle Seiten (wie die Foliengrösse in PowerPoint).
  final PageOrientation orientation;

  /// Papiergrösse; gilt für alle Seiten.
  final PaperSize paper;

  /// Seitenbreite und -höhe in mm.
  double get pageWidth => orientation == PageOrientation.portrait ? paper.shortMm : paper.longMm;
  double get pageHeight => orientation == PageOrientation.portrait ? paper.longMm : paper.shortMm;

  /// Ausrichtung ändern; die Elemente bleiben, wo sie sind.
  TextlyDocument withOrientation(PageOrientation o) => TextlyDocument(pages: pages, assets: assets, orientation: o, paper: paper);

  /// Papiergrösse ändern. Mit [scale] wird alles im gleichen Verhältnis mitvergrössert bzw. -verkleinert
  /// (Lage, Grösse, Schrift, Linien), sodass die Seite gleich aussieht – nur grösser oder kleiner.
  TextlyDocument withPaper(PaperSize p, {bool scale = true}) {
    if (p == paper) return this;
    final f = p.shortMm / paper.shortMm;
    return TextlyDocument(
      pages: [
        for (final pg in pages) scale ? DocPage(id: pg.id, elements: [for (final e in pg.elements) scaledElement(e, f)]) : pg,
      ],
      assets: assets,
      orientation: orientation,
      paper: p,
    );
  }

  /// Bilddateien des Dokuments, nach ID. Werden beim Löschen eines Bildes nicht entfernt,
  /// damit Rückgängig funktioniert; unbenutzte Dateien entfallen beim Speichern ([withoutUnusedAssets]).
  final Map<String, ImageAsset> assets;

  DocPage page(int index) => pages[index];

  TextlyDocument _withPages(List<DocPage> pages) => TextlyDocument(pages: pages, assets: assets, orientation: orientation, paper: paper);
  TextlyDocument _withPage(int index, DocPage page) => _withPages([...pages]..[index] = page);

  /// Fügt eine Bilddatei hinzu (oder ersetzt sie bei gleicher ID).
  TextlyDocument addAsset(ImageAsset asset) => TextlyDocument(pages: pages, assets: {...assets, asset.id: asset}, orientation: orientation, paper: paper);

  /// IDs der Bilddateien, auf die ein Bildblock verweist.
  Set<String> get usedAssetIds => {
        for (final p in pages)
          for (final e in p.elements)
            if (e is ImageBlock) e.asset,
      };

  TextlyDocument withoutUnusedAssets() {
    final used = usedAssetIds;
    return TextlyDocument(
      pages: pages,
      assets: {for (final a in assets.values) if (used.contains(a.id)) a.id: a},
      orientation: orientation,
      paper: paper,
    );
  }

  /// Ersetzt ein Element (gleiche ID) auf der Seite.
  TextlyDocument replaceElement(int pageIndex, DocElement element) {
    final p = pages[pageIndex];
    final i = p.indexOf(element.id);
    if (i < 0) throw ArgumentError('Element ${element.id} nicht auf Seite $pageIndex');
    return _withPage(pageIndex, p.withElements([...p.elements]..[i] = element));
  }

  /// Fügt ein Element zuoberst ein.
  TextlyDocument addElement(int pageIndex, DocElement element) {
    final p = pages[pageIndex];
    return _withPage(pageIndex, p.withElements([...p.elements, element]));
  }

  TextlyDocument removeElement(int pageIndex, String id) {
    final p = pages[pageIndex];
    return _withPage(pageIndex, p.withElements(p.elements.where((e) => e.id != id).toList()));
  }

  TextlyDocument bringToFront(int pageIndex, String id) {
    final p = pages[pageIndex];
    final e = p.find(id);
    if (e == null) return this;
    return _withPage(pageIndex, p.withElements([...p.elements.where((x) => x.id != id), e]));
  }

  TextlyDocument sendToBack(int pageIndex, String id) {
    final p = pages[pageIndex];
    final e = p.find(id);
    if (e == null) return this;
    return _withPage(pageIndex, p.withElements([e, ...p.elements.where((x) => x.id != id)]));
  }

  TextlyDocument insertPage(int index, DocPage page) => _withPages([...pages]..insert(index, page));

  TextlyDocument removePage(int index) {
    if (pages.length == 1) return this;
    return _withPages([...pages]..removeAt(index));
  }

  TextlyDocument movePage(int from, int to) {
    final list = [...pages];
    final p = list.removeAt(from);
    list.insert(to, p);
    return _withPages(list);
  }

  /// [assetBytes]: Inhalt der Bilddateien nach ID (im .appdoc-Paket als eigene Dateien gespeichert).
  factory TextlyDocument.fromJson(Map<String, dynamic> j, {Map<String, Uint8List> assetBytes = const {}}) {
    if (j['format'] != 'appdoc') throw const FormatException('Kein Textly-Dokument');
    final v = j['version'] as int;
    if (v > formatVersion) {
      throw FormatException('Das Dokument stammt aus einer neueren Textly-Version (Format $v).');
    }
    // Migrationen älterer Formate kommen hier hinzu.
    final assets = <String, ImageAsset>{};
    for (final a in (j['assets'] as List?) ?? const []) {
      final m = a as Map<String, dynamic>;
      final bytes = assetBytes[m['id']];
      if (bytes == null) throw FormatException('Bilddatei ${m['id']} fehlt im Dokument');
      assets[m['id'] as String] = ImageAsset.fromJson(m, bytes);
    }
    return TextlyDocument(
      pages: [for (final p in j['pages'] as List) DocPage.fromJson(p as Map<String, dynamic>)],
      assets: assets,
      // ältere Dateien ohne Angabe: Hochformat
      orientation: PageOrientation.values.asNameMap()[j['orientation']] ?? PageOrientation.portrait,
      // ältere Dateien ohne Angabe: A4
      paper: PaperSize.values.asNameMap()[j['paper']] ?? PaperSize.a4,
    );
  }

  Map<String, dynamic> toJson() =>
      {
        'format': 'appdoc',
        'version': formatVersion,
        if (orientation != PageOrientation.portrait) 'orientation': orientation.name,
        if (paper != PaperSize.a4) 'paper': paper.name,
        'pages': [for (final p in pages) p.toJson()],
        'assets': [for (final a in assets.values) a.toJson()],
      };
}

/// Element im Verhältnis [f] vergrössern bzw. verkleinern (Lage ab der linken oberen Seitenecke).
DocElement scaledElement(DocElement e, double f) {
  Box box(Box b) => Box(b.x * f, b.y * f, b.w * f, b.h * f);
  return switch (e) {
    TextBlock t => t.copyWith(box: box(t.box), size: t.size * f),
    ImageBlock i => i.copyWith(box: box(i.box)),
    RectShape r => r.copyWith(box: box(r.box), strokeWidth: r.strokeWidth * f),
    LineShape l => l.copyWith(a: Pt(l.a.x * f, l.a.y * f), b: Pt(l.b.x * f, l.b.y * f), width: l.width * f),
    TableBlock t => t.copyWith(
        x: t.x * f,
        y: t.y * f,
        columns: [for (final c in t.columns) c * f],
        size: t.size * f,
        heightHint: t.heightHint * f,
      ),
  };
}
