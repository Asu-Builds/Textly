import 'package:doc_exchange/doc_exchange.dart';
import 'package:doc_model/doc_model.dart';
import 'package:doc_render/doc_render.dart';
import 'package:flutter/material.dart';

import '../editor/editor_controller.dart';
import '../editor/editor_page.dart';
import '../editor/toolbar_widgets.dart';
import '../files/services.dart';
import '../history/history_store.dart';
import '../images/image_import.dart';
import 'autosave.dart';
import 'document_library.dart';
import 'template_dialog.dart';
import 'templates.dart';

/// Startseite «Meine Dokumente»: alle Dokumente mit Vorschau, ohne Ordner und Dateinamen.
/// Speichern geschieht automatisch; gelöschte Dokumente bleiben 30 Tage im Papierkorb.
class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.library,
    required this.services,
    required this.newController,
    this.startupFile,
    this.fitOnStart = false,
    this.autosaveDelay = const Duration(milliseconds: 1200),
    this.historyFor,
  });

  /// Verlauf eines Dokuments (ausserhalb der Dokumentdatei); ohne: kein Verlauf.
  final HistoryStore Function(String id)? historyFor;

  final DocumentLibrary library;
  final AppServices services;

  /// Erzeugt den Editor-Zustand für ein Dokument (Rechtschreibprüfung usw.).
  final EditorController Function(TextlyDocument doc) newController;

  /// Beim Start hereinzuholende Datei (Doppelklick auf eine .textly-Datei).
  final String? startupFile;
  final bool fitOnStart;
  final Duration autosaveDelay;

  @override
  State<HomePage> createState() => HomePageState();
}

/// Was die Startseite zeigt.
enum _View { docs, templates, trash }

class HomePageState extends State<HomePage> {
  DocumentLibrary get lib => widget.library;
  _View _view = _View.docs;
  bool get _trash => _view == _View.trash;

  /// Eigene Vorlagen (für «Neu beginnen» und die Seite «Vorlagen»).
  List<LibraryEntry> _ownTemplates = const [];
  String _query = '';
  List<LibraryEntry> _entries = const [];
  bool _loading = true;
  final _thumbs = <String, (DateTime, Future<TextlyDocument>)>{};

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      for (final id in await lib.purgeTrash()) {
        await _deleteHistory(id);
      }
    } on LibraryUnavailableException {
      // später; _reload zeigt den Hinweis
    }
    await _reload();
    final f = widget.startupFile;
    if (f != null && mounted && !_unavailable) await _once(() => importFile(f));
  }

  /// «Meine Dokumente» lässt sich gerade nicht lesen (Ordner offline, gesperrt …).
  bool _unavailable = false;

  Future<void> _reload() async {
    final List<LibraryEntry> list, own;
    try {
      list = await lib.entries(trash: _trash, templates: _view == _View.templates);
      own = await lib.entries(templates: true);
    } on LibraryUnavailableException {
      if (mounted) {
        setState(() {
          _unavailable = true;
          _loading = false;
        });
      }
      return;
    }
    if (!mounted) return;
    if (lib.repaired) {
      lib.repaired = false;
      _snack('Die Liste «Meine Dokumente» war beschädigt und wurde aus den Dokumentdateien neu aufgebaut. '
          'Eigene Namen und Vorlagen müssen eventuell neu gesetzt werden.');
    }
    setState(() {
      _unavailable = false;
      _entries = list;
      _ownTemplates = own;
      _loading = false;
    });
  }

  void _snack(String text, {SnackBarAction? action}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      // Auch mit «Rückgängig» nach einigen Sekunden verschwinden (sonst bleibt die Meldung stehen)
      ..showSnackBar(SnackBar(content: Text(text), action: action, persist: false, duration: Duration(seconds: text.length > 90 ? 12 : 6)));
  }

  Future<TextlyDocument> _thumbDoc(LibraryEntry e) {
    final cached = _thumbs[e.id];
    if (cached != null && cached.$1 == e.modified) return cached.$2;
    final f = lib.load(e.id);
    _thumbs[e.id] = (e.modified, f);
    return f;
  }

  // ---------- Befehle ----------

  /// Läuft gerade ein Öffnen oder Anlegen? Dann werden weitere Klicks (z. B. ein Doppelklick) ignoriert,
  /// sonst entstünden zwei Editoren für dasselbe Dokument oder doppelte Dokumente.
  bool _busy = false;

  Future<void> _once(Future<void> Function() action) async {
    if (_busy) return;
    _busy = true;
    try {
      await action();
    } on LibraryUnavailableException {
      _snack('«Meine Dokumente» lässt sich gerade nicht lesen. Bitte gleich nochmals versuchen.');
      await _reload();
    } finally {
      _busy = false;
    }
  }

  /// Dokument im Editor öffnen; beim Zurückkehren ist alles gespeichert.
  Future<void> open(LibraryEntry e, {String? message}) async {
    final TextlyDocument doc;
    try {
      doc = await lib.load(e.id);
    } catch (_) {
      _snack('Das Dokument «${e.name}» lässt sich nicht öffnen. Die Datei ist beschädigt.');
      return;
    }
    if (!mounted) return;
    // Meldungen der Startseite (z. B. «… gelöscht») nicht mit ins Dokument nehmen
    ScaffoldMessenger.of(context).clearSnackBars();
    if (message != null) _snack(message);
    final c = widget.newController(doc);
    final session = AutosaveSession(lib, e, c, delay: widget.autosaveDelay, history: widget.historyFor?.call(e.id));
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => EditorPage(controller: c, services: widget.services, session: session, fitOnStart: widget.fitOnStart),
      ),
    );
    if (mounted) ScaffoldMessenger.of(context).clearSnackBars(); // Meldungen aus dem Dokument bleiben dort
    await session.finish();
    session.dispose();
    await _reload();
  }

  Future<void> _deleteHistory(String id) async {
    try {
      await widget.historyFor?.call(id).deleteAll();
    } catch (_) {}
  }

  Future<void> newDocument(PageOrientation o, {PaperSize paper = PaperSize.a4}) async {
    final e = await lib.create(
      TextlyDocument(
        pages: [DocPage(id: newId('p'))],
        orientation: o,
        paper: paper,
      ),
      name: null,
    );
    await open(e);
    // Neu angelegt und leer gelassen: nicht als «Unbenanntes Dokument» liegen lassen
    try {
      final d = await lib.load(e.id);
      if (d.pages.every((p) => p.elements.isEmpty)) {
        await lib.deleteForever(e.id);
        await _deleteHistory(e.id);
        await _reload();
      }
    } catch (_) {}
  }

  Future<void> _useAsCopy(LibraryEntry e) async {
    final copy = await lib.duplicate(e.id);
    await open(copy, message: 'Kopie «${copy.name}» angelegt. Das Original bleibt unverändert.');
  }

  Future<void> _rename(LibraryEntry e) async {
    final ctrl = TextEditingController(text: e.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Umbenennen'),
        content: TextField(
          key: const ValueKey('rename-field'),
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(helperText: 'Leer lassen: Name folgt dem Titel im Dokument'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Abbrechen')),
          FilledButton(key: const ValueKey('rename-ok'), onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Übernehmen')),
        ],
      ),
    );
    if (name == null) return;
    await lib.rename(e.id, name);
    await _reload();
  }

  Future<void> _moveToTrash(LibraryEntry e) async {
    await lib.moveToTrash(e.id);
    await _reload();
    _snack(
      '«${e.name}» liegt im Papierkorb.',
      action: SnackBarAction(
        label: 'Rückgängig',
        onPressed: () async {
          await lib.restore(e.id);
          await _reload();
        },
      ),
    );
  }

  Future<void> _restore(LibraryEntry e) async {
    await lib.restore(e.id);
    await _reload();
    _snack('«${e.name}» ist wieder in «Meine Dokumente».');
  }

  Future<bool> _confirm(String title, String text, String ok) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(text),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Abbrechen')),
            FilledButton(
              key: const ValueKey('confirm-ok'),
              style: FilledButton.styleFrom(backgroundColor: Ui.danger),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(ok),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _deleteForever(LibraryEntry e) async {
    if (!await _confirm('Endgültig löschen?', '«${e.name}» wird endgültig gelöscht. Das lässt sich nicht rückgängig machen.', 'Endgültig löschen')) {
      return;
    }
    await lib.deleteForever(e.id);
    await _deleteHistory(e.id);
    await _reload();
  }

  Future<void> _emptyTrash() async {
    if (!await _confirm('Papierkorb leeren?', _entries.length == 1 ? 'Das Dokument im Papierkorb wird endgültig gelöscht.' : 'Alle ${_entries.length} Dokumente im Papierkorb werden endgültig gelöscht.', 'Leeren')) {
      return;
    }
    for (final e in _entries) {
      await lib.deleteForever(e.id);
      await _deleteHistory(e.id);
    }
    await _reload();
  }

  /// «Datei hereinholen»: Textly-, PowerPoint- oder Word-Datei als Kopie in «Meine Dokumente» holen.
  Future<void> pickAndImport() async {
    final path = await widget.services.picker.pickOpen(label: 'Textly, PowerPoint oder Word', extensions: const ['textly', 'pptx', 'docx']);
    if (path != null) await importFile(path);
  }

  Future<void> importFile(String path) async {
    final fileName = path.split(RegExp(r'[\\/]')).last;
    final base = fileName.contains('.') ? fileName.substring(0, fileName.lastIndexOf('.')) : fileName;
    try {
      final bytes = await widget.services.files.read(path);
      final LibraryEntry e;
      var notes = const <String>[];
      if (fileName.toLowerCase().endsWith('.pptx')) {
        final r = importPptx(bytes, prepareImage: (b) => prepareImageSync(b));
        notes = r.notes;
        e = await lib.create(r.document, name: base);
      } else if (fileName.toLowerCase().endsWith('.docx')) {
        // Absätze werden mit demselben Satz wie im Editor gemessen und auf A4-Seiten verteilt
        final r = importDocx(
          bytes,
          heightMm: (e) => switch (e) {
            TextBlock t => textBlockHeightPt(t) / mmToPt,
            TableBlock t => tableHeightMm(t),
            _ => e.box.h,
          },
          // wie beim gewöhnlichen Einfügen: Drehung aus den Kameradaten, sehr grosse Fotos verkleinert
          prepareImage: (b) => prepareImageSync(b),
        );
        notes = r.notes;
        e = await lib.create(r.document, name: base);
      } else {
        e = await lib.create(decodeTextly(bytes), name: base);
      }
      await _reload();
      await open(
        e,
        message: notes.isEmpty
            ? '«$base» ist jetzt in «Meine Dokumente». Die Originaldatei bleibt unverändert.'
            : '«$base» übernommen. Hinweis: ${notes.join(' ')}',
      );
    } on TextlyFileException catch (err) {
      _snack(err.message);
    } on PptxImportException catch (err) {
      _snack(err.message);
    } on DocxImportException catch (err) {
      _snack(err.message);
    } catch (_) {
      _snack('Die Datei «$fileName» lässt sich nicht öffnen.');
    }
  }

  // ---------- Darstellung ----------

  @override
  Widget build(BuildContext context) {
    final shown = _query.isEmpty ? _entries : _entries.where((e) => e.name.toLowerCase().contains(_query.toLowerCase())).toList();
    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F9),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sidebar(),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(36, 28, 36, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          switch (_view) {
                            _View.docs => 'Meine Dokumente',
                            _View.templates => 'Vorlagen',
                            _View.trash => 'Papierkorb',
                          },
                          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: Ui.ink),
                        ),
                      ),
                      if (_view == _View.docs)
                        SizedBox(
                          width: 340,
                          child: TextField(
                            key: const ValueKey('home-search'),
                            controller: _search,
                            onChanged: (v) => setState(() => _query = v),
                            decoration: InputDecoration(
                              hintText: 'Suchen, z. B. «Herbst»',
                              prefixIcon: const Icon(Icons.search_rounded, size: 20),
                              isDense: true,
                              filled: true,
                              fillColor: Colors.white,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide: const BorderSide(color: Color(0xFFD0D5DD)),
                              ),
                            ),
                          ),
                        ),
                      if (_trash && _entries.isNotEmpty)
                        OutlinedButton(key: const ValueKey('trash-empty'), onPressed: _emptyTrash, child: const Text('Papierkorb leeren')),
                    ],
                  ),
                  const SizedBox(height: 22),
                  Expanded(
                    child: _loading
                        ? const SizedBox()
                        : _unavailable
                        ? _unavailableNote()
                        : switch (_view) {
                            _View.docs => _grid(shown),
                            _View.templates => _templatesView(),
                            _View.trash => _trashList(),
                          },
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sidebar() => Container(
    width: 240,
    color: Colors.white,
    padding: const EdgeInsets.fromLTRB(14, 20, 14, 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 18),
          child: Row(
            children: [
              Image.asset('assets/branding/textly_icon_256.png', width: 34, height: 34, filterQuality: FilterQuality.medium),
              const SizedBox(width: 10),
              const Text(
                'Textly',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Ui.ink),
              ),
            ],
          ),
        ),
        FilledButton.icon(
          key: const ValueKey('home-new'),
          // führt zu «Neu beginnen»: dort Format oder Vorlage wählen (gleich wie überall)
          onPressed: _showNewSection,
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 46),
            backgroundColor: Ui.accent,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            textStyle: const TextStyle(fontFamily: Ui.fontFamily, fontSize: 14, fontWeight: FontWeight.w600),
          ),
          icon: const Icon(Icons.add_rounded),
          label: const Text('Neues Dokument'),
        ),
        const SizedBox(height: 12),
        _nav('home-nav-docs', Icons.description_outlined, 'Meine Dokumente', _view == _View.docs, () => _show(_View.docs)),
        _nav('home-nav-templates', Icons.dashboard_customize_outlined, 'Vorlagen', _view == _View.templates, () => _show(_View.templates)),
        _nav('home-nav-trash', Icons.delete_outline_rounded, 'Papierkorb', _view == _View.trash, () => _show(_View.trash)),
        const Spacer(),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: const Color(0xFFF4F6F9), borderRadius: BorderRadius.circular(10)),
          child: const Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: 'Du musst nichts speichern. ',
                  style: TextStyle(fontWeight: FontWeight.w700, color: Ui.ink),
                ),
                TextSpan(text: 'Textly bewahrt jede Änderung automatisch auf. Gelöschte Dokumente bleiben 30 Tage im Papierkorb.'),
              ],
            ),
            style: TextStyle(fontSize: 12, height: 1.5, color: Ui.muted),
          ),
        ),
      ],
    ),
  );

  Future<void> _show(_View v) async {
    setState(() {
      _view = v;
      _loading = true;
    });
    await _reload();
  }

  Widget _nav(String key, IconData icon, String label, bool active, VoidCallback onTap) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Material(
      color: active ? Ui.accentSoft : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        key: ValueKey(key),
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: SizedBox(
          height: 42,
          child: Row(
            children: [
              const SizedBox(width: 12),
              Icon(icon, size: 19, color: active ? Ui.accent : Ui.ink),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14, fontWeight: active ? FontWeight.w600 : FontWeight.w400, color: active ? Ui.accent : Ui.ink),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _grid(List<LibraryEntry> shown) {
    // Noch keine Dokumente: zuerst «Neu beginnen», darunter «Datei hereinholen»
    if (_entries.isEmpty && _query.isEmpty) {
      return ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          const Text(
            'Noch keine Dokumente. Beginne mit einem leeren Blatt oder einer Vorlage – oder hole eine Datei herein.',
            key: ValueKey('home-empty'),
            style: TextStyle(fontSize: 14, color: Ui.muted),
          ),
          const SizedBox(height: 22),
          _newSection(),
          const SizedBox(height: 30),
          _importCard(),
        ],
      );
    }
    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        Text(
          _query.isEmpty ? 'Zuletzt bearbeitet' : '${shown.length} gefunden',
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Ui.muted),
        ),
        const SizedBox(height: 12),
        Wrap(spacing: 22, runSpacing: 22, children: [for (final e in shown) _card(e), if (_query.isEmpty) _importCard()]),
        if (_query.isEmpty) ...[
          const SizedBox(height: 34),
          _newSection(),
        ],
      ],
    );
  }

  Widget _card(LibraryEntry e) => SizedBox(
    width: 200,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Material(
          color: const Color(0xFFE9EDF3),
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            key: ValueKey('doc-card-${e.id}'),
            borderRadius: BorderRadius.circular(12),
            onTap: () => _once(() => open(e)),
            child: SizedBox(height: 220, child: Center(child: _thumb(e, 150, 190))),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    e.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Ui.ink),
                  ),
                  const SizedBox(height: 2),
                  Text(relativeTime(e.modified, DateTime.now()), style: const TextStyle(fontSize: 12, color: Ui.muted)),
                ],
              ),
            ),
            PopupMenuButton<String>(
              key: ValueKey('doc-menu-${e.id}'),
              tooltip: 'Weitere Möglichkeiten',
              icon: const Icon(Icons.more_horiz_rounded),
              onSelected: (v) => switch (v) {
                'open' => _once(() => open(e)),
                'copy' => _once(() => _useAsCopy(e)),
                'rename' => _rename(e),
                'template' => _saveAsTemplate(e),
                'trash' => _moveToTrash(e),
                _ => null,
              },
              itemBuilder: (_) => const [
                PopupMenuItem(key: ValueKey('doc-open'), value: 'open', child: Text('Öffnen')),
                PopupMenuItem(
                  key: ValueKey('doc-copy'),
                  value: 'copy',
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('Als Kopie verwenden'),
                    subtitle: Text('z. B. für den nächsten Anlass'),
                  ),
                ),
                PopupMenuItem(key: ValueKey('doc-rename'), value: 'rename', child: Text('Umbenennen')),
                PopupMenuItem(
                  key: ValueKey('doc-template'),
                  value: 'template',
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('Als Vorlage speichern …'),
                    subtitle: Text('für ähnliche Dokumente'),
                  ),
                ),
                PopupMenuDivider(),
                PopupMenuItem(
                  key: ValueKey('doc-trash'),
                  value: 'trash',
                  child: Text('In den Papierkorb', style: TextStyle(color: Ui.danger)),
                ),
              ],
            ),
          ],
        ),
      ],
    ),
  );

  /// Vorschau der ersten Seite (hoch oder quer), eingepasst in [maxW] × [maxH].
  Widget _thumb(LibraryEntry e, double maxW, double maxH) => _thumbFrom(_thumbDoc(e), maxW, maxH);

  Widget _thumbFrom(Future<TextlyDocument> doc, double maxW, double maxH) => FutureBuilder<TextlyDocument>(
    future: doc,
    builder: (context, snap) {
      final d = snap.data;
      if (d == null) {
        return snap.hasError
            ? const Icon(Icons.broken_image_outlined, color: Ui.muted)
            : Container(width: maxW * .8, height: maxH, color: Colors.white);
      }
      final s = (maxW / d.pageWidth) < (maxH / d.pageHeight) ? maxW / d.pageWidth : maxH / d.pageHeight;
      return Container(
        width: d.pageWidth * s,
        height: d.pageHeight * s,
        decoration: const BoxDecoration(
          color: Colors.white,
          boxShadow: [BoxShadow(color: Color(0x1F101828), blurRadius: 8, offset: Offset(0, 2))],
        ),
        child: FittedBox(
          child: IgnorePointer(
            child: StaticPage(page: d.page(0), images: documentImages(d), widthMm: d.pageWidth, heightMm: d.pageHeight),
          ),
        ),
      );
    },
  );

  Widget _importCard() => SizedBox(
    width: 200,
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        key: const ValueKey('home-import'),
        borderRadius: BorderRadius.circular(12),
        onTap: () => _once(pickAndImport),
        child: DashedBorder(
          radius: 12,
          child: const SizedBox(
            height: 220,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.file_download_outlined, size: 28, color: Ui.ink),
                SizedBox(height: 8),
                Text(
                  'Datei öffnen',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Ui.ink),
                ),
                SizedBox(height: 2),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    'Word, PowerPoint oder .textly – kommt als Kopie in «Meine Dokumente»',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: Ui.muted),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  /// Hinweis, wenn «Meine Dokumente» gerade nicht lesbar ist – statt einer (falschen) leeren Liste.
  Widget _unavailableNote() => Align(
    alignment: Alignment.topLeft,
    child: Container(
      key: const ValueKey('home-unavailable'),
      constraints: const BoxConstraints(maxWidth: 560),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(color: Ui.warnBg, borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('«Meine Dokumente» lässt sich gerade nicht lesen', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Ui.ink)),
          const SizedBox(height: 8),
          const Text(
            'Der Ordner «Dokumente\\Textly» ist im Moment nicht erreichbar, zum Beispiel weil OneDrive gerade '
            'synchronisiert oder die Datei von einem anderen Programm gesperrt ist. Deine Dokumente sind nicht verloren.',
            style: TextStyle(fontSize: 13.5, height: 1.45, color: Ui.ink),
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            key: const ValueKey('home-retry'),
            onPressed: () {
              setState(() => _loading = true);
              _reload();
            },
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Nochmals versuchen'),
          ),
        ],
      ),
    ),
  );

  // ---------- Neu beginnen: leeres Blatt und Vorlagen ----------

  final _search = TextEditingController();
  final _newKey = GlobalKey();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// «Neues Dokument»: zu «Neu beginnen» springen (Suche leeren, Ansicht «Meine Dokumente»).
  Future<void> _showNewSection() async {
    if (_view != _View.docs) await _show(_View.docs);
    if (_query.isNotEmpty) {
      _search.clear();
      setState(() => _query = '');
    }
    setState(() => _filter = null);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _newKey.currentContext;
      if (ctx != null) Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 350), curve: Curves.easeOut);
    });
  }

  /// Filter unter «Neu beginnen»: null = alle, 'mine' = eigene, sonst eine [TemplateKind].
  String? _filter;
  PaperSize _blankPaper = PaperSize.a4;
  PageOrientation _blankOrientation = PageOrientation.portrait;
  final _builtinDocs = <String, Future<TextlyDocument>>{};

  Future<TextlyDocument> _builtinDoc(BuiltinTemplate b) => _builtinDocs[b.id] ??= Future.value(b.build());

  bool _passes(TemplateKind kind, {required bool own}) => switch (_filter) {
    null => true,
    'mine' => own,
    final f => kind.name == f,
  };

  Widget _newSection() {
    final kinds = {for (final b in builtinTemplates) b.kind, for (final t in _ownTemplates) TemplateKind.of(t.templateKind)};
    Widget chip(String? value, String label, {IconData? icon}) => ChoiceChip(
      key: ValueKey('home-filter-${value ?? 'all'}'),
      avatar: icon == null ? null : Icon(icon, size: 16, color: Ui.accent),
      label: Text(label),
      selected: _filter == value,
      showCheckmark: false,
      onSelected: (_) => setState(() => _filter = value),
    );
    return Column(
      key: _newKey,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: Text('Neu beginnen', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Ui.ink)),
            ),
            chip(null, 'Alle'),
            for (final k in TemplateKind.values)
              if (kinds.contains(k)) chip(k.name, k.plural),
            if (_ownTemplates.isNotEmpty) chip('mine', 'Meine Vorlagen', icon: Icons.star_rounded),
          ],
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 22,
          runSpacing: 22,
          children: [
            if (_filter == null) _blankTile(),
            for (final t in _ownTemplates)
              if (_passes(TemplateKind.of(t.templateKind), own: true)) _templateCard(t),
            for (final b in builtinTemplates)
              if (_passes(b.kind, own: false)) _builtinCard(b),
          ],
        ),
      ],
    );
  }

  /// «Leeres Blatt»: Papiergrösse und Ausrichtung direkt auf der Kachel wählen.
  Widget _blankTile() {
    final landscape = _blankOrientation == PageOrientation.landscape;
    final w = landscape ? _blankPaper.longMm : _blankPaper.shortMm, h = landscape ? _blankPaper.shortMm : _blankPaper.longMm;
    // Massstab: A3 füllt die Kachel, A5 ist sichtbar kleiner
    final s = 120 / 420;
    Widget pick<T>(String key, String label, T value, T current, void Function(T) set) => Padding(
      padding: const EdgeInsets.only(right: 4),
      child: ChoiceChip(
        key: ValueKey(key),
        label: Text(label, style: const TextStyle(fontSize: 12)),
        selected: value == current,
        showCheckmark: false,
        labelPadding: const EdgeInsets.symmetric(horizontal: 2),
        onSelected: (_) => setState(() => set(value)),
      ),
    );
    return SizedBox(
      width: 200,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DashedBorder(
            radius: 12,
            child: Column(children: [
              Material(
                color: Colors.transparent,
                child: InkWell(
                  key: const ValueKey('home-new-blank'),
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                  onTap: () => _once(() => newDocument(_blankOrientation, paper: _blankPaper)),
                  child: SizedBox(
                    height: 140,
                    width: double.infinity,
                    child: Center(
                      child: Container(
                        width: w * s,
                        height: h * s,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          border: Border.all(color: const Color(0xFF98A2B3), width: 1.4),
                          borderRadius: BorderRadius.circular(2),
                        ),
                        alignment: Alignment.center,
                        child: const Icon(Icons.add_rounded, color: Ui.muted),
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                child: Column(children: [
                  Wrap(alignment: WrapAlignment.center, runSpacing: 4, children: [
                    for (final p in PaperSize.values) pick('home-paper-${p.name}', p.label, p, _blankPaper, (v) => _blankPaper = v),
                  ]),
                  const SizedBox(height: 4),
                  Wrap(alignment: WrapAlignment.center, runSpacing: 4, children: [
                    pick('home-orient-portrait', 'Hochformat', PageOrientation.portrait, _blankOrientation, (v) => _blankOrientation = v),
                    pick('home-orient-landscape', 'Querformat', PageOrientation.landscape, _blankOrientation, (v) => _blankOrientation = v),
                  ]),
                ]),
              ),
            ]),
          ),
          const SizedBox(height: 8),
          const Text('Leeres Blatt', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Ui.ink)),
          const SizedBox(height: 2),
          Text(
            '${_blankPaper.label} ${landscape ? 'Querformat' : 'Hochformat'} · Format wählen, dann aufs Blatt klicken',
            style: const TextStyle(fontSize: 12, color: Ui.muted),
          ),
        ],
      ),
    );
  }

  Widget _tile({required Key key, required Future<TextlyDocument> doc, required VoidCallback onTap, required String name, required String note, Widget? badge, Widget? menu}) =>
      SizedBox(
        width: 200,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Material(
              color: const Color(0xFFE9EDF3),
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                key: key,
                borderRadius: BorderRadius.circular(12),
                onTap: onTap,
                child: SizedBox(
                  height: 220,
                  child: Stack(children: [
                    Center(child: _thumbFrom(doc, 150, 190)),
                    if (badge != null) Positioned(left: 10, top: 10, child: badge),
                  ]),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Ui.ink)),
                      const SizedBox(height: 2),
                      Text(note, style: const TextStyle(fontSize: 12, color: Ui.muted)),
                    ],
                  ),
                ),
                ?menu,
              ],
            ),
          ],
        ),
      );

  Widget _ownBadge() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(6)),
    child: const Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.star_rounded, size: 13, color: Ui.accent),
      SizedBox(width: 3),
      Text('Eigene', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Ui.accent)),
    ]),
  );

  /// Eigene Vorlage: Klick legt ein neues Dokument an; im Menü bearbeiten, umbenennen, löschen.
  Widget _templateCard(LibraryEntry t) => _tile(
    key: ValueKey('tpl-card-${t.id}'),
    doc: _thumbDoc(t),
    onTap: () => _once(() => _fromTemplate(t)),
    name: t.name,
    note: TemplateKind.of(t.templateKind).label,
    badge: _ownBadge(),
    menu: PopupMenuButton<String>(
      key: ValueKey('tpl-menu-${t.id}'),
      tooltip: 'Weitere Möglichkeiten',
      icon: const Icon(Icons.more_horiz_rounded),
      onSelected: (v) => switch (v) {
        'use' => _once(() => _fromTemplate(t)),
        'edit' => _once(() => open(t, message: 'Du bearbeitest die Vorlage «${t.name}». Neue Dokumente daraus sehen dann so aus.')),
        'rename' => _rename(t),
        'trash' => _moveToTrash(t),
        _ => null,
      },
      itemBuilder: (_) => const [
        PopupMenuItem(key: ValueKey('tpl-use'), value: 'use', child: Text('Neues Dokument daraus')),
        PopupMenuItem(key: ValueKey('tpl-edit'), value: 'edit', child: Text('Vorlage bearbeiten')),
        PopupMenuItem(key: ValueKey('tpl-rename'), value: 'rename', child: Text('Umbenennen')),
        PopupMenuDivider(),
        PopupMenuItem(
          key: ValueKey('tpl-trash'),
          value: 'trash',
          child: Text('In den Papierkorb', style: TextStyle(color: Ui.danger)),
        ),
      ],
    ),
  );

  Widget _builtinCard(BuiltinTemplate b) => FutureBuilder<TextlyDocument>(
    future: _builtinDoc(b),
    builder: (context, snap) {
      final d = snap.data;
      final format = d == null ? '' : ' · ${d.paper.label} ${d.orientation == PageOrientation.landscape ? 'Querformat' : 'Hochformat'}';
      return _tile(key: ValueKey('tpl-builtin-${b.id}'), doc: _builtinDoc(b), onTap: () => _once(() => _fromBuiltin(b)), name: b.name, note: '${b.kind.label}$format');
    },
  );

  /// Neues Dokument aus einer eigenen Vorlage (Kopie; die Vorlage bleibt unverändert).
  Future<void> _fromTemplate(LibraryEntry t) async {
    final TextlyDocument doc;
    try {
      doc = await lib.load(t.id);
    } catch (_) {
      _snack('Die Vorlage «${t.name}» lässt sich nicht öffnen. Die Datei ist beschädigt.');
      return;
    }
    final e = await lib.create(doc);
    await _reload();
    await open(e, message: 'Neues Dokument aus der Vorlage «${t.name}». Die Vorlage bleibt unverändert.');
  }

  Future<void> _fromBuiltin(BuiltinTemplate b) async {
    final e = await lib.create(b.build());
    await _reload();
    await open(e, message: 'Neues Dokument aus der Vorlage «${b.name}». Klicke in einen Text und schreibe darüber.');
  }

  /// «Als Vorlage speichern …» im Menü einer Dokumentkarte.
  Future<void> _saveAsTemplate(LibraryEntry e) async {
    final r = await showSaveTemplateDialog(context, name: e.name, preview: _thumbFrom(_thumbDoc(e), 110, 150));
    if (r == null) return;
    final t = await lib.saveAsTemplate(e.id, name: r.name, kind: r.kind.name);
    await _reload();
    _snack('Vorlage «${t.name}» gespeichert. Du findest sie unter «Neu beginnen» und bei «Vorlagen».');
  }

  /// Seite «Vorlagen»: eigene (bearbeiten, umbenennen, löschen) und mitgelieferte.
  Widget _templatesView() => ListView(
    key: const PageStorageKey('vorlagen'),
    padding: const EdgeInsets.only(bottom: 32),
    children: [
      const Text('Meine Vorlagen', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Ui.muted)),
      const SizedBox(height: 12),
      if (_ownTemplates.isEmpty)
        const Text(
          'Noch keine eigenen Vorlagen. In «Meine Dokumente» im Menü «…» eines Dokuments «Als Vorlage speichern …» wählen.',
          key: ValueKey('tpl-empty'),
          style: TextStyle(fontSize: 13.5, color: Ui.muted),
        )
      else
        Wrap(spacing: 22, runSpacing: 22, children: [for (final t in _ownTemplates) _templateCard(t)]),
      const SizedBox(height: 30),
      const Text('Mitgeliefert', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Ui.muted)),
      const SizedBox(height: 12),
      Wrap(spacing: 22, runSpacing: 22, children: [for (final b in builtinTemplates) _builtinCard(b)]),
    ],
  );

  Widget _trashList() {
    if (_entries.isEmpty) {
      return const Align(
        alignment: Alignment.topLeft,
        child: Text('Der Papierkorb ist leer.', style: TextStyle(fontSize: 14, color: Ui.muted)),
      );
    }
    return ListView(
      children: [
        const Text(
          'Gelöschte Dokumente bleiben 30 Tage hier, danach werden sie endgültig entfernt.',
          style: TextStyle(fontSize: 13, color: Ui.muted),
        ),
        const SizedBox(height: 14),
        for (final e in _entries)
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Ui.line),
            ),
            child: Row(
              children: [
                SizedBox(width: 60, height: 70, child: Center(child: _thumb(e, 50, 66))),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        e.name,
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Ui.ink),
                      ),
                      Text('Gelöscht ${relativeTime(e.deletedAt!, DateTime.now())}', style: const TextStyle(fontSize: 12, color: Ui.muted)),
                    ],
                  ),
                ),
                OutlinedButton(key: ValueKey('trash-restore-${e.id}'), onPressed: () => _restore(e), child: const Text('Wiederherstellen')),
                const SizedBox(width: 8),
                TextButton(
                  key: ValueKey('trash-delete-${e.id}'),
                  onPressed: () => _deleteForever(e),
                  style: TextButton.styleFrom(foregroundColor: Ui.danger),
                  child: const Text('Endgültig löschen'),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// «gerade eben», «vor 5 Minuten», «gestern», «vor 3 Tagen», sonst Datum.
String relativeTime(DateTime t, DateTime now) {
  final d = now.difference(t);
  if (d.inMinutes < 1) return 'gerade eben';
  if (d.inMinutes < 60) return d.inMinutes == 1 ? 'vor 1 Minute' : 'vor ${d.inMinutes} Minuten';
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(t.year, t.month, t.day);
  final days = today.difference(day).inDays;
  if (days == 0) return d.inHours == 1 ? 'vor 1 Stunde' : 'vor ${d.inHours} Stunden';
  if (days == 1) return 'gestern';
  if (days < 7) return 'vor $days Tagen';
  return '${t.day}.${t.month}.${t.year}';
}
