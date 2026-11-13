import 'package:doc_model/doc_model.dart';

/// Art einer Änderung (für Farbe und Symbol im Verlauf).
enum ChangeKind { add, delete, move, resize, edit, style, page, other }

class Change {
  const Change(this.kind, this.text);
  final ChangeKind kind;
  final String text;
}

/// Beschreibt in Alltagssprache, was sich zwischen zwei Ständen geändert hat,
/// z. B. «Text «Anmeldung» gelöscht», «Bild vergrössert», «Text verschoben».
List<Change> describeChanges(TextlyDocument before, TextlyDocument after) {
  final out = <Change>[];
  if (before.orientation != after.orientation) {
    out.add(Change(ChangeKind.page, after.orientation == PageOrientation.landscape ? 'Auf Querformat umgestellt' : 'Auf Hochformat umgestellt'));
  }
  if (before.paper != after.paper) {
    // alles wurde mitskaliert: nur das Format nennen, nicht jedes Element
    out.add(Change(ChangeKind.page, 'Auf ${after.paper.label} umgestellt'));
    return out;
  }
  final pagesBefore = {for (final p in before.pages) p.id};
  final pagesAfter = {for (final p in after.pages) p.id};
  final addedPages = pagesAfter.difference(pagesBefore).length;
  final removedPages = pagesBefore.difference(pagesAfter).length;
  if (addedPages > 0) out.add(Change(ChangeKind.page, addedPages == 1 ? 'Seite hinzugefügt' : '$addedPages Seiten hinzugefügt'));
  if (removedPages > 0) out.add(Change(ChangeKind.delete, removedPages == 1 ? 'Seite gelöscht' : '$removedPages Seiten gelöscht'));
  if (addedPages == 0 && removedPages == 0 && before.pages.map((p) => p.id).join() != after.pages.map((p) => p.id).join()) {
    out.add(const Change(ChangeKind.page, 'Seiten umgestellt'));
  }

  // Elemente seitenübergreifend nach ID vergleichen (gelöschte Seiten zählen oben schon)
  Map<String, DocElement> byId(TextlyDocument d, Set<String> pages) => {
        for (final p in d.pages)
          if (pages.contains(p.id))
            for (final e in p.elements) e.id: e,
      };
  final common = pagesBefore.intersection(pagesAfter);
  final a = byId(before, common), b = byId(after, pagesAfter);
  for (final e in b.values) {
    if (!a.containsKey(e.id) && !(byId(before, pagesBefore).containsKey(e.id))) out.add(Change(ChangeKind.add, '${_name(e)} eingefügt'));
  }
  for (final e in a.values) {
    if (!b.containsKey(e.id)) out.add(Change(ChangeKind.delete, '${_name(e)} gelöscht'));
  }
  for (final e in b.values) {
    final old = a[e.id];
    if (old == null || identical(old, e)) continue;
    final c = _elementChange(old, e);
    if (c != null) out.add(c);
  }
  // Reihenfolge (nach vorne/hinten) auf einer Seite
  for (final id in common) {
    final pa = before.pages.firstWhere((p) => p.id == id), pb = after.pages.firstWhere((p) => p.id == id);
    final oa = [for (final e in pa.elements) if (pb.find(e.id) != null) e.id];
    final ob = [for (final e in pb.elements) if (pa.find(e.id) != null) e.id];
    if (oa.join('|') != ob.join('|') && out.isEmpty) out.add(const Change(ChangeKind.other, 'Reihenfolge geändert'));
  }
  return out;
}

/// Eine Zeile für die Liste: eine Änderung, oder zwei, oder «… und N weitere».
String summarize(List<Change> changes) {
  if (changes.isEmpty) return 'Keine sichtbare Änderung';
  if (changes.length == 1) return changes.first.text;
  if (changes.length == 2) return '${changes[0].text}, ${changes[1].text}';
  return '${changes[0].text} und ${changes.length - 1} weitere Änderungen';
}

/// Wichtigste Art (gelöscht vor allem anderen, damit Löschungen im Verlauf auffallen).
ChangeKind mainKind(List<Change> changes) {
  if (changes.any((c) => c.kind == ChangeKind.delete)) return ChangeKind.delete;
  return changes.isEmpty ? ChangeKind.other : changes.first.kind;
}

Change? _elementChange(DocElement a, DocElement b) {
  if (a.locked != b.locked && _sameExceptLock(a, b)) {
    return Change(ChangeKind.style, '${_name(b)} ${b.locked ? 'gesperrt' : 'entsperrt'}');
  }
  switch ((a, b)) {
    case (TextBlock x, TextBlock y):
      if (x.text != y.text) return Change(ChangeKind.edit, '${_name(y)} geändert');
      if (x.box.x != y.box.x || x.box.y != y.box.y) {
        return x.box.w != y.box.w ? Change(ChangeKind.resize, '${_name(y)} breiter/schmaler gemacht') : Change(ChangeKind.move, '${_name(y)} verschoben');
      }
      if (x.box.w != y.box.w) return Change(ChangeKind.resize, '${_name(y)} ${y.box.w > x.box.w ? 'breiter' : 'schmaler'} gemacht');
      return Change(ChangeKind.style, '${_name(y)} formatiert');
    case (ImageBlock x, ImageBlock y):
      if (x.asset != y.asset) return const Change(ChangeKind.edit, 'Bild ersetzt');
      if (x.quarterTurns != y.quarterTurns) return const Change(ChangeKind.style, 'Bild gedreht');
      if (x.cropX != y.cropX || x.cropY != y.cropY || x.zoom != y.zoom || x.fit != y.fit) {
        if (x.box.w == y.box.w && x.box.h == y.box.h) return const Change(ChangeKind.style, 'Bildausschnitt geändert');
      }
      return _boxChange('Bild', x.box, y.box);
    case (RectShape x, RectShape y):
      if (x.box != y.box) return _boxChange('Fläche', x.box, y.box);
      return const Change(ChangeKind.style, 'Fläche gestaltet');
    case (LineShape x, LineShape y):
      if (x.a != y.a || x.b != y.b) {
        final la = (x.b - x.a), lb = (y.b - y.a);
        final same = (la.x - lb.x).abs() < 1e-6 && (la.y - lb.y).abs() < 1e-6;
        return Change(same ? ChangeKind.move : ChangeKind.resize, same ? 'Linie verschoben' : 'Linie verändert');
      }
      return const Change(ChangeKind.style, 'Linie gestaltet');
    case (TableBlock x, TableBlock y):
      if (x.cells.length != y.cells.length) return Change(ChangeKind.edit, y.rowCount > x.rowCount ? 'Tabellenzeile eingefügt' : 'Tabellenzeile gelöscht');
      if (x.columnCount != y.columnCount) return Change(ChangeKind.edit, y.columnCount > x.columnCount ? 'Tabellenspalte eingefügt' : 'Tabellenspalte gelöscht');
      if (x.x != y.x || x.y != y.y) return const Change(ChangeKind.move, 'Tabelle verschoben');
      if (x.cells.toString() != y.cells.toString()) return const Change(ChangeKind.edit, 'Tabelle geändert');
      return const Change(ChangeKind.style, 'Tabelle gestaltet');
    default:
      return null; // gleiche ID, anderer Typ: kommt nicht vor
  }
}

bool _sameExceptLock(DocElement a, DocElement b) => a.withLocked(b.locked).toJson().toString() == b.toJson().toString();

Change _boxChange(String what, Box a, Box b) {
  final areaA = a.w * a.h, areaB = b.w * b.h;
  if ((areaA - areaB).abs() > 1e-6) {
    return Change(ChangeKind.resize, '$what ${areaB > areaA ? 'vergrössert' : 'verkleinert'}');
  }
  return Change(ChangeKind.move, '$what verschoben');
}

/// Art des Elements in Alltagssprache: «Titel», «Fliesstext», «Bild», «Fläche», «Linie».
/// (Kein Textausschnitt: ein abgeschnittener Satz wie «Um 7.40 Uhr startete …» verwirrt mehr, als er hilft.)
String _name(DocElement e) => switch (e) {
      TextBlock t => textKindPresets[t.kind]!.label,
      ImageBlock _ => 'Bild',
      RectShape _ => 'Fläche',
      LineShape _ => 'Linie',
      TableBlock _ => 'Tabelle',
    };

// ---------- Sicherungspunkte ----------

/// Kategorie eines Elements für Zusammenfassungen («3 Texte, 1 Bild»).
String elementCategory(DocElement e) => switch (e) {
      TextBlock _ => 'text',
      ImageBlock _ => 'image',
      RectShape _ => 'rect',
      LineShape _ => 'line',
      TableBlock _ => 'table',
    };

/// Elemente, die zwischen zwei Ständen gelöscht wurden (inkl. Elemente gelöschter Seiten).
List<DocElement> deletedElements(TextlyDocument before, TextlyDocument after) {
  final now = {for (final p in after.pages) for (final e in p.elements) e.id};
  return [for (final p in before.pages) for (final e in p.elements) if (!now.contains(e.id)) e];
}

/// Beschriftung einer Löschung: «Bild wurde gelöscht», «Seite 2 wurde gelöscht», «3 Elemente wurden gelöscht».
String deletionLabel(TextlyDocument before, TextlyDocument after) {
  bool gonePage(DocPage p) => !after.pages.any((q) => q.id == p.id);
  final pagesGone = before.pages.where(gonePage).length;
  if (pagesGone == 1) return 'Seite ${before.pages.indexWhere(gonePage) + 1} wurde gelöscht';
  if (pagesGone > 1) return '$pagesGone Seiten wurden gelöscht';
  final gone = deletedElements(before, after);
  if (gone.length == 1) return '${_name(gone.single)} wurde gelöscht';
  return '${gone.length} Elemente wurden gelöscht';
}

/// Worum es bei mehreren Elementen geht: eine Kategorie («text», «image» …) oder «mixed»; null wenn leer.
String? subjectOf(Iterable<String> categories) {
  final set = categories.toSet();
  return set.isEmpty ? null : set.length == 1 ? set.single : 'mixed';
}

/// Beschriftung einer grossen Veränderung (oder null), siehe [bigChange].
String? bigChangeLabel(TextlyDocument before, TextlyDocument after, {double moveMm = 30}) => bigChange(before, after, moveMm: moveMm)?.label;

/// Grosse Veränderung, die einen eigenen Sicherungspunkt verdient (oder null):
/// Verschieben um mehr als [moveMm] oder auf eine andere Seite, Bild ersetzt, Hoch-/Querformat.
/// [subject]: was betroffen ist («text», «image», «rect», «line» oder «doc» für das Format).
({String label, String subject})? bigChange(TextlyDocument before, TextlyDocument after, {double moveMm = 30}) {
  if (before.orientation != after.orientation) {
    return (label: after.orientation == PageOrientation.landscape ? 'Auf Querformat umgestellt' : 'Auf Hochformat umgestellt', subject: 'doc');
  }
  if (before.paper != after.paper) return (label: 'Auf ${after.paper.label} umgestellt', subject: 'doc');
  final pageOf = <String, int>{};
  final old = <String, DocElement>{};
  for (var i = 0; i < before.pages.length; i++) {
    for (final e in before.pages[i].elements) {
      pageOf[e.id] = i;
      old[e.id] = e;
    }
  }
  for (var i = 0; i < after.pages.length; i++) {
    for (final e in after.pages[i].elements) {
      final o = old[e.id];
      if (o == null || identical(o, e)) continue;
      if (pageOf[e.id] != i && before.pages[pageOf[e.id]!].id != after.pages[i].id) return (label: '${_name(e)} wurde auf eine andere Seite verschoben', subject: elementCategory(e));
      if (o is ImageBlock && e is ImageBlock && o.asset != e.asset) return (label: 'Bild wurde ersetzt', subject: 'image');
      final dx = e.box.centerX - o.box.centerX, dy = e.box.centerY - o.box.centerY;
      if (o is LineShape && e is LineShape) {
        final mx = (e.a.x + e.b.x - o.a.x - o.b.x) / 2, my = (e.a.y + e.b.y - o.a.y - o.b.y) / 2;
        if (mx * mx + my * my > moveMm * moveMm) return (label: 'Linie wurde verschoben', subject: 'line');
      } else if (dx * dx + dy * dy > moveMm * moveMm) {
        return (label: '${_name(e)} wurde verschoben', subject: elementCategory(e));
      }
    }
  }
  return null;
}

/// Geänderte oder neue Elemente (ID → Kategorie), für «Bearbeitet: 3 Texte, 1 Bild».
Map<String, String> editedElements(TextlyDocument before, TextlyDocument after) {
  final old = {for (final p in before.pages) for (final e in p.elements) e.id: e};
  return {
    for (final p in after.pages)
      for (final e in p.elements)
        if (!identical(old[e.id], e) && old[e.id]?.toJson().toString() != e.toJson().toString()) e.id: elementCategory(e),
  };
}

/// «Bearbeitet: 3 Texte, 1 Bild».
String editSummary(Map<String, String> edited, {int pagesAdded = 0}) {
  final counts = <String, int>{};
  for (final c in edited.values) {
    counts[c] = (counts[c] ?? 0) + 1;
  }
  String part(String cat, String one, String many) {
    final n = counts[cat] ?? 0;
    return n == 0 ? '' : '$n ${n == 1 ? one : many}';
  }

  final parts = [
    part('text', 'Text', 'Texte'),
    part('image', 'Bild', 'Bilder'),
    part('rect', 'Fläche', 'Flächen'),
    part('line', 'Linie', 'Linien'),
    part('table', 'Tabelle', 'Tabellen'),
    if (pagesAdded > 0) '$pagesAdded ${pagesAdded == 1 ? 'Seite' : 'Seiten'} hinzugefügt',
  ].where((p) => p.isNotEmpty).toList();
  return parts.isEmpty ? 'Bearbeitet' : 'Bearbeitet: ${parts.join(', ')}';
}
