import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:doc_model/doc_model.dart';

import 'pptx_common.dart';
import 'pptx_templates.dart';

/// Liefert die tatsächlichen Umrisse eines Elements in mm (Textblöcke mit automatischer Höhe
/// werden von der Darstellung gemessen; das reine Dart-Paket kann das nicht selbst).
typedef BoxOf = Box Function(DocElement e);

/// Liefert die Zeilenhöhen einer Tabelle in mm (von der Darstellung gemessen).
typedef RowHeightsOf = List<double> Function(TableBlock t);

/// Liefert die Bytes einer Bilddatei, die nicht im Dokument liegt (z. B. App-Assets des Beispiels).
typedef ExternalImage = Uint8List? Function(String asset);

/// Lage eines Bildes bei «Ganzes Bild» innerhalb des Rahmens (in mm, relativ zum Rahmen).
Box containPlacement(ImageBlock i) {
  final s = math.min(i.box.w / i.naturalWidth, i.box.h / i.naturalHeight);
  final w = i.naturalWidth * s, h = i.naturalHeight * s;
  return Box((i.box.w - w) / 2, (i.box.h - h) / 2, w, h);
}

/// Schreibt ein Textly-Dokument als PowerPoint-Datei.
Uint8List exportPptx(TextlyDocument doc, {required BoxOf boxOf, ExternalImage? externalImage, RowHeightsOf? rowHeightsOf}) {
  final files = <String, Object>{}; // Pfad → String (XML) oder Uint8List
  final media = <String, String>{}; // Asset-ID → Pfad im Paket
  var mediaCount = 0;

  String mediaFor(String assetId) {
    final known = media[assetId];
    if (known != null) return known;
    final own = doc.assets[assetId];
    final Uint8List? bytes = own?.bytes ?? externalImage?.call(assetId);
    if (bytes == null) throw StateError('Bilddatei $assetId nicht gefunden');
    final isJpeg = bytes.length > 2 && bytes[0] == 0xFF && bytes[1] == 0xD8;
    final path = 'ppt/media/image${++mediaCount}.${isJpeg ? 'jpeg' : 'png'}';
    files[path] = bytes;
    return media[assetId] = path;
  }

  for (var p = 0; p < doc.pages.length; p++) {
    final rels = <String>['<Relationship Id="rId1" Type="$relBase/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>'];
    final shapes = StringBuffer();
    var id = 2;
    final counters = <String, int>{};
    String name(String base) => '$base ${counters[base] = (counters[base] ?? 0) + 1}';

    for (final e in doc.pages[p].elements) {
      switch (e) {
        case TextBlock t:
          shapes.write(_textShape(t, boxOf(t), id++, name(textKindPresets[t.kind]!.label)));
        case ImageBlock i:
          final rid = 'rId${rels.length + 1}';
          final target = mediaFor(i.asset).replaceFirst('ppt/', '../');
          rels.add('<Relationship Id="$rid" Type="$relBase/image" Target="$target"/>');
          shapes.write(_picture(i, id++, name('Bild'), rid));
        case RectShape r:
          shapes.write(_rect(r, id++, name('Rechteck')));
        case LineShape l:
          shapes.write(_line(l, id++, name('Linie')));
        case TableBlock t:
          final b = boxOf(t);
          // ohne gemessene Höhen: gleichmässig verteilt (PowerPoint vergrössert Zeilen selbst bei Bedarf)
          final rows = rowHeightsOf?.call(t) ?? List.filled(t.rowCount, b.h / t.rowCount);
          shapes.write(_table(t, b, rows, id++, name('Tabelle')));
      }
    }
    files['ppt/slides/slide${p + 1}.xml'] = slideXml(shapes.toString());
    files['ppt/slides/_rels/slide${p + 1}.xml.rels'] = relsXml(rels);
  }

  files.addAll(packageParts(
    slideCount: doc.pages.length,
    mediaExtensions: {for (final m in media.values) m.split('.').last},
    slideWidthMm: doc.pageWidth,
    slideHeightMm: doc.pageHeight,
  ));

  final archive = Archive();
  // [Content_Types].xml zuerst (von manchen Programmen erwartet)
  final order = files.keys.toList()..sort((a, b) => a == '[Content_Types].xml' ? -1 : (b == '[Content_Types].xml' ? 1 : a.compareTo(b)));
  for (final path in order) {
    final v = files[path]!;
    if (v is String) {
      archive.addFile(ArchiveFile.string(path, v));
    } else {
      final bytes = v as Uint8List;
      archive.addFile(ArchiveFile(path, bytes.length, bytes));
    }
  }
  return ZipEncoder().encodeBytes(archive);
}

String _xfrm(Box b, {bool flipH = false, bool flipV = false, int quarterTurns = 0}) =>
    '<a:xfrm${quarterTurns % 4 != 0 ? ' rot="${(quarterTurns % 4) * 5400000}"' : ''}${flipH ? ' flipH="1"' : ''}${flipV ? ' flipV="1"' : ''}>'
    '<a:off x="${emu(b.x)}" y="${emu(b.y)}"/><a:ext cx="${emu(b.w)}" cy="${emu(b.h)}"/></a:xfrm>';

String _textShape(TextBlock t, Box rendered, int id, String name) {
  final lineSpacing = (t.size * lineHeightFactor(t.kind) * 100).round(); // Hundertstel pt
  final font = esc(fontInfos[t.effectiveFont]!.label);
  final paras = StringBuffer();
  var offset = 0;
  for (final line in t.text.split('\n')) {
    final start = offset, end = offset + line.length;
    offset = end + 1;
    paras.write('<a:p><a:pPr algn="${switch (t.align) {
      TextAlignment.left => 'l',
      TextAlignment.center => 'ctr',
      TextAlignment.right => 'r',
    }}"><a:lnSpc><a:spcPts val="$lineSpacing"/></a:lnSpc><a:spcBef><a:spcPts val="0"/></a:spcBef><a:spcAft><a:spcPts val="0"/></a:spcAft></a:pPr>');
    for (final seg in segmentsOf(t.text.length, t.runs)) {
      final a = math.max(seg.start, start), b = math.min(seg.end, end);
      if (a >= b) continue;
      final eff = t.effectiveAt(a);
      paras.write('<a:r>${_rPr(t.size, eff.bold, eff.italic, eff.underline, eff.color, font)}'
          '<a:t>${esc(t.text.substring(a, b))}</a:t></a:r>');
    }
    paras.write('<a:endParaRPr lang="de-CH" sz="${(t.size * 100).round()}" dirty="0"/></a:p>');
  }
  return '<p:sp><p:nvSpPr><p:cNvPr id="$id" name="${esc(name)}"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>'
      '<p:spPr>${_xfrm(rendered)}<a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/></p:spPr>'
      '<p:txBody><a:bodyPr wrap="square" lIns="${emu(textPadXmm)}" tIns="${emu(textPadYmm)}" rIns="${emu(textPadXmm)}" '
      'bIns="${emu(textPadYmm)}" anchor="t" rtlCol="0"><a:spAutoFit/></a:bodyPr>'
      '<a:lstStyle/>$paras</p:txBody></p:sp>';
}

String _rPr(double size, bool bold, bool italic, bool underline, int color, String font) =>
    '<a:rPr lang="de-CH" sz="${(size * 100).round()}" b="${bold ? 1 : 0}" i="${italic ? 1 : 0}" '
    'u="${underline ? 'sng' : 'none'}" dirty="0"><a:solidFill><a:srgbClr val="${hexColor(color)}"/></a:solidFill>'
    '<a:latin typeface="$font"/><a:cs typeface="$font"/></a:rPr>';

String _picture(ImageBlock i, int id, String name, String rid) {
  Box frame;
  var srcRect = '';
  if (i.fit == ImageFit.cover) {
    frame = i.box;
    // PowerPoint schneidet die ungedrehte Bilddatei zu und dreht danach die ganze Form
    final w = windowInSource(cropWindow(i), i.quarterTurns);
    int pct(double f) => (f * 100000).round();
    srcRect = '<a:srcRect l="${pct(w.x)}" t="${pct(w.y)}" r="${pct(1 - w.x - w.w)}" b="${pct(1 - w.y - w.h)}"/>';
  } else {
    // «Ganzes Bild»: Das Bild wird in seiner tatsächlichen Lage im Rahmen gezeigt.
    final p = containPlacement(i);
    frame = Box(i.box.x + p.x, i.box.y + p.y, p.w, p.h);
  }
  // Gedreht: PowerPoint erwartet die Lage vor der Drehung (um die Mitte gedreht)
  if (i.quarterTurns.isOdd) frame = Box(frame.centerX - frame.h / 2, frame.centerY - frame.w / 2, frame.h, frame.w);
  return '<p:pic><p:nvPicPr><p:cNvPr id="$id" name="${esc(name)}"/><p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>'
      '<p:blipFill><a:blip r:embed="$rid"/>$srcRect<a:stretch><a:fillRect/></a:stretch></p:blipFill>'
      '<p:spPr>${_xfrm(frame, quarterTurns: i.quarterTurns)}<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic>';
}

String _rect(RectShape r, int id, String name) {
  // Textly zeichnet den Rahmen innerhalb der Fläche, PowerPoint mittig auf der Kante:
  // Form um die halbe Rahmenstärke verkleinern, damit die Aussenkante gleich bleibt.
  final half = r.strokeWidth / 2;
  final b = Box(r.box.x + half, r.box.y + half, r.box.w - r.strokeWidth, r.box.h - r.strokeWidth);
  final geom = r.round
      ? '<a:prstGeom prst="roundRect"><a:avLst><a:gd name="adj" fmla="val ${(math.min(b.w, b.h) <= 0 ? 0 : math.max(0, rectRadiusMm - half) / math.min(b.w, b.h) * 100000).round()}"/></a:avLst></a:prstGeom>'
      : '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom>';
  final fill = (r.fill >> 24) == 0 ? '<a:noFill/>' : '<a:solidFill><a:srgbClr val="${hexColor(r.fill)}"/></a:solidFill>';
  final ln = r.strokeWidth > 0
      ? '<a:ln w="${emu(r.strokeWidth)}"><a:solidFill><a:srgbClr val="${hexColor(r.stroke)}"/></a:solidFill></a:ln>'
      : '<a:ln><a:noFill/></a:ln>';
  return '<p:sp><p:nvSpPr><p:cNvPr id="$id" name="${esc(name)}"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>'
      '<p:spPr>${_xfrm(b)}$geom$fill$ln</p:spPr></p:sp>';
}

String _line(LineShape l, int id, String name) {
  final b = Box.fromPoints(l.a, l.b);
  // Ohne Spiegelung läuft die Linie von links oben nach rechts unten.
  final flipH = (l.a.x > l.b.x) != (l.a.y > l.b.y) && b.w > 0 && b.h > 0 ? true : false;
  final flipV = false;
  return '<p:cxnSp><p:nvCxnSpPr><p:cNvPr id="$id" name="${esc(name)}"/><p:cNvCxnSpPr/><p:nvPr/></p:nvCxnSpPr>'
      '<p:spPr>${_xfrm(b, flipH: flipH, flipV: flipV)}<a:prstGeom prst="line"><a:avLst/></a:prstGeom>'
      '<a:ln w="${emu(l.width)}" cap="rnd"><a:solidFill><a:srgbClr val="${hexColor(l.color)}"/></a:solidFill></a:ln></p:spPr></p:cxnSp>';
}

/// Tabelle als echte PowerPoint-Tabelle (a:tbl). Linien und Hintergründe stehen ausdrücklich an jeder
/// Zelle (ohne Tabellenformatvorlage), damit PowerPoint sie genau so zeigt wie Textly.
String _table(TableBlock t, Box b, List<double> rowHeights, int id, String name) {
  final font = esc(fontInfos[t.effectiveFont]!.label);
  final lineSpacing = (t.size * lineHeightFactor(TextKind.body) * 100).round();
  final solidLine = '<a:solidFill><a:srgbClr val="${hexColor(t.lineColor)}"/></a:solidFill>';
  String border(String tag, bool on) => on
      ? '<a:$tag w="${emu(t.lineWidth)}" cap="flat" cmpd="sng" algn="ctr">$solidLine<a:prstDash val="solid"/></a:$tag>'
      : '<a:$tag w="0"><a:noFill/></a:$tag>';
  final lastRow = t.rowCount - 1, lastCol = t.columnCount - 1;
  final rows = StringBuffer();
  for (var r = 0; r < t.rowCount; r++) {
    final h = r < rowHeights.length ? rowHeights[r] : 6.0;
    rows.write('<a:tr h="${emu(h)}">');
    for (var c = 0; c < t.columnCount; c++) {
      final align = switch (t.align[c]) {
        TextAlignment.left => 'l',
        TextAlignment.center => 'ctr',
        TextAlignment.right => 'r',
      };
      final rPr = _rPr(t.size, t.isHeader(r), false, false, t.cellTextColor(r), font);
      final paras = StringBuffer();
      for (final line in t.cells[r][c].split('\n')) {
        paras.write('<a:p><a:pPr algn="$align"><a:lnSpc><a:spcPts val="$lineSpacing"/></a:lnSpc>'
            '<a:spcBef><a:spcPts val="0"/></a:spcBef><a:spcAft><a:spcPts val="0"/></a:spcAft></a:pPr>');
        if (line.isNotEmpty) paras.write('<a:r>$rPr<a:t>${esc(line)}</a:t></a:r>');
        paras.write('<a:endParaRPr lang="de-CH" sz="${(t.size * 100).round()}" b="${t.isHeader(r) ? 1 : 0}" dirty="0"/></a:p>');
      }
      final (left, right, top, bottom) = switch (t.lines) {
        TableLines.all => (true, true, true, true),
        TableLines.horizontal => (false, false, true, true),
        TableLines.outer => (c == 0, c == lastCol, r == 0, r == lastRow),
        TableLines.none => (false, false, false, false),
      };
      final fill = t.rowFill(r);
      final mx = emu(tableCellPadMmX + textPadXmm), my = emu(tableCellPadMmY + textPadYmm);
      rows.write('<a:tc><a:txBody><a:bodyPr/><a:lstStyle/>$paras</a:txBody>'
          '<a:tcPr marL="$mx" marR="$mx" marT="$my" marB="$my" anchor="t">'
          '${border('lnL', left)}${border('lnR', right)}${border('lnT', top)}${border('lnB', bottom)}'
          '${fill == null ? '<a:noFill/>' : '<a:solidFill><a:srgbClr val="${hexColor(fill)}"/></a:solidFill>'}'
          '</a:tcPr></a:tc>');
    }
    rows.write('</a:tr>');
  }
  final grid = [for (final w in t.columns) '<a:gridCol w="${emu(w)}"/>'].join();
  return '<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id="$id" name="${esc(name)}"/>'
      '<p:cNvGraphicFramePr><a:graphicFrameLocks noGrp="1"/></p:cNvGraphicFramePr><p:nvPr/></p:nvGraphicFramePr>'
      '<p:xfrm><a:off x="${emu(b.x)}" y="${emu(b.y)}"/><a:ext cx="${emu(b.w)}" cy="${emu(b.h)}"/></p:xfrm>'
      '<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/table">'
      '<a:tbl><a:tblPr firstRow="${t.headerRow ? 1 : 0}" bandRow="${t.zebra ? 1 : 0}"/><a:tblGrid>$grid</a:tblGrid>$rows</a:tbl>'
      '</a:graphicData></a:graphic></p:graphicFrame>';
}
