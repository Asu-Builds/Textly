import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// Inhalt der Zwischenablage, der sich als Bild einfügen lässt.
sealed class ClipboardImageContent {}

/// Bilddaten: PNG (z. B. aus Browsern, Office) oder BMP (aus einem Windows-Bitmap, z. B. Bildschirmfoto).
class ClipboardImageBytes extends ClipboardImageContent {
  ClipboardImageBytes(this.bytes, {required this.fromBitmap});
  final Uint8List bytes;

  /// Windows-Bitmaps haben oft einen leeren Alphakanal; das Bild ist dann als undurchsichtig zu behandeln.
  final bool fromBitmap;
}

/// Im Explorer kopierte Dateien.
class ClipboardFiles extends ClipboardImageContent {
  ClipboardFiles(this.paths);
  final List<String> paths;
}

/// Liest ein Bild oder kopierte Dateien aus der Windows-Zwischenablage. Ergibt null, wenn nichts Passendes da ist.
///
/// Reihenfolge: PNG (verlustfrei, mit Transparenz) → Dateien → Bitmap (CF_DIB).
ClipboardImageContent? readWindowsClipboard() {
  if (OpenClipboard(NULL) == 0) return null;
  try {
    final pngFormat = using((a) => RegisterClipboardFormat('PNG'.toNativeUtf16(allocator: a)));
    if (pngFormat != 0 && IsClipboardFormatAvailable(pngFormat) != 0) {
      final bytes = _globalBytes(GetClipboardData(pngFormat));
      if (bytes != null) return ClipboardImageBytes(bytes, fromBitmap: false);
    }
    if (IsClipboardFormatAvailable(CF_HDROP) != 0) {
      final hDrop = GetClipboardData(CF_HDROP);
      if (hDrop != 0) {
        final count = DragQueryFile(hDrop, 0xFFFFFFFF, nullptr, 0);
        final paths = <String>[];
        for (var i = 0; i < count; i++) {
          final len = DragQueryFile(hDrop, i, nullptr, 0);
          final buf = calloc<Uint16>(len + 1).cast<Utf16>();
          try {
            DragQueryFile(hDrop, i, buf, len + 1);
            paths.add(buf.toDartString());
          } finally {
            calloc.free(buf);
          }
        }
        if (paths.isNotEmpty) return ClipboardFiles(paths);
      }
    }
    if (IsClipboardFormatAvailable(CF_DIB) != 0) {
      final dib = _globalBytes(GetClipboardData(CF_DIB));
      if (dib != null) {
        final bmp = bmpFromDib(dib);
        if (bmp != null) return ClipboardImageBytes(bmp, fromBitmap: true);
      }
    }
    return null;
  } finally {
    CloseClipboard();
  }
}

Uint8List? _globalBytes(int handle) {
  if (handle == 0) return null;
  final h = Pointer<Void>.fromAddress(handle);
  final size = GlobalSize(h);
  final p = GlobalLock(h);
  if (p == nullptr) return null;
  try {
    return size == 0 ? null : Uint8List.fromList(p.cast<Uint8>().asTypedList(size));
  } finally {
    GlobalUnlock(h); // auch bei leerem Inhalt wieder freigeben
  }
}

/// Ergänzt ein Windows-DIB um den 14-Byte-Dateikopf zu einer BMP-Datei.
Uint8List? bmpFromDib(Uint8List dib) {
  if (dib.length < 40) return null;
  final d = ByteData.sublistView(dib);
  final headerSize = d.getUint32(0, Endian.little);
  final bitCount = d.getUint16(14, Endian.little);
  final compression = d.getUint32(16, Endian.little);
  final colorsUsed = d.getUint32(32, Endian.little);
  var extra = 0;
  if (headerSize == 40 && (compression == 3 || compression == 6)) extra = compression == 3 ? 12 : 16; // Farbmasken
  final colorTable = bitCount <= 8 ? (colorsUsed == 0 ? (1 << bitCount) : colorsUsed) * 4 : colorsUsed * 4;
  final offset = 14 + headerSize + extra + colorTable;
  final out = Uint8List(14 + dib.length);
  final o = ByteData.sublistView(out);
  o.setUint8(0, 0x42); // B
  o.setUint8(1, 0x4D); // M
  o.setUint32(2, out.length, Endian.little);
  o.setUint32(10, offset, Endian.little);
  out.setRange(14, out.length, dib);
  return out;
}
