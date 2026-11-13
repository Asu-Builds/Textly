import 'package:flutter/material.dart';

import '../editor/toolbar_widgets.dart';
import 'history_store.dart';

const historyRed = Color(0xFFC2410C);
const historyGreen = Color(0xFF1F9D63);
const _blue = Color(0xFF2457D6);
const _gold = Color(0xFFE0A23A);

/// Was betroffen ist (Text, Bild …) als Symbol.
IconData? _subjectIcon(String? subject) => switch (subject) {
      'text' => Icons.text_fields_rounded,
      'image' => Icons.image_outlined,
      'rect' => Icons.crop_square_rounded,
      'line' => Icons.horizontal_rule_rounded,
      'table' => Icons.table_chart_outlined,
      'page' => Icons.description_outlined,
      'doc' => Icons.crop_rotate_rounded,
      'mixed' => Icons.layers_outlined,
      _ => null,
    };

/// Was passiert ist: kleines Abzeichen unten rechts (gelöscht, verschoben, bearbeitet).
(IconData, Color)? _badge(HistoryEntry e) => switch (e.kind) {
      'delete' => (Icons.close_rounded, historyRed),
      'big' => (Icons.open_with_rounded, _blue),
      'edit' => (Icons.edit_rounded, Ui.muted),
      _ => null,
    };

/// Hauptsymbol und Farbe eines Eintrags.
(IconData, Color) _main(HistoryEntry e) {
  if (e.name != null) return (Icons.star_rounded, _gold);
  final subject = _subjectIcon(e.subject);
  return switch (e.kind) {
    'delete' => (subject ?? Icons.delete_outline_rounded, historyRed),
    'big' => (subject ?? Icons.open_with_rounded, _blue),
    'edit' => (subject ?? Icons.edit_outlined, const Color(0xFF475467)),
    'share' => (Icons.ios_share_rounded, historyGreen),
    'restore' => (Icons.history_rounded, _blue),
    'start' => (Icons.flag_outlined, const Color(0xFF475467)),
    _ => (Icons.circle_outlined, Ui.muted),
  };
}

/// Piktogramm eines Verlaufseintrags: was betroffen ist (Text, Bild, Seite …) plus ein Abzeichen für
/// das Ereignis (rot ✕ gelöscht, blau ✥ verschoben, Stift bearbeitet). Gleich in Liste und Zeitstrahl.
class HistoryPictogram extends StatelessWidget {
  const HistoryPictogram(this.entry, {super.key, this.size = 30, this.selected = false});

  final HistoryEntry entry;
  final double size;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = _main(entry);
    final badge = entry.name == null && _subjectIcon(entry.subject) != null ? _badge(entry) : null;
    final b = size * .46;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(clipBehavior: Clip.none, children: [
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: selected ? _blue : Color.lerp(color, Colors.white, .88),
            border: Border.all(color: selected ? _blue : color.withValues(alpha: .55), width: 1.5),
            boxShadow: selected ? const [BoxShadow(color: Color(0x592457D6), blurRadius: 8, offset: Offset(0, 2))] : null,
          ),
          child: Icon(icon, size: size * .55, color: selected ? Colors.white : color),
        ),
        if (badge != null)
          Positioned(
            right: -b * .25,
            bottom: -b * .2,
            child: Container(
              width: b,
              height: b,
              decoration: BoxDecoration(shape: BoxShape.circle, color: badge.$2, border: Border.all(color: Colors.white, width: 1.5)),
              child: Icon(badge.$1, size: b * .68, color: Colors.white),
            ),
          ),
      ]),
    );
  }
}

/// Piktogramm für «Jetzt» (aktueller Stand).
class NowPictogram extends StatelessWidget {
  const NowPictogram({super.key, this.size = 30, this.selected = false});

  final double size;
  final bool selected;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: selected ? _blue : Ui.accentSoft,
          border: Border.all(color: _blue, width: 1.5),
          boxShadow: selected ? const [BoxShadow(color: Color(0x592457D6), blurRadius: 8, offset: Offset(0, 2))] : null,
        ),
        child: Icon(Icons.description_rounded, size: size * .55, color: selected ? Colors.white : _blue),
      );
}
