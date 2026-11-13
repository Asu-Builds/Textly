import 'package:doc_model/doc_model.dart';
import 'package:doc_render/doc_render.dart';
import 'package:flutter/material.dart';

import 'color_picker.dart';
import 'crop_editor.dart';
import 'editor_controller.dart';
import 'toolbar_widgets.dart';

const _cardLine = Color(0xFFE4E7EC);
const _selectedBg = Color(0xFFF5F8FF);

/// Schriftgrössen-Stufen in pt (Spezifikation 4.1: «Schriftgrösse in festen Stufen»).
const fontSizeSteps = <double>[7, 8, 8.5, 9, 10, 10.5, 11, 12, 13, 14, 16, 18, 20, 22, 24, 26, 28, 32, 36, 40, 48, 60, 72];

/// Schriftfarben (kleine Palette, Weiss für Text auf dunklen Flächen).
const textColors = <(int, String)>[
  (0xFF1D2733, 'Schwarzblau'),
  (0xFF5B6773, 'Grau'),
  (0xFF2F5BD3, 'Blau'),
  (0xFF1F7A5A, 'Grün'),
  (0xFFB4442C, 'Rot'),
  (0xFFC98A12, 'Ocker'),
  (0xFFFFFFFF, 'Weiss'),
];

/// Füllfarben für Rechtecke (helle Flächen für Infokästen, kräftige für Balken, «Keine»).
const fillColors = <(int, String)>[
  (0xFFE8EEF7, 'Hellblau'),
  (0xFFE7F3EC, 'Hellgrün'),
  (0xFFFBEBE4, 'Hellrot'),
  (0xFFF7F0DC, 'Hellocker'),
  (0xFF1D2733, 'Dunkel'),
  (0xFF2F5BD3, 'Blau'),
  (0x00FFFFFF, 'Keine'),
];

/// Rahmen- und Linienfarben.
const strokeColors = <(int, String)>[
  (0xFF1D2733, 'Schwarzblau'),
  (0xFF5B6773, 'Grau'),
  (0xFF2F5BD3, 'Blau'),
  (0xFF1F7A5A, 'Grün'),
  (0xFFB4442C, 'Rot'),
  (0xFFC98A12, 'Ocker'),
];

/// Nächste Stufe nach oben (+1) bzw. unten (−1); Werte zwischen den Stufen rasten auf die nächste ein.
double stepFontSize(double size, int direction) {
  if (direction > 0) {
    return fontSizeSteps.firstWhere((s) => s > size + .01, orElse: () => fontSizeSteps.last);
  }
  return fontSizeSteps.lastWhere((s) => s < size - .01, orElse: () => fontSizeSteps.first);
}

/// Eigene Farbe (falls nicht in der Palette) als gewählter Punkt und der Knopf «Weitere Farben …».
List<Widget> _custom(String key, int current, Iterable<int> palette, ValueChanged<int> onPicked, {String title = 'Farbe wählen'}) => [
  if (!palette.contains(current)) _Swatch(key: ValueKey('$key-custom'), color: current, name: 'Eigene Farbe', selected: true, onTap: () {}),
  MoreColorsButton(key: ValueKey('$key-more'), current: current, onPicked: onPicked, title: title),
];

String _fmt(double v) => (v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString()).replaceAll('.', ',');

/// Rechte Leiste: zeigt nur die Einstellungen, die zum ausgewählten Element passen (Spezifikation 6).
/// Aufbau «Sichtbare Vorlagen»: Auswahlmöglichkeiten zeigen ihre Wirkung (Textarten in ihrer Schrift,
/// Rahmen als Linien); Kopieren, Ebenen, Sperren und Löschen stehen in einer Fusszeile.
class PropertiesPanel extends StatelessWidget {
  const PropertiesPanel({super.key, required this.controller, this.onReplaceImage});
  final EditorController controller;

  /// «Anderes Bild wählen» (öffnet den Dateidialog der Hauptansicht).
  final VoidCallback? onReplaceImage;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final e = c.selected;
    final children = <Widget>[];

    if (e == null) {
      children.addAll(_pageSections());
    } else {
      children.add(
        _Header(
          icon: switch (e) {
            TextBlock _ => Icons.title_rounded,
            ImageBlock _ => Icons.image_outlined,
            RectShape _ => Icons.rectangle_outlined,
            LineShape _ => Icons.horizontal_rule_rounded,
            TableBlock _ => Icons.table_chart_outlined,
          },
          title: switch (e) {
            TextBlock _ => 'Text',
            ImageBlock _ => 'Bild',
            RectShape _ => 'Fläche',
            LineShape _ => 'Linie',
            TableBlock t => 'Tabelle · ${t.columnCount} ${t.columnCount == 1 ? 'Spalte' : 'Spalten'}, ${t.rowCount} ${t.rowCount == 1 ? 'Zeile' : 'Zeilen'}',
          },
          hint: switch (e) {
            _ when e.locked => 'Gesperrt. Zum Ändern unter dem Element auf «Entsperren» klicken.',
            TextBlock t when c.editingId == t.id => 'Du schreibst gerade. Klicke daneben, um fertig zu werden.',
            TextBlock _ => 'In den Text klicken, um zu schreiben. Verschieben am Griff «Verschieben».',
            TableBlock t when c.editingId == t.id => 'Du schreibst in einer Zelle. Tab springt in die nächste.',
            TableBlock _ => 'In eine Zelle klicken, um zu schreiben. Am Griff «Verschieben» bewegen.',
            LineShape _ => 'Ziehen zum Verschieben, Endpunkte einzeln ziehen.',
          _ => 'Ziehen zum Verschieben, Griffe für die Grösse.',
          },
        ),
      );
      final sections = switch (e) {
        TextBlock t => _textSections(context, t),
        ImageBlock i => _imageSections(i),
        RectShape r => _rectSections(r),
        LineShape l => _lineSections(l),
        TableBlock t => _tableSections(t),
      };
      if (e.locked) {
        // Gesperrt: Einstellungen sichtbar, aber nicht bedienbar (entsperren über die Fusszeile)
        children.add(Opacity(
          key: const ValueKey('prop-locked'),
          opacity: .45,
          child: IgnorePointer(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: sections)),
        ));
      } else {
        children.addAll(sections);
        children.addAll(_overlapSection(context, e));
      }
    }

    // Klicks in der Leiste gelten für das Textfeld als «innen»: Beim Schreiben bleiben Cursor und
    // Markierung erhalten, während Grösse, Farbe usw. geändert werden.
    return TextFieldTapRegion(
      child: Container(
        color: Colors.white,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ListView(padding: const EdgeInsets.fromLTRB(18, 18, 18, 18), children: children),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- nichts ausgewählt

  List<Widget> _pageSections() {
    final c = controller;
    final landscape = c.doc.orientation == PageOrientation.landscape;
    // Elemente aller Seiten, die über den Papierrand hinausragen (z. B. nach dem Umschalten)
    final outside = printIssues(c.doc).where((i) => i.kind == PrintIssueKind.cutOff).length;
    return [
      Text(
        'Seite ${c.pageIndex + 1} von ${c.doc.pages.length}',
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Ui.ink),
      ),
      const SizedBox(height: 3),
      Text(
        '${c.doc.paper.label} ${landscape ? 'Querformat' : 'Hochformat'} · ${_fmt(c.doc.pageWidth)} × ${_fmt(c.doc.pageHeight)} mm',
        style: const TextStyle(fontSize: 12, color: Ui.muted),
      ),
      const _Gap(),
      const _Title('Papiergrösse'),
      Builder(
        builder: (context) => Row(children: [
          for (final (i, p) in PaperSize.values.indexed) ...[
            if (i > 0) const SizedBox(width: 8),
            Expanded(
              child: _OptionCard(
                key: ValueKey('prop-paper-${p.name}'),
                selected: c.doc.paper == p,
                onTap: () => _setPaper(context, p),
                // Muster in echten Grössenverhältnissen (A3 = doppelte Fläche von A4)
                child: _OrientationSample(label: p.label, w: p.shortMm / 7.2, h: p.longMm / 7.2, box: 86),
              ),
            ),
          ],
        ]),
      ),
      const SizedBox(height: 6),
      const _Hint('A5: Flyer, Karten, Hefte · A4: Briefe, Einladungen · A3: Plakate'),
      const _Gap(),
      const _Title('Hoch- oder Querformat'),
      Row(children: [
        Expanded(
          child: _OptionCard(
            key: const ValueKey('prop-orient-portrait'),
            selected: !landscape,
            onTap: () => c.setOrientation(PageOrientation.portrait),
            child: const _OrientationSample(label: 'Hochformat', w: 21, h: 29.7),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _OptionCard(
            key: const ValueKey('prop-orient-landscape'),
            selected: landscape,
            onTap: () => c.setOrientation(PageOrientation.landscape),
            child: const _OrientationSample(label: 'Querformat', w: 29.7, h: 21),
          ),
        ),
      ]),
      const SizedBox(height: 8),
      const _Hint('Gilt für alle Seiten. Die Elemente bleiben, wo sie sind; was danach über den Rand ragt, zeigt die Vorschau.'),
      if (outside > 0) ...[
        const SizedBox(height: 8),
        Container(
          key: const ValueKey('prop-outside'),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: Ui.warnBg, borderRadius: BorderRadius.circular(8)),
          child: Text(
            outside == 1 ? '1 Element ragt über den Seitenrand.' : '$outside Elemente ragen über den Seitenrand.',
            style: const TextStyle(fontSize: 12, color: Ui.warnFg),
          ),
        ),
      ],
      const _Gap(),
      const _Title('Raster'),
      _SwitchRow(key: const ValueKey('prop-grid'), label: 'Raster anzeigen', value: c.showGrid, onChanged: c.setShowGrid),
      _SwitchRow(key: const ValueKey('prop-snap'), label: 'Beim Verschieben einrasten', value: c.snapToGrid, onChanged: c.setSnapToGrid),
      const SizedBox(height: 6),
      Row(children: [
        const Text('Rasterweite', style: TextStyle(fontSize: 12.5, color: Ui.muted)),
        const SizedBox(width: 12),
        Expanded(
          child: SegmentedButton<double>(
            key: const ValueKey('prop-grid-size'),
            showSelectedIcon: false,
            style: SegmentedButton.styleFrom(visualDensity: VisualDensity.compact, textStyle: const TextStyle(fontFamily: Ui.fontFamily, fontSize: 12.5)),
            segments: const [ButtonSegment(value: 5, label: Text('5 mm')), ButtonSegment(value: 10, label: Text('10 mm'))],
            selected: {c.gridSize},
            onSelectionChanged: (v) => c.setGridSize(v.first),
          ),
        ),
      ]),
      const SizedBox(height: 8),
      const _Hint('Alt-Taste beim Ziehen: kurz nicht einrasten.'),
      const _Gap(),
      const _Title('So funktioniert es'),
      const _Hint(
        'Klick in einen Text oder eine Tabellenzelle: sofort schreiben. Bilder und Formen: Klick wählt aus. '
        'Textblöcke verschiebst du am Griff «Verschieben», Bilder und Formen direkt. '
        'Runde Eckgriffe ändern die Grösse, längliche Seitengriffe die Form.',
      ),
    ];
  }

  /// Papiergrösse umstellen; alles wird mitskaliert. Eine Meldung sagt es und bietet «Rückgängig».
  void _setPaper(BuildContext context, PaperSize p) {
    final c = controller;
    final from = c.doc.paper;
    if (from == p) return;
    c.setPaper(p);
    c.offerUndo();
    final percent = (p.shortMm / from.shortMm * 100).round();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        key: const ValueKey('paper-changed'),
        persist: false,
        duration: const Duration(seconds: 8),
        content: Text(
          'Auf ${p.label} umgestellt. Alles wurde ${percent < 100 ? 'mitverkleinert' : 'mitvergrössert'} ($percent %), damit die Seite gleich aussieht.',
        ),
        action: SnackBarAction(label: 'Rückgängig', onPressed: c.undoOffered),
      ));
  }

  // ---------------------------------------------------------------- Text

  List<Widget> _textSections(BuildContext context, TextBlock t) {
    final c = controller;
    return [
      const _Title('Wie soll der Text aussehen?'),
      for (final k in TextKind.values)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: _KindOption(
            key: ValueKey('prop-kind-${k.name}'),
            kind: k,
            font: t.font ?? defaultFontForKind(k),
            selected: t.kind == k,
            onTap: () => c.updateSelectedText((b) => b.withKind(k)),
          ),
        ),
      const _Gap(),
      const _Title('Feinheiten', small: true),
      _FontPicker(
        value: t.effectiveFont,
        isDefault: t.font == null,
        kindDefault: defaultFontForKind(t.kind),
        bold: t.bold,
        onChanged: (f) => c.updateSelectedText((b) => b.withFont(f)),
      ),
      const SizedBox(height: 10),
      Row(
        children: [
          _Stepper(
            value: _fmt(t.size),
            onMinus: t.size <= fontSizeSteps.first
                ? null
                : () => c.updateSelectedText((b) => b.copyWith(size: stepFontSize(b.size, -1)), mergeKey: 'size'),
            onPlus: t.size >= fontSizeSteps.last
                ? null
                : () => c.updateSelectedText((b) => b.copyWith(size: stepFontSize(b.size, 1)), mergeKey: 'size'),
          ),
          const Spacer(),
          _StyleToggle(
            key: const ValueKey('prop-bold'),
            tooltip: 'Fett (Strg+B)',
            selected: c.inlineActive(InlineAttr.bold),
            onTap: () => c.toggleInline(InlineAttr.bold),
            child: const Text('F', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
          ),
          const SizedBox(width: 4),
          _StyleToggle(
            key: const ValueKey('prop-italic'),
            tooltip: 'Kursiv (Strg+I)',
            selected: c.inlineActive(InlineAttr.italic),
            onTap: () => c.toggleInline(InlineAttr.italic),
            child: const Text(
              'K',
              style: TextStyle(fontStyle: FontStyle.italic, fontSize: 15, fontFamily: 'Georgia'),
            ),
          ),
          const SizedBox(width: 4),
          _StyleToggle(
            key: const ValueKey('prop-underline'),
            tooltip: 'Unterstrichen (Strg+U)',
            selected: c.inlineActive(InlineAttr.underline),
            onTap: () => c.toggleInline(InlineAttr.underline),
            child: const Text('U', style: TextStyle(decoration: TextDecoration.underline, fontSize: 14)),
          ),
        ],
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 2,
        runSpacing: 4,
        children: [
          for (final (color, name) in textColors)
            _Swatch(
              key: ValueKey('prop-color-${color.toRadixString(16)}'),
              color: color,
              name: name,
              selected: c.inlineColor() == color,
              onTap: () => c.setInlineColor(color),
            ),
          ..._custom('prop-color', c.inlineColor() ?? t.color, [for (final (v, _) in textColors) v], (v) {
            c.setInlineColor(v);
            if (c.editingId != null) c.textFocus.requestFocus(); // weiterschreiben
          }, title: 'Schriftfarbe'),
        ],
      ),
      const SizedBox(height: 8),
      // Farbe und Schriftstil wirken beim Schreiben auf die Markierung, sonst auf den ganzen Block.
      Container(
        key: const ValueKey('prop-scope'),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(color: c.hasTextSelection ? Ui.accentSoft : Ui.field, borderRadius: BorderRadius.circular(8)),
        child: Text(
          c.hasTextSelection
              ? 'Farbe und Stil gelten für den markierten Text.'
              : 'Farbe und Stil gelten für den ganzen Block. Markiere beim Schreiben Wörter, um nur diese zu ändern.',
          style: TextStyle(fontSize: 12, height: 1.35, color: c.hasTextSelection ? Ui.accent : Ui.muted),
        ),
      ),
      const SizedBox(height: 12),
      _IconSegments<TextAlignment>(
        value: t.align,
        options: const [
          (TextAlignment.left, Icons.format_align_left_rounded, 'Linksbündig', 'prop-align-left'),
          (TextAlignment.center, Icons.format_align_center_rounded, 'Zentriert', 'prop-align-center'),
          (TextAlignment.right, Icons.format_align_right_rounded, 'Rechtsbündig', 'prop-align-right'),
        ],
        onChanged: (v) => c.updateSelectedText((b) => b.copyWith(align: v)),
      ),
    ];
  }

  // ---------------------------------------------------------------- Tabelle

  List<Widget> _tableSections(TableBlock t) {
    final c = controller;
    final col = (c.activeCell?.col ?? 0).clamp(0, t.columnCount - 1);
    return [
      const _Title('Wie soll die Tabelle aussehen?'),
      Row(children: [
        for (final (i, style) in TableStyle.values.indexed) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            child: _OptionCard(
              key: ValueKey('prop-table-style-${style.name}'),
              selected: t.style == style,
              onTap: () => c.updateSelectedTable((x) => x.withStyle(style)),
              padding: const EdgeInsets.fromLTRB(8, 10, 8, 8),
              child: Column(children: [
                SizedBox(height: 40, child: _TableSample(style: style, headerColor: t.headerColor)),
                const SizedBox(height: 6),
                Text(
                  style == TableStyle.header ? 'Kopfzeile farbig' : 'Gitter',
                  style: TextStyle(fontSize: 12, fontWeight: t.style == style ? FontWeight.w600 : FontWeight.w400, color: Ui.ink),
                ),
              ]),
            ),
          ),
        ],
      ]),
      const SizedBox(height: 8),
      _SwitchRow(
        key: const ValueKey('prop-table-header'),
        label: 'Erste Zeile als Überschrift',
        value: t.headerRow,
        onChanged: (v) => c.updateSelectedTable((x) => x.copyWith(headerRow: v)),
      ),
      const _Gap(),
      const _Title('Text in der Tabelle', small: true),
      _FontPicker(
        value: t.effectiveFont,
        isDefault: t.font == null,
        kindDefault: defaultFontForKind(TextKind.body),
        bold: false,
        onChanged: (f) => c.updateSelectedTable((x) => x.withFont(f)),
      ),
      const SizedBox(height: 8),
      // Schriftgrösse wie bei Textblöcken (gleiche Stufen); mehrere Klicks sind ein Rückgängig-Schritt
      Row(
        children: [
          _Stepper(
            key: const ValueKey('prop-table-size'),
            value: _fmt(t.size),
            onMinus: t.size <= fontSizeSteps.first
                ? null
                : () => c.updateSelectedTable((x) => x.copyWith(size: stepFontSize(x.size, -1)), mergeKey: 'size'),
            onPlus: t.size >= fontSizeSteps.last
                ? null
                : () => c.updateSelectedTable((x) => x.copyWith(size: stepFontSize(x.size, 1)), mergeKey: 'size'),
          ),
        ],
      ),
      const SizedBox(height: 10),
      Text('Ausrichtung in Spalte ${col + 1}', style: const TextStyle(fontSize: 12, color: Ui.muted)),
      const SizedBox(height: 6),
      _IconSegments<TextAlignment>(
        value: t.align[col],
        options: const [
          (TextAlignment.left, Icons.format_align_left_rounded, 'Linksbündig', 'prop-table-align-left'),
          (TextAlignment.center, Icons.format_align_center_rounded, 'Zentriert', 'prop-table-align-center'),
          (TextAlignment.right, Icons.format_align_right_rounded, 'Rechtsbündig (z. B. Preise)', 'prop-table-align-right'),
        ],
        onChanged: (v) => c.updateSelectedTable((x) => x.copyWith(align: [for (var i = 0; i < x.columnCount; i++) i == col ? v : x.align[i]])),
      ),
      const _Gap(),
      const _Title('Linien', small: true),
      _Segmented<TableLines>(
        keyPrefix: 'prop-table-lines',
        value: t.lines,
        options: const [(TableLines.all, 'Alle'), (TableLines.horizontal, 'Waagrecht'), (TableLines.outer, 'Aussen'), (TableLines.none, 'Keine')],
        onChanged: (v) => c.updateSelectedTable((x) => x.copyWith(lines: v)),
      ),
      if (t.lines != TableLines.none) ...[
        const SizedBox(height: 10),
        Wrap(spacing: 2, runSpacing: 4, children: [
          for (final (color, name) in const [(0xFFC4CBD6, 'Hellgrau'), (0xFF475467, 'Dunkelgrau'), (0xFF1F7A5A, 'Grün'), (0xFF2F5BD3, 'Blau')])
            _Swatch(
              key: ValueKey('prop-table-line-${color.toRadixString(16)}'),
              color: color,
              name: name,
              selected: t.lineColor == color,
              onTap: () => c.updateSelectedTable((x) => x.copyWith(lineColor: color)),
            ),
          ..._custom('prop-table-line', t.lineColor, const [0xFFC4CBD6, 0xFF475467, 0xFF1F7A5A, 0xFF2F5BD3],
              (v) => c.updateSelectedTable((x) => x.copyWith(lineColor: v)), title: 'Linienfarbe'),
        ]),
        const SizedBox(height: 8),
        _Segmented<double>(
          keyPrefix: 'prop-table-weight',
          value: t.lineWidth > (tableLineFine + tableLineStrong) / 2 ? tableLineStrong : tableLineFine,
          options: const [(tableLineFine, 'Fein'), (tableLineStrong, 'Kräftig')],
          onChanged: (v) => c.updateSelectedTable((x) => x.copyWith(lineWidth: v)),
        ),
      ],
      const _Gap(),
      const _Title('Farben', small: true),
      if (t.style == TableStyle.header && t.headerRow) ...[
        const Text('Kopfzeile', style: TextStyle(fontSize: 12, color: Ui.muted)),
        const SizedBox(height: 6),
        Wrap(spacing: 2, runSpacing: 4, children: [
          for (final (color, name) in const [(0xFF1F7A5A, 'Grün'), (0xFF2F5BD3, 'Blau'), (0xFFB4442C, 'Rot'), (0xFF1D2733, 'Dunkel')])
            _Swatch(
              key: ValueKey('prop-table-head-${color.toRadixString(16)}'),
              color: color,
              name: name,
              selected: t.headerColor == color,
              onTap: () => c.updateSelectedTable((x) => x.copyWith(headerColor: color)),
            ),
          ..._custom('prop-table-head', t.headerColor, const [0xFF1F7A5A, 0xFF2F5BD3, 0xFFB4442C, 0xFF1D2733],
              (v) => c.updateSelectedTable((x) => x.copyWith(headerColor: v)), title: 'Farbe der Kopfzeile'),
        ]),
        const SizedBox(height: 6),
      ],
      _SwitchRow(
        key: const ValueKey('prop-table-zebra'),
        label: 'Zeilen abwechselnd einfärben',
        value: t.zebra,
        onChanged: (v) => c.updateSelectedTable((x) => x.copyWith(zebra: v)),
      ),
      const _Gap(),
      const _Title('Zeilen und Spalten', small: true),
      Align(
        alignment: Alignment.centerLeft,
        child: _SmallButton(key: const ValueKey('prop-table-equal'), label: 'Spalten gleich breit', onTap: () => c.updateSelectedTable((x) => x.withEqualColumns())),
      ),
      const SizedBox(height: 8),
      const _Hint(
        'Klicke in eine Zelle: «+ Spalte» und «+ Zeile» erscheinen direkt an der Zelle, «Zeile löschen» und '
        '«Spalte löschen» am Rand der Tabelle. Zeigst du darauf, siehst du vorher, was passiert. '
        'Rechtsklick in eine Zelle: auch «Zeile darüber» und «Spalte links». Senkrechte Linien ziehen ändert die Spaltenbreite.',
      ),
    ];
  }

  // ---------------------------------------------------------------- Bild

  List<Widget> _imageSections(ImageBlock i) {
    final c = controller;
    final cover = i.fit == ImageFit.cover;
    return [
      const _Title('Wie soll das Bild in den Rahmen?'),
      Row(
        children: [
          Expanded(
            child: _OptionCard(
              key: const ValueKey('prop-fit-Fläche füllen'),
              selected: cover,
              onTap: () => c.updateSelectedImage((b) => b.copyWith(fit: ImageFit.cover)),
              child: const _CardText(icon: Icons.crop_free_rounded, title: 'Fläche füllen', note: 'Rand wird abgeschnitten'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _OptionCard(
              key: const ValueKey('prop-fit-Ganzes Bild'),
              selected: !cover,
              onTap: () => c.updateSelectedImage((b) => b.copyWith(fit: ImageFit.contain)),
              child: const _CardText(icon: Icons.fit_screen_outlined, title: 'Ganzes Bild', note: 'Nichts geht verloren'),
            ),
          ),
        ],
      ),
      if (cover) ...[
        const _Gap(),
        const _Title('Ausschnitt wählen', small: true),
        CropEditor(controller: c, block: i),
        const SizedBox(height: 6),
        const _Hint('Rahmen in der Mitte fassen und verschieben. An den weissen Griffen ziehen, um das Bild zuzuschneiden.'),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _SmallButton(
                key: const ValueKey('crop-zoom-in'),
                label: 'Näher',
                onTap: i.zoom >= maxCropZoom ? null : () => c.updateSelectedImage((b) => withCropZoom(b, b.zoom * 1.25), mergeKey: 'cropzoom'),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _SmallButton(
                key: const ValueKey('crop-zoom-out'),
                label: 'Weiter weg',
                onTap: i.zoom <= minCropZoom ? null : () => c.updateSelectedImage((b) => withCropZoom(b, b.zoom / 1.25), mergeKey: 'cropzoom'),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _SmallButton(
                key: const ValueKey('crop-reset'),
                label: 'Zurücksetzen',
                onTap: i.zoom == 1 && i.cropX == .5 && i.cropY == .5 ? null : () => c.updateSelectedImage(withCropReset),
              ),
            ),
          ],
        ),
      ],
      const _Gap(),
      Row(
        children: [
          Expanded(
            child: _TileButton(
              key: const ValueKey('img-rotate-left'),
              icon: Icons.rotate_left_rounded,
              label: 'Links drehen',
              tooltip: 'Bild nach links drehen (Strg+Umschalt+R)',
              onTap: i.locked ? null : () => c.rotateSelectedImage(clockwise: false),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: _TileButton(
              key: const ValueKey('img-rotate-right'),
              icon: Icons.rotate_right_rounded,
              label: 'Rechts drehen',
              tooltip: 'Bild nach rechts drehen (Strg+R)',
              onTap: i.locked ? null : () => c.rotateSelectedImage(),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: _TileButton(
              key: const ValueKey('img-replace'),
              icon: Icons.swap_horiz_rounded,
              label: 'Ersetzen',
              tooltip: 'Anderes Bild wählen; Rahmen bleibt',
              onTap: onReplaceImage,
            ),
          ),
        ],
      ),
      if (hasChangedShape(i)) ...[
        const SizedBox(height: 10),
        _SmallButton(
          key: const ValueKey('img-original-shape'),
          label: 'Ursprüngliche Bildform wiederherstellen',
          onTap: () => c.updateSelectedImage(withOriginalShape),
        ),
      ],
    ];
  }

  // ---------------------------------------------------------------- Fläche

  List<Widget> _rectSections(RectShape r) {
    final c = controller;
    return [
      const _Title('Farbe'),
      GridView.count(
        crossAxisCount: 4,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: .95,
        children: [
          for (final (color, name) in fillColors)
            _ColorTile(
              key: ValueKey('prop-fill-${color.toRadixString(16)}'),
              color: color,
              name: name,
              selected: r.fill == color,
              onTap: () => c.updateSelectedRect((s) => s.copyWith(fill: color)),
            ),
        ],
      ),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        const Text('Eigene Farbe', style: TextStyle(fontSize: 12, color: Ui.muted)),
        ..._custom('prop-fill', r.fill, [for (final (v, _) in fillColors) v], (v) => c.updateSelectedRect((s) => s.copyWith(fill: v)), title: 'Füllfarbe'),
      ]),
      const _Gap(),
      const _Title('Rahmen'),
      Row(
        children: [
          for (final (i, (w, label)) in const [(0.0, 'Kein'), (.3, 'Fein'), (.6, 'Mittel'), (1.2, 'Kräftig')].indexed) ...[
            if (i > 0) const SizedBox(width: 6),
            Expanded(
              child: _OptionCard(
                key: ValueKey('prop-stroke-$label'),
                selected: r.strokeWidth == w,
                onTap: () => c.updateSelectedRect((s) => s.copyWith(strokeWidth: w)),
                child: _ShapeSample(label: label, border: w == 0 ? 0 : (w * 2.5).clamp(1, 3), fill: r.fill),
              ),
            ),
          ],
        ],
      ),
      if (r.strokeWidth > 0) ...[
        const SizedBox(height: 10),
        Wrap(
          spacing: 2,
          runSpacing: 4,
          children: [
            for (final (color, name) in strokeColors)
              _Swatch(
                key: ValueKey('prop-strokecolor-${color.toRadixString(16)}'),
                color: color,
                name: name,
                selected: r.stroke == color,
                onTap: () => c.updateSelectedRect((s) => s.copyWith(stroke: color)),
              ),
            ..._custom('prop-strokecolor', r.stroke, [for (final (v, _) in strokeColors) v], (v) => c.updateSelectedRect((s) => s.copyWith(stroke: v)),
                title: 'Rahmenfarbe'),
          ],
        ),
      ],
      const _Gap(),
      const _Title('Ecken'),
      Row(
        children: [
          Expanded(
            child: _OptionCard(
              key: const ValueKey('prop-corners-Eckig'),
              selected: !r.round,
              onTap: () => c.updateSelectedRect((s) => s.copyWith(round: false)),
              child: _ShapeSample(label: 'Eckig', border: 1.5, radius: 0, fill: r.fill, row: true),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: _OptionCard(
              key: const ValueKey('prop-corners-Abgerundet'),
              selected: r.round,
              onTap: () => c.updateSelectedRect((s) => s.copyWith(round: true)),
              child: _ShapeSample(label: 'Abgerundet', border: 1.5, radius: 6, fill: r.fill, row: true),
            ),
          ),
        ],
      ),
    ];
  }

  // ---------------------------------------------------------------- Linie

  List<Widget> _lineSections(LineShape l) {
    final c = controller;
    return [
      const _Title('Farbe'),
      Wrap(
        spacing: 2,
        runSpacing: 4,
        children: [
          for (final (color, name) in strokeColors)
            _Swatch(
              key: ValueKey('prop-linecolor-${color.toRadixString(16)}'),
              color: color,
              name: name,
              selected: l.color == color,
              onTap: () => c.updateSelectedLine((s) => s.copyWith(color: color)),
            ),
          ..._custom('prop-linecolor', l.color, [for (final (v, _) in strokeColors) v], (v) => c.updateSelectedLine((s) => s.copyWith(color: v)),
              title: 'Linienfarbe'),
        ],
      ),
      const _Gap(),
      const _Title('Stärke'),
      Row(
        children: [
          for (final (i, (w, label)) in const [(.3, 'Fein'), (.6, 'Mittel'), (1.2, 'Kräftig'), (2.5, 'Balken')].indexed) ...[
            if (i > 0) const SizedBox(width: 6),
            Expanded(
              child: _OptionCard(
                key: ValueKey('prop-linewidth-$label'),
                selected: l.width == w,
                onTap: () => c.updateSelectedLine((s) => s.copyWith(width: w)),
                child: SizedBox(
                  height: 44,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(width: 30, height: (w * 2.4).clamp(1, 6), color: Color(l.color)),
                      const SizedBox(height: 8),
                      Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, color: Ui.ink),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
      const SizedBox(height: 10),
      const _Hint('Die Endpunkte lassen sich einzeln ziehen. In der Nähe der Waagrechten oder Senkrechten rastet die Linie gerade ein.'),
    ];
  }

  // ---------------------------------------------------------------- Überlappung

  List<Widget> _overlapSection(BuildContext context, DocElement e) {
    final c = controller;
    final overlaps = c.overlapsOfSelected();
    if (overlaps.isEmpty) return const [];
    return [
      const SizedBox(height: 14),
      Container(
        key: const ValueKey('prop-overlap'),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: Ui.warnBg, borderRadius: BorderRadius.circular(10)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              overlaps.length == 1
                  ? 'Dieses Element überdeckt ein anderes (orange markiert).'
                  : 'Dieses Element überdeckt ${overlaps.length} andere (orange markiert).',
              style: const TextStyle(fontSize: 12, height: 1.35, color: Ui.warnFg),
            ),
            const SizedBox(height: 8),
            _SmallButton(
              key: const ValueKey('move-below'),
              label: 'Darunter verschieben',
              onTap: e.locked
                  ? null
                  : () {
                      if (!c.moveSelectedBelowOverlaps()) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Unten ist nicht genug Platz. Mach den Block kleiner oder verschiebe ihn auf eine andere Seite.'),
                          ),
                        );
                      }
                    },
            ),
          ],
        ),
      ),
    ];
  }
}

// ==================================================================== Bausteine

class _Header extends StatelessWidget {
  const _Header({required this.icon, required this.title, required this.hint});
  final IconData icon;
  final String title, hint;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 18),
    child: Row(
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(color: Ui.accentSoft, borderRadius: BorderRadius.circular(9)),
          child: Icon(icon, size: 19, color: Ui.accent),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Ui.ink),
              ),
              const SizedBox(height: 1),
              Text(hint, style: const TextStyle(fontSize: 12, color: Ui.muted)),
            ],
          ),
        ),
      ],
    ),
  );
}

class _Title extends StatelessWidget {
  const _Title(this.text, {this.small = false});
  final String text;
  final bool small;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Text(
      text,
      style: TextStyle(fontSize: small ? 13 : 14.5, fontWeight: FontWeight.w600, color: Ui.ink),
    ),
  );
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Text(text, style: const TextStyle(fontSize: 12, height: 1.4, color: Ui.muted));
}

class _Gap extends StatelessWidget {
  const _Gap();
  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(vertical: 16),
    child: Divider(height: 1, color: Color(0xFFEDEFF3)),
  );
}

/// Auswählbare Karte mit Rahmen; die gewählte ist blau umrandet.
class _OptionCard extends StatelessWidget {
  const _OptionCard({super.key, required this.selected, required this.onTap, required this.child, this.padding = const EdgeInsets.all(10)});
  final bool selected;
  final VoidCallback? onTap;
  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    button: true,
    child: Material(
      color: selected ? _selectedBg : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: selected ? Ui.accent : _cardLine, width: selected ? 1.5 : 1),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(padding: padding, child: child),
      ),
    ),
  );
}

/// Textart als Vorschau in ihrer eigenen Schrift.
class _KindOption extends StatelessWidget {
  const _KindOption({super.key, required this.kind, required this.font, required this.selected, required this.onTap});
  final TextKind kind;
  final TextFont font;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = textKindPresets[kind]!;
    final size = switch (kind) {
      TextKind.title => 22.0,
      TextKind.subtitle || TextKind.heading => 15.0,
      TextKind.body => 13.0,
      TextKind.caption => 11.5,
    };
    return _OptionCard(
      selected: selected,
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      child: Row(
        children: [
          Expanded(
            child: Text(
              kind == TextKind.body ? 'Fliesstext für Absätze' : p.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: fontInfos[font]!.family,
                fontSize: size,
                height: 1.15,
                fontWeight: p.bold ? FontWeight.w700 : FontWeight.w400,
                fontStyle: p.italic ? FontStyle.italic : FontStyle.normal,
                color: Color(p.color),
              ),
            ),
          ),
          if (selected) const Icon(Icons.check_rounded, size: 18, color: Ui.accent),
        ],
      ),
    );
  }
}

/// Auswahl der Schriftart; jede Schrift wird in sich selbst gezeigt.
class _FontPicker extends StatelessWidget {
  const _FontPicker({required this.value, required this.isDefault, required this.kindDefault, required this.bold, required this.onChanged});
  final TextFont value;
  final bool isDefault;
  final TextFont kindDefault;
  final bool bold;
  final ValueChanged<TextFont?> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget item(String key, TextFont f, String? caption, bool checked, VoidCallback onPressed) => TextFieldTapRegion(
      child: MenuItemButton(
        key: ValueKey(key),
        onPressed: onPressed,
        trailingIcon: checked ? const Icon(Icons.check_rounded, size: 18, color: Ui.accent) : null,
        style: MenuItemButton.styleFrom(minimumSize: const Size(280, 48)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              fontInfos[f]!.label,
              style: TextStyle(fontFamily: fontInfos[f]!.family, fontSize: 16, color: Ui.ink),
            ),
            Text(caption ?? fontInfos[f]!.note, style: const TextStyle(fontSize: 12, color: Ui.muted)),
          ],
        ),
      ),
    );
    return MenuAnchor(
      menuChildren: [
        item('prop-font-default', kindDefault, 'Wie bei dieser Textart', isDefault, () => onChanged(null)),
        const Divider(height: 8),
        for (final f in TextFont.values) item('prop-font-${f.name}', f, null, !isDefault && f == value, () => onChanged(f)),
      ],
      builder: (context, menu, _) => Material(
        color: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: Color(0xFFD0D5DD)),
        ),
        child: InkWell(
          key: const ValueKey('prop-font'),
          borderRadius: BorderRadius.circular(8),
          onTap: () => menu.isOpen ? menu.close() : menu.open(),
          child: SizedBox(
            height: 42,
            child: Row(
              children: [
                const SizedBox(width: 12),
                const SizedBox(
                  width: 66,
                  child: Text('Schriftart', style: TextStyle(fontSize: 12, color: Ui.muted)),
                ),
                Expanded(
                  child: Text(
                    fontInfos[value]!.label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: fontInfos[value]!.family,
                      fontSize: 15,
                      fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
                      color: Ui.ink,
                    ),
                  ),
                ),
                const Icon(Icons.expand_more_rounded, size: 18, color: Ui.muted),
                const SizedBox(width: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({super.key, required this.value, required this.onMinus, required this.onPlus});
  final String value;
  final VoidCallback? onMinus, onPlus;

  @override
  Widget build(BuildContext context) {
    Widget btn(String key, IconData icon, String tip, VoidCallback? onTap) => IconButton(
      key: ValueKey(key),
      tooltip: tip,
      onPressed: onTap,
      icon: Icon(icon, size: 18),
      color: Ui.ink,
      style: IconButton.styleFrom(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        minimumSize: const Size(34, 36),
        padding: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
      ),
    );
    return Container(
      height: 38,
      decoration: BoxDecoration(
        border: Border.all(color: _cardLine),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          btn('prop-size-minus', Icons.remove_rounded, 'Kleiner', onMinus),
          SizedBox(
            width: 52,
            child: Text(
              value,
              key: const ValueKey('prop-size-value'),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Ui.ink, fontFeatures: [FontFeature.tabularFigures()]),
            ),
          ),
          btn('prop-size-plus', Icons.add_rounded, 'Grösser', onPlus),
        ],
      ),
    );
  }
}

class _StyleToggle extends StatelessWidget {
  const _StyleToggle({super.key, required this.tooltip, required this.selected, required this.onTap, required this.child});
  final String tooltip;
  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Material(
      color: selected ? Ui.accentSoft : const Color(0xFFF5F6F8),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: SizedBox(
          width: 38,
          height: 38,
          child: Center(
            child: DefaultTextStyle.merge(
              style: TextStyle(color: selected ? Ui.accent : Ui.ink),
              child: child,
            ),
          ),
        ),
      ),
    ),
  );
}

/// Wenige Möglichkeiten als Symbole in einer Reihe (z. B. Ausrichtung).
class _IconSegments<T> extends StatelessWidget {
  const _IconSegments({required this.value, required this.options, required this.onChanged});
  final T value;
  final List<(T, IconData, String, String)> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(color: Ui.field, borderRadius: BorderRadius.circular(9)),
    child: Row(
      children: [
        for (final (i, (v, icon, tip, key)) in options.indexed) ...[
          if (i > 0) const SizedBox(width: 3),
          Expanded(
            child: Tooltip(
              message: tip,
              child: Material(
                color: v == value ? Colors.white : Colors.transparent,
                elevation: v == value ? 1 : 0,
                shadowColor: const Color(0x22101828),
                borderRadius: BorderRadius.circular(7),
                child: InkWell(
                  key: ValueKey(key),
                  borderRadius: BorderRadius.circular(7),
                  onTap: () => onChanged(v),
                  child: SizedBox(height: 32, child: Icon(icon, size: 18, color: v == value ? Ui.ink : Ui.muted)),
                ),
              ),
            ),
          ),
        ],
      ],
    ),
  );
}

/// Wenige Möglichkeiten als Text in einer Reihe (z. B. Rastergrösse).
class _Segmented<T> extends StatelessWidget {
  const _Segmented({required this.keyPrefix, required this.value, required this.options, required this.onChanged});
  final String keyPrefix;
  final T value;
  final List<(T, String)> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(color: Ui.field, borderRadius: BorderRadius.circular(9)),
    child: Row(
      children: [
        for (final (i, (v, label)) in options.indexed) ...[
          if (i > 0) const SizedBox(width: 3),
          Expanded(
            child: Material(
              color: v == value ? Colors.white : Colors.transparent,
              elevation: v == value ? 1 : 0,
              shadowColor: const Color(0x22101828),
              borderRadius: BorderRadius.circular(7),
              child: InkWell(
                key: ValueKey('$keyPrefix-$label'),
                borderRadius: BorderRadius.circular(7),
                onTap: () => onChanged(v),
                child: SizedBox(
                  height: 32,
                  child: Center(
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: v == value ? FontWeight.w600 : FontWeight.w400,
                        color: v == value ? Ui.ink : Ui.muted,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    ),
  );
}

class _CardText extends StatelessWidget {
  const _CardText({required this.icon, required this.title, required this.note});
  final IconData icon;
  final String title, note;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, size: 22, color: Ui.ink),
      const SizedBox(height: 8),
      Text(
        title,
        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Ui.ink),
      ),
      const SizedBox(height: 2),
      Text(note, style: const TextStyle(fontSize: 12, color: Ui.muted)),
    ],
  );
}

/// Kleines Blatt im Seitenverhältnis von A4 hoch bzw. quer.
class _OrientationSample extends StatelessWidget {
  const _OrientationSample({required this.label, required this.w, required this.h, this.box = 64});
  final String label;
  final double w, h;

  /// Höhe des Kärtcheninhalts (gleich für alle Kärtchen einer Reihe).
  final double box;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: box,
        child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
          Container(
            width: w,
            height: h,
            decoration: BoxDecoration(color: Colors.white, border: Border.all(color: Ui.ink, width: 1.4), borderRadius: BorderRadius.circular(2)),
          ),
          const SizedBox(height: 7),
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Ui.ink)),
        ]),
      );
}

/// Kleines Muster einer Fläche, um Rahmen und Ecken zu zeigen.
class _ShapeSample extends StatelessWidget {
  const _ShapeSample({required this.label, required this.border, required this.fill, this.radius = 3, this.row = false});
  final String label;
  final double border, radius;
  final int fill;
  final bool row;

  @override
  Widget build(BuildContext context) {
    final sample = Container(
      width: 28,
      height: 18,
      decoration: BoxDecoration(
        color: (fill >> 24) == 0 ? Colors.white : Color(fill),
        borderRadius: BorderRadius.circular(radius),
        border: border > 0 ? Border.all(color: Ui.ink, width: border) : Border.all(color: const Color(0xFFD9DDE3)),
      ),
    );
    final text = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 12, color: Ui.ink),
    );
    return SizedBox(
      height: row ? 30 : 44,
      child: row
          ? Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                sample,
                const SizedBox(width: 8),
                Flexible(child: text),
              ],
            )
          : Column(mainAxisAlignment: MainAxisAlignment.center, children: [sample, const SizedBox(height: 7), text]),
    );
  }
}

class _ColorTile extends StatelessWidget {
  const _ColorTile({super.key, required this.color, required this.name, required this.selected, required this.onTap});
  final int color;
  final String name;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final none = (color >> 24) == 0;
    return Semantics(
      label: name,
      selected: selected,
      button: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Column(
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: none ? Colors.white : Color(color),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: none ? const Color(0xFFB8C0CC) : const Color(0x14000000)),
                  boxShadow: selected ? const [BoxShadow(color: Colors.white, spreadRadius: 2), BoxShadow(color: Ui.accent, spreadRadius: 4)] : null,
                ),
                child: none ? const Center(child: Icon(Icons.block, size: 18, color: Ui.muted)) : null,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: selected ? Ui.ink : Ui.muted, fontWeight: selected ? FontWeight.w600 : FontWeight.w400),
            ),
          ],
        ),
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({super.key, required this.color, required this.name, required this.selected, required this.onTap});
  final int color;
  final String name;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: name,
    child: InkWell(
      customBorder: const CircleBorder(),
      onTap: onTap,
      child: SizedBox(
        width: 32,
        height: 32,
        child: Center(
          child: Container(
        width: 26,
        height: 26,
        decoration: BoxDecoration(
          color: Color(color),
          shape: BoxShape.circle,
          border: Border.all(color: color == 0xFFFFFFFF ? const Color(0xFFD0D5DD) : const Color(0x14000000)),
          boxShadow: selected ? const [BoxShadow(color: Colors.white, spreadRadius: 2), BoxShadow(color: Ui.accent, spreadRadius: 4)] : null,
        ),
      ),
        ),
      ),
    ),
  );
}

class _SmallButton extends StatelessWidget {
  const _SmallButton({super.key, required this.label, required this.onTap});
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => OutlinedButton(
    onPressed: onTap,
    style: OutlinedButton.styleFrom(
      minimumSize: const Size(0, 34),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      foregroundColor: Ui.ink,
      side: const BorderSide(color: _cardLine),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      textStyle: const TextStyle(fontFamily: Ui.fontFamily, fontSize: 12),
    ),
    child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
  );
}

/// Kachel mit Symbol und Beschriftung (Drehen, Ersetzen).
class _TileButton extends StatelessWidget {
  const _TileButton({super.key, required this.icon, required this.label, required this.tooltip, required this.onTap});
  final IconData icon;
  final String label, tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final fg = onTap == null ? Ui.muted.withValues(alpha: .5) : Ui.ink;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: _cardLine),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: SizedBox(
            height: 60,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 20, color: fg),
                const SizedBox(height: 5),
                Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, height: 1.15, color: fg),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Fusszeile: Kopie, Ebenen, Sperren und Löschen für jedes Element – Symbol mit Beschriftung.
class _SwitchRow extends StatelessWidget {
  const _SwitchRow({super.key, required this.label, required this.value, required this.onChanged});
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(8),
    onTap: () => onChanged(!value),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Transform.scale(
            scale: .8,
            alignment: Alignment.centerLeft,
            child: Switch(value: value, onChanged: onChanged, activeTrackColor: Ui.accent),
          ),
          Expanded(child: Text(label, style: const TextStyle(fontSize: 13, color: Ui.ink))),
        ],
      ),
    ),
  );
}

/// Kleines Bild einer Tabellenvorlage.
class _TableSample extends StatelessWidget {
  const _TableSample({required this.style, required this.headerColor});
  final TableStyle style;
  final int headerColor;

  @override
  Widget build(BuildContext context) => CustomPaint(painter: _TableSamplePainter(style, headerColor), size: Size.infinite);
}

class _TableSamplePainter extends CustomPainter {
  _TableSamplePainter(this.style, this.headerColor);
  final TableStyle style;
  final int headerColor;

  @override
  void paint(Canvas canvas, Size size) {
    final rows = 3, cols = 3;
    final rh = size.height / rows, cw = size.width / cols;
    if (style == TableStyle.header) canvas.drawRect(Rect.fromLTWH(0, 0, size.width, rh), Paint()..color = Color(headerColor));
    final line = Paint()
      ..color = Color(style == TableStyle.header ? 0xFFC4CBD6 : 0xFF475467)
      ..strokeWidth = 1;
    for (var r = 0; r <= rows; r++) {
      canvas.drawLine(Offset(0, r * rh), Offset(size.width, r * rh), line);
    }
    for (var c = 0; c <= cols; c++) {
      canvas.drawLine(Offset(c * cw, 0), Offset(c * cw, size.height), line);
    }
    final text = Paint()..color = const Color(0xFF98A2B3);
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        final head = r == 0;
        canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromLTWH(c * cw + 4, r * rh + rh / 2 - 1.5, cw * (head ? .55 : .45), 3), const Radius.circular(1.5)),
          head ? (Paint()..color = style == TableStyle.header ? Colors.white : const Color(0xFF1D2733)) : text,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_TableSamplePainter old) => old.style != style || old.headerColor != headerColor;
}
