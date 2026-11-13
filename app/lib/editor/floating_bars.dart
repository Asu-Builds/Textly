import 'package:doc_model/doc_model.dart';
import 'package:flutter/material.dart';

import 'color_picker.dart';
import 'editor_controller.dart';
import 'properties_panel.dart' show fontSizeSteps, stepFontSize, textColors;
import 'toolbar_widgets.dart';

/// Zeigt [child] in der obersten Ebene an der Stelle [at] (Punkt auf der Seite, Koordinaten der Seite).
/// So ist eine Leiste auch über dem Seitenrand anklickbar und folgt beim Scrollen und Zoomen.
/// [child] wird in Bildschirmgrösse gebaut (der Zoom der Seite wird ausgeglichen).
class FloatingAnchor extends StatefulWidget {
  const FloatingAnchor({super.key, required this.at, required this.align, required this.zoom, required this.child});
  final Offset at;

  /// Welche Ecke der Leiste an [at] liegt (z. B. unten links = Leiste darüber).
  final Alignment align;
  final double zoom;
  final Widget child;

  @override
  State<FloatingAnchor> createState() => _FloatingAnchorState();
}

class _FloatingAnchorState extends State<FloatingAnchor> {
  final _portal = OverlayPortalController();
  final _link = LayerLink();

  @override
  void initState() {
    super.initState();
    _portal.show();
  }

  @override
  Widget build(BuildContext context) => OverlayPortal(
    controller: _portal,
    overlayChildBuilder: (_) => Stack(children: [
      CompositedTransformFollower(
        link: _link,
        showWhenUnlinked: false,
        followerAnchor: widget.align,
        child: Transform.scale(scale: 1 / widget.zoom, alignment: widget.align, child: widget.child),
      ),
    ]),
    child: Stack(clipBehavior: Clip.none, children: [
      Positioned(left: widget.at.dx, top: widget.at.dy, child: CompositedTransformTarget(link: _link, child: const SizedBox.shrink())),
    ]),
  );
}

/// Gemeinsames Aussehen der schwebenden Leisten.
class _Bar extends StatelessWidget {
  const _Bar({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => TextFieldTapRegion(
    // Klicks gehören zum Textfeld: Schreiben, Cursor und Markierung bleiben erhalten
    child: Material(
      color: Colors.white,
      elevation: 6,
      shadowColor: const Color(0x55101828),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: const BorderSide(color: Ui.line)),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Row(mainAxisSize: MainAxisSize.min, children: children),
      ),
    ),
  );
}

class _BarButton extends StatelessWidget {
  const _BarButton({super.key, required this.tooltip, required this.onTap, this.icon, this.label, this.child, this.on = false, this.danger = false});
  final String tooltip;
  final VoidCallback? onTap;
  final IconData? icon;
  final String? label;
  final Widget? child;
  final bool on, danger;

  @override
  Widget build(BuildContext context) {
    final fg = onTap == null ? Ui.muted.withValues(alpha: .5) : (danger ? Ui.danger : (on ? Ui.accent : Ui.ink));
    // Keine Tooltip-Blase: Sie müsste ihre Lage in der mitlaufenden Ebene messen, was dort nicht geht.
    // Die Bedeutung steht für Bildschirmleser in der Beschreibung.
    return Semantics(
      label: tooltip,
      button: true,
      child: Material(
        color: on ? Ui.accentSoft : Colors.transparent,
        borderRadius: BorderRadius.circular(7),
        child: InkWell(
          borderRadius: BorderRadius.circular(7),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: label == null ? 6 : 9),
              child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
                if (child != null) DefaultTextStyle.merge(style: TextStyle(color: fg), child: child!),
                if (icon != null) Icon(icon, size: 18, color: fg),
                if (icon != null && label != null) const SizedBox(width: 5),
                if (label != null) Text(label!, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500, color: fg)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _Sep extends StatelessWidget {
  const _Sep();
  @override
  Widget build(BuildContext context) => Container(width: 1, height: 20, margin: const EdgeInsets.symmetric(horizontal: 3), color: Ui.line);
}

String _fmt(double v) => (v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString()).replaceAll('.', ',');

/// Kleines Auswahlmenü unter einem Knopf der schwebenden Leiste. (Ein MenuAnchor kann seine Lage innerhalb
/// einer mitlaufenden Ebene nicht bestimmen; das Aufklappmenü rechnet erst beim Öffnen.) Danach wird
/// weitergeschrieben.
Future<void> _popup(BuildContext context, EditorController c, List<PopupMenuEntry<VoidCallback>> items) async {
  final box = context.findRenderObject()! as RenderBox;
  final overlay = Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
  final at = box.localToGlobal(Offset(0, box.size.height + 4), ancestor: overlay);
  final action = await showMenu<VoidCallback>(
    context: context,
    position: RelativeRect.fromLTRB(at.dx, at.dy, overlay.size.width - at.dx, overlay.size.height - at.dy),
    items: items,
  );
  action?.call();
  if (c.editingId != null) c.textFocus.requestFocus();
}

/// Schwebende Textleiste über dem Text, solange man schreibt: Schriftart, Grösse, Fett/Kursiv/Unterstrichen,
/// Farbe, Ausrichtung. Gilt wie die rechte Leiste für die Markierung, sonst für den ganzen Block.
class TextBar extends StatelessWidget {
  const TextBar({super.key, required this.controller, required this.block});
  final EditorController controller;
  final TextBlock block;

  @override
  Widget build(BuildContext context) {
    final c = controller, t = block;
    return _Bar(
      key: const ValueKey('float-text-bar'),
      children: [
        Builder(
          builder: (context) => _BarButton(
            key: const ValueKey('float-font'),
            tooltip: 'Schriftart',
            onTap: () => _popup(context, c, [
              PopupMenuItem(
                key: const ValueKey('float-font-default'),
                value: () => c.updateSelectedText((b) => b.withFont(null)),
                child: const TextFieldTapRegion(child: Text('Wie bei dieser Textart')),
              ),
              const PopupMenuDivider(),
              for (final f in TextFont.values)
                PopupMenuItem(
                  key: ValueKey('float-font-${f.name}'),
                  value: () => c.updateSelectedText((b) => b.withFont(f)),
                  child: TextFieldTapRegion(
                    child: Row(children: [
                      Expanded(child: Text(fontInfos[f]!.label, style: TextStyle(fontFamily: fontInfos[f]!.family, fontSize: 15))),
                      if (t.font == f) const Icon(Icons.check_rounded, size: 16, color: Ui.accent),
                    ]),
                  ),
                ),
            ]),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(fontInfos[t.effectiveFont]!.label, style: TextStyle(fontFamily: fontInfos[t.effectiveFont]!.family, fontSize: 13)),
              const Icon(Icons.expand_more_rounded, size: 16, color: Ui.muted),
            ]),
          ),
        ),
        const _Sep(),
        _BarButton(
          key: const ValueKey('float-size-minus'),
          tooltip: 'Kleiner',
          icon: Icons.remove_rounded,
          onTap: t.size <= fontSizeSteps.first ? null : () => c.updateSelectedText((b) => b.copyWith(size: stepFontSize(b.size, -1)), mergeKey: 'size'),
        ),
        SizedBox(width: 34, child: Text(_fmt(t.size), textAlign: TextAlign.center, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Ui.ink))),
        _BarButton(
          key: const ValueKey('float-size-plus'),
          tooltip: 'Grösser',
          icon: Icons.add_rounded,
          onTap: t.size >= fontSizeSteps.last ? null : () => c.updateSelectedText((b) => b.copyWith(size: stepFontSize(b.size, 1)), mergeKey: 'size'),
        ),
        const _Sep(),
        _BarButton(
          key: const ValueKey('float-bold'),
          tooltip: 'Fett (Strg+B)',
          on: c.inlineActive(InlineAttr.bold),
          onTap: () => c.toggleInline(InlineAttr.bold),
          child: const Text('F', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
        ),
        _BarButton(
          key: const ValueKey('float-italic'),
          tooltip: 'Kursiv (Strg+I)',
          on: c.inlineActive(InlineAttr.italic),
          onTap: () => c.toggleInline(InlineAttr.italic),
          child: const Text('K', style: TextStyle(fontStyle: FontStyle.italic, fontSize: 15, fontFamily: 'Georgia')),
        ),
        _BarButton(
          key: const ValueKey('float-underline'),
          tooltip: 'Unterstrichen (Strg+U)',
          on: c.inlineActive(InlineAttr.underline),
          onTap: () => c.toggleInline(InlineAttr.underline),
          child: const Text('U', style: TextStyle(decoration: TextDecoration.underline, fontSize: 14)),
        ),
        const _Sep(),
        Builder(
          builder: (context) => _BarButton(
            key: const ValueKey('float-color'),
            tooltip: 'Schriftfarbe',
            onTap: () => _popup(context, c, [
              PopupMenuItem<VoidCallback>(
                enabled: false,
                child: Builder(
                  // Farbpunkte schliessen das Menü selbst und geben die Wahl zurück
                  builder: (menu) => TextFieldTapRegion(
                    child: Wrap(spacing: 8, runSpacing: 8, children: [
                      for (final (color, name) in textColors)
                        Tooltip(
                          message: name,
                          child: InkWell(
                            key: ValueKey('float-color-${color.toRadixString(16)}'),
                            customBorder: const CircleBorder(),
                            onTap: () => Navigator.of(menu).pop<VoidCallback>(() => c.setInlineColor(color)),
                            child: Container(
                              width: 26,
                              height: 26,
                              decoration: BoxDecoration(
                                color: Color(color),
                                shape: BoxShape.circle,
                                border: Border.all(color: color == 0xFFFFFFFF ? const Color(0xFFD0D5DD) : const Color(0x14000000)),
                              ),
                            ),
                          ),
                        ),
                      MoreColorsButton(
                        key: const ValueKey('float-color-more'),
                        current: c.inlineColor() ?? t.color,
                        title: 'Schriftfarbe',
                        onPicked: (v) => Navigator.of(menu).pop<VoidCallback>(() => c.setInlineColor(v)),
                      ),
                    ]),
                  ),
                ),
              ),
            ]),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(color: Color(c.inlineColor() ?? t.color), shape: BoxShape.circle, border: Border.all(color: const Color(0x22000000))),
              ),
              const Icon(Icons.expand_more_rounded, size: 16, color: Ui.muted),
            ]),
          ),
        ),
        const _Sep(),
        for (final (a, icon, tip, key) in const [
          (TextAlignment.left, Icons.format_align_left_rounded, 'Linksbündig', 'float-align-left'),
          (TextAlignment.center, Icons.format_align_center_rounded, 'Zentriert', 'float-align-center'),
          (TextAlignment.right, Icons.format_align_right_rounded, 'Rechtsbündig', 'float-align-right'),
        ])
          _BarButton(key: ValueKey(key), tooltip: tip, icon: icon, on: t.align == a, onTap: () => c.updateSelectedText((b) => b.copyWith(align: a))),
        const _Sep(),
        _BarButton(key: const ValueKey('float-delete-text'), tooltip: 'Ganzen Textblock löschen', icon: Icons.delete_outline_rounded, danger: true, onTap: c.deleteSelected),
      ],
    );
  }
}

/// Leiste an der Auswahl: nur, was gerade Sinn ergibt. Löschen immer, Drehen bei Bildern,
/// «Nach vorne holen» bzw. «Nach hinten legen» nur, wenn sich das Element mit einem anderen überdeckt.
/// Gesperrte Elemente (z. B. aus älteren Dateien) zeigen nur «Entsperren».
class SelectionBar extends StatelessWidget {
  const SelectionBar({super.key, required this.controller, required this.element});
  final EditorController controller;
  final DocElement element;

  @override
  Widget build(BuildContext context) {
    final c = controller, e = element;
    if (e.locked) {
      return _Bar(
        key: const ValueKey('float-selection-bar'),
        children: [_BarButton(key: const ValueKey('float-unlock'), tooltip: 'Entsperren', icon: Icons.lock_open_rounded, label: 'Entsperren', onTap: c.toggleLockSelected)],
      );
    }
    final stack = c.stackingOfSelected();
    final extra = <Widget>[
      if (e is ImageBlock)
        _BarButton(key: const ValueKey('float-rotate'), tooltip: 'Um 90° drehen (Strg+R)', icon: Icons.rotate_right_rounded, label: 'Drehen', onTap: c.rotateSelectedImage),
      if (stack.above)
        _BarButton(
          key: const ValueKey('float-front'),
          tooltip: 'Über die anderen Elemente legen',
          icon: Icons.flip_to_front_rounded,
          label: 'Nach vorne holen',
          onTap: c.bringSelectedToFront,
        ),
      if (stack.below)
        _BarButton(
          key: const ValueKey('float-back'),
          tooltip: 'Unter die anderen Elemente legen',
          icon: Icons.flip_to_back_rounded,
          label: 'Nach hinten legen',
          onTap: c.sendSelectedToBack,
        ),
    ];
    return _Bar(
      key: const ValueKey('float-selection-bar'),
      children: [
        ...extra,
        if (extra.isNotEmpty) const _Sep(),
        _BarButton(
          key: const ValueKey('float-delete'),
          tooltip: 'Löschen (Entf)',
          icon: Icons.delete_outline_rounded,
          label: e is TableBlock ? 'Tabelle löschen' : 'Löschen',
          danger: true,
          onTap: c.deleteSelected,
        ),
      ],
    );
  }
}
