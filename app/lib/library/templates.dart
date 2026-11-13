import 'package:doc_model/doc_model.dart';

/// Arten von Vorlagen (für den Filter «Neu beginnen» und beim Speichern einer eigenen Vorlage).
enum TemplateKind {
  einladung('Einladung', 'Einladungen'),
  flyer('Flyer / Plakat', 'Flyer & Plakate'),
  brief('Brief', 'Briefe'),
  programm('Programm', 'Programme'),
  protokoll('Protokoll', 'Protokolle'),
  andere('Andere', 'Andere');

  const TemplateKind(this.label, this.plural);

  /// Name einer einzelnen Vorlage dieser Art («Einladung»).
  final String label;

  /// Name im Filter («Einladungen»).
  final String plural;

  static TemplateKind of(String? name) => TemplateKind.values.asNameMap()[name] ?? TemplateKind.andere;
}

/// Eine mitgelieferte Vorlage: wird bei Bedarf gebaut (Bilder verweisen auf App-Assets).
class BuiltinTemplate {
  const BuiltinTemplate(this.id, this.name, this.kind, this.build);
  final String id;
  final String name;
  final TemplateKind kind;
  final TextlyDocument Function() build;
}

const _green = 0xFF1F7A5A, _ink = 0xFF1D2733, _muted = 0xFF5B6773, _white = 0xFFFFFFFF, _blue = 0xFF2F5BD3;

/// Hilfen zum Bauen der Vorlagen (Masse in mm).
class _B {
  var _n = 0;
  String id() => 'v${_n++}';

  TextBlock text(
    TextKind kind,
    double x,
    double y,
    double w,
    String text, {
    double? size,
    int? color,
    TextAlignment align = TextAlignment.left,
    TextFont? font,
    bool? bold,
  }) {
    final p = textKindPresets[kind]!;
    return TextBlock(
      id: id(),
      box: Box(x, y, w, 10),
      text: text,
      kind: kind,
      size: size ?? p.size,
      color: color ?? p.color,
      bold: bold ?? p.bold,
      italic: p.italic,
      align: align,
      font: font,
    );
  }

  RectShape rect(double x, double y, double w, double h, int fill) =>
      RectShape(id: id(), box: Box(x, y, w, h), fill: fill, stroke: fill, strokeWidth: 0, round: false);

  LineShape line(double x1, double y, double x2, {int color = _blue, double width = .6}) =>
      LineShape(id: id(), a: Pt(x1, y), b: Pt(x2, y), color: color, width: width);

  ImageBlock image(String asset, double x, double y, double w, double h, int nw, int nh) =>
      ImageBlock(id: id(), box: Box(x, y, w, h), asset: asset, naturalWidth: nw, naturalHeight: nh);

  TableBlock table(double x, double y, List<double> cols, List<List<String>> cells, {bool header = true, TableStyle style = TableStyle.header}) =>
      TableBlock(id: id(), x: x, y: y, columns: cols, cells: cells, headerRow: header).withStyle(style);
}

TextlyDocument _einladung() {
  final b = _B();
  return TextlyDocument(pages: [
    DocPage(id: 'p1', elements: [
      b.rect(0, 0, 210, 92, _green),
      b.text(TextKind.title, 20, 22, 170, 'EINLADUNG', size: 44, color: _white),
      b.text(TextKind.subtitle, 20, 46, 170, 'zur Generalversammlung 2027', size: 18, color: 0xFFD7F0E6),
      b.text(TextKind.subtitle, 20, 62, 170, 'Freitag, 12. März 2027 · 19.30 Uhr · Mehrzweckhalle Seetal', size: 12, color: _white),
      b.text(TextKind.body, 20, 108, 170,
          'Liebe Mitglieder\n\nWir laden euch herzlich zur diesjährigen Generalversammlung ein. Nach dem offiziellen Teil '
          'offeriert der Verein einen Apéro. Wir freuen uns auf einen gemütlichen Abend mit euch.',
          size: 11),
      b.text(TextKind.heading, 20, 148, 170, 'Traktanden'),
      b.table(20, 158, [20, 150], [
        ['Nr.', 'Traktandum'],
        ['1', 'Begrüssung'],
        ['2', 'Protokoll der letzten Versammlung'],
        ['3', 'Jahresbericht und Jahresrechnung'],
        ['4', 'Wahlen'],
        ['5', 'Verschiedenes'],
      ]),
      b.text(TextKind.body, 20, 222, 170, 'Bitte meldet euch bis zum 1. März beim Vorstand an.', size: 11, bold: true),
      b.line(20, 268, 190, color: _green),
      b.text(TextKind.caption, 20, 272, 170, 'Turnverein Seetal · Anna Muster, Präsidentin · anna.muster@beispiel.ch'),
    ]),
  ]);
}

TextlyDocument _flyer() {
  final b = _B();
  return TextlyDocument(paper: PaperSize.a5, pages: [
    DocPage(id: 'p1', elements: [
      b.image('assets/images/lake.jpg', 0, 0, 148, 82, 1000, 1250),
      b.text(TextKind.title, 12, 92, 124, 'Sommerfest', size: 32),
      b.text(TextKind.subtitle, 12, 110, 124, 'Samstag, 4. Juli · ab 14 Uhr · Schulhausplatz', size: 11, color: _green),
      b.text(TextKind.body, 12, 124, 124,
          'Musik, Spiele für Gross und Klein, Grill und Kuchenbuffet. Bei jedem Wetter – der Festplatz ist gedeckt.',
          size: 9.5),
      b.rect(12, 160, 124, 22, 0xFFE8F5EE),
      b.text(TextKind.body, 16, 165, 116, 'Eintritt frei · Kollekte für die Jugendriege', size: 10, color: _green, bold: true, align: TextAlignment.center),
      b.text(TextKind.caption, 12, 196, 124, 'Turnverein Seetal · www.beispiel.ch', align: TextAlignment.center),
    ]),
  ]);
}

TextlyDocument _brief() {
  final b = _B();
  return TextlyDocument(pages: [
    DocPage(id: 'p1', elements: [
      b.text(TextKind.heading, 20, 15, 110, 'Turnverein Seetal', color: _blue),
      b.text(TextKind.caption, 20, 23, 110, 'Postfach 12 · 5703 Seon · info@beispiel.ch'),
      b.line(20, 32, 190),
      b.text(TextKind.body, 20, 48, 85, 'Frau\nMaria Beispiel\nDorfstrasse 1\n5703 Seon', size: 11),
      b.text(TextKind.body, 120, 80, 70, 'Seon, 12. Januar 2027', size: 11, align: TextAlignment.right),
      b.text(TextKind.heading, 20, 98, 170, 'Betreff des Briefes'),
      b.text(TextKind.body, 20, 110, 170,
          'Sehr geehrte Frau Beispiel\n\nHier steht der Text des Briefes. Klicke hinein und schreibe einfach darüber.\n\n'
          'Freundliche Grüsse\n\n\nAnna Muster\nPräsidentin',
          size: 11),
    ]),
  ]);
}

TextlyDocument _protokoll() {
  final b = _B();
  return TextlyDocument(pages: [
    DocPage(id: 'p1', elements: [
      b.text(TextKind.title, 20, 18, 170, 'Protokoll'),
      b.text(TextKind.subtitle, 20, 34, 170, 'Vorstandssitzung'),
      b.table(20, 46, [40, 130], [
        ['Datum', '12. Januar 2027, 19.30 – 21.00 Uhr'],
        ['Ort', 'Vereinslokal'],
        ['Anwesend', 'Anna Muster, Peter Beispiel, …'],
        ['Protokoll', 'Maria Beispiel'],
      ], header: false, style: TableStyle.grid),
      b.text(TextKind.heading, 20, 84, 170, 'Traktanden und Beschlüsse'),
      b.table(20, 94, [14, 76, 80], [
        ['Nr.', 'Traktandum', 'Beschluss / Wer macht was'],
        ['1', 'Begrüssung', ''],
        ['2', 'Jahresprogramm', ''],
        ['3', 'Finanzen', ''],
        ['4', 'Verschiedenes', ''],
      ]),
      b.text(TextKind.heading, 20, 160, 170, 'Nächste Sitzung'),
      b.text(TextKind.body, 20, 170, 170, 'Datum, Zeit und Ort der nächsten Sitzung.', size: 11),
    ]),
  ]);
}

TextlyDocument _plakat() {
  final b = _B();
  return TextlyDocument(paper: PaperSize.a3, pages: [
    DocPage(id: 'p1', elements: [
      b.rect(0, 0, 297, 420, 0xFFFFB547),
      b.text(TextKind.title, 24, 30, 249, 'KONZERT', size: 110, color: _ink),
      b.text(TextKind.subtitle, 24, 82, 249, 'Jahreskonzert der Musikgesellschaft', size: 26, color: _ink),
      b.image('assets/images/glacier.jpg', 24, 112, 249, 166, 1500, 1000),
      b.text(TextKind.heading, 24, 292, 249, 'Samstag, 18. April · 20 Uhr', size: 40, color: _ink),
      b.text(TextKind.body, 24, 316, 249, 'Mehrzweckhalle Seetal · Türöffnung 19 Uhr · Eintritt frei, Kollekte', size: 20, color: _ink),
      b.rect(0, 380, 297, 40, _ink),
      b.text(TextKind.body, 24, 392, 249, 'www.beispiel.ch', size: 18, color: _white, align: TextAlignment.center),
    ]),
  ]);
}

TextlyDocument _programm() {
  final b = _B();
  return TextlyDocument(pages: [
    DocPage(id: 'p1', elements: [
      b.text(TextKind.subtitle, 20, 18, 170, 'TURNVEREIN SEETAL', size: 10, color: _green, bold: true),
      b.text(TextKind.title, 20, 26, 170, 'Jahresprogramm 2027'),
      b.text(TextKind.body, 20, 46, 170, 'Unsere Anlässe im neuen Vereinsjahr. Änderungen teilen wir per E-Mail mit.', size: 11, color: _muted),
      b.table(20, 60, [32, 98, 40], [
        ['Datum', 'Anlass', 'Ort'],
        ['12. März', 'Generalversammlung', 'Mehrzweckhalle'],
        ['18. April', 'Frühlingswanderung', 'Treffpunkt Bahnhof'],
        ['4. Juli', 'Sommerfest', 'Schulhausplatz'],
        ['12. September', 'Vereinsausflug', 'Aletschgebiet'],
        ['5. Dezember', 'Chlausabend', 'Vereinslokal'],
      ]),
      b.text(TextKind.heading, 20, 132, 170, 'Trainings'),
      b.text(TextKind.body, 20, 142, 170, 'Jeden Dienstag, 19.30 – 21 Uhr, Turnhalle Seetal. Neue Mitglieder sind jederzeit willkommen.', size: 11),
    ]),
  ]);
}

/// Mit Textly mitgelieferte Vorlagen.
const builtinTemplates = [
  BuiltinTemplate('einladung', 'Einladung', TemplateKind.einladung, _einladung),
  BuiltinTemplate('flyer', 'Flyer', TemplateKind.flyer, _flyer),
  BuiltinTemplate('brief', 'Brief mit Briefkopf', TemplateKind.brief, _brief),
  BuiltinTemplate('programm', 'Jahresprogramm', TemplateKind.programm, _programm),
  BuiltinTemplate('protokoll', 'Protokoll', TemplateKind.protokoll, _protokoll),
  BuiltinTemplate('plakat', 'Plakat', TemplateKind.flyer, _plakat),
];
