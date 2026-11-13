import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:doc_model/doc_model.dart';
import 'package:image/image.dart' as img;

import 'pptx_writer.dart' show ExternalImage;

import 'pptx_common.dart';

/// Dateiendung des eigenen Formats.
const textlyExtension = 'textly';

/// Das eigene Dateiformat: ein ZIP-Paket.
///
/// ```
/// mimetype            «application/x-textly» (unkomprimiert, zuerst – erkennt die Datei schnell)
/// document.json       Dokument mit Formatversion; Bilder nur als Verweis (id, Typ, Grösse, Datei)
/// media/1.jpg …       die Bilddateien
/// ```
/// Unbenutzte Bilder entfallen beim Speichern. Bilder, die nicht im Dokument liegen (Beispieldokument:
/// App-Assets), werden über [externalImage] eingebettet, damit die Datei überall vollständig ist.
const textlyMimeType = 'application/x-textly';

class TextlyFileException implements Exception {
  const TextlyFileException(this.message);
  final String message;
  @override
  String toString() => message;
}

Uint8List encodeTextly(TextlyDocument doc, {ExternalImage? externalImage}) {
  var d = doc;
  // Externe Bilder einbetten
  for (final id in d.usedAssetIds) {
    if (d.assets.containsKey(id)) continue;
    final bytes = externalImage?.call(id);
    if (bytes == null) throw TextlyFileException('Bild «$id» wurde nicht gefunden.');
    final decoder = img.findDecoderForData(bytes);
    final info = decoder?.startDecode(bytes);
    if (info == null) throw TextlyFileException('Bild «$id» ist beschädigt.');
    d = d.addAsset(ImageAsset(
      id: id,
      bytes: bytes,
      mimeType: decoder is img.JpegDecoder ? 'image/jpeg' : 'image/png',
      width: info.width,
      height: info.height,
    ));
  }
  d = d.withoutUnusedAssets();

  final json = d.toJson();
  final archive = Archive();
  final mime = ArchiveFile.string('mimetype', textlyMimeType)..compression = CompressionType.none;
  archive.addFile(mime);
  final files = <String, String>{};
  var n = 0;
  for (final a in d.assets.values) {
    final path = 'media/${++n}.${a.fileExtension}';
    files[a.id] = path;
    archive.addFile(ArchiveFile(path, a.bytes.length, a.bytes)..compression = CompressionType.none); // JPG/PNG sind schon komprimiert
  }
  json['assets'] = [
    for (final a in d.assets.values) {...a.toJson(), 'file': files[a.id]},
  ];
  archive.addFile(ArchiveFile.string('document.json', const JsonEncoder.withIndent(' ').convert(json)));
  return ZipEncoder().encodeBytes(archive);
}

/// Grösste erlaubte document.json (entpackt).
const int maxDocumentJsonBytes = 50 * 1024 * 1024;

/// JPG (FF D8) oder PNG (89 50 4E 47).
bool _looksLikeImage(Uint8List b) =>
    (b.length > 3 && b[0] == 0xFF && b[1] == 0xD8) || (b.length > 8 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47);

TextlyDocument decodeTextly(Uint8List bytes) {
  final Archive zip;
  try {
    zip = ZipDecoder().decodeBytes(bytes);
  } catch (_) {
    throw const TextlyFileException('Die Datei ist kein Textly-Dokument oder beschädigt.');
  }
  final docFile = zip.findFile('document.json');
  if (docFile == null) throw const TextlyFileException('Die Datei ist kein Textly-Dokument oder beschädigt.');
  // Schutz vor manipulierten Dateien, die beim Entpacken riesig werden
  if (docFile.size > maxDocumentJsonBytes) throw const TextlyFileException('Das Dokument in der Datei ist beschädigt.');
  final Map<String, dynamic> json;
  try {
    json = jsonDecode(utf8.decode(docFile.content)) as Map<String, dynamic>;
  } catch (_) {
    throw const TextlyFileException('Das Dokument in der Datei ist beschädigt.');
  }
  final assetBytes = <String, Uint8List>{};
  var total = 0;
  try {
    for (final a in (json['assets'] as List?) ?? const []) {
      final m = a as Map<String, dynamic>;
      final f = zip.findFile(m['file'] as String? ?? '');
      if (f == null) throw TextlyFileException('Ein Bild fehlt in der Datei (${m['file']}).');
      // Schutz vor präparierten Dateien: angegebene und tatsächliche Grösse begrenzen
      if (f.size > maxZipPartBytes) throw TextlyFileException('Ein Bild in der Datei ist zu gross oder beschädigt (${m['file']}).');
      final bytes = f.content;
      if (bytes.length > maxZipPartBytes) throw TextlyFileException('Ein Bild in der Datei ist zu gross oder beschädigt (${m['file']}).');
      total += bytes.length;
      if (total > maxZipTotalBytes) throw const TextlyFileException('Die Bilder in der Datei sind zusammen zu gross.');
      if (!_looksLikeImage(bytes)) throw TextlyFileException('Ein Bild in der Datei ist beschädigt (${m['file']}).');
      assetBytes[m['id'] as String] = bytes;
    }
  } on TextlyFileException {
    rethrow;
  } catch (_) {
    throw const TextlyFileException('Das Dokument in der Datei ist beschädigt.');
  }
  try {
    return TextlyDocument.fromJson(json, assetBytes: assetBytes);
  } on FormatException catch (e) {
    throw TextlyFileException(e.message);
  } catch (_) {
    throw const TextlyFileException('Das Dokument in der Datei ist beschädigt.');
  }
}
