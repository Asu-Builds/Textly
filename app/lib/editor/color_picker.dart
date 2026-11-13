import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'toolbar_widgets.dart';

/// Zuletzt gewählte eigene Farben (während das Programm läuft), neueste zuerst.
final List<int> recentColors = [];

/// Farbwähler für beliebige Farben: grosses Farbfeld (Helligkeit und Sättigung), Regenbogen-Leiste (Farbton),
/// zuletzt gewählte Farben und – für Geübte – der Farbcode (z. B. #1F7A5A). Ergibt die Farbe oder null.
Future<int?> showColorPicker(BuildContext context, {required int initial, String title = 'Farbe wählen'}) => showDialog<int>(
  context: context,
  builder: (_) => _ColorDialog(initial: initial, title: title),
);

class _ColorDialog extends StatefulWidget {
  const _ColorDialog({required this.initial, required this.title});
  final int initial;
  final String title;

  @override
  State<_ColorDialog> createState() => _ColorDialogState();
}

class _ColorDialogState extends State<_ColorDialog> {
  late HSVColor _hsv = HSVColor.fromColor(Color(widget.initial | 0xFF000000));
  late final _hex = TextEditingController(text: _hexOf(_value));

  int get _value => _hsv.toColor().toARGB32() | 0xFF000000;

  static String _hexOf(int c) => '#${(c & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

  void _set(HSVColor c, {bool updateHex = true}) {
    setState(() => _hsv = c);
    if (updateHex) _hex.text = _hexOf(_value);
  }

  void _fromHex(String s) {
    final t = s.trim().replaceFirst('#', '');
    if (t.length != 6) return;
    final v = int.tryParse(t, radix: 16);
    if (v != null) _set(HSVColor.fromColor(Color(0xFF000000 | v)), updateHex: false);
  }

  void _ok() {
    final v = _value;
    recentColors
      ..remove(v)
      ..insert(0, v);
    if (recentColors.length > 8) recentColors.removeLast();
    Navigator.pop(context, v);
  }

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const w = 300.0;
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: w,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Helligkeit (oben hell, unten dunkel) und Sättigung (links blass, rechts kräftig)
            _Drag(
              key: const ValueKey('color-field'),
              size: const Size(w, 170),
              onPick: (p) => _set(_hsv.withSaturation(p.dx).withValue(1 - p.dy)),
              child: CustomPaint(painter: _FieldPainter(_hsv)),
            ),
            const SizedBox(height: 12),
            // Farbton
            _Drag(
              key: const ValueKey('color-hue'),
              size: const Size(w, 22),
              onPick: (p) => _set(_hsv.withHue((p.dx * 360).clamp(0, 359.9))),
              child: CustomPaint(painter: _HuePainter(_hsv.hue)),
            ),
            const SizedBox(height: 16),
            Row(children: [
              Container(
                key: const ValueKey('color-preview'),
                width: 44,
                height: 44,
                decoration: BoxDecoration(color: Color(_value), shape: BoxShape.circle, border: Border.all(color: const Color(0x22000000))),
              ),
              const SizedBox(width: 14),
              SizedBox(
                width: 120,
                child: TextField(
                  key: const ValueKey('color-hex'),
                  controller: _hex,
                  onChanged: _fromHex,
                  onSubmitted: (_) => _ok(),
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp('[#0-9a-fA-F]')), LengthLimitingTextInputFormatter(7)],
                  decoration: const InputDecoration(isDense: true, labelText: 'Farbcode', border: OutlineInputBorder()),
                ),
              ),
            ]),
            if (recentColors.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Text('Zuletzt gewählt', style: TextStyle(fontSize: 12, color: Ui.muted)),
              const SizedBox(height: 6),
              Wrap(spacing: 8, children: [
                for (final c in recentColors)
                  InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => _set(HSVColor.fromColor(Color(c))),
                    child: Container(
                      width: 26,
                      height: 26,
                      decoration: BoxDecoration(color: Color(c), shape: BoxShape.circle, border: Border.all(color: const Color(0x22000000))),
                    ),
                  ),
              ]),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(key: const ValueKey('color-cancel'), onPressed: () => Navigator.pop(context), child: const Text('Abbrechen')),
        FilledButton(key: const ValueKey('color-ok'), onPressed: _ok, child: const Text('Übernehmen')),
      ],
    );
  }
}

/// Fläche, auf der man klickt oder zieht; meldet die Stelle als Anteil (0…1) der Breite und Höhe.
class _Drag extends StatelessWidget {
  const _Drag({super.key, required this.size, required this.onPick, required this.child});
  final Size size;
  final ValueChanged<Offset> onPick;
  final Widget child;

  void _at(Offset p) => onPick(Offset((p.dx / size.width).clamp(0, 1), (p.dy / size.height).clamp(0, 1)));

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.precise,
    child: GestureDetector(
      onTapDown: (d) => _at(d.localPosition),
      onPanUpdate: (d) => _at(d.localPosition),
      child: ClipRRect(borderRadius: BorderRadius.circular(8), child: SizedBox.fromSize(size: size, child: child)),
    ),
  );
}

class _FieldPainter extends CustomPainter {
  _FieldPainter(this.hsv);
  final HSVColor hsv;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Offset.zero & size;
    final hue = HSVColor.fromAHSV(1, hsv.hue, 1, 1).toColor();
    canvas.drawRect(r, Paint()..shader = LinearGradient(colors: [Colors.white, hue]).createShader(r));
    canvas.drawRect(r, Paint()..shader = const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Colors.black]).createShader(r));
    final p = Offset(hsv.saturation * size.width, (1 - hsv.value) * size.height);
    canvas.drawCircle(p, 8, Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 3);
    canvas.drawCircle(p, 8, Paint()..color = const Color(0x55000000)..style = PaintingStyle.stroke..strokeWidth = 1);
  }

  @override
  bool shouldRepaint(_FieldPainter old) => old.hsv != hsv;
}

class _HuePainter extends CustomPainter {
  _HuePainter(this.hue);
  final double hue;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Offset.zero & size;
    canvas.drawRect(
      r,
      Paint()..shader = LinearGradient(colors: [for (var h = 0; h <= 360; h += 60) HSVColor.fromAHSV(1, h % 360 == 0 && h > 0 ? 359.9 : h.toDouble(), 1, 1).toColor()]).createShader(r),
    );
    final x = hue / 360 * size.width;
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(x, size.height / 2), width: 8, height: size.height + 2), const Radius.circular(3)),
      Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 3,
    );
  }

  @override
  bool shouldRepaint(_HuePainter old) => old.hue != hue;
}

/// Runder Knopf «Weitere Farben» neben den Farbpunkten (Regenbogen mit Plus).
class MoreColorsButton extends StatelessWidget {
  const MoreColorsButton({super.key, required this.current, required this.onPicked, this.title = 'Farbe wählen', this.size = 26});
  final int current;
  final ValueChanged<int> onPicked;
  final String title;
  final double size;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'Weitere Farben …',
    child: InkWell(
      customBorder: const CircleBorder(),
      onTap: () async {
        final v = await showColorPicker(context, initial: current, title: title);
        if (v != null) onPicked(v);
      },
      child: Container(
        width: size,
        height: size,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          gradient: SweepGradient(colors: [Color(0xFFE53935), Color(0xFFFDD835), Color(0xFF43A047), Color(0xFF1E88E5), Color(0xFF8E24AA), Color(0xFFE53935)]),
        ),
        child: Center(
          child: Container(
            width: size * .55,
            height: size * .55,
            decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
            child: Icon(Icons.add_rounded, size: size * .45, color: Ui.ink),
          ),
        ),
      ),
    ),
  );
}
