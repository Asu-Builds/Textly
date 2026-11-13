import 'dart:typed_data';

import 'package:meta/meta.dart';

/// Eine Bilddatei, die zum Dokument gehört (eingefügt, verkleinert, richtig gedreht).
/// Bildblöcke verweisen über die [id] darauf. Die Daten werden später als eigene Datei
/// im .appdoc-Paket gespeichert; im JSON stehen nur die Angaben.
@immutable
class ImageAsset {
  const ImageAsset({required this.id, required this.bytes, required this.mimeType, required this.width, required this.height});

  final String id;
  final Uint8List bytes;

  /// `image/jpeg` oder `image/png`.
  final String mimeType;
  final int width, height;

  bool get isJpeg => mimeType == 'image/jpeg';
  String get fileExtension => isJpeg ? 'jpg' : 'png';

  Map<String, dynamic> toJson() => {'id': id, 'mimeType': mimeType, 'width': width, 'height': height};

  factory ImageAsset.fromJson(Map<String, dynamic> j, Uint8List bytes) => ImageAsset(
        id: j['id'] as String,
        bytes: bytes,
        mimeType: j['mimeType'] as String,
        width: j['width'] as int,
        height: j['height'] as int,
      );
}
