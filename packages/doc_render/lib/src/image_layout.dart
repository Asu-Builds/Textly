import 'dart:math' as math;

import 'package:doc_model/doc_model.dart';
import 'package:flutter/painting.dart';

/// Lage des sichtbaren Bildes im Rahmen (in Punkt, relativ zum Rahmen).
/// Gilt gleichermassen für Bildschirm und PDF.
Rect imagePlacement(ImageBlock i) {
  final w = i.box.w * mmToPt, h = i.box.h * mmToPt;
  if (i.fit == ImageFit.contain) {
    final s = math.min(w / i.naturalWidth, h / i.naturalHeight);
    final iw = i.naturalWidth * s, ih = i.naturalHeight * s;
    return Rect.fromLTWH((w - iw) / 2, (h - ih) / 2, iw, ih);
  }
  final s = math.max(w / i.naturalWidth, h / i.naturalHeight) * i.zoom;
  final iw = i.naturalWidth * s, ih = i.naturalHeight * s;
  return Rect.fromLTWH((w - iw) * i.cropX, (h - ih) * i.cropY, iw, ih);
}
