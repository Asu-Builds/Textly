import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../model/document.dart';
import '../pdf/pdf_export.dart' show imagePlacement;
import '../spell/spell_check.dart';
import 'text_layout.dart';

/// Zustand der Arbeitsfläche: Auswahl, Bearbeitung, Verschieben.
class EditorState extends ChangeNotifier {
  EditorState(this.doc, this.spell);
  final TextlyDocument doc;
  final SpellChecker spell;
  int pageIndex = 0;
  String? selectedId;
  String? editingId;
  final TextEditingController textController = TextEditingController();
  final FocusNode focusNode = FocusNode();
  int _revision = 0;
  int get revision => _revision;

  DocPage get page => doc.pages[pageIndex];
  DocElement? get selected => selectedId == null ? null : page.elements.where((e) => e.id == selectedId).firstOrNull;

  void changed() {
    _revision++;
    notifyListeners();
  }

  void select(String? id) {
    finishEditing();
    selectedId = id;
    notifyListeners();
  }

  void goToPage(int i) {
    finishEditing();
    pageIndex = i;
    selectedId = null;
    notifyListeners();
  }

  /// Zweiter Klick: Bearbeitung starten und den Cursor an die Klickstelle setzen.
  void startEditing(TextElement t, Offset localInBlock) {
    editingId = t.id;
    textController.text = t.text;
    final tp = layoutText(t);
    final pos = tp.getPositionForOffset(localInBlock - const Offset(kTextPadX, kTextPadY));
    textController.selection = TextSelection.collapsed(offset: pos.offset);
    notifyListeners();
    WidgetsBinding.instance.addPostFrameCallback((_) => focusNode.requestFocus());
  }

  void finishEditing() {
    final id = editingId;
    if (id == null) return;
    editingId = null;
    final el = page.elements.whereType<TextElement>().where((e) => e.id == id).firstOrNull;
    if (el != null) {
      if (textController.text.trim().isEmpty) {
        page.elements.remove(el);
        if (selectedId == id) selectedId = null;
      } else {
        el.text = textController.text;
      }
    }
    focusNode.unfocus();
    changed();
  }

  void onTextChanged(TextElement t) {
    t.text = textController.text;
    changed();
  }

  void moveBy(DocElement el, Offset deltaPt) {
    if (el.locked) return;
    final dx = deltaPt.dx / kMmToPt, dy = deltaPt.dy / kMmToPt;
    switch (el) {
      case TextElement t:
        t.x += dx;
        t.y += dy;
      case ImageElement i:
        i.x += dx;
        i.y += dy;
      case RectElement r:
        r.x += dx;
        r.y += dy;
      case LineElement l:
        l.x1 += dx;
        l.x2 += dx;
        l.y1 += dy;
        l.y2 += dy;
    }
    changed();
  }

  @override
  void dispose() {
    textController.dispose();
    focusNode.dispose();
    super.dispose();
  }
}

/// Eine Seite in Punkt-Einheiten (595 × 842). Für den Bildschirm wird sie von aussen skaliert.
class PageCanvas extends StatelessWidget {
  const PageCanvas({super.key, required this.state, required this.page, this.interactive = true});
  final EditorState state;
  final DocPage page;
  final bool interactive;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[
      Positioned.fill(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: interactive ? (_) => state.select(null) : null,
          child: const ColoredBox(color: Colors.white),
        ),
      ),
      for (final el in page.elements) _element(el),
    ];
    final sel = interactive ? state.selected : null;
    if (sel != null) children.addAll(_selectionOverlay(sel));
    return SizedBox(
      width: kPageWidthPt,
      height: kPageHeightPt,
      child: ClipRect(child: Stack(clipBehavior: Clip.none, children: children)),
    );
  }

  Widget _element(DocElement el) => switch (el) {
        TextElement t => _text(t),
        ImageElement i => _movable(i, _rectOf(i), _image(i)),
        RectElement r => _movable(r, _rectOf(r), _rect(r)),
        LineElement l => _line(l),
      };

  Rect _rectOf(DocElement el) => switch (el) {
        TextElement t => Rect.fromLTWH(t.x * kMmToPt, t.y * kMmToPt, t.w * kMmToPt, textBlockHeight(t, layoutText(t))),
        ImageElement i => Rect.fromLTWH(i.x * kMmToPt, i.y * kMmToPt, i.w * kMmToPt, i.h * kMmToPt),
        RectElement r => Rect.fromLTWH(r.x * kMmToPt, r.y * kMmToPt, r.w * kMmToPt, r.h * kMmToPt),
        LineElement l => Rect.fromPoints(Offset(l.x1, l.y1) * kMmToPt, Offset(l.x2, l.y2) * kMmToPt),
      };

  Widget _movable(DocElement el, Rect r, Widget child) => Positioned.fromRect(
        rect: r,
        child: interactive
            ? GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (_) => state.select(el.id),
                onPanStart: (_) => state.select(el.id),
                onPanUpdate: (d) => state.moveBy(el, d.delta),
                child: MouseRegion(cursor: SystemMouseCursors.move, child: child),
              )
            : child,
      );

  Widget _image(ImageElement i) {
    final p = imagePlacement(i);
    return ClipRect(
      child: Stack(children: [
        Positioned.fromRect(rect: p, child: Image.asset(i.asset, fit: BoxFit.fill, filterQuality: FilterQuality.medium)),
      ]),
    );
  }

  Widget _rect(RectElement r) => DecoratedBox(
        decoration: BoxDecoration(
          color: Color(r.fill),
          borderRadius: r.round ? BorderRadius.circular(2.5 * kMmToPt) : null,
          border: r.strokeWidth > 0 ? Border.all(color: Color(r.stroke), width: r.strokeWidth * kMmToPt) : null,
        ),
      );

  Widget _line(LineElement l) {
    final pad = math.max(4.0, l.width * kMmToPt);
    final r = _rectOf(l).inflate(pad);
    final painter = _LinePainter(l, r.topLeft);
    final child = CustomPaint(painter: painter, size: r.size);
    return Positioned.fromRect(
      rect: r,
      child: interactive
          ? GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTapDown: (_) => state.select(l.id),
              onPanStart: (_) => state.select(l.id),
              onPanUpdate: (d) => state.moveBy(l, d.delta),
              child: child,
            )
          : child,
    );
  }

  Widget _text(TextElement t) {
    final tp = layoutText(t);
    final r = _rectOf(t);
    final editing = interactive && state.editingId == t.id;
    final Widget body;
    if (editing) {
      body = Padding(
        padding: const EdgeInsets.fromLTRB(kTextPadX, kTextPadY, 0, 0),
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: textLayoutWidth(t) + kCaretMargin,
          maxWidth: textLayoutWidth(t) + kCaretMargin,
          maxHeight: double.infinity,
          child: MediaQuery.withNoTextScaling(child: _editor(t)),
        ),
      );
    } else {
      body = CustomPaint(painter: _TextPainterWidget(tp), size: r.size);
    }
    final block = ClipRect(clipBehavior: t.autoHeight ? Clip.none : Clip.hardEdge, child: body);
    return Positioned.fromRect(
      rect: r,
      child: !interactive || editing
          ? block
          : GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) {
                if (state.selectedId == t.id) {
                  state.startEditing(t, d.localPosition);
                } else {
                  state.select(t.id);
                }
              },
              child: MouseRegion(
                cursor: state.selectedId == t.id ? SystemMouseCursors.text : SystemMouseCursors.click,
                child: block,
              ),
            ),
    );
  }

  Widget _editor(TextElement t) {
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): state.finishEditing},
      child: TextField(
        controller: state.textController,
        focusNode: state.focusNode,
        style: textStyleFor(t),
        strutStyle: strutFor(t),
        textAlign: textAlignFor(t),
        maxLines: null,
        cursorWidth: kCursorWidth,
        cursorColor: const Color(0xFF2F5BD3),
        decoration: const InputDecoration.collapsed(hintText: null),
        // Eingabetaste = neue Zeile im selben Block (Entscheid Spezifikation 4.1).
        keyboardType: TextInputType.multiline,
        textInputAction: TextInputAction.newline,
        onChanged: (_) => state.onTextChanged(t),
        onTapOutside: (_) {},
        spellCheckConfiguration: state.spell.configuration(),
        contextMenuBuilder: state.spell.contextMenu,
      ),
    );
  }

  List<Widget> _selectionOverlay(DocElement el) {
    final r = _rectOf(el);
    final editing = state.editingId == el.id;
    const blue = Color(0xFF2F5BD3);
    return [
      Positioned.fromRect(
        rect: el is LineElement ? r.inflate(3) : r,
        child: IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(border: Border.all(color: blue, width: editing ? .6 : 1.2)),
          ),
        ),
      ),
      if (el is TextElement && !el.locked)
        Positioned(
          left: r.left,
          top: r.top > 22 ? r.top - 20 : r.bottom + 4,
          child: GestureDetector(
            onPanStart: (_) => state.finishEditing(),
            onPanUpdate: (d) => state.moveBy(el, d.delta),
            child: MouseRegion(
              cursor: SystemMouseCursors.grab,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(color: blue, borderRadius: BorderRadius.circular(9)),
                child: const Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.drag_indicator, size: 10, color: Colors.white),
                  SizedBox(width: 3),
                  Text('Verschieben', style: TextStyle(fontSize: 8, color: Colors.white, fontFamily: 'TextlySans')),
                ]),
              ),
            ),
          ),
        ),
    ];
  }
}

class _TextPainterWidget extends CustomPainter {
  _TextPainterWidget(this.tp);
  final TextPainter tp;
  @override
  void paint(Canvas canvas, Size size) => tp.paint(canvas, const Offset(kTextPadX, kTextPadY));
  @override
  bool shouldRepaint(_TextPainterWidget old) => true;
}

class _LinePainter extends CustomPainter {
  _LinePainter(this.l, this.origin);
  final LineElement l;
  final Offset origin;
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Color(l.color)
      ..strokeWidth = l.width * kMmToPt
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(l.x1, l.y1) * kMmToPt - origin, Offset(l.x2, l.y2) * kMmToPt - origin, p);
  }

  @override
  bool shouldRepaint(_LinePainter old) => true;
}
