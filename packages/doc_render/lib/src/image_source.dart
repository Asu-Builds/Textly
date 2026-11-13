import 'package:doc_model/doc_model.dart';
import 'package:flutter/widgets.dart';

import 'element_view.dart';

final _cache = Expando<MemoryImage>();

/// Bilder eines Dokuments: eingefügte Bilder aus dem Dokument, sonst App-Assets (Beispieldokument).
/// Das MemoryImage wird pro Bilddatei wiederverwendet, damit Flutter es nicht neu dekodiert.
ImageResolver documentImages(TextlyDocument doc) => (String id) {
      final a = doc.assets[id];
      if (a == null) return AssetImage(id);
      return _cache[a] ??= MemoryImage(a.bytes);
    };
