// Vergleicht zwei PPTX-Dateien nach dem Einlesen in Textly (z. B. Original und von LibreOffice neu gespeichert).
// Aufruf: dart run tool/compare_pptx.dart original.pptx neu.pptx
import 'dart:io';

import 'package:doc_exchange/doc_exchange.dart';
import 'package:doc_model/doc_model.dart';

void main(List<String> args) {
  final a = importPptx(File(args[0]).readAsBytesSync());
  final b = importPptx(File(args[1]).readAsBytesSync());
  print('Hinweise Original: ${a.notes}');
  print('Hinweise neu:      ${b.notes}');
  var problems = 0;
  void diff(String where, String what, Object? x, Object? y) {
    if (x != y) {
      problems++;
      print('ABWEICHUNG $where – $what: $x → $y');
    }
  }

  String r(double v) => v.toStringAsFixed(2);
  String bx(Box b) => '${r(b.x)} ${r(b.y)} ${r(b.w)}×${r(b.h)}';
  for (var p = 0; p < a.document.pages.length; p++) {
    final ea = a.document.page(p).elements, eb = b.document.page(p).elements;
    diff('Seite ${p + 1}', 'Anzahl Elemente', ea.length, eb.length);
    for (var i = 0; i < ea.length && i < eb.length; i++) {
      final w = 'Seite ${p + 1}/${i + 1} ${ea[i].runtimeType}';
      diff(w, 'Typ', ea[i].runtimeType, eb[i].runtimeType);
      if (ea[i].runtimeType != eb[i].runtimeType) continue;
      diff(w, 'Lage', bx(ea[i].box), bx(eb[i].box));
      switch ((ea[i], eb[i])) {
        case (TextBlock x, TextBlock y):
          diff(w, 'Text', x.text, y.text);
          diff(w, 'Textart', x.kind, y.kind);
          diff(w, 'Grösse/fett/kursiv/Farbe', '${x.size} ${x.bold} ${x.italic} ${x.color}', '${y.size} ${y.bold} ${y.italic} ${y.color}');
          diff(w, 'Ausrichtung', '${x.align}', '${y.align}');
          diff(w, 'Formatierung', x.runs.toString(), y.runs.toString());
        case (ImageBlock x, ImageBlock y):
          diff(w, 'Ausschnitt', '${r(x.zoom)} ${r(x.cropX)} ${r(x.cropY)}', '${r(y.zoom)} ${r(y.cropX)} ${r(y.cropY)}');
        case (RectShape x, RectShape y):
          diff(w, 'Füllung/Rahmen/Ecken', '${x.fill} ${x.stroke} ${r(x.strokeWidth)} ${x.round}', '${y.fill} ${y.stroke} ${r(y.strokeWidth)} ${y.round}');
        case (LineShape x, LineShape y):
          diff(w, 'Linie', '${r(x.a.x)},${r(x.a.y)}–${r(x.b.x)},${r(x.b.y)} ${r(x.width)} ${x.color}', '${r(y.a.x)},${r(y.a.y)}–${r(y.b.x)},${r(y.b.y)} ${r(y.width)} ${y.color}');
        default:
      }
    }
  }
  print(problems == 0 ? 'KEINE ABWEICHUNGEN' : '$problems Abweichungen');
}
