import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:doc_model/doc_model.dart';

/// Gemeinsame Festlegungen für den PowerPoint-Austausch.
///
/// Abbildung Textly → PPTX (siehe README):
/// - Seite → Folie, Foliengrösse A4 hochformat (210 × 297 mm).
/// - Textblock → Textfeld (p:sp txBox). Innenabstand = Textly-Innenabstand, automatische Höhe = spAutoFit,
///   Zeilenabstand exakt in Punkt, jede Textstelle ein eigener Lauf (a:r) mit vollständigen Angaben.
///   Die Textart steht im Formnamen («Fliesstext 3»); PowerPoint und LibreOffice behalten Formnamen.
/// - Bild → Bild (p:pic) mit Zuschnitt (a:srcRect) – entspricht «Fläche füllen» mit Ausschnitt.
/// - Rechteck → Rechteck bzw. abgerundetes Rechteck; Linie → Verbindungslinie (p:cxnSp).

/// EMU (English Metric Units): 1 mm = 36 000 EMU, 1 pt = 12 700 EMU.
int emu(double mm) => (mm * 36000).round();
double mmFromEmu(num e) => e / 36000;

const String nsA = 'http://schemas.openxmlformats.org/drawingml/2006/main';
const String nsR = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
const String nsP = 'http://schemas.openxmlformats.org/presentationml/2006/main';
const String nsRel = 'http://schemas.openxmlformats.org/package/2006/relationships';
const String relBase = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';

/// Zeilenhöhen-Faktor je Textart (wie doc_render/text_layout.dart; dort massgeblich).
double lineHeightFactor(TextKind k) => switch (k) {
      TextKind.title => 1.15,
      TextKind.subtitle => 1.3,
      TextKind.heading => 1.25,
      TextKind.body => 1.45,
      TextKind.caption => 1.35,
    };

/// Innenabstand der Textblöcke (wie doc_render).
const double textPadXmm = 1.0;
const double textPadYmm = 0.8;

/// Zusätzlicher Innenabstand einer Tabellenzelle (wie doc_render/table_layout.dart).
const double tableCellPadMmX = .9, tableCellPadMmY = .7;

/// Eckenradius abgerundeter Rechtecke in mm (wie doc_render).
const double rectRadiusMm = 2.5;

/// Formname → Textart (für den Import). Unbekannte Namen ergeben Fliesstext.
TextKind kindFromShapeName(String name) {
  final lower = name.toLowerCase();
  for (final e in textKindPresets.entries) {
    if (lower.startsWith(e.value.label.toLowerCase())) return e.key;
  }
  return TextKind.body;
}

String hexColor(int argb) => (argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase();

/// Für XML 1.0 verbotene Steuerzeichen (z. B. \v aus der Zwischenablage, \r) entfernen.
final _invalidXml = RegExp(r'[\x00-\x08\x0B-\x1F\uFFFE\uFFFF]');

String esc(String s) => s
    .replaceAll(_invalidXml, '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

/// Grösster einzelner Teil (z. B. ein Foto) und grösste Summe, die beim Öffnen entpackt wird.
/// Schützt vor präparierten Dateien, die beim Entpacken riesig werden («ZIP-Bombe»).
const int maxZipPartBytes = 64 * 1024 * 1024, maxZipTotalBytes = 400 * 1024 * 1024;

/// Zu gross zum Entpacken (siehe [maxZipPartBytes]).
class ZipTooLargeException implements Exception {
  const ZipTooLargeException();
}

/// Inhalt eines ZIP-Pakets, der erst beim Zugriff entpackt wird – nur, was gebraucht wird, und mit Grenzen.
class LazyZip {
  LazyZip(Archive archive) : _files = {for (final f in archive.files) if (f.isFile) f.name: f};

  final Map<String, ArchiveFile> _files;
  final _cache = <String, Uint8List>{};
  var _total = 0;

  bool containsKey(String path) => _files.containsKey(path);
  Iterable<String> get keys => _files.keys;

  /// Inhalt von [path] oder null; [ZipTooLargeException], wenn er (oder alles zusammen) zu gross wird.
  Uint8List? operator [](String path) {
    final known = _cache[path];
    if (known != null) return known;
    final f = _files[path];
    if (f == null) return null;
    // angegebene Grösse vor dem Entpacken prüfen, tatsächliche danach
    if (f.size > maxZipPartBytes || _total + f.size > maxZipTotalBytes) throw const ZipTooLargeException();
    final c = f.content;
    if (c.length > maxZipPartBytes || _total + c.length > maxZipTotalBytes) throw const ZipTooLargeException();
    _total += c.length;
    return _cache[path] = c;
  }
}
