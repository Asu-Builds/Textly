import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:doc_model/doc_model.dart';
import 'package:image/image.dart' as img;

/// Längste Bildkante nach dem Einfügen. Genügt für 300 dpi über die ganze A4-Breite (rund 2480 Pixel).
const int maxImageEdge = 3000;

class ImageImportException implements Exception {
  const ImageImportException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Bereitet eine Bilddatei zum Einfügen auf – im Hintergrund, damit die App nicht stockt.
///
/// [opaque]: Transparenz verwerfen (Windows-Bitmaps aus der Zwischenablage haben oft einen leeren Alphakanal).
Future<ImageAsset> prepareImage(Uint8List bytes, {bool opaque = false}) =>
    Isolate.run(() => prepareImageSync(bytes, opaque: opaque));

/// Wie [prepareImage], aber im aktuellen Ablauf (für Tests).
///
/// - JPG und PNG bis [maxImageEdge] ohne Drehangabe werden unverändert übernommen (keine Qualitätsverluste).
/// - Grössere Bilder werden verkleinert.
/// - Die Drehangabe von Kamerafotos (EXIF) wird ins Bild übernommen. PDF-Betrachter beachten sie nicht,
///   das Bild stünde dort sonst quer.
/// - Andere Formate (GIF, BMP, TIFF, WebP, …) werden zu JPG bzw. bei Transparenz zu PNG.
ImageAsset prepareImageSync(Uint8List bytes, {bool opaque = false}) {
  try {
    return _prepare(bytes, opaque: opaque);
  } on ImageImportException {
    rethrow;
  } catch (_) {
    // leere, abgeschnittene oder fehlerhafte Dateien (RangeError, FormatException … im Decoder)
    throw const ImageImportException('Das Bild ist beschädigt und lässt sich nicht öffnen.');
  }
}

/// Grösste Bildfläche (Bildpunkte), die Textly öffnet. Grössere Bilder bräuchten Gigabytes Speicher.
const int maxImagePixels = 100 * 1000 * 1000;

ImageAsset _prepare(Uint8List bytes, {required bool opaque}) {
  if (bytes.length < 8) throw const ImageImportException('Die Datei ist leer oder kein Bild.');
  final decoder = img.findDecoderForData(bytes);
  if (decoder == null) {
    throw const ImageImportException(
      'Diese Datei kann Textly nicht als Bild öffnen. Unterstützt sind JPG, PNG, GIF, BMP, TIFF und WebP.',
    );
  }
  final isJpeg = decoder is img.JpegDecoder;
  final isPng = decoder is img.PngDecoder;
  final info = decoder.startDecode(bytes);
  if (info != null && info.width * info.height > maxImagePixels) {
    throw ImageImportException(
      'Das Bild ist zu gross (${info.width} × ${info.height} Bildpunkte). Bitte vorher verkleinern, höchstens 100 Megapixel.',
    );
  }
  final orientation = isJpeg ? (img.decodeJpgExif(bytes)?.imageIfd.orientation ?? 1) : 1;

  if (!opaque && info != null && (isJpeg || isPng) && orientation == 1 && math.max(info.width, info.height) <= maxImageEdge) {
    return ImageAsset(
      id: newId('img'),
      bytes: bytes,
      mimeType: isJpeg ? 'image/jpeg' : 'image/png',
      width: info.width,
      height: info.height,
    );
  }

  var image = decoder.decode(bytes, frame: 0); // bei GIF-Animationen nur das erste Bild
  if (image == null) throw const ImageImportException('Das Bild ist beschädigt und lässt sich nicht öffnen.');
  image = img.bakeOrientation(image);
  if (opaque && image.hasAlpha) image = image.convert(numChannels: 3);
  if (math.max(image.width, image.height) > maxImageEdge) {
    final landscape = image.width >= image.height;
    image = img.copyResize(
      image,
      width: landscape ? maxImageEdge : null,
      height: landscape ? null : maxImageEdge,
      interpolation: img.Interpolation.average,
    );
  }
  final png = image.hasAlpha && !isJpeg;
  final out = png ? img.encodePng(image, level: 6) : img.encodeJpg(image, quality: 88);
  return ImageAsset(
    id: newId('img'),
    bytes: out,
    mimeType: png ? 'image/png' : 'image/jpeg',
    width: image.width,
    height: image.height,
  );
}

/// Dateiendungen für den Dateidialog und das Ziehen aus dem Explorer.
const imageExtensions = ['jpg', 'jpeg', 'png', 'gif', 'bmp', 'tif', 'tiff', 'webp'];

bool looksLikeImageFile(String path) => imageExtensions.contains(path.split('.').last.toLowerCase());
