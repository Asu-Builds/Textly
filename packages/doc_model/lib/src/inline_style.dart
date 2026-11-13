import 'package:meta/meta.dart';

/// Formatierung einzelner Textstellen innerhalb eines Textblocks.
///
/// Jedes Feld ist eine Abweichung vom Blockstil; `null` heisst «wie der Block».
/// Die Schriftgrösse gilt bewusst nur pro Block: Verschiedene Grössen in einer Zeile würden die
/// feste Zeilenhöhe sprengen.
///
/// Aufbau wie formatierte Textstücke in Word (w:r/w:rPr), PowerPoint (a:r/a:rPr) und Quill-Delta;
/// beim Austausch entspricht ein Textstück 1:1 einem Textstück dort.
@immutable
class InlineStyle {
  const InlineStyle({this.bold, this.italic, this.underline, this.color});

  final bool? bold, italic, underline;
  final int? color;

  static const none = InlineStyle();

  bool get isEmpty => bold == null && italic == null && underline == null && color == null;

  /// Felder aus [patch] überschreiben die eigenen.
  InlineStyle merge(InlineStyle patch) => InlineStyle(
        bold: patch.bold ?? bold,
        italic: patch.italic ?? italic,
        underline: patch.underline ?? underline,
        color: patch.color ?? color,
      );

  /// Entfernt die genannten Abweichungen (z. B. wenn der ganze Block eine neue Farbe bekommt).
  InlineStyle without({bool bold = false, bool italic = false, bool underline = false, bool color = false}) => InlineStyle(
        bold: bold ? null : this.bold,
        italic: italic ? null : this.italic,
        underline: underline ? null : this.underline,
        color: color ? null : this.color,
      );

  Map<String, dynamic> toJson() => {
        if (bold != null) 'b': bold,
        if (italic != null) 'i': italic,
        if (underline != null) 'u': underline,
        if (color != null) 'c': color,
      };

  factory InlineStyle.fromJson(Map<String, dynamic> j) => InlineStyle(
        bold: j['b'] as bool?,
        italic: j['i'] as bool?,
        underline: j['u'] as bool?,
        color: j['c'] as int?,
      );

  @override
  bool operator ==(Object other) =>
      other is InlineStyle && other.bold == bold && other.italic == italic && other.underline == underline && other.color == color;
  @override
  int get hashCode => Object.hash(bold, italic, underline, color);
  @override
  String toString() => 'InlineStyle(${toJson()})';
}

/// Eine formatierte Textstelle [start, end) mit Abweichungen vom Blockstil.
@immutable
class StyleRun {
  const StyleRun(this.start, this.end, this.style);
  final int start, end;
  final InlineStyle style;

  Map<String, dynamic> toJson() => {'s': start, 'e': end, ...style.toJson()};
  factory StyleRun.fromJson(Map<String, dynamic> j) => StyleRun(j['s'] as int, j['e'] as int, InlineStyle.fromJson(j));

  @override
  bool operator ==(Object other) => other is StyleRun && other.start == start && other.end == end && other.style == style;
  @override
  int get hashCode => Object.hash(start, end, style);
  @override
  String toString() => 'StyleRun($start–$end, $style)';
}

/// Ein Abschnitt mit einheitlicher Formatierung; zusammen decken die Abschnitte den ganzen Text ab.
@immutable
class TextSegment {
  const TextSegment(this.start, this.end, this.style);
  final int start, end;
  final InlineStyle style;
}

/// Formatierung pro Zeichen (intern; Textblöcke sind kurz, das ist einfach und robust).
List<InlineStyle> _expand(List<StyleRun> runs, int length) {
  final out = List<InlineStyle>.filled(length, InlineStyle.none);
  for (final r in runs) {
    for (var i = r.start.clamp(0, length); i < r.end.clamp(0, length); i++) {
      out[i] = r.style;
    }
  }
  return out;
}

List<StyleRun> _compress(List<InlineStyle> styles) {
  final runs = <StyleRun>[];
  var i = 0;
  while (i < styles.length) {
    var j = i + 1;
    while (j < styles.length && styles[j] == styles[i]) {
      j++;
    }
    if (!styles[i].isEmpty) runs.add(StyleRun(i, j, styles[i]));
    i = j;
  }
  return List.unmodifiable(runs);
}

/// Bereinigt: im Text, ohne Lücken-Einträge, sortiert, gleiche Nachbarn zusammengefasst.
List<StyleRun> normalizeRuns(List<StyleRun> runs, int length) => _compress(_expand(runs, length));

/// Abschnitte mit einheitlicher Formatierung über den ganzen Text (zum Zeichnen und Exportieren).
List<TextSegment> segmentsOf(int length, List<StyleRun> runs) {
  final styles = _expand(runs, length);
  final out = <TextSegment>[];
  var i = 0;
  while (i < length) {
    var j = i + 1;
    while (j < length && styles[j] == styles[i]) {
      j++;
    }
    out.add(TextSegment(i, j, styles[i]));
    i = j;
  }
  return out;
}

InlineStyle styleAt(List<StyleRun> runs, int index) {
  for (final r in runs) {
    if (index >= r.start && index < r.end) return r.style;
  }
  return InlineStyle.none;
}

/// Entfernt Abweichungen, die dem Blockstil entsprechen (z. B. «nicht fett» in einem nicht fetten Block).
List<StyleRun> simplifyRuns(List<StyleRun> runs, int length, {required bool bold, required bool italic, required int color}) =>
    _compress([
      for (final st in _expand(runs, length))
        InlineStyle(
          bold: st.bold == bold ? null : st.bold,
          italic: st.italic == italic ? null : st.italic,
          underline: st.underline == false ? null : st.underline,
          color: st.color == color ? null : st.color,
        ),
    ]);

/// Wendet [patch] auf [start, end) an.
List<StyleRun> applyInlineStyle(List<StyleRun> runs, int length, int start, int end, InlineStyle patch) {
  final styles = _expand(runs, length);
  for (var i = start.clamp(0, length); i < end.clamp(0, length); i++) {
    styles[i] = styles[i].merge(patch);
  }
  return _compress(styles);
}

/// Entfernt Abweichungen überall (z. B. weil der ganze Block die Eigenschaft bekommt).
List<StyleRun> clearInlineAttribute(List<StyleRun> runs, int length,
        {bool bold = false, bool italic = false, bool underline = false, bool color = false}) =>
    _compress([
      for (final s in _expand(runs, length)) s.without(bold: bold, italic: italic, underline: underline, color: color),
    ]);

/// Passt die Formatierung an eine Textänderung an (Tippen, Löschen, Einfügen, Rückgängig).
///
/// Ermittelt den geänderten Bereich über gemeinsamen Anfang und gemeinsames Ende. Neu eingefügter
/// Text übernimmt die Formatierung des Zeichens davor (am Textanfang: des Zeichens danach; beim
/// Überschreiben: des ersten überschriebenen Zeichens), es sei
/// denn, [inserted] gibt sie vor (z. B. nach Strg+B ohne Markierung).
///
/// [cursor]: Cursor nach der Änderung. Löst Mehrdeutigkeiten auf, wenn neben dem eingefügten Text
/// gleiche Zeichen stehen (z. B. ein Leerzeichen vor einem Leerzeichen getippt).
bool _isLowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;

List<StyleRun> runsAfterEdit(String oldText, String newText, List<StyleRun> runs, {InlineStyle? inserted, int? cursor}) {
  if (oldText == newText) return normalizeRuns(runs, newText.length);
  final old = _expand(runs, oldText.length);
  var p = 0;
  final maxP = oldText.length < newText.length ? oldText.length : newText.length;
  while (p < maxP && oldText.codeUnitAt(p) == newText.codeUnitAt(p)) {
    p++;
  }
  // Nie mitten in einem Emoji (Ersatzpaar) trennen: sonst teilt eine Formatierungsgrenze das Zeichen.
  if (p > 0 && p < oldText.length && _isLowSurrogate(oldText.codeUnitAt(p))) p--;
  var s = 0;
  while (s < oldText.length - p && s < newText.length - p &&
      oldText.codeUnitAt(oldText.length - 1 - s) == newText.codeUnitAt(newText.length - 1 - s)) {
    s++;
  }
  if (s > 0 && _isLowSurrogate(oldText.codeUnitAt(oldText.length - s))) {
    // Das gemeinsame Ende beginnt mit der zweiten Hälfte eines Paars: ganzes Paar dazunehmen,
    // falls die erste Hälfte in beiden Texten gleich ist, sonst das Paar zum geänderten Teil zählen.
    final io = oldText.length - s - 1, ino = newText.length - s - 1;
    if (io >= p && ino >= p && oldText.codeUnitAt(io) == newText.codeUnitAt(ino)) {
      s++;
    } else {
      s--;
    }
  }
  var insertedCount = newText.length - p - s;
  var deletedCount = oldText.length - p - s;
  // Reines Einfügen: Lage über den Cursor bestimmen, falls der Textvergleich mehrdeutig ist.
  if (cursor != null && deletedCount == 0 && insertedCount > 0) {
    final q = cursor - insertedCount;
    if (q >= 0 && q != p && q <= oldText.length &&
        newText.substring(0, q) == oldText.substring(0, q) &&
        newText.substring(cursor) == oldText.substring(q)) {
      p = q;
      s = oldText.length - q;
      insertedCount = newText.length - p - s;
      deletedCount = 0;
    }
  }
  // Überschreiben einer Markierung behält deren Formatierung (wie in Word), sonst die des Zeichens davor.
  final inherit = inserted ??
      (deletedCount > 0
          ? old[p]
          : p > 0
              ? old[p - 1]
              : (old.isNotEmpty ? old[0] : InlineStyle.none));
  return _compress([
    ...old.sublist(0, p),
    for (var i = 0; i < insertedCount; i++) inherit,
    ...old.sublist(oldText.length - s),
  ]);
}
