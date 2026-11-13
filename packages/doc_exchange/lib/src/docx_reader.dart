import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:doc_model/doc_model.dart';
import 'package:image/image.dart' as img;
import 'package:xml/xml.dart';

import 'pptx_common.dart';

/// Ergebnis des Word-Imports: das Dokument und kurze Hinweise, was vereinfacht wurde.
class DocxImport {
  DocxImport(this.document, this.notes);
  final TextlyDocument document;
  final List<String> notes;
}

class DocxImportException implements Exception {
  const DocxImportException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Liest eine Word-Datei (.docx) und setzt ihren Text auf A4-Seiten.
///
/// Word ist Fliesstext, Textly hat feste Seiten mit Blöcken: Die Absätze werden der Reihe nach als
/// Textblöcke zwischen die Ränder gestellt; ist eine Seite voll, beginnt die nächste. [heightMm] misst einen
/// Textblock oder eine Tabelle (in der App mit demselben Satz wie im Editor).
///
/// Übernommen werden Titel, Untertitel, Überschriften, Fliesstext und Beschriftungen, fett, kursiv,
/// unterstrichen und Farbe einzelner Textstellen, Ausrichtung, Schriftart (nächstliegende), Listen (als
/// «•»/«1.» vor dem Text), Bilder (JPEG, PNG), Tabellen (Spaltenbreiten, Kopfzeile, Linien), Seitenumbrüche
/// und Hoch-/Querformat.
///
/// [prepareImage] bereitet Bilder auf wie beim gewöhnlichen Einfügen (Drehung aus den Kameradaten
/// übernehmen, sehr grosse Fotos verkleinern); null für nicht lesbare Bilder. Ohne: Datei unverändert.
DocxImport importDocx(Uint8List bytes, {required double Function(DocElement) heightMm, ImageAsset? Function(Uint8List bytes)? prepareImage}) {
  // Alte Word-Dateien (.doc) und verschlüsselte Dateien sind OLE-Container, keine ZIP-Archive
  if (bytes.length > 8 && bytes[0] == 0xD0 && bytes[1] == 0xCF && bytes[2] == 0x11 && bytes[3] == 0xE0) {
    throw const DocxImportException(
      'Das ist eine ältere Word-Datei (.doc) oder eine geschützte Datei. Bitte in Word mit «Speichern unter» als .docx speichern.',
    );
  }
  final Archive zip;
  try {
    zip = ZipDecoder().decodeBytes(bytes);
  } catch (_) {
    throw const DocxImportException('Die Datei ist keine gültige Word-Datei (.docx).');
  }
  final files = LazyZip(zip);
  if (!files.containsKey('word/document.xml')) {
    throw const DocxImportException('Die Datei ist keine gültige Word-Datei (.docx).');
  }
  try {
    final r = _Reader(files, prepareImage)..read();
    return DocxImport(_layout(r.paras, r.assets, r.orientation, r.paper, heightMm, r.notes, header: r.header, footer: r.footer), r.notes);
  } on DocxImportException {
    rethrow;
  } on ZipTooLargeException {
    throw const DocxImportException('Die Word-Datei ist zu gross oder beschädigt (ein Teil wäre entpackt über 64 MB).');
  } catch (_) {
    throw const DocxImportException('Die Word-Datei ist beschädigt oder enthält etwas, das Textly nicht lesen kann.');
  }
}

// ---------------------------------------------------------------- XML-Hilfen

XmlElement? _child(XmlElement? e, String local) {
  if (e == null) return null;
  for (final c in e.childElements) {
    if (c.name.local == local) return c;
  }
  return null;
}

Iterable<XmlElement> _children(XmlElement? e, String local) => e == null ? const [] : e.childElements.where((c) => c.name.local == local);

String? _attr(XmlElement? e, String local) {
  if (e == null) return null;
  for (final a in e.attributes) {
    if (a.name.local == local) return a.value;
  }
  return null;
}

String? _val(XmlElement? e) => _attr(e, 'val');

/// Beziehungs-Verweis (r:id), nicht das gewöhnliche Attribut «id».
String? _relId(XmlElement? e) {
  if (e == null) return null;
  for (final a in e.attributes) {
    if (a.name.local == 'id' && (a.name.prefix == 'r' || a.name.namespaceUri?.contains('relationships') == true)) return a.value;
  }
  return null;
}

/// Platzhalter für Seitenzahl und Seitenanzahl in Kopf-/Fusszeilen (Zeichen aus dem privaten Bereich).
const _pageToken = '\u{E000}', _pagesToken = '\u{E001}';

/// Ein-/Aus-Eigenschaft wie `<w:b/>` oder `<w:b w:val="0"/>`; null = nicht angegeben.
bool? _onOff(XmlElement? e) {
  if (e == null) return null;
  final v = _val(e);
  return v == null || !(v == '0' || v == 'false' || v == 'off' || v == 'none');
}

bool _containsLocal(XmlElement e, String local) => e.descendantElements.any((d) => d.name.local == local);

// ---------------------------------------------------------------- Formate

/// Zeichenformat aus w:rPr (alles optional).
class _RunFmt {
  const _RunFmt({this.bold, this.italic, this.underline, this.color, this.size, this.font});
  final bool? bold, italic, underline;
  final int? color;
  final double? size;
  final String? font;

  static const none = _RunFmt();

  _RunFmt over(_RunFmt o) => _RunFmt(
    bold: o.bold ?? bold,
    italic: o.italic ?? italic,
    underline: o.underline ?? underline,
    color: o.color ?? color,
    size: o.size ?? size,
    font: o.font ?? font,
  );

  factory _RunFmt.of(XmlElement? rPr) {
    if (rPr == null) return none;
    final u = _child(rPr, 'u');
    final c = _val(_child(rPr, 'color'));
    final sz = double.tryParse(_val(_child(rPr, 'sz')) ?? '');
    final fonts = _child(rPr, 'rFonts');
    return _RunFmt(
      bold: _onOff(_child(rPr, 'b')),
      italic: _onOff(_child(rPr, 'i')),
      underline: u == null ? null : _val(u) != 'none',
      color: c == null || c == 'auto' || c.length != 6 ? null : int.tryParse('FF$c', radix: 16),
      size: sz == null ? null : sz / 2,
      font: _attr(fonts, 'ascii') ?? _attr(fonts, 'hAnsi'),
    );
  }
}

class _Style {
  _Style(this.id, this.name, this.basedOn, this.pPr, this.rPr, this.type, this.tblPr);
  final String id;
  final String name;
  final String? basedOn;
  final XmlElement? pPr, rPr, tblPr;
  final String type;
}

/// Ein Bild im Textfluss.
class _Img {
  _Img(this.asset, this.w, this.h, this.align, {this.crop = (l: 0, t: 0, r: 0, b: 0)});

  /// In Word abgeschnittene Ränder (Anteile des Bildes).
  final ({double l, double t, double r, double b}) crop;

  /// Bildblock in [box]; ein Zuschnitt aus Word wird zum Ausschnitt (Rahmen füllen, vergrössert, verschoben).
  ImageBlock block(Box box) {
    final vw = 1 - crop.l - crop.r, vh = 1 - crop.t - crop.b;
    final cropped = vw < .999 || vh < .999;
    return ImageBlock(
      id: newId(),
      box: box,
      asset: asset.id,
      naturalWidth: asset.width,
      naturalHeight: asset.height,
      zoom: cropped ? (1 / math.max(vw, vh)).clamp(minCropZoom, maxCropZoom).toDouble() : 1,
      cropX: crop.l + crop.r > 0 ? crop.l / (crop.l + crop.r) : .5,
      cropY: crop.t + crop.b > 0 ? crop.t / (crop.t + crop.b) : .5,
    );
  }
  final ImageAsset asset;
  final double w, h;
  final TextAlignment align;
  bool pageBreakBefore = false;
}

/// Eine Tabelle im Textfluss (Spaltenbreiten noch in Word-Grösse; das Setzen passt sie an).
class _Tbl {
  _Tbl(this.table, this.align);
  final TableBlock table;
  final TextAlignment align;
  bool pageBreakBefore = false;
}

/// Ein Absatz, wie er gesetzt wird.
class _Para {
  _Para(this.kind);
  TextKind kind;
  TextAlignment align = TextAlignment.left;
  final text = StringBuffer();

  /// Formatierung pro Textstück (absolut; wird später gegen den Blockstil vereinfacht).
  final pieces = <(int, int, _RunFmt)>[];
  bool pageBreakBefore = false;

  /// Beginnt einen eigenen Block (z. B. die Fussnoten am Ende).
  bool startsBlock = false;
  bool get isEmpty => text.toString().trim().isEmpty;

  void add(String s, _RunFmt f) {
    if (s.isEmpty) return;
    final start = text.length;
    text.write(s);
    pieces.add((start, text.length, f));
  }

  /// Häufigster Wert über die Zeichen (Schriftgrösse, Schriftart).
  T? dominant<T>(T? Function(_RunFmt) of) {
    final count = <T, int>{};
    for (final (s, e, f) in pieces) {
      final v = of(f);
      if (v != null && text.toString().substring(s, e).trim().isNotEmpty) count[v] = (count[v] ?? 0) + e - s;
    }
    if (count.isEmpty) return null;
    return (count.entries.toList()..sort((a, b) => b.value - a.value)).first.key;
  }
}

/// Word-Schrift → nächstliegende Textly-Schrift (null: Vorgabe der Textart).
TextFont? _mapFont(String? name) {
  if (name == null) return null;
  final exact = fontByName(name);
  if (exact != null) return exact;
  final n = name.toLowerCase();
  const serif = ['times', 'cambria', 'georgia', 'garamond', 'book antiqua', 'palatino', 'constantia', 'baskerville', 'minion', 'century'];
  const script = ['comic', 'script', 'brush', 'segoe print', 'lucida handwriting', 'kristen'];
  if (n.contains('playfair') || n.contains('bodoni') || n.contains('didot')) return TextFont.playfair;
  if (serif.any(n.contains)) return TextFont.lora;
  if (script.any(n.contains)) return TextFont.caveat;
  if (n.contains('condensed') || n.contains('narrow') || n.contains('bahnschrift')) return TextFont.robotoCondensed;
  if (n.contains('montserrat') || n.contains('century gothic') || n.contains('futura')) return TextFont.montserrat;
  return null;
}

// ---------------------------------------------------------------- Lesen

class _Reader {
  _Reader(this.files, this.prepareImage);
  final LazyZip files;
  final ImageAsset? Function(Uint8List bytes)? prepareImage;
  final notes = <String>[];
  /// Der Inhalt der Reihe nach: [_Para], [_Img] oder [_Tbl].
  var paras = <Object>[];
  final assets = <String, ImageAsset>{};
  final _assetByPath = <String, String>{};

  /// Beziehungen des Teils, der gerade gelesen wird (Dokument, Kopf- oder Fusszeile).
  Map<String, String> _rels = const {};

  // Felder (Seitenzahlen), Fussnoten
  StringBuffer? _fieldInstr;
  bool _fieldSkip = false, _inHeaderFooter = false;
  Map<String, XmlElement> _footnoteParts = const {}, _endnoteParts = const {};
  final _noteOrder = <(int, XmlElement)>[];
  String? _notePrefix;
  bool _noteStartsBlock = false;
  PageOrientation orientation = PageOrientation.portrait;
  PaperSize paper = PaperSize.a4;

  final _styles = <String, _Style>{};
  String? _defaultParaStyle;
  _RunFmt _docDefaults = _RunFmt.none;

  // Listen: numId → abstractNumId, abstractNumId → Ebene → (Format, Text, Start)
  final _numAbstract = <String, String>{};
  final _levels = <String, Map<int, ({String fmt, String text, int start})>>{};
  final _counters = <String, List<int?>>{};

  int _images = 0, _textBoxes = 0, _justified = 0, _mixedSizes = 0, _mergedCells = 0;
  bool _pageBreakPending = false;

  XmlDocument? _xml(String path) {
    final b = files[path];
    return b == null ? null : XmlDocument.parse(utf8.decode(b, allowMalformed: true));
  }

  void read() {
    _readStyles();
    _readNumbering();
    _rels = _readRels('word/document.xml');
    _footnoteParts = _readNotes('word/footnotes.xml', 'footnote');
    _endnoteParts = _readNotes('word/endnotes.xml', 'endnote');
    final doc = _xml('word/document.xml')!;
    final body = _child(doc.rootElement, 'body');
    _block(body);
    final sect = _child(body, 'sectPr');
    _readPage(sect);
    _readHeadersFooters(sect);
    // Fuss- und Endnoten am Ende, nummeriert wie im Text
    if (_noteOrder.isNotEmpty) {
      _inNotes = true;
      for (var i = 0; i < _noteOrder.length; i++) {
        final (n, note) = _noteOrder[i];
        _notePrefix = '[$n] ';
        _noteStartsBlock = n == _noteOrder.first.$1;
        final first = paras.length;
        _block(note);
        // Notiz ohne Absatz (leer): Nummer trotzdem zeigen
        if (paras.length == first) paras.add(_Para(TextKind.body)..add('[$n]', _docDefaults));
      }
      _inNotes = false;
      notes.add(_noteOrder.length == 1 ? 'Die Fussnote steht am Ende des Dokuments.' : 'Die Fussnoten stehen am Ende des Dokuments.');
    }
    if (_images > 0) notes.add(_images == 1 ? '1 Bild wurde nicht übernommen.' : '$_images Bilder wurden nicht übernommen.');
    if (_mergedCells > 0) notes.add('Verbundene Tabellenzellen wurden getrennt.');
    if (_textBoxes > 0) notes.add(_textBoxes == 1 ? 'Ein Textfeld wurde als gewöhnlicher Text eingefügt.' : '$_textBoxes Textfelder wurden als gewöhnlicher Text eingefügt.');
    if (_justified > 0) notes.add('Blocksatz wird linksbündig gesetzt.');
    if (_mixedSizes > 0) notes.add('Verschiedene Schriftgrössen innerhalb eines Absatzes wurden angeglichen.');
    if (files.containsKey('word/comments.xml')) notes.add('Kommentare wurden weggelassen.');
  }

  // ---------- Kopf- und Fusszeilen

  /// Inhalt von Kopf- und Fusszeile (je für alle Seiten und, falls in Word so eingestellt, für die erste).
  ({List<Object> all, List<Object>? first})? header, footer;

  void _readHeadersFooters(XmlElement? sect) {
    final titlePage = _onOff(_child(sect, 'titlePg')) == true;
    ({List<Object> all, List<Object>? first})? read(String local) {
      List<Object>? part(String type) {
        final ref = _children(sect, local).where((r) => (_attr(r, 'type') ?? 'default') == type).firstOrNull;
        final path = ref == null ? null : _rels[_relId(ref) ?? ''];
        final xml = path == null ? null : _xml(path);
        if (xml == null) return null;
        // Inhalt in eine eigene Liste lesen (Bilder über die Beziehungen dieses Teils)
        final saved = paras, savedRels = _rels;
        paras = <Object>[];
        _rels = _readRels(path!);
        _inHeaderFooter = true;
        try {
          _block(xml.rootElement);
          return paras.where((x) => x is! _Para || !x.isEmpty).toList();
        } finally {
          paras = saved;
          _rels = savedRels;
          _inHeaderFooter = false;
        }
      }

      final all = part('default') ?? const <Object>[];
      final first = titlePage ? (part('first') ?? const <Object>[]) : null;
      if (all.isEmpty && (first == null || first.isEmpty)) return null;
      return (all: all, first: first);
    }

    header = read('headerReference');
    footer = read('footerReference');
  }

  /// Seitenzahl-Felder in Kopf-/Fusszeilen als Platzhalter (pro Seite ersetzt).
  String? _fieldToken(String? instr) {
    if (!_inHeaderFooter || instr == null) return null;
    final w = instr.trim().split(RegExp(r'\s+')).firstOrNull?.toUpperCase();
    return switch (w) {
      'PAGE' => _pageToken,
      'NUMPAGES' || 'SECTIONPAGES' => _pagesToken,
      _ => null,
    };
  }

  // ---------- Fuss- und Endnoten

  Map<String, XmlElement> _readNotes(String path, String local) {
    final doc = _xml(path);
    if (doc == null) return const {};
    return {
      for (final n in _children(doc.rootElement, local))
        if (_attr(n, 'id') != null && (_attr(n, 'type') ?? 'normal') == 'normal') _attr(n, 'id')!: n,
    };
  }

  /// Nummer einer Fuss-/Endnote im Text (fortlaufend); ihr Inhalt kommt ans Ende.
  /// Werden gerade die Fussnoten am Ende gelesen? Dann zählen Verweise darin nicht (keine Endlosschleife).
  bool _inNotes = false;

  int? _noteRef(Map<String, XmlElement> parts, String? id) {
    if (_inNotes) return null;
    final note = id == null ? null : parts[id];
    if (note == null) return null;
    final n = _noteOrder.length + 1;
    _noteOrder.add((n, note));
    return n;
  }

  void _readPage(XmlElement? sect) {
    final pg = _child(sect, 'pgSz');
    final w = int.tryParse(_attr(pg, 'w') ?? '');
    final h = int.tryParse(_attr(pg, 'h') ?? '');
    final landscape = _attr(pg, 'orient') == 'landscape' || (w != null && h != null && w > h);
    if (landscape) orientation = PageOrientation.landscape;
    if (w != null && h != null) {
      // Twips → mm; A5, A4 und A3 werden erkannt, alles andere (z. B. US Letter) wird A4
      final shortMm = (w < h ? w : h) / 1440 * 25.4, longMm = (w < h ? h : w) / 1440 * 25.4;
      final match = PaperSize.values.where((p) => (p.shortMm - shortMm).abs() <= 5 && (p.longMm - longMm).abs() <= 5).firstOrNull;
      paper = match ?? PaperSize.a4;
      final note = 'Das Seitenformat (${shortMm.round()} × ${longMm.round()} mm) wurde auf A4 umgestellt.';
      if (match == null && !notes.contains(note)) notes.add(note);
    }
  }

  // ---------- Formatvorlagen

  void _readStyles() {
    final doc = _xml('word/styles.xml');
    if (doc == null) return;
    final root = doc.rootElement;
    _docDefaults = _RunFmt.of(_child(_child(_child(root, 'docDefaults'), 'rPrDefault'), 'rPr'));
    for (final s in _children(root, 'style')) {
      final id = _attr(s, 'styleId');
      if (id == null) continue;
      final type = _attr(s, 'type') ?? 'paragraph';
      _styles[id] = _Style(id, (_val(_child(s, 'name')) ?? id).toLowerCase(), _val(_child(s, 'basedOn')), _child(s, 'pPr'), _child(s, 'rPr'), type, _child(s, 'tblPr'));
      final d = _attr(s, 'default');
      if (type == 'paragraph' && (d == '1' || d == 'true')) _defaultParaStyle = id;
    }
  }

  /// Formatvorlage samt ihren Vorlagen (basedOn), die nächste zuerst.
  Iterable<_Style> _chain(String? id) sync* {
    final seen = <String>{};
    var cur = id == null ? null : _styles[id];
    while (cur != null && seen.add(cur.id)) {
      yield cur;
      cur = cur.basedOn == null ? null : _styles[cur.basedOn!];
    }
  }

  /// Zeichenformat einer Vorlage (geerbt von ihren Vorlagen).
  _RunFmt _styleRun(String? id) {
    var f = _RunFmt.none;
    for (final s in _chain(id).toList().reversed) {
      f = f.over(_RunFmt.of(s.rPr));
    }
    return f;
  }

  /// Textart aus der Absatzvorlage (über Namen der eingebauten Vorlagen, auch bei deutschem Word).
  TextKind _kindOf(String? styleId, XmlElement? pPr) {
    for (final s in _chain(styleId)) {
      final n = s.name;
      if (n == 'title' || n == 'titel') return TextKind.title;
      if (n == 'subtitle' || n == 'untertitel') return TextKind.subtitle;
      if (n == 'caption' || n == 'beschriftung') return TextKind.caption;
      if (RegExp(r'^(heading|überschrift) ?\d$').hasMatch(n)) return TextKind.heading;
      final lvl = _val(_child(s.pPr, 'outlineLvl'));
      if (lvl != null && lvl != '9') return TextKind.heading;
    }
    final lvl = _val(_child(pPr, 'outlineLvl'));
    if (lvl != null && lvl != '9') return TextKind.heading;
    return TextKind.body;
  }

  /// Absatz-Eigenschaft aus dem Absatz selbst oder seiner Vorlage.
  XmlElement? _pProp(XmlElement? pPr, String? styleId, String local) {
    final own = _child(pPr, local);
    if (own != null) return own;
    for (final s in _chain(styleId)) {
      final v = _child(s.pPr, local);
      if (v != null) return v;
    }
    return null;
  }

  // ---------- Listen

  void _readNumbering() {
    final doc = _xml('word/numbering.xml');
    if (doc == null) return;
    for (final a in _children(doc.rootElement, 'abstractNum')) {
      final id = _attr(a, 'abstractNumId');
      if (id == null) continue;
      _levels[id] = {
        for (final l in _children(a, 'lvl'))
          int.tryParse(_attr(l, 'ilvl') ?? '0') ?? 0: (
            fmt: _val(_child(l, 'numFmt')) ?? 'bullet',
            text: _val(_child(l, 'lvlText')) ?? '',
            start: (int.tryParse(_val(_child(l, 'start')) ?? '1') ?? 1).clamp(0, 32767),
          ),
      };
    }
    for (final n in _children(doc.rootElement, 'num')) {
      final id = _attr(n, 'numId');
      final abs = _val(_child(n, 'abstractNumId'));
      if (id != null && abs != null) _numAbstract[id] = abs;
    }
  }

  static String _roman(int n) {
    if (n <= 0 || n > 3999) return '$n'; // römisch nur 1…3999
    const v = [1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1];
    const s = ['m', 'cm', 'd', 'cd', 'c', 'xc', 'l', 'xl', 'x', 'ix', 'v', 'iv', 'i'];
    final b = StringBuffer();
    for (var i = 0; i < v.length; i++) {
      while (n >= v[i]) {
        b.write(s[i]);
        n -= v[i];
      }
    }
    return b.toString();
  }

  static String _letter(int n) {
    if (n <= 0) return '$n';
    var s = '';
    while (n > 0) {
      n--;
      s = String.fromCharCode(97 + n % 26) + s;
      n ~/= 26;
    }
    return s;
  }

  /// «• », «1. », «a) » … vor einem Listenabsatz; eingerückt nach Ebene.
  String? _listLabel(String numId, int ilvl) {
    if (numId == '0') return null;
    final levels = _levels[_numAbstract[numId]];
    final lvl = levels?[ilvl];
    final indent = '    ' * ilvl;
    if (lvl == null || lvl.fmt == 'bullet' || lvl.fmt == 'none') {
      if (lvl?.fmt == 'none') return indent;
      return '$indent${ilvl.isOdd ? '–' : '•'} ';
    }
    final c = _counters.putIfAbsent(numId, () => List<int?>.filled(9, null));
    c[ilvl] = c[ilvl] == null ? lvl.start : c[ilvl]! + 1;
    for (var i = ilvl + 1; i < 9; i++) {
      c[i] = null;
    }
    String fmt(int level) {
      final l = levels![level];
      final n = c[level] ?? l?.start ?? 1;
      return switch (l?.fmt) {
        'lowerLetter' => _letter(n),
        'upperLetter' => _letter(n).toUpperCase(),
        'lowerRoman' => _roman(n),
        'upperRoman' => _roman(n).toUpperCase(),
        _ => '$n',
      };
    }

    final label = lvl.text.replaceAllMapped(RegExp(r'%(\d)'), (m) => fmt((int.parse(m[1]!) - 1).clamp(0, 8)));
    return '$indent$label ';
  }

  // ---------- Inhalt

  void _block(XmlElement? container) {
    if (container == null) return;
    for (final e in container.childElements) {
      switch (e.name.local) {
        case 'p':
          _paragraph(e);
        case 'tbl':
          _table(e);
        case 'sdt':
          _block(_child(e, 'sdtContent'));
        case 'customXml' || 'ins' || 'smartTag':
          _block(e);
      }
    }
  }

  // ---------- Bilder

  /// Beziehungen eines Teils (z. B. word/header1.xml → word/_rels/header1.xml.rels).
  Map<String, String> _readRels(String part) {
    final slash = part.lastIndexOf('/');
    final doc = _xml('${part.substring(0, slash + 1)}_rels/${part.substring(slash + 1)}.rels');
    if (doc == null) return const {};
    return {
      for (final r in _children(doc.rootElement, 'Relationship'))
        if (_attr(r, 'TargetMode') != 'External' && _attr(r, 'Id') != null && _attr(r, 'Target') != null) _attr(r, 'Id')!: _resolve(_attr(r, 'Target')!),
    };
  }

  /// Ziel einer Beziehung relativ zu word/ (z. B. «media/image1.png» → «word/media/image1.png»).
  static String _resolve(String target) {
    if (target.startsWith('/')) return target.substring(1);
    final parts = <String>['word'];
    for (final p in target.split('/')) {
      if (p == '..') {
        if (parts.isNotEmpty) parts.removeLast();
      } else if (p.isNotEmpty && p != '.') {
        parts.add(p);
      }
    }
    return parts.join('/');
  }

  ImageAsset? _asset(String path, Uint8List bytes) {
    final known = _assetByPath[path];
    if (known != null) return assets[known];
    final ImageAsset a;
    final prepare = prepareImage;
    if (prepare != null) {
      ImageAsset? p;
      try {
        p = prepare(bytes);
      } catch (_) {
        p = null;
      }
      if (p == null) return null;
      a = p;
    } else {
      final decoder = img.findDecoderForData(bytes);
      if (decoder == null || (decoder is! img.JpegDecoder && decoder is! img.PngDecoder)) return null;
      final info = decoder.startDecode(bytes);
      if (info == null) return null;
      a = ImageAsset(id: newId('img'), bytes: bytes, mimeType: decoder is img.JpegDecoder ? 'image/jpeg' : 'image/png', width: info.width, height: info.height);
    }
    assets[a.id] = a;
    _assetByPath[path] = a.id;
    return a;
  }

  /// Bild aus w:drawing (DrawingML) oder w:pict (VML); Grösse wie in Word.
  _Img? _picture(XmlElement e, TextAlignment align) {
    XmlElement? first(String local) => e.descendantElements.where((d) => d.name.local == local).firstOrNull;
    final rid = _attr(first('blip'), 'embed') ?? _attr(first('imagedata'), 'id');
    final path = rid == null ? null : _rels[rid];
    final bytes = path == null ? null : files[path];
    if (bytes == null) return null;
    final asset = _asset(path!, bytes);
    if (asset == null) return null;
    // In Word zugeschnitten (a:srcRect: abgeschnittene Ränder in Tausendstelprozent)
    final src = first('srcRect');
    double cut(String k) => ((int.tryParse(_attr(src, k) ?? '') ?? 0) / 100000).clamp(0.0, .95);
    final crop = (l: cut('l'), t: cut('t'), r: cut('r'), b: cut('b'));
    final ext = first('extent');
    final cx = int.tryParse(_attr(ext, 'cx') ?? ''), cy = int.tryParse(_attr(ext, 'cy') ?? '');
    if (cx != null && cy != null && cx > 0 && cy > 0) return _Img(asset, cx / 36000, cy / 36000, align, crop: crop);
    // VML: style="width:120pt;height:80pt"
    final style = _attr(first('shape'), 'style') ?? '';
    double? pt(String k) => double.tryParse(RegExp('$k:([0-9.]+)pt').firstMatch(style)?.group(1) ?? '');
    final w = pt('width'), h = pt('height');
    if (w != null && h != null && w > 0 && h > 0) return _Img(asset, w / mmToPt, h / mmToPt, align);
    return _Img(asset, asset.width * 25.4 / 96, asset.height * 25.4 / 96, align);
  }

  // ---------- Tabellen

  /// Text, Formatierung und Ausrichtung einer Zelle (verschachtelte Tabellen als Text).
  ({String text, List<(String, _RunFmt)> runs, TextAlignment align, int? fill}) _cell(XmlElement tc) {
    final lines = <String>[];
    final runs = <(String, _RunFmt)>[];
    TextAlignment? align;
    for (final p in tc.descendantElements.where((d) => d.name.local == 'p' && !d.ancestorElements.any((a) => a.name.local == 'Fallback'))) {
      final pPr = _child(p, 'pPr');
      final styleId = _val(_child(pPr, 'pStyle')) ?? _defaultParaStyle;
      final base = _docDefaults.over(_styleRun(styleId));
      final jc = _val(_pProp(pPr, styleId, 'jc'));
      final b = StringBuffer();
      void walk(XmlElement e) {
        for (final c in e.childElements) {
          switch (c.name.local) {
            case 'r':
              final rPr = _child(c, 'rPr');
              final f = base.over(_styleRun(_val(_child(rPr, 'rStyle')))).over(_RunFmt.of(rPr));
              for (final x in c.childElements) {
                switch (x.name.local) {
                  case 't':
                    b.write(x.innerText);
                    runs.add((x.innerText, f));
                  case 'tab' || 'br' || 'cr':
                    b.write(' ');
                  case 'drawing' || 'pict':
                    _images++;
                }
              }
            case 'del' || 'moveFrom' || 'pPr' || 'rPr' || 'tbl':
              break;
            default:
              walk(c);
          }
        }
      }

      walk(p);
      if (b.isNotEmpty || lines.isNotEmpty) lines.add(b.toString());
      if (align == null && b.toString().trim().isNotEmpty) {
        align = switch (jc) {
          'center' => TextAlignment.center,
          'right' || 'end' => TextAlignment.right,
          _ => TextAlignment.left,
        };
      }
    }
    while (lines.isNotEmpty && lines.last.trim().isEmpty) {
      lines.removeLast();
    }
    final shd = _attr(_child(_child(tc, 'tcPr'), 'shd'), 'fill');
    final fill = shd == null || shd == 'auto' || shd.length != 6 || shd.toUpperCase() == 'FFFFFF' ? null : int.tryParse('FF$shd', radix: 16);
    return (text: lines.join('\n'), runs: runs, align: align ?? TextAlignment.left, fill: fill);
  }

  /// Linien der Tabelle aus w:tblBorders (direkt oder aus der Tabellenvorlage).
  ({TableLines lines, int? color, bool strong}) _borders(XmlElement? tblPr, String? styleId) {
    var b = _child(tblPr, 'tblBorders');
    if (b == null) {
      for (final s in _chain(styleId)) {
        b = _child(s.tblPr, 'tblBorders');
        if (b != null) break;
      }
    }
    if (b == null) return (lines: TableLines.none, color: null, strong: false);
    XmlElement? side(String a, [String? alt]) => _child(b, a) ?? (alt == null ? null : _child(b, alt));
    bool on(XmlElement? e) {
      final v = _val(e);
      return e != null && v != null && v != 'none' && v != 'nil';
    }

    final outer = on(side('top')) && on(side('bottom')) && on(side('left', 'start')) && on(side('right', 'end'));
    final inH = on(side('insideH')), inV = on(side('insideV'));
    final lines = inH && inV
        ? TableLines.all
        : inH
        ? TableLines.horizontal
        : outer
        ? TableLines.outer
        : TableLines.none;
    final present = [side('insideH'), side('top'), side('insideV'), side('left', 'start'), side('bottom')].where(on).toList();
    final any = present.where((e) => (_attr(e, 'color') ?? 'auto') != 'auto').firstOrNull ?? present.firstOrNull;
    final c = _attr(any, 'color');
    final sz = int.tryParse(_attr(any, 'sz') ?? '') ?? 4;
    return (lines: lines, color: c == null || c == 'auto' || c.length != 6 ? null : int.tryParse('FF$c', radix: 16), strong: sz >= 8);
  }

  void _table(XmlElement tbl) {
    final tblPr = _child(tbl, 'tblPr');
    final styleId = _val(_child(tblPr, 'tblStyle'));
    final grid = [for (final g in _children(_child(tbl, 'tblGrid'), 'gridCol')) (int.tryParse(_attr(g, 'w') ?? '') ?? 0) / 1440 * 25.4];
    final rows = <List<String>>[];
    final colAlign = <int, Map<TextAlignment, int>>{}, firstRowAlign = <int, Map<TextAlignment, int>>{};
    final runs = <(String, _RunFmt)>[];
    var headerFlag = false, firstRowBold = true;
    int? headerFill;
    var cols = grid.length;
    var r = 0;
    for (final tr in _children(tbl, 'tr')) {
      if (r == 0) headerFlag = _onOff(_child(_child(tr, 'trPr'), 'tblHeader')) == true;
      final row = <String>[];
      for (final tc in _children(tr, 'tc')) {
        final tcPr = _child(tc, 'tcPr');
        final span = (int.tryParse(_val(_child(tcPr, 'gridSpan')) ?? '1') ?? 1).clamp(1, 63);
        final vm = _child(tcPr, 'vMerge');
        final cont = vm != null && _val(vm) != 'restart';
        if (span > 1 || cont) _mergedCells++;
        final cell = _cell(tc);
        final col = row.length;
        row.add(cont ? '' : cell.text);
        for (var k = 1; k < span; k++) {
          row.add('');
        }
        // Ausrichtung der Spalte: zählen nur gewöhnliche Zellen unterhalb der ersten Zeile (sonst die erste Zeile)
        if (cell.text.trim().isNotEmpty && span == 1) {
          final m = (r == 0 ? firstRowAlign : colAlign).putIfAbsent(col, () => {});
          m[cell.align] = (m[cell.align] ?? 0) + 1;
        }
        runs.addAll(cell.runs);
        if (r == 0) {
          headerFill ??= cell.fill;
          if (cell.runs.any((x) => x.$1.trim().isNotEmpty && x.$2.bold != true)) firstRowBold = false;
        }
      }
      if (row.length > cols) cols = row.length;
      rows.add(row);
      r++;
    }
    if (rows.isEmpty || cols == 0) return;
    final hasHeaderText = rows.first.any((c) => c.trim().isNotEmpty);
    final header = rows.length > 1 && hasHeaderText && (headerFlag || headerFill != null || firstRowBold);
    // Grösse und Schrift: die häufigsten in der Tabelle
    final sizes = <double, int>{}, fonts = <String, int>{};
    for (final (t, f) in runs) {
      if (f.size != null) sizes[f.size!] = (sizes[f.size!] ?? 0) + t.length;
      if (f.font != null) fonts[f.font!] = (fonts[f.font!] ?? 0) + t.length;
    }
    K? top<K>(Map<K, int> m) => m.isEmpty ? null : (m.entries.toList()..sort((a, b) => b.value - a.value)).first.key;
    // Spaltenbreiten aus Word; fehlen sie, gleich breit (0 = «noch verteilen», siehe Setzen)
    final known = grid.length == cols && grid.every((w) => w > 0);
    final b = _borders(tblPr, styleId);
    var t = TableBlock(
      id: newId('t'),
      x: 0,
      y: 0,
      columns: known ? grid : List.filled(cols, 0.0),
      cells: rows,
      headerRow: header,
      size: (top(sizes) ?? 10.5).clamp(7.0, 30.0).toDouble(),
      align: [
        for (var c = 0; c < cols; c++)
          ((colAlign[c] ?? firstRowAlign[c])?.entries.toList()?..sort((a, b) => b.value - a.value))?.first.key ?? TextAlignment.left,
      ],
    ).withStyle(headerFill != null ? TableStyle.header : TableStyle.grid);
    if (headerFill != null) t = t.copyWith(headerColor: headerFill);
    t = t.copyWith(lines: b.lines, lineColor: b.color ?? t.lineColor, lineWidth: b.strong ? tableLineStrong : tableLineFine);
    final font = _mapFont(top(fonts));
    if (font != null) t = t.withFont(font);
    paras.add(_Tbl(t, _tableAlign(tblPr, styleId))..pageBreakBefore = _takeBreak());
  }

  TextAlignment _tableAlign(XmlElement? tblPr, String? styleId) {
    var jc = _val(_child(tblPr, 'jc'));
    if (jc == null) {
      for (final s in _chain(styleId)) {
        jc = _val(_child(s.tblPr, 'jc'));
        if (jc != null) break;
      }
    }
    return switch (jc) {
      'center' => TextAlignment.center,
      'right' || 'end' => TextAlignment.right,
      _ => TextAlignment.left,
    };
  }

  bool _takeBreak() {
    final b = _pageBreakPending;
    _pageBreakPending = false;
    return b;
  }

  void _paragraph(XmlElement p) {
    final pPr = _child(p, 'pPr');
    final styleId = _val(_child(pPr, 'pStyle')) ?? _defaultParaStyle;
    final kind = _kindOf(styleId, pPr);
    var para = _Para(kind)..pageBreakBefore = _takeBreak() || _onOff(_pProp(pPr, styleId, 'pageBreakBefore')) == true;
    final jc = _val(_pProp(pPr, styleId, 'jc'));
    para.align = switch (jc) {
      'center' => TextAlignment.center,
      'right' || 'end' => TextAlignment.right,
      _ => TextAlignment.left,
    };
    if (jc == 'both' || jc == 'distribute') _justified++;

    // Grundformat: Dokumentvorgabe, Absatzvorlage (nur Fliesstext; Überschriften nehmen die Textly-Vorlage)
    var base = _docDefaults.over(_styleRun(styleId));
    // Titel und Überschriften: Aussehen der Textly-Vorlage (keine Vorlagenfarben aus Word); direkte Formatierung bleibt
    if (kind != TextKind.body) base = _RunFmt(size: base.size, font: base.font);

    // Liste
    final numPr = _pProp(pPr, styleId, 'numPr');
    if (numPr != null) {
      final numId = _val(_child(numPr, 'numId'));
      final ilvl = int.tryParse(_val(_child(numPr, 'ilvl')) ?? '0') ?? 0;
      final label = numId == null ? null : _listLabel(numId, ilvl.clamp(0, 8));
      if (label != null) para.add(label, base);
    }

    void child(XmlElement c, _RunFmt f, bool caps) {
      switch (c.name.local) {
        case 't':
          if (!_fieldSkip) para.add(caps ? c.innerText.toUpperCase() : c.innerText, f);
        case 'tab' || 'ptab':
          para.add('    ', f); // Textly setzt keine Tabstopps
        case 'br':
          if (_attr(c, 'type') == 'page') {
            paras.add(para);
            para = _Para(kind)
              ..align = para.align
              ..pageBreakBefore = true;
          } else {
            para.add('\n', f);
          }
        case 'cr':
          para.add('\n', f);
        case 'noBreakHyphen':
          para.add('-', f);
        case 'fldChar':
          // Felder: in Kopf-/Fusszeilen werden Seitenzahlen pro Seite eingesetzt, sonst gilt Words Ergebnis
          switch (_attr(c, 'fldCharType')) {
            case 'begin':
              _fieldInstr = StringBuffer();
              _fieldSkip = false;
            case 'separate':
              final token = _fieldToken(_fieldInstr?.toString());
              if (token != null) {
                para.add(token, f);
                _fieldSkip = true;
              }
              _fieldInstr = null;
            case 'end':
              if (_fieldInstr != null) {
                // Feld ohne Ergebnis (z. B. PAGE ohne «separate»)
                final token = _fieldToken(_fieldInstr.toString());
                if (token != null) para.add(token, f);
              }
              _fieldInstr = null;
              _fieldSkip = false;
          }
        case 'instrText':
          _fieldInstr?.write(c.innerText);
        case 'AlternateContent':
          // Word speichert manches doppelt (neu und für ältere Programme): nur eine Fassung lesen
          final pick = _child(c, 'Choice') ?? _child(c, 'Fallback');
          if (pick != null) {
            for (final x in pick.childElements) {
              child(x, f, caps);
            }
          }
        case 'drawing' || 'pict' || 'object':
          final boxes = [
            for (final d in c.descendantElements)
              if (d.name.local == 'txbxContent' && !d.ancestorElements.takeWhile((a) => a != c).any((a) => a.name.local == 'txbxContent')) d,
          ];
          if (boxes.isNotEmpty) {
            // Textfeld: sein Inhalt kommt als gewöhnlicher Text an diese Stelle
            paras.add(para);
            for (final b in boxes) {
              _block(b);
            }
            _textBoxes++;
            para = _Para(kind)..align = para.align;
          } else if (_containsLocal(c, 'pic') || _containsLocal(c, 'imagedata') || _containsLocal(c, 'blip')) {
            final picture = _picture(c, para.align);
            if (picture == null) {
              _images++; // anderes Format (z. B. EMF) oder fehlende Datei
            } else {
              // Absatz teilen: Text davor, Bild, Text danach
              paras.add(para);
              paras.add(picture);
              para = _Para(kind)..align = para.align;
            }
          }
        case 'footnoteReference' || 'endnoteReference':
          final n = _noteRef(c.name.local == 'footnoteReference' ? _footnoteParts : _endnoteParts, _attr(c, 'id'));
          if (n != null) para.add('[$n]', f);
      }
    }

    void run(XmlElement r) {
      final rPr = _child(r, 'rPr');
      if (_onOff(_child(rPr, 'vanish')) == true) return; // verborgener Text
      final styleRun = _child(_styles[_val(_child(rPr, 'rStyle')) ?? '']?.rPr, 'caps');
      final caps = (_onOff(_child(rPr, 'caps')) ?? _onOff(styleRun)) == true;
      final f = base.over(_styleRun(_val(_child(rPr, 'rStyle')))).over(_RunFmt.of(rPr));
      for (final c in r.childElements) {
        child(c, f, caps);
      }
    }

    void walk(XmlElement e) {
      for (final c in e.childElements) {
        switch (c.name.local) {
          case 'r':
            run(c);
          case 'del' || 'moveFrom' || 'pPr' || 'rPr':
            break; // gelöscht (Änderungen nachverfolgen): angenommener Stand
          case 'sdt':
            final content = _child(c, 'sdtContent');
            if (content != null) walk(content);
          case 'fldSimple':
            final token = _fieldToken(_attr(c, 'instr'));
            if (token != null) {
              para.add(token, base);
            } else {
              walk(c);
            }
          case 'AlternateContent':
            final pick = _child(c, 'Choice') ?? _child(c, 'Fallback');
            if (pick != null) walk(pick);
          default:
            walk(c); // hyperlink, ins, smartTag, customXml …
        }
      }
    }

    if (_notePrefix != null) {
      para.add(_notePrefix!, base);
      para.startsBlock = _noteStartsBlock;
      _notePrefix = null;
      _noteStartsBlock = false;
    }
    walk(p);
    final sizes = {
      for (final (s, e, f) in para.pieces)
        if (f.size != null && para.text.toString().substring(s, e).trim().isNotEmpty) f.size,
    };
    if (kind == TextKind.body && sizes.length > 1) _mixedSizes++;
    paras.add(para);

    // Abschnittswechsel auf eine neue Seite
    final sect = _child(pPr, 'sectPr');
    if (sect != null) {
      _readPage(sect);
      final type = _val(_child(sect, 'type'));
      if (type != 'continuous') _pageBreakPending = true;
    }
  }
}

// ---------------------------------------------------------------- Setzen

const _margin = 15.0;

/// Textblock aus einem oder mehreren Absätzen (gleiche Art, Ausrichtung, Schrift, Grösse).
TextBlock _blockOf(List<_Para> group, Box box) {
  final first = group.firstWhere((p) => !p.isEmpty, orElse: () => group.first);
  final preset = textKindPresets[first.kind]!;
  final text = StringBuffer();
  final runs = <StyleRun>[];
  for (var i = 0; i < group.length; i++) {
    if (i > 0) text.write('\n');
    final offset = text.length;
    text.write(group[i].text);
    for (final (s, e, f) in group[i].pieces) {
      runs.add(StyleRun(offset + s, offset + e, InlineStyle(bold: f.bold, italic: f.italic, underline: f.underline == true ? true : null, color: f.color)));
    }
  }
  final s = text.toString();
  final size = first.kind == TextKind.body ? (first.dominant((f) => f.size)?.clamp(7.0, 48.0).toDouble() ?? preset.size) : preset.size;
  return TextBlock(
    id: newId(),
    box: box,
    text: s,
    kind: first.kind,
    size: size,
    color: preset.color,
    bold: preset.bold,
    italic: preset.italic,
    align: first.align,
    runs: simplifyRuns(normalizeRuns(runs, s.length), s.length, bold: preset.bold, italic: preset.italic, color: preset.color),
    font: _mapFont(first.dominant((f) => f.font)),
  );
}

/// Absatz mit eingesetzter Seitenzahl und Seitenanzahl.
_Para _subst(_Para p, String page, String pages) {
  final out = _Para(p.kind)..align = p.align;
  final t = p.text.toString();
  for (final (s, e, f) in p.pieces) {
    out.add(t.substring(s, e).replaceAll(_pageToken, page).replaceAll(_pagesToken, pages), f);
  }
  return out;
}

/// Abstand nach einem Block.
double _gapAfter(TextKind k) => switch (k) {
  TextKind.title => 3,
  TextKind.subtitle => 5,
  TextKind.heading => 1.5,
  TextKind.body || TextKind.caption => 4,
};

TextlyDocument _layout(
  List<Object> flow,
  Map<String, ImageAsset> assets,
  PageOrientation o,
  PaperSize paper,
  double Function(DocElement) measure,
  List<String> notes, {
  ({List<Object> all, List<Object>? first})? header,
  ({List<Object> all, List<Object>? first})? footer,
}) {
  final landscape = o == PageOrientation.landscape;
  final width = (landscape ? paper.longMm : paper.shortMm) - 2 * _margin;
  final pageBottom = (landscape ? paper.shortMm : paper.longMm) - _margin;

  double xFor(TextAlignment a, double w) => switch (a) {
    TextAlignment.center => _margin + (width - w) / 2,
    TextAlignment.right => _margin + width - w,
    TextAlignment.left => _margin,
  };

  /// Tabelle auf die Breite bringen: Spalten wie in Word, höchstens Satzspiegelbreite; ohne Angabe gleich breit.
  TableBlock fitTable(_Tbl tb) {
    final t = tb.table;
    final sum = t.columns.fold(0.0, (a, b) => a + b);
    final total = sum <= 0 ? width : (sum > width ? width : sum);
    final cols = sum <= 0 ? List.filled(t.columnCount, width / t.columnCount) : [for (final c in t.columns) c * total / sum];
    return t.copyWith(columns: cols, x: xFor(tb.align, total));
  }

  /// Kopf- oder Fusszeile ab [y0] setzen; Seitenzahlen eingesetzt. Ergibt die Elemente und die Höhe.
  (List<DocElement>, double) band(List<Object>? items, double y0, int page, int pages) {
    final out = <DocElement>[];
    var by = y0;
    for (final it in items ?? const <Object>[]) {
      switch (it) {
        case _Para p:
          final b = _blockOf([_subst(p, '$page', '$pages')], Box(_margin, by, width, 10));
          final h = measure(b);
          out.add(b.copyWith(box: Box(_margin, by, width, h)));
          by += h + 1;
        case _Img im:
          var w = im.w, h = im.h;
          if (w > width) {
            h *= width / w;
            w = width;
          }
          out.add(im.block(Box(xFor(im.align, w), by, w, h)));
          by += h + 1;
        case _Tbl tb:
          final t = fitTable(tb).copyWith(id: newId('t'), y: by);
          out.add(t);
          by += measure(t) + 1;
      }
    }
    return (out, out.isEmpty ? 0.0 : by - 1 - y0);
  }

  double bandHeight(List<Object>? items) => band(items, 0, 99, 99).$2;
  final headH = math.max(bandHeight(header?.all), bandHeight(header?.first));
  final footH = math.max(bandHeight(footer?.all), bandHeight(footer?.first));
  // Kopf- und Fusszeilen dürfen höchstens ein Drittel der Seite belegen
  final useBands = headH + footH < (pageBottom - _margin) / 3;
  if (!useBands && headH + footH > 0) notes.add('Kopf- und Fusszeilen sind zu gross und wurden weggelassen.');
  final top = useBands && headH > 0 ? _margin + headH + 5 : _margin;
  final bottom = useBands && footH > 0 ? pageBottom - footH - 5 : pageBottom;

  final pages = <DocPage>[];
  var elements = <DocElement>[];
  var y = top;
  var overflow = false;

  void newPage() {
    pages.add(DocPage(id: newId('p'), elements: elements));
    elements = <DocElement>[];
    y = top;
  }

  void place(List<_Para> group) {
    final b = _blockOf(group, Box(_margin, y, width, 10));
    final h = measure(b);
    if (y + h > bottom && elements.isNotEmpty) newPage();
    if (y + h > bottom) overflow = true;
    elements.add(b.copyWith(box: Box(_margin, y, width, h)));
    y += h + _gapAfter(b.kind);
  }

  void placeImage(_Img im) {
    var w = im.w, h = im.h;
    if (w > width) {
      h *= width / w;
      w = width;
    }
    final maxH = bottom - top;
    if (h > maxH) {
      w *= maxH / h;
      h = maxH;
    }
    if (y + h > bottom && elements.isNotEmpty) newPage();
    elements.add(im.block(Box(xFor(im.align, w), y, w, h)));
    y += h + 2.5; // Bildunterschrift nah am Bild
  }

  /// Tabelle setzen; passt sie nicht mehr auf die Seite, geht sie auf der nächsten weiter (Kopfzeile wiederholt).
  void placeTable(_Tbl tb) {
    var t = fitTable(tb);
    while (true) {
      final h = measure(t.copyWith(y: y));
      if (y + h <= bottom) {
        elements.add(t.copyWith(y: y));
        y += h + 4;
        return;
      }
      final head = t.headerRow ? 1 : 0;
      var fit = 0;
      for (var k = head + 1; k < t.rowCount; k++) {
        if (y + measure(t.copyWith(y: y, cells: t.cells.sublist(0, k))) <= bottom) {
          fit = k;
        } else {
          break;
        }
      }
      if (fit == 0) {
        if (elements.isNotEmpty) {
          newPage();
          continue;
        }
        overflow = true; // schon eine einzelne Zeile ist höher als die Seite
        elements.add(t.copyWith(y: y));
        y += h + 4;
        return;
      }
      elements.add(t.copyWith(id: newId('t'), y: y, cells: t.cells.sublist(0, fit)));
      newPage();
      t = t.copyWith(id: newId('t'), cells: [if (head == 1) t.cells.first, ...t.cells.sublist(fit)]);
    }
  }

  bool sameBlock(_Para a, _Para b) =>
      a.kind == TextKind.body &&
      b.kind == TextKind.body &&
      a.align == b.align &&
      _mapFont(a.dominant((f) => f.font)) == _mapFont(b.dominant((f) => f.font)) &&
      a.dominant((f) => f.size) == b.dominant((f) => f.size);

  var group = <_Para>[];

  /// Fliesstext-Absätze zu einem Block zusammenfassen, solange er auf die Seite passt.
  void flush() {
    while (group.isNotEmpty && group.last.isEmpty) {
      group.removeLast();
    }
    var take = <_Para>[];
    for (final p in group) {
      final next = [...take, p];
      if (take.isNotEmpty && y + measure(_blockOf(next, Box(_margin, y, width, 10))) > bottom) {
        while (take.last.isEmpty) {
          take.removeLast();
        }
        place(take);
        newPage();
        take = p.isEmpty ? [] : [p];
      } else {
        take = next;
      }
    }
    if (take.isNotEmpty) place(take);
    group = [];
  }

  for (final item in flow) {
    final breakBefore = switch (item) {
      _Para p => p.pageBreakBefore,
      _Img i => i.pageBreakBefore,
      _Tbl t => t.pageBreakBefore,
      _ => false,
    };
    if (breakBefore) {
      flush();
      if (elements.isNotEmpty) newPage();
    }
    switch (item) {
      case _Img im:
        flush();
        placeImage(im);
      case _Tbl tb:
        flush();
        placeTable(tb);
      case _Para p when p.isEmpty:
        // Leere Absätze: im Fliesstext eine Leerzeile, sonst nur Abstand (den setzt Textly selbst)
        if (group.isNotEmpty && !group.last.isEmpty) group.add(p);
      case _Para p:
        if (p.startsBlock) flush();
        if (group.isNotEmpty && !sameBlock(group.lastWhere((x) => !x.isEmpty), p)) flush();
        if (p.kind == TextKind.body) {
          group.add(p);
        } else {
          flush();
          place([p]);
        }
    }
  }
  flush();
  if (elements.isNotEmpty || pages.isEmpty) newPage();
  if (overflow) notes.add('Ein sehr langer Absatz ragt über den Seitenrand; bitte kürzen oder aufteilen.');
  if (!useBands) return TextlyDocument(pages: pages, assets: assets, orientation: o, paper: paper);
  // Kopf- und Fusszeile auf jede Seite (erste Seite eigene, falls in Word so eingestellt)
  final n = pages.length;
  return TextlyDocument(
    pages: [
      for (var i = 0; i < n; i++)
        () {
          final head = band(i == 0 && header?.first != null ? header!.first : header?.all, _margin, i + 1, n).$1;
          final footItems = i == 0 && footer?.first != null ? footer!.first : footer?.all;
          final foot = band(footItems, pageBottom - bandHeight(footItems), i + 1, n).$1;
          return DocPage(id: pages[i].id, elements: [...head, ...pages[i].elements, ...foot]);
        }(),
    ],
    assets: assets,
    orientation: o,
    paper: paper,
  );
}
