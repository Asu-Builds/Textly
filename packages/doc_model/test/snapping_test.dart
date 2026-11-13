import 'package:doc_model/doc_model.dart';
import 'package:test/test.dart';

void main() {
  final targets = SnapTargets.forPage([const Box(50, 100, 40, 20)]); // anderes Element
  const s = SnapSettings(threshold: 1.5, grid: 5);
  const noGrid = SnapSettings(threshold: 1.5);

  test('Kante rastet an der Kante eines anderen Elements ein und zeigt eine Linie', () {
    final r = snapMove(const Box(90.8, 150.3, 30, 10), targets, s);
    expect(r.box.x, 90); // linke Kante an rechter Kante des anderen
    expect(r.guides, contains(const Guide(SnapAxis.vertical, 90)));
  });

  test('Mitten werden aneinander ausgerichtet', () {
    final r = snapMove(const Box(55.6, 180, 30, 10), targets, noGrid); // Mitte 70.6 → 70
    expect(r.box.centerX, 70);
  });

  test('Seitenmitte und Seitenrand', () {
    final mid = snapMove(const Box(94, 200, 21, 10), targets, noGrid); // Mitte 104.5 → 105
    expect(mid.box.centerX, pageWidthMm / 2);
    final margin = snapMove(const Box(16.2, 230, 30, 10), targets, noGrid);
    expect(margin.box.x, pageMarginMm);
  });

  test('ohne Ziel in der Nähe: Raster; ohne Raster: unverändert', () {
    final r = snapMove(const Box(122.4, 41.7, 30, 10), targets, s);
    expect((r.box.x, r.box.y), (120, 40));
    expect(r.guides, isEmpty);
    expect(snapMove(const Box(122.4, 41.7, 30, 10), targets, noGrid).box, const Box(122.4, 41.7, 30, 10));
  });

  test('Ausrichtung hat Vorrang vor dem Raster', () {
    final r = snapValue(89.2, SnapAxis.vertical, targets, s); // Raster wäre 90 sowieso; Ziel 90
    expect(r.value, 90);
    expect(r.guide, isNotNull);
    final g = snapValue(127.4, SnapAxis.vertical, targets, s);
    expect((g.value, g.guide), (125, null));
  });

  test('Überlappung: Berühren zählt nicht', () {
    const a = Box(0, 0, 10, 10);
    expect(overlappingIndices(a, const [Box(10, 0, 10, 10), Box(9, 9, 5, 5), Box(30, 30, 1, 1)]), [1]);
  });
}
