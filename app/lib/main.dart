import 'dart:io';

import 'package:doc_model/doc_model.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'editor/editor_controller.dart';
import 'files/services.dart';
import 'history/history_store.dart';
import 'library/document_library.dart';
import 'library/home_page.dart';
import 'spell/spell_check.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final spell = SpellChecker(await defaultSpellBackend());
  final services = AppServices();

  // «Meine Dokumente»: sichtbar unter Dokumente\Textly, damit die Dateien auch ohne Textly auffindbar sind
  final documents = await getApplicationDocumentsDirectory();
  final library = DocumentLibrary(
    services.files,
    '${documents.path}${Platform.pathSeparator}Textly',
    loadAsset: services.loadAsset,
  );
  // Allererster Start: das Beispiel zum Ausprobieren anlegen
  if (!await library.exists) await library.create(sampleDocument(), name: 'Beispiel: Vereinsausflug');

  // Verlauf ausserhalb der Dokumente: lokal (nicht in OneDrive), wird nie mit weitergegeben
  final local = Platform.environment['LOCALAPPDATA'] ?? (await getApplicationSupportDirectory()).path;
  final historyRoot = '$local${Platform.pathSeparator}Textly${Platform.pathSeparator}Verlauf';

  // Doppelklick auf eine .textly-Datei: Windows übergibt ihren Pfad; Textly holt eine Kopie herein
  final startupFile = args.where((a) => a.toLowerCase().endsWith('.textly') && File(a).existsSync()).firstOrNull;
  runApp(TextlyApp(
    library: library,
    services: services,
    newController: (doc) => EditorController(doc, spell: spell),
    startupFile: startupFile,
    historyFor: (id) => HistoryStore(services.files, '$historyRoot${Platform.pathSeparator}$id'),
  ));
}

class TextlyApp extends StatelessWidget {
  const TextlyApp({super.key, required this.library, required this.services, required this.newController, this.startupFile, this.historyFor});
  final HistoryStore Function(String id)? historyFor;
  final DocumentLibrary library;
  final AppServices services;
  final EditorController Function(TextlyDocument doc) newController;
  final String? startupFile;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Textly',
        debugShowCheckedModeBanner: false,
        theme: textlyTheme(),
        home: HomePage(
          library: library,
          services: services,
          newController: newController,
          startupFile: startupFile,
          fitOnStart: true,
          historyFor: historyFor,
        ),
      );
}

/// Farben und Dichte der Bedienoberfläche (auch für die Bildschirmfotos der Anleitung).
ThemeData textlyTheme() => ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2457D6), primary: const Color(0xFF2457D6)),
      useMaterial3: true,
      visualDensity: VisualDensity.compact,
    );
