import 'dart:math' as math;

import 'package:meta/meta.dart';

import 'elements.dart';
import 'geometry.dart';

/// Kleinste und grösste Vergrösserung des Bildausschnitts.
const double minCropZoom = 1;
const double maxCropZoom = 4;

/// Der sichtbare Teil eines Bildes bei «Fläche füllen», in Anteilen des ganzen Bildes (0…1).
@immutable
class CropWindow {
  const CropWindow(this.x, this.y, this.w, this.h);
  final double x, y, w, h;

  @override
  String toString() => 'CropWindow($x, $y, $w × $h)';
}

/// Welcher Anteil des Bildes ist sichtbar, und wo?
CropWindow cropWindow(ImageBlock i) {
  final (wx, wy) = _visibleFraction(i);
  return CropWindow(i.cropX * (1 - wx), i.cropY * (1 - wy), wx, wy);
}

(double, double) _visibleFraction(ImageBlock i) {
  final scale = math.max(i.box.w / i.naturalWidth, i.box.h / i.naturalHeight) * i.zoom;
  // Rahmen ohne Fläche oder Bild ohne Bildpunkte: ganzes Bild (statt NaN, das später den Export abbricht)
  if (!(scale > 0) || !scale.isFinite) return (1.0, 1.0);
  return (
    math.min(1.0, i.box.w / (i.naturalWidth * scale)),
    math.min(1.0, i.box.h / (i.naturalHeight * scale)),
  );
}

/// Ausschnitt so verschieben, dass seine linke obere Ecke bei ([x], [y]) liegt (Anteile).
/// Der Ausschnitt bleibt immer ganz im Bild.
ImageBlock withCropAt(ImageBlock i, double x, double y) {
  final (wx, wy) = _visibleFraction(i);
  final cx = (1 - wx) > 1e-6 ? (x.clamp(0.0, 1 - wx) / (1 - wx)) : .5;
  final cy = (1 - wy) > 1e-6 ? (y.clamp(0.0, 1 - wy) / (1 - wy)) : .5;
  return i.copyWith(cropX: cx, cropY: cy);
}

/// Ausschnitt so verschieben, dass seine Mitte bei ([x], [y]) liegt (Anteile).
ImageBlock withCropCenteredAt(ImageBlock i, double x, double y) {
  final w = cropWindow(i);
  return withCropAt(i, x - w.w / 2, y - w.h / 2);
}

/// Vergrösserung ändern; die Mitte des Ausschnitts bleibt, soweit möglich, wo sie war.
ImageBlock withCropZoom(ImageBlock i, double zoom) {
  final before = cropWindow(i);
  final cx = before.x + before.w / 2, cy = before.y + before.h / 2;
  return withCropCenteredAt(i.copyWith(zoom: zoom.clamp(minCropZoom, maxCropZoom)), cx, cy);
}

/// Kleinster Anteil, der beim Zuschneiden sichtbar bleibt (je Richtung).
const double minCropPart = 1 / maxCropZoom;

/// Zuschneiden wie in Word: sichtbar bleibt der Teil [x0]…[x1] × [y0]…[y1] (Anteile des ganzen Bildes).
/// Das Bild behält Grösse und Lage auf der Seite; der Rahmen wird um das Abgeschnittene kleiner.
ImageBlock withCropRect(ImageBlock i, double x0, double y0, double x1, double y1) {
  final w = cropWindow(i);
  final nW = i.naturalWidth.toDouble(), nH = i.naturalHeight.toDouble();
  final mmPerPx = i.box.w / (w.w * nW);
  // im Bild bleiben, nicht kleiner als erlaubt
  x0 = x0.clamp(0.0, 1 - minCropPart);
  y0 = y0.clamp(0.0, 1 - minCropPart);
  x1 = x1.clamp(x0 + minCropPart, 1.0);
  y1 = y1.clamp(y0 + minCropPart, 1.0);
  final boxW = (x1 - x0) * nW * mmPerPx, boxH = (y1 - y0) * nH * mmPerPx;
  final box = Box(i.box.x + (x0 - w.x) * nW * mmPerPx, i.box.y + (y0 - w.y) * nH * mmPerPx, boxW, boxH);
  final zoom = (mmPerPx / math.max(boxW / nW, boxH / nH)).clamp(minCropZoom, maxCropZoom);
  return withCropAt(i.copyWith(box: box, zoom: zoom), x0, y0);
}

/// Ganzes Bild mittig, ohne Vergrösserung.
ImageBlock withCropReset(ImageBlock i) => i.copyWith(cropX: .5, cropY: .5, zoom: 1);

/// Hat der Rahmen eine andere Form als das Originalbild?
bool hasChangedShape(ImageBlock i) => ((i.box.w / i.box.h) - i.naturalAspect).abs() > .01;

/// Rahmen auf die Form des Originalbilds zurücksetzen (Breite und vertikale Mitte bleiben).
ImageBlock withOriginalShape(ImageBlock i) {
  final h = i.box.w / i.naturalAspect;
  return i.copyWith(box: i.box.copyWith(y: i.box.centerY - h / 2, h: h));
}

/// Bild um 90° drehen, im Uhrzeigersinn oder mit [clockwise] = false dagegen.
/// Der Rahmen dreht sich um seine Mitte mit; der Ausschnitt zeigt danach denselben Bildteil.
ImageBlock withQuarterTurn(ImageBlock i, {bool clockwise = true}) {
  final b = i.box;
  return i.copyWith(
    box: Box(b.centerX - b.h / 2, b.centerY - b.w / 2, b.h, b.w),
    naturalWidth: i.naturalHeight,
    naturalHeight: i.naturalWidth,
    quarterTurns: (i.quarterTurns + (clockwise ? 1 : 3)) % 4,
    cropX: clockwise ? 1 - i.cropY : i.cropY,
    cropY: clockwise ? i.cropX : 1 - i.cropX,
  );
}

/// Ausschnitt im gedrehten Bild (wie gezeigt) → derselbe Ausschnitt in der ungedrehten Bilddatei.
CropWindow windowInSource(CropWindow w, int quarterTurns) => switch (quarterTurns % 4) {
      1 => CropWindow(w.y, 1 - w.x - w.w, w.h, w.w),
      2 => CropWindow(1 - w.x - w.w, 1 - w.y - w.h, w.w, w.h),
      3 => CropWindow(1 - w.y - w.h, w.x, w.h, w.w),
      _ => w,
    };

/// Umkehrung von [windowInSource].
CropWindow windowInDisplay(CropWindow w, int quarterTurns) => windowInSource(w, (4 - quarterTurns % 4) % 4);
