import 'document.dart';
import 'elements.dart';
import 'geometry.dart';

/// Beispieldokument (wie Prototyp v3 und Machbarkeitstest). Die Bilder verweisen auf App-Assets.
TextlyDocument sampleDocument() {
  var n = 0;
  String id() => 's${n++}';
  TextBlock t(TextKind kind, double x, double y, double w, String text) =>
      TextBlock.ofKind(id: id(), box: Box(x, y, w, 10), text: text, kind: kind);

  return TextlyDocument(pages: [
    DocPage(id: 'p1', elements: [
      t(TextKind.title, 18, 20, 174, 'Vereinsausflug ins Aletschgebiet'),
      t(TextKind.subtitle, 18, 35, 174, 'Wanderverein Oberwallis · Samstag, 12. September 2026'),
      LineShape(id: id(), a: const Pt(20, 45), b: const Pt(190, 45)),
      ImageBlock(id: id(), box: const Box(20, 52, 170, 90), asset: 'assets/images/glacier.jpg', naturalWidth: 1500, naturalHeight: 1000),
      t(TextKind.caption, 19, 143, 172, 'Blick vom Eggishorn auf den Grossen Aletschgletscher'),
      t(TextKind.heading, 19, 156, 82, 'Von der Riederalp zum Eggishorn'),
      t(TextKind.body, 19, 166, 82,
          'Um 7.40 Uhr startete die Gruppe mit 23 Mitgliedern in Brig. Mit der Luftseilbahn ging es auf die '
          'Riederalp und von dort auf dem Höhenweg durch den Aletschwald, vorbei an jahrhundertealten Arven und Lärchen.'),
      t(TextKind.body, 19, 212, 82,
          'Nach der Mittagsrast am Märjelensee erreichten wir am frühen Nachmittag das Eggishorn. Die Aussicht auf '
          'den längsten Gletscher der Alpen entschädigte für jeden Höhenmeter. Zurück ging es mit der Bahn nach Fiesch.'),
      ImageBlock(id: id(), box: const Box(108, 158, 82, 102.5), asset: 'assets/images/lake.jpg', naturalWidth: 1000, naturalHeight: 1250),
      t(TextKind.caption, 107, 262, 84, 'Abendstimmung am Märjelensee'),
    ]),
    DocPage(id: 'p2', elements: [
      t(TextKind.heading, 19, 20, 172, 'Nächster Anlass'),
      t(TextKind.body, 19, 30, 172,
          'Herbstwanderung im Baltschiedertal am Samstag, 17. Oktober 2026. Treffpunkt um 8.00 Uhr am Bahnhof Visp. '
          'Die Wanderzeit beträgt rund fünf Stunden; Verpflegung aus dem Rucksack.'),
      RectShape(id: id(), box: const Box(20, 50, 170, 26)),
      t(TextKind.body, 25, 55, 160, 'Anmeldung bis 10. Oktober beim Vorstand. Kosten für Nichtmitglieder: CHF 15.–'),
    ]),
  ]);
}
