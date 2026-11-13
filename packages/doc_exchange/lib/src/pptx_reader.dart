import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:doc_model/doc_model.dart';
import 'package:image/image.dart' as img;
import 'package:xml/xml.dart';

import 'pptx_common.dart';

/// Ergebnis eines Imports: das Dokument und Hinweise, was nicht übernommen werden konnte.
class PptxImport {
  PptxImport(this.document, this.notes);
  final TextlyDocument document;

  /// Verständliche Hinweise für den Benutzer (leer, wenn alles übernommen wurde).
  final List<String> notes;
}

class PptxImportException implements Exception {
  const PptxImportException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Liest eine PowerPoint-Datei (.pptx) als Textly-Dokument.
///
/// Übernommen werden Textfelder (mit Formatierung einzelner Textstellen), Bilder (mit Zuschnitt),
/// Rechtecke und Linien. Folien in anderer Grösse werden auf A4 hochformat verkleinert.
///
/// [prepareImage] bereitet Bilder auf wie beim gewöhnlichen Einfügen (Drehung aus den Kameradaten,
/// sehr grosse Fotos verkleinern); null für nicht lesbare Bilder. Ohne: Datei unverändert.
PptxImport importPptx(Uint8List bytes, {ImageAsset? Function(Uint8List bytes)? prepareImage}) {
  final Archive zip;
  try {
    zip = ZipDecoder().decodeBytes(bytes);
  } catch (_) {
    throw const PptxImportException('Die Datei ist keine gültige PowerPoint-Datei.');
  }
  try {
    return _Reader(LazyZip(zip), prepareImage).read();
  } on PptxImportException {
    rethrow;
  } on ZipTooLargeException {
    throw const PptxImportException('Die PowerPoint-Datei ist zu gross oder beschädigt (ein Teil wäre entpackt über 64 MB).');
  } catch (_) {
    // fehlerhaftes XML, ungültige Zahlen o. Ä.: verständliche Meldung statt technischer Ausnahme
    throw const PptxImportException('Die PowerPoint-Datei ist beschädigt oder enthält etwas, das Textly nicht lesen kann.');
  }
}

XmlElement? _child(XmlElement? e, String local) {
  if (e == null) return null;
  for (final c in e.childElements) {
    if (c.name.local == local) return c;
  }
  return null;
}

Iterable<XmlElement> _children(XmlElement? e, String local) =>
    e == null ? const [] : e.childElements.where((c) => c.name.local == local);

XmlElement? _path(XmlElement? e, List<String> locals) {
  var cur = e;
  for (final l in locals) {
    cur = _child(cur, l);
  }
  return cur;
}

String? _attr(XmlElement? e, String local) {
  if (e == null) return null;
  for (final a in e.attributes) {
    if (a.name.local == local) return a.value;
  }
  return null;
}

int? _int(XmlElement? e, String local) => int.tryParse(_attr(e, local) ?? '');

/// Beziehungs-Verweis (r:id). Nicht mit dem gewöhnlichen Attribut «id» verwechseln.
String? _relId(XmlElement? e) {
  if (e == null) return null;
  for (final a in e.attributes) {
    if (a.name.local == 'id' && (a.name.namespaceUri == nsR || a.name.prefix == 'r')) return a.value;
  }
  return null;
}

/// Abbildung eines Gruppen-Koordinatensystems auf die Folie.
class _Transform {
  const _Transform(this.ox, this.oy, this.sx, this.sy);
  static const identity = _Transform(0, 0, 1, 1);
  final double ox, oy, sx, sy;
  (double, double) point(double x, double y) => (ox + x * sx, oy + y * sy);
  _Transform then(_Transform inner) => _Transform(ox + inner.ox * sx, oy + inner.oy * sy, sx * inner.sx, sy * inner.sy);
}

class _Reader {
  _Reader(this.files, this.prepareImage);
  final LazyZip files;
  final ImageAsset? Function(Uint8List bytes)? prepareImage;
  final notes = <String>[];
  final assets = <String, ImageAsset>{};
  final _assetByPath = <String, String>{};
  final _skipped = <String, int>{};
  Map<String, String> _theme = const {};
  double _scale = 1;
  PageOrientation _orientation = PageOrientation.portrait;
  PaperSize _paper = PaperSize.a4;

  XmlDocument _xml(String path) {
    final b = files[path];
    if (b == null) throw PptxImportException('Bestandteil fehlt: $path');
    return XmlDocument.parse(utf8.decode(b, allowMalformed: true));
  }

  /// Beziehungen eines Teils: rId → Pfad im Paket.
  Map<String, String> _rels(String partPath) {
    final dir = partPath.substring(0, partPath.lastIndexOf('/') + 1);
    final name = partPath.substring(partPath.lastIndexOf('/') + 1);
    final relPath = '${dir}_rels/$name.rels';
    if (!files.containsKey(relPath)) return const {};
    final out = <String, String>{};
    for (final r in _xml(relPath).rootElement.childElements) {
      final target = _attr(r, 'Target') ?? '';
      out[_attr(r, 'Id') ?? ''] = _resolve(dir, target);
    }
    return out;
  }

  static String _resolve(String dir, String target) {
    if (target.startsWith('/')) return target.substring(1);
    final parts = [...dir.split('/').where((p) => p.isNotEmpty), ...target.split('/')];
    final out = <String>[];
    for (final p in parts) {
      if (p == '..') {
        if (out.isNotEmpty) out.removeLast();
      } else if (p != '.') {
        out.add(p);
      }
    }
    return out.join('/');
  }

  PptxImport read() {
    const presPath = 'ppt/presentation.xml';
    if (!files.containsKey(presPath)) throw const PptxImportException('Die Datei ist keine PowerPoint-Präsentation.');
    final pres = _xml(presPath).rootElement;
    final presRels = _rels(presPath);
    final size = _child(pres, 'sldSz');
    final wMm = mmFromEmu(_int(size, 'cx') ?? emu(210)), hMm = mmFromEmu(_int(size, 'cy') ?? emu(297));
    // Breite Folien werden Querformat, hohe Hochformat; A5, A4 und A3 werden erkannt, andere Grössen auf A4 angepasst
    final orientation = wMm > hMm ? PageOrientation.landscape : PageOrientation.portrait;
    final shortMm = math.min(wMm, hMm), longMm = math.max(wMm, hMm);
    _paper = PaperSize.values.where((p) => (p.shortMm - shortMm).abs() <= 3 && (p.longMm - longMm).abs() <= 3).firstOrNull ?? PaperSize.a4;
    final targetW = orientation == PageOrientation.landscape ? _paper.longMm : _paper.shortMm;
    final targetH = orientation == PageOrientation.landscape ? _paper.shortMm : _paper.longMm;
    _scale = math.min(targetW / wMm, targetH / hMm);
    if ((_scale - 1).abs() > .02) {
      notes.add('Die Folien haben ein anderes Format (${wMm.toStringAsFixed(0)} × ${hMm.toStringAsFixed(0)} mm) '
          'und wurden auf A4 ${orientation == PageOrientation.landscape ? 'quer' : 'hoch'} angepasst (${(_scale * 100).round()} %).');
    }
    _orientation = orientation;
    _loadTheme(presRels);

    final pages = <DocPage>[];
    for (final sid in _children(_child(pres, 'sldIdLst'), 'sldId')) {
      final path = presRels[_relId(sid) ?? ''];
      if (path == null || !files.containsKey(path)) continue;
      pages.add(_slide(path));
    }
    if (pages.isEmpty) pages.add(DocPage(id: newId('p')));
    for (final e in _skipped.entries) {
      notes.add('${e.value} × ${e.key} nicht übernommen.');
    }
    return PptxImport(TextlyDocument(pages: pages, assets: assets, orientation: _orientation, paper: _paper), notes);
  }

  void _skip(String what) => _skipped[what] = (_skipped[what] ?? 0) + 1;

  void _loadTheme(Map<String, String> presRels) {
    final themePath = presRels.values.firstWhere((p) => p.contains('theme/'), orElse: () => '');
    if (!files.containsKey(themePath)) return;
    final scheme = _path(_xml(themePath).rootElement, ['themeElements', 'clrScheme']);
    final t = <String, String>{};
    for (final c in scheme?.childElements ?? const <XmlElement>[]) {
      final v = _attr(_child(c, 'srgbClr'), 'val') ?? _attr(_child(c, 'sysClr'), 'lastClr');
      if (v != null) t[c.name.local] = v;
    }
    _theme = t;
  }

  int? _color(XmlElement? fillParent) {
    final solid = _child(fillParent, 'solidFill');
    if (solid == null) return null;
    final srgb = _attr(_child(solid, 'srgbClr'), 'val');
    if (srgb != null) {
      final v = int.tryParse(srgb, radix: 16);
      return v == null ? null : 0xFF000000 | (v & 0xFFFFFF);
    }
    var scheme = _attr(_child(solid, 'schemeClr'), 'val');
    if (scheme != null) {
      scheme = const {'tx1': 'dk1', 'bg1': 'lt1', 'tx2': 'dk2', 'bg2': 'lt2'}[scheme] ?? scheme;
      final v = _theme[scheme];
      final n = v == null ? null : int.tryParse(v, radix: 16);
      if (n != null) return 0xFF000000 | (n & 0xFFFFFF);
    }
    return null;
  }

  // ---------- Folie ----------

  DocPage _slide(String path) {
    final rels = _rels(path);
    final layoutPath = rels.values.firstWhere((p) => p.contains('slideLayouts/'), orElse: () => '');
    final layoutTree = files.containsKey(layoutPath) ? _path(_xml(layoutPath).rootElement, ['cSld', 'spTree']) : null;
    final masterPath = layoutPath.isEmpty ? '' : _rels(layoutPath).values.firstWhere((p) => p.contains('slideMasters/'), orElse: () => '');
    final masterTree = files.containsKey(masterPath) ? _path(_xml(masterPath).rootElement, ['cSld', 'spTree']) : null;
    final ctx = _SlideCtx(rels, layoutTree, masterTree);
    final elements = <DocElement>[];
    final tree = _path(_xml(path).rootElement, ['cSld', 'spTree']);
    _walk(tree, _Transform.identity, ctx, elements);
    return DocPage(id: newId('p'), elements: elements);
  }

  void _walk(XmlElement? tree, _Transform tf, _SlideCtx ctx, List<DocElement> out) {
    for (final e in tree?.childElements ?? const <XmlElement>[]) {
      switch (e.name.local) {
        case 'sp':
          _shape(e, tf, ctx, out);
        case 'pic':
          _picture(e, tf, ctx, out);
        case 'cxnSp':
          _connector(e, tf, out);
        case 'grpSp':
          final x = _path(e, ['grpSpPr', 'xfrm']);
          final off = _child(x, 'off'), ext = _child(x, 'ext'), chOff = _child(x, 'chOff'), chExt = _child(x, 'chExt');
          if (x == null) {
            _walk(e, tf, ctx, out);
          } else {
            final sx = (_int(chExt, 'cx') ?? 0) == 0 ? 1.0 : (_int(ext, 'cx') ?? 0) / _int(chExt, 'cx')!;
            final sy = (_int(chExt, 'cy') ?? 0) == 0 ? 1.0 : (_int(ext, 'cy') ?? 0) / _int(chExt, 'cy')!;
            final inner = _Transform(
              (_int(off, 'x') ?? 0) - (_int(chOff, 'x') ?? 0) * sx,
              (_int(off, 'y') ?? 0) - (_int(chOff, 'y') ?? 0) * sy,
              sx,
              sy,
            );
            _walk(e, tf.then(inner), ctx, out);
          }
        case 'graphicFrame':
          final tbl = _path(e, ['graphic', 'graphicData', 'tbl']);
          if (tbl == null) {
            _skip('Diagramm oder anderes eingebettetes Objekt');
          } else {
            _table(e, tbl, tf, out);
          }
        case 'nvGrpSpPr' || 'grpSpPr' || 'extLst':
          break;
        default:
          _skip('anderes Element (${e.name.local})');
      }
    }
  }

  /// Rechteck auf der Folie in mm (inkl. Gruppen-Transformation und Verkleinerung).
  Box? _box(XmlElement? xfrm, _Transform tf) {
    final off = _child(xfrm, 'off'), ext = _child(xfrm, 'ext');
    if (off == null || ext == null) return null;
    final (x, y) = tf.point((_int(off, 'x') ?? 0).toDouble(), (_int(off, 'y') ?? 0).toDouble());
    final w = (_int(ext, 'cx') ?? 0) * tf.sx, h = (_int(ext, 'cy') ?? 0) * tf.sy;
    return Box(mmFromEmu(x) * _scale, mmFromEmu(y) * _scale, mmFromEmu(w) * _scale, mmFromEmu(h) * _scale);
  }

  /// Lage eines Platzhalters ohne eigene Angabe: aus dem Layout bzw. Folienmaster.
  XmlElement? _placeholderXfrm(XmlElement sp, _SlideCtx ctx) {
    final ph = _path(sp, ['nvSpPr', 'nvPr', 'ph']);
    if (ph == null) return null;
    final idx = _attr(ph, 'idx'), type = _attr(ph, 'type') ?? 'body';
    for (final tree in [ctx.layoutTree, ctx.masterTree]) {
      for (final cand in _children(tree, 'sp')) {
        final cph = _path(cand, ['nvSpPr', 'nvPr', 'ph']);
        if (cph == null) continue;
        final sameIdx = idx != null && _attr(cph, 'idx') == idx;
        final sameType = (_attr(cph, 'type') ?? 'body') == type;
        if (sameIdx || (idx == null && sameType) || (sameType && type != 'body')) {
          final x = _path(cand, ['spPr', 'xfrm']);
          if (x != null) return x;
        }
      }
    }
    return null;
  }

  void _shape(XmlElement sp, _Transform tf, _SlideCtx ctx, List<DocElement> out) {
    final spPr = _child(sp, 'spPr');
    final box = _box(_child(spPr, 'xfrm') ?? _placeholderXfrm(sp, ctx), tf);
    final name = _attr(_path(sp, ['nvSpPr', 'cNvPr']), 'name') ?? '';
    final prst = _attr(_child(spPr, 'prstGeom'), 'prst') ?? (_child(spPr, 'custGeom') != null ? 'custom' : 'rect');
    if (box == null) {
      _skip('Element ohne Lageangabe');
      return;
    }
    // Linie als Form
    if (prst == 'line' || prst.startsWith('straightConnector')) {
      _addLine(spPr, box, out);
      return;
    }
    // Drehung: Vielfache von 180° ändern ein Rechteck nicht, 90°/270° tauschen Breite und Höhe.
    final rot = (_int(_child(spPr, 'xfrm'), 'rot') ?? 0) % 21600000;
    final quarter = rot % 5400000 == 0;
    final shapeBox = quarter && (rot ~/ 5400000).isOdd ? Box(box.centerX - box.h / 2, box.centerY - box.w / 2, box.h, box.w) : box;
    final fill = _color(spPr);
    final ln = _child(spPr, 'ln');
    final lnWidth = _child(ln, 'noFill') != null ? 0.0 : mmFromEmu(_int(ln, 'w') ?? 0) * _scale;
    final lnColor = _color(ln);
    final hasText = (_child(sp, 'txBody')?.innerText.trim() ?? '').isNotEmpty;
    final visible = fill != null || (lnColor != null && lnWidth > 0);
    if (visible) {
      if (prst == 'rect' || prst == 'roundRect') {
        // Rahmen liegt bei PowerPoint mittig auf der Kante, bei Textly innen
        final half = lnColor != null ? lnWidth / 2 : 0.0;
        if (!quarter) _skip('schräg gedrehte Form (wird gerade gezeigt)');
        out.add(RectShape(
          id: newId(),
          box: Box(shapeBox.x - half, shapeBox.y - half, shapeBox.w + 2 * half, shapeBox.h + 2 * half),
          fill: fill ?? 0x00FFFFFF,
          stroke: lnColor ?? 0xFF1D2733,
          strokeWidth: lnColor != null ? lnWidth : 0,
          round: prst == 'roundRect',
        ));
      } else {
        _skip('Form ($prst)');
      }
    }
    if (hasText) {
      if (rot != 0) _skip('gedrehter Text (wird waagrecht gezeigt)');
      out.add(_text(sp, box, name));
    }
  }

  /// PowerPoint-Tabelle → Textly-Tabelle. Übernommen werden Spaltenbreiten, Text, Kopfzeile,
  /// Ausrichtung je Spalte, Schriftgrösse und -art, Linien (Farbe, Stärke, welche) und die Farbe der Kopfzeile.
  /// Zusammengeführte Zellen und Formatierung einzelner Wörter kennt Textly nicht.
  void _table(XmlElement frame, XmlElement tbl, _Transform tf, List<DocElement> out) {
    final box = _box(_child(frame, 'xfrm'), tf);
    final grid = [for (final g in _children(_child(tbl, 'tblGrid'), 'gridCol')) mmFromEmu(_int(g, 'w') ?? 0) * tf.sx * _scale];
    final trs = _children(tbl, 'tr').toList();
    if (box == null || grid.isEmpty || grid.any((w) => w <= 0) || trs.isEmpty) {
      _skip('Tabelle ohne lesbaren Aufbau');
      return;
    }
    final cells = <List<String>>[];
    double? size;
    String? fontName;
    final aligns = List<TextAlignment?>.filled(grid.length, null);
    var merged = false;
    for (var r = 0; r < trs.length; r++) {
      final row = <String>[];
      final tcs = _children(trs[r], 'tc').toList();
      for (var c = 0; c < grid.length; c++) {
        final tc = c < tcs.length ? tcs[c] : null;
        if (_attr(tc, 'gridSpan') != null || _attr(tc, 'rowSpan') != null || _attr(tc, 'hMerge') != null || _attr(tc, 'vMerge') != null) {
          merged = true;
        }
        final lines = <String>[];
        for (final p in _children(_child(tc, 'txBody'), 'p')) {
          final buf = StringBuffer();
          for (final run in p.childElements) {
            if (run.name.local == 'br') buf.write('\n');
            if (run.name.local != 'r' && run.name.local != 'fld') continue;
            buf.write(_child(run, 't')?.innerText ?? '');
            final rPr = _child(run, 'rPr');
            size ??= _int(rPr, 'sz') == null ? null : _int(rPr, 'sz')! / 100;
            fontName ??= _attr(_child(rPr, 'latin'), 'typeface');
          }
          lines.add(buf.toString());
          final body = !(r == 0 && trs.length > 1);
          if (body && aligns[c] == null && buf.isNotEmpty) {
            aligns[c] = switch (_attr(_child(p, 'pPr'), 'algn')) {
              'ctr' => TextAlignment.center,
              'r' => TextAlignment.right,
              _ => TextAlignment.left,
            };
          }
        }
        row.add(lines.join('\n'));
      }
      cells.add(row);
    }
    if (merged) _skip('verbundene Tabellenzellen (werden einzeln gezeigt)');

    // Kopfzeile, Linien und Farben aus der ersten Zelle bzw. ersten Zeile ablesen
    final tblPr = _child(tbl, 'tblPr');
    final headerRow = _attr(tblPr, 'firstRow') == '1' || _attr(tblPr, 'firstRow') == 'true';
    XmlElement? tcPr(int r, int c) {
      final tcs = _children(trs[r], 'tc').toList();
      return c < tcs.length ? _child(tcs[c], 'tcPr') : null;
    }

    bool on(XmlElement? pr, String tag) {
      final ln = _child(pr, tag);
      return ln != null && _child(ln, 'noFill') == null && _color(ln) != null && (_int(ln, 'w') ?? 12700) > 0;
    }

    final first = tcPr(0, 0);
    final inner = trs.length > 1 ? tcPr(1, 0) : first;
    final lines = on(inner, 'lnL') && on(inner, 'lnT')
        ? TableLines.all
        : on(inner, 'lnT') || on(inner, 'lnB')
            ? TableLines.horizontal
            : on(first, 'lnL') || on(first, 'lnT')
                ? TableLines.outer
                : TableLines.none;
    XmlElement? anyLine;
    for (final tag in ['lnT', 'lnL', 'lnB', 'lnR']) {
      if (on(inner, tag)) {
        anyLine = _child(inner, tag);
        break;
      }
      if (on(first, tag)) {
        anyLine = _child(first, tag);
        break;
      }
    }
    final lineWidth = anyLine == null ? tableLineFine : mmFromEmu(_int(anyLine, 'w') ?? 9144) * _scale;
    final headerFill = headerRow ? _color(first) : null;
    final bodyFill = trs.length > 2 ? _color(tcPr(2, 0)) : null;

    final fn = fontName;
    final font = fn == null || fn.startsWith('+') ? null : fontByName(fn);
    if (fn != null && !fn.startsWith('+') && font == null) _skip('Schrift «$fn» (Textly nimmt eine eigene Schrift)');
    final pt = (size ?? 10.5) * _scale;

    var t = TableBlock(
      id: newId(),
      x: box.x,
      y: box.y,
      columns: grid,
      cells: cells,
      heightHint: box.h,
      headerRow: headerRow,
      style: headerFill != null ? TableStyle.header : TableStyle.grid,
      size: (pt * 2).round() / 2, // auf halbe Punkte, wie bei Textfeldern
      align: [for (final a in aligns) a ?? TextAlignment.left],
      lines: lines,
      lineColor: anyLine == null ? 0xFFC4CBD6 : (_color(anyLine) ?? 0xFFC4CBD6),
      lineWidth: lineWidth < (tableLineFine + tableLineStrong) / 2 ? tableLineFine : tableLineStrong,
      headerColor: headerFill ?? 0xFF1F7A5A,
      zebra: _attr(tblPr, 'bandRow') == '1' && bodyFill != null,
    );
    if (font != null && font != t.effectiveFont) t = t.withFont(font);
    out.add(t);
  }

  TextBlock _text(XmlElement sp, Box box, String name) {
    final body = _child(sp, 'txBody');
    final bodyPr = _child(body, 'bodyPr');
    double inset(String a, int def) => mmFromEmu(_int(bodyPr, a) ?? def) * _scale;
    final l = inset('lIns', 91440), t = inset('tIns', 45720), r = inset('rIns', 91440), b = inset('bIns', 45720);
    final kind = kindFromShapeName(name);

    // Text und Formatierung je Zeichen sammeln
    final text = StringBuffer();
    final chars = <({bool bold, bool italic, bool underline, int? color, double? size, String? font})>[];
    TextAlignment? align;
    var firstPara = true;
    for (final p in _children(body, 'p')) {
      if (!firstPara) {
        text.write('\n');
        chars.add(chars.isEmpty ? (bold: false, italic: false, underline: false, color: null, size: null, font: null) : chars.last);
      }
      firstPara = false;
      align ??= switch (_attr(_child(p, 'pPr'), 'algn')) {
        'ctr' => TextAlignment.center,
        'r' => TextAlignment.right,
        _ => null,
      };
      for (final r in p.childElements) {
        final local = r.name.local;
        if (local != 'r' && local != 'br' && local != 'fld') continue;
        final rPr = _child(r, 'rPr');
        final s = (
          bold: _attr(rPr, 'b') == '1' || _attr(rPr, 'b') == 'true',
          italic: _attr(rPr, 'i') == '1' || _attr(rPr, 'i') == 'true',
          underline: (_attr(rPr, 'u') ?? 'none') != 'none',
          color: _color(rPr),
          size: _int(rPr, 'sz') == null ? null : _int(rPr, 'sz')! / 100,
          font: _attr(_child(rPr, 'latin'), 'typeface'),
        );
        final value = local == 'br' ? '\n' : (_child(r, 't')?.innerText ?? '');
        text.write(value);
        for (var i = 0; i < value.length; i++) {
          chars.add(s);
        }
      }
    }
    final value = text.toString();

    // Blockstil = häufigste Ausprägung; Abweichungen werden formatierte Textstellen
    T majority<T>(Iterable<T> xs, T fallback) {
      final counts = <T, int>{};
      for (final x in xs) {
        counts[x] = (counts[x] ?? 0) + 1;
      }
      if (counts.isEmpty) return fallback;
      return counts.entries.reduce((a, b) => b.value > a.value ? b : a).key;
    }

    final preset = textKindPresets[kind]!;
    final defaultColor = _theme['dk1'] == null ? 0xFF000000 : 0xFF000000 | int.parse(_theme['dk1']!, radix: 16);
    final bold = majority(chars.map((c) => c.bold), preset.bold);
    final italic = majority(chars.map((c) => c.italic), preset.italic);
    final color = majority(chars.map((c) => c.color ?? defaultColor), preset.color);
    final size = majority(chars.where((c) => c.size != null).map((c) => c.size!), 18.0) * _scale;
    if (chars.any((c) => c.size != null && (c.size! * _scale - size).abs() > .01)) {
      _skip('abweichende Schriftgrösse innerhalb eines Textfelds (Textly: eine Grösse pro Block)');
    }
    var runs = <StyleRun>[];
    for (var i = 0; i < chars.length; i++) {
      final c = chars[i];
      final st = InlineStyle(
        bold: c.bold == bold ? null : c.bold,
        italic: c.italic == italic ? null : c.italic,
        underline: c.underline ? true : null,
        color: (c.color ?? defaultColor) == color ? null : (c.color ?? defaultColor),
      );
      if (!st.isEmpty) runs = applyInlineStyle(runs, value.length, i, i + 1, st);
    }

    // Schriftart: die häufigste; bekannte Schriften übernehmen, sonst Vorgabe der Textart
    final fontName = majority(chars.map((c) => c.font).whereType<String>(), '');
    final font = fontName.isEmpty || fontName.startsWith('+') ? null : fontByName(fontName);
    if (fontName.isNotEmpty && !fontName.startsWith('+') && font == null) {
      _skip('Schrift «$fontName» (Textly nimmt eine eigene Schrift)');
    }

    return TextBlock(
      id: newId(),
      // Innenabstand von PowerPoint auf den von Textly umrechnen, damit der Text an derselben Stelle beginnt
      // sehr schmale Felder: mindestens 5 mm breit (sonst negative Breite)
      box: Box(box.x + l - textPadXmm, box.y + t - textPadYmm, math.max(5.0, box.w - l - r + 2 * textPadXmm),
          math.max(1.0, box.h - t - b + 2 * textPadYmm)),
      text: value,
      kind: kind,
      size: (size * 2).round() / 2, // auf halbe Punkte
      color: color,
      bold: bold,
      italic: italic,
      align: align ?? TextAlignment.left,
      runs: simplifyRuns(runs, value.length, bold: bold, italic: italic, color: color),
      font: font == defaultFontForKind(kind) ? null : font,
    );
  }

  void _picture(XmlElement pic, _Transform tf, _SlideCtx ctx, List<DocElement> out) {
    final xfrm = _path(pic, ['spPr', 'xfrm']);
    var box = _box(xfrm, tf);
    final blipFill = _child(pic, 'blipFill');
    final rid = _attr(_child(blipFill, 'blip'), 'embed');
    final path = rid == null ? null : ctx.rels[rid];
    final bytes = path == null ? null : files[path];
    if (box == null || bytes == null) {
      _skip('Bild ohne Bilddatei');
      return;
    }
    if (box.w <= 0 || box.h <= 0) {
      _skip('Bild ohne Fläche');
      return;
    }
    final asset = _asset(path!, bytes);
    if (asset == null) {
      _skip('Bild in nicht unterstütztem Format (z. B. EMF, SVG)');
      return;
    }
    // Drehung in 90°-Schritten übernehmen; andere Winkel kennt Textly nicht
    final rot = _int(xfrm, 'rot') ?? 0;
    var q = 0;
    if (rot % 5400000 == 0) {
      q = (rot ~/ 5400000) % 4;
    } else {
      _skip('schräg gedrehtes Bild (wird gerade gezeigt)');
    }
    if (q.isOdd) box = Box(box.centerX - box.h / 2, box.centerY - box.w / 2, box.h, box.w);
    final src = _child(blipFill, 'srcRect');
    double f(String a) => (_int(src, a) ?? 0) / 100000;
    final crop = windowInDisplay(CropWindow(f('l'), f('t'), 1 - f('l') - f('r'), 1 - f('t') - f('b')), q);
    final wx = crop.w, wy = crop.h;
    var block = ImageBlock(
      id: newId(),
      box: box,
      asset: asset.id,
      naturalWidth: q.isOdd ? asset.height : asset.width,
      naturalHeight: q.isOdd ? asset.width : asset.height,
      quarterTurns: q,
    );
    // Zuschnitt → Vergrösserung und Lage des Ausschnitts
    final base = cropWindow(block); // sichtbarer Anteil ohne Vergrösserung
    if (wx > 0 && wy > 0 && (wx < .9999 || wy < .9999 || base.w < .9999 || base.h < .9999)) {
      final zx = base.w / wx, zy = base.h / wy;
      if ((zx - zy).abs() / math.max(zx, zy) > .02) _skip('verzerrtes Bild (wird unverzerrt gezeigt)');
      block = withCropAt(withCropZoom(block, math.max(1.0, math.min(zx, zy))), crop.x, crop.y);
    }
    out.add(block);
  }

  ImageAsset? _asset(String path, Uint8List bytes) {
    final known = _assetByPath[path];
    if (known != null) return assets[known];
    final prepare = prepareImage;
    if (prepare != null) {
      ImageAsset? a;
      try {
        a = prepare(bytes);
      } catch (_) {
        a = null;
      }
      if (a == null) return null;
      assets[a.id] = a;
      _assetByPath[path] = a.id;
      return a;
    }
    final decoder = img.findDecoderForData(bytes);
    if (decoder == null || (decoder is! img.JpegDecoder && decoder is! img.PngDecoder)) return null;
    final info = decoder.startDecode(bytes);
    if (info == null) return null;
    final a = ImageAsset(
      id: newId('img'),
      bytes: bytes,
      mimeType: decoder is img.JpegDecoder ? 'image/jpeg' : 'image/png',
      width: info.width,
      height: info.height,
    );
    assets[a.id] = a;
    _assetByPath[path] = a.id;
    return a;
  }

  void _connector(XmlElement cxn, _Transform tf, List<DocElement> out) {
    final spPr = _child(cxn, 'spPr');
    final box = _box(_child(spPr, 'xfrm'), tf);
    if (box == null) return;
    _addLine(spPr, box, out);
  }

  void _addLine(XmlElement? spPr, Box box, List<DocElement> out) {
    final x = _child(spPr, 'xfrm');
    final flipH = _attr(x, 'flipH') == '1', flipV = _attr(x, 'flipV') == '1';
    final ln = _child(spPr, 'ln');
    var a = Pt(flipH ? box.right : box.x, flipV ? box.bottom : box.y);
    var b = Pt(flipH ? box.x : box.right, flipV ? box.y : box.bottom);
    // Drehung um die Mitte (PowerPoint speichert senkrechte Linien oft als gedrehte waagrechte)
    final rot = _int(x, 'rot') ?? 0;
    if (rot % 21600000 != 0) {
      final th = rot / 60000 * math.pi / 180, c = math.cos(th), s = math.sin(th);
      Pt turn(Pt p) {
        final dx = p.x - box.centerX, dy = p.y - box.centerY;
        return Pt(box.centerX + dx * c - dy * s, box.centerY + dx * s + dy * c);
      }

      a = turn(a);
      b = turn(b);
    }
    out.add(LineShape(
      id: newId(),
      a: a,
      b: b,
      color: _color(ln) ?? 0xFF1D2733,
      width: mmFromEmu(_int(ln, 'w') ?? 9525) * _scale,
    ));
  }
}

class _SlideCtx {
  _SlideCtx(this.rels, this.layoutTree, this.masterTree);
  final Map<String, String> rels;
  final XmlElement? layoutTree, masterTree;
}
