import 'package:meta/meta.dart';

import 'elements.dart';

/// Schriftarten, die Textly mitbringt (alle unter der SIL Open Font License).
/// Die Dateien liegen in app/assets/fonts; das PDF bettet sie ein.
enum TextFont { roboto, robotoCondensed, montserrat, nunito, lora, playfair, caveat }

@immutable
class FontInfo {
  const FontInfo(this.label, this.family, this.filePrefix, this.note, {this.hasItalic = true});

  /// Echter Name der Schrift (Anzeige und PowerPoint).
  final String label;

  /// Familienname in Flutter (pubspec).
  final String family;

  /// Dateien: `assets/fonts/<prefix>-Regular.ttf` usw.
  final String filePrefix;

  /// Kurze Beschreibung für die Auswahl.
  final String note;

  /// Ohne eigenen Kursivschnitt wird aufrecht gesetzt (auf dem Bildschirm wie im PDF).
  final bool hasItalic;
}

const Map<TextFont, FontInfo> fontInfos = {
  TextFont.roboto: FontInfo('Roboto', 'TextlySans', 'Sans', 'Klar und neutral'),
  TextFont.robotoCondensed: FontInfo('Roboto Condensed', 'TextlyCondensed', 'Cond', 'Schmal, für Titel'),
  TextFont.montserrat: FontInfo('Montserrat', 'TextlyMontserrat', 'Montserrat', 'Modern und breit'),
  TextFont.nunito: FontInfo('Nunito', 'TextlyNunito', 'Nunito', 'Rund und freundlich'),
  TextFont.lora: FontInfo('Lora', 'TextlyLora', 'Lora', 'Mit Serifen, gut lesbar'),
  TextFont.playfair: FontInfo('Playfair Display', 'TextlyPlayfair', 'Playfair', 'Elegant, für Titel'),
  TextFont.caveat: FontInfo('Caveat', 'TextlyCaveat', 'Caveat', 'Handschrift', hasItalic: false),
};

/// Schrift einer Textart, solange keine eigene gewählt ist.
TextFont defaultFontForKind(TextKind k) => switch (k) {
      TextKind.title || TextKind.subtitle || TextKind.heading => TextFont.robotoCondensed,
      TextKind.body || TextKind.caption => TextFont.roboto,
    };

/// Datei eines Schnitts (für das PDF).
String fontAssetPath(TextFont f, {required bool bold, required bool italic}) {
  final info = fontInfos[f]!;
  final it = italic && info.hasItalic;
  final style = bold && it ? 'BoldItalic' : bold ? 'Bold' : it ? 'Italic' : 'Regular';
  return 'assets/fonts/${info.filePrefix}-$style.ttf';
}

/// Schrift zu einem Namen, z. B. aus einer PowerPoint-Datei (Gross-/Kleinschreibung egal).
TextFont? fontByName(String name) {
  final n = name.trim().toLowerCase();
  for (final e in fontInfos.entries) {
    if (e.value.label.toLowerCase() == n) return e.key;
  }
  return null;
}
