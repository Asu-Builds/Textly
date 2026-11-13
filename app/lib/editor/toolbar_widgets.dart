import 'package:flutter/material.dart';

import '../library/autosave.dart';

/// Farben der Bedienoberfläche (Variante A der Mockups).
abstract final class Ui {
  static const accent = Color(0xFF2457D6);
  static const accentSoft = Color(0xFFEAF0FD);
  static const accentLine = Color(0xFFC9D6F8);
  static const ink = Color(0xFF1D2433);
  static const muted = Color(0xFF5B6475);
  static const line = Color(0xFFE4E7EC);
  static const bar = Colors.white;
  static const panel = Color(0xFFF8F9FB);
  static const field = Color(0xFFF2F4F7);
  static const okBg = Color(0xFFE8F5EE);
  static const okFg = Color(0xFF1B6B47);
  static const warnBg = Color(0xFFFFF3DC);
  static const warnFg = Color(0xFF8A5300);

  /// Löschen, Fehler.
  static const danger = Color(0xFFA33A22);

  /// Schrift der Bedienoberfläche (unter Windows die Systemschrift). Wo Knöpfe eine eigene Textgrösse
  /// bekommen, wird sie mitgegeben, damit überall dieselbe Schrift steht.
  static const fontFamily = 'Segoe UI';
}

/// Werkzeug mit grossem Symbol und Beschriftung darunter.
class ToolTile extends StatelessWidget {
  const ToolTile({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.tooltip,
    this.selected,
    this.width = 72,
    this.prominent = false,
  });

  /// Häufig gebraucht (Text, Bild, Tabelle): leicht hinterlegt und mit farbigem Symbol.
  final bool prominent;

  /// Breite der Kachel (schmaler in kleinen Fenstern).
  final double width;
  final Widget icon;
  final String label;
  final VoidCallback? onPressed;
  final String? tooltip;

  /// Für Schalter: an oder aus. `null` = gewöhnlicher Knopf.
  final bool? selected;

  @override
  Widget build(BuildContext context) {
    final on = selected ?? false;
    final enabled = onPressed != null;
    final fg = !enabled ? Ui.muted.withValues(alpha: .5) : (on ? Ui.accent : Ui.ink);
    final iconColor = prominent && enabled ? Ui.accent : fg;
    final tile = Semantics(
      button: true,
      toggled: selected,
      label: label,
      child: Material(
        color: on || prominent ? Ui.accentSoft : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: on || prominent ? Ui.accentLine : Colors.transparent),
        ),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(10),
          hoverColor: const Color(0xFFF0F2F6),
          child: SizedBox(
            width: width,
            height: 60,
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              IconTheme(data: IconThemeData(size: 24, color: iconColor), child: icon),
              const SizedBox(height: 5),
              // Lange Wörter («Rückgängig») in schmalen Kacheln (Laptop) leicht verkleinern statt abschneiden
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    label,
                    maxLines: 1,
                    softWrap: false,
                    style: TextStyle(fontSize: 12, fontWeight: on || prominent ? FontWeight.w600 : FontWeight.w500, color: fg),
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
    return tooltip == null ? tile : Tooltip(message: tooltip!, waitDuration: const Duration(milliseconds: 400), child: tile);
  }
}

/// Gruppe von Werkzeugen mit Überschrift darunter («Einfügen», «Ansicht» …).
class ToolGroup extends StatelessWidget {
  const ToolGroup({super.key, required this.caption, required this.children});
  final String caption;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(
            height: 60,
            child: Row(mainAxisSize: MainAxisSize.min, spacing: 4, children: children),
          ),
          const SizedBox(height: 3),
          Text(caption, style: const TextStyle(fontSize: 12, color: Ui.muted, letterSpacing: .2)),
        ]),
      );
}

class GroupDivider extends StatelessWidget {
  const GroupDivider({super.key});
  @override
  Widget build(BuildContext context) => Container(width: 1, height: 52, margin: const EdgeInsets.fromLTRB(6, 0, 6, 14), color: Ui.line);
}

/// Speicherstand neben dem Dokumentnamen: «Nicht gespeichert» bei Änderungen, «Gespeichert» nach dem
/// Speichern; ein neues, unverändertes Dokument zeigt nichts.
class SaveStatus extends StatelessWidget {
  const SaveStatus({super.key, required this.dirty, required this.hasFile});
  final bool dirty;
  final bool hasFile;

  @override
  Widget build(BuildContext context) {
    if (!dirty && !hasFile) return const SizedBox.shrink();
    final (bg, fg, icon, text) = dirty
        ? (Ui.warnBg, Ui.warnFg, Icons.circle, 'Nicht gespeichert')
        : (Ui.okBg, Ui.okFg, Icons.check_rounded, 'Gespeichert');
    return Container(
      key: const ValueKey('doc-status'),
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 9),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: dirty ? 7 : 14, color: fg),
        const SizedBox(width: 5),
        Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: fg)),
      ]),
    );
  }
}

/// Speicherstand bei automatischem Speichern («Meine Dokumente»).
class AutosaveStatus extends StatelessWidget {
  const AutosaveStatus({super.key, required this.state});
  final SaveState state;

  @override
  Widget build(BuildContext context) {
    final (bg, fg, icon, text) = switch (state) {
      SaveState.saved => (Ui.okBg, Ui.okFg, Icons.check_rounded, 'Alles gespeichert'),
      SaveState.pending || SaveState.saving => (Ui.field, Ui.muted, Icons.sync_rounded, 'Wird gespeichert …'),
      SaveState.failed => (Ui.warnBg, Ui.warnFg, Icons.error_outline_rounded, 'Nicht gespeichert'),
    };
    return Tooltip(
      message: state == SaveState.failed
          ? 'Speichern klappt gerade nicht (Datei gesperrt oder Speicher voll?). Textly versucht es alle paar Sekunden erneut.'
          : 'Textly speichert jede Änderung automatisch in «Meine Dokumente».',
      child: Container(
        key: const ValueKey('doc-status'),
        height: 24,
        padding: const EdgeInsets.symmetric(horizontal: 9),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: fg),
          const SizedBox(width: 5),
          Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: fg)),
        ]),
      ),
    );
  }
}

/// Runder Knopf mit Symbol, z. B. für den Zoom.
class RoundIconButton extends StatelessWidget {
  const RoundIconButton({super.key, required this.icon, required this.tooltip, required this.onPressed});
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: Material(
          color: Colors.white,
          shape: const CircleBorder(side: BorderSide(color: Ui.line)),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: SizedBox(width: 36, height: 36, child: Icon(icon, size: 18, color: Ui.ink)),
          ),
        ),
      );
}

/// Magnet-Symbol für «Einrasten» (in den Material-Symbolen nicht enthalten).
class MagnetIcon extends StatelessWidget {
  const MagnetIcon({super.key});
  @override
  Widget build(BuildContext context) {
    final t = IconTheme.of(context);
    return SizedBox.square(dimension: t.size ?? 24, child: CustomPaint(painter: _MagnetPainter(t.color ?? Ui.ink)));
  }
}

class _MagnetPainter extends CustomPainter {
  _MagnetPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24);
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    // U-Form: aussen Radius 6, innen Radius 2
    final path = Path()
      ..moveTo(6, 4)
      ..lineTo(6, 12)
      ..arcToPoint(const Offset(18, 12), radius: const Radius.circular(6), clockwise: false)
      ..lineTo(18, 4)
      ..lineTo(14, 4)
      ..lineTo(14, 12)
      ..arcToPoint(const Offset(10, 12), radius: const Radius.circular(2))
      ..lineTo(10, 4)
      ..close();
    canvas.drawPath(path, p);
    canvas.drawLine(const Offset(6, 8), const Offset(10, 8), p);
    canvas.drawLine(const Offset(14, 8), const Offset(18, 8), p);
  }

  @override
  bool shouldRepaint(_MagnetPainter old) => old.color != color;
}

/// Gestrichelter Rahmen (Platzhalter «Neue Seite»).
class DashedBorder extends StatelessWidget {
  const DashedBorder({super.key, required this.child, this.color = const Color(0xFFB8C0CC), this.radius = 6});
  final Widget child;
  final Color color;
  final double radius;

  @override
  Widget build(BuildContext context) => CustomPaint(painter: _DashPainter(color, radius), child: child);
}

class _DashPainter extends CustomPainter {
  _DashPainter(this.color, this.radius);
  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final path = Path()..addRRect(RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius)).deflate(.75));
    for (final m in path.computeMetrics()) {
      for (var d = 0.0; d < m.length; d += 9) {
        canvas.drawPath(m.extractPath(d, d + 5), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashPainter old) => old.color != color;
}
