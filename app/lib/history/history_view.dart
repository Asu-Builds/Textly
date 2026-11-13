import 'dart:math' as math;

import 'package:doc_model/doc_model.dart';
import 'package:doc_render/doc_render.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../editor/editor_controller.dart';
import '../editor/toolbar_widgets.dart';
import '../library/autosave.dart';
import 'history_icon.dart';
import 'history_store.dart';

const _red = historyRed;

String _hm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// «heute 14:12», «gestern 19:40», «12.3. 10:05».
String historyTime(DateTime t, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final days = today.difference(DateTime(t.year, t.month, t.day)).inDays;
  if (days == 0) return 'heute ${_hm(t)}';
  if (days == 1) return 'gestern ${_hm(t)}';
  return '${t.day}.${t.month}.${t.year == now.year ? '' : t.year} ${_hm(t)}';
}

/// Verlauf eines Dokuments als Zeitstrahl unter dem Editor: wenige Sicherungspunkte (Löschungen, grosse
/// Veränderungen, Arbeitsabschnitte, Weitergaben). Der Editor bleibt, wie er ist; nur wenn ein früherer
/// Punkt gewählt ist, zeigt die Arbeitsfläche diesen Stand ([builder] bekommt die Vorschau, sonst null).
/// Oben die Tage, darunter die Stände des Tages mit Uhrzeit. Nichts wird verändert, bis «Mit diesem Stand
/// weiterarbeiten» gewählt wird; «Zurück zu meinem aktuellen Dokument» schliesst ohne Änderung.
class HistoryView extends StatefulWidget {
  const HistoryView({super.key, required this.session, required this.controller, required this.onClose, required this.builder, this.zoom, this.now});

  /// Zoom der Arbeitsfläche: die Vorschau erscheint gleich gross wie die Seite im Editor.
  final double? zoom;

  final AutosaveSession session;
  final EditorController controller;
  final VoidCallback onClose;

  /// Baut den Editor; [preview] ersetzt die Arbeitsfläche, solange ein früherer Stand gewählt ist.
  final Widget Function(Widget? preview) builder;

  /// Uhrzeit für «heute»/«gestern» (Tests).
  final DateTime Function()? now;

  @override
  State<HistoryView> createState() => _HistoryViewState();
}

class _HistoryViewState extends State<HistoryView> {
  HistoryStore get store => widget.session.history!;
  DateTime get _now => (widget.now ?? DateTime.now)();
  List<HistoryEntry> _entries = const [];

  /// Gewählter Punkt; null = «Jetzt» (aktueller Stand).
  int? _selected;
  TextlyDocument? _shown;

  /// Bei einer Löschung: die gelöschten Elemente mit ihrer Seite (für die gestrichelten Umrisse).
  List<({String page, DocElement element})> _ghosts = const [];
  final _cache = <int, Future<TextlyDocument>>{};
  final _focus = FocusNode(debugLabel: 'Verlauf');
  final _tl = ScrollController();
  final _tlKey = GlobalKey();

  /// Lage der Punkte des gezeigten Tages (für das Scrollen zum gewählten Punkt).
  Map<int?, double> _tlXs = const {};
  int _seenVersion = -1;

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_onSession);
    _lastDoc = widget.controller.doc;
    widget.controller.addListener(_onDoc);
    _reload();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    widget.session.removeListener(_onSession);
    widget.controller.removeListener(_onDoc);
    _focus.dispose();
    _tl.dispose();
    super.dispose();
  }

  void _onSession() {
    if (widget.session.historyVersion != _seenVersion) _reload();
  }

  late TextlyDocument _lastDoc;

  void _onDoc() {
    if (!mounted) return;
    final changed = !identical(widget.controller.doc, _lastDoc);
    _lastDoc = widget.controller.doc;
    if (changed && _selected != null) {
      _select(null); // Dokument verändert: zurück zum aktuellen Stand
    } else {
      setState(() {});
    }
  }

  Future<void> _reload() async {
    _seenVersion = widget.session.historyVersion;
    final List<HistoryEntry> list;
    try {
      list = await store.entries();
    } catch (_) {
      return; // Verlauf gerade nicht lesbar: bisherige Anzeige lassen
    }
    if (!mounted) return;
    final first = _entries.isEmpty;
    setState(() => _entries = list);
    if (_selected != null && !list.any((e) => e.n == _selected)) _select(null);
    // Beim Öffnen den neuesten Stand zeigen (ganz rechts)
    if (first) WidgetsBinding.instance.addPostFrameCallback((_) => _scrollTimeline(animate: false));
  }

  Future<TextlyDocument> _doc(int n) {
    if (_cache.length > 40) _cache.remove(_cache.keys.first);
    final f = _cache[n] ??= store.load(n);
    // fehlgeschlagenes Laden nicht merken (beim nächsten Mal erneut versuchen)
    f.catchError((Object _) {
      _cache.remove(n);
      return TextlyDocument(pages: [DocPage(id: 'leer')]);
    });
    return f;
  }

  bool _restoring = false;

  /// Der gewählte Stand liess sich nicht lesen.
  bool _unreadable = false;

  Future<void> _select(int? n) async {
    setState(() {
      _selected = n;
      _shown = null;
      _ghosts = const [];
      _unreadable = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollTimeline());
    if (n == null) return;
    try {
      final d = await _doc(n);
      final e = _entries.where((x) => x.n == n).firstOrNull;
      final before = e != null && e.deleted.isNotEmpty ? await store.loadBefore(n) : null;
      final ghosts = [
        if (before != null)
          for (final p in before.pages)
            for (final el in p.elements)
              if (e!.deleted.contains(el.id)) (page: p.id, element: el),
      ];
      if (mounted && _selected == n) {
        setState(() {
          _shown = d;
          _ghosts = ghosts;
        });
      }
    } catch (_) {
      if (mounted && _selected == n) setState(() => _unreadable = true);
    }
  }

  /// Gewählten Punkt auf dem Zeitstrahl sichtbar machen.
  void _scrollTimeline({bool animate = true}) {
    if (!_tl.hasClients) return;
    final x = _tlXs[_selected];
    if (x == null) return;
    final pos = _tl.position;
    if (!animate) {
      _tl.jumpTo((x - pos.viewportDimension / 2).clamp(0.0, pos.maxScrollExtent));
      return;
    }
    final target = (x - pos.viewportDimension / 2).clamp(0.0, pos.maxScrollExtent);
    _tl.animateTo(target, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
  }

  HistoryEntry? get _entry => _selected == null ? null : _entries.where((e) => e.n == _selected).firstOrNull;

  /// Reihenfolge für Zeitstrahl und Pfeiltasten: älteste zuerst, «Jetzt» (null) am Ende.
  List<int?> get _stops => [for (final e in _entries) e.n, null];

  void _step(int delta) {
    final stops = _stops;
    final i = stops.indexOf(_selected);
    final j = (i + delta).clamp(0, stops.length - 1);
    if (j != i) _select(stops[j]);
  }

  // ---------- Aktionen ----------

  /// Den angezeigten Zustand dieses Punktes wiederherstellen.
  Future<void> _restoreThis(HistoryEntry e) async {
    if (_restoring) return; // Doppelklick
    final TextlyDocument old;
    try {
      old = await _doc(e.n);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Dieser Stand lässt sich nicht lesen. Bitte einen anderen wählen.')));
      }
      return;
    }
    _restoring = true;
    final label = 'Stand von ${historyTime(e.time, _now)} wiederhergestellt';
    try {
      await widget.session.restore(old, label);
    } finally {
      _restoring = false;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$label. Strg+Z macht es ungeschehen.')));
    widget.onClose(); // weiterarbeiten wie gewohnt
  }

  // ---------- Darstellung ----------

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Expanded(
        child: widget.builder(
          _selected == null
              ? null
              : ColoredBox(
                  key: const ValueKey('history-preview'),
                  color: const Color(0xFFE8EBEF),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _banner(),
                      Expanded(child: _preview()),
                    ],
                  ),
                ),
        ),
      ),
      const Divider(height: 1, color: Ui.line),
      Focus(
        focusNode: _focus,
        onKeyEvent: (_, ev) {
          if (ev is! KeyDownEvent && ev is! KeyRepeatEvent) return KeyEventResult.ignored;
          final k = ev.logicalKey;
          if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.arrowUp) {
            _step(-1);
          } else if (k == LogicalKeyboardKey.arrowRight || k == LogicalKeyboardKey.arrowDown) {
            _step(1);
          } else if (k == LogicalKeyboardKey.home && _entries.isNotEmpty) {
            _select(_entries.first.n);
          } else if (k == LogicalKeyboardKey.end) {
            _select(null);
          } else if (k == LogicalKeyboardKey.escape) {
            widget.onClose();
          } else {
            return KeyEventResult.ignored;
          }
          return KeyEventResult.handled;
        },
        child: Listener(onPointerDown: (_) => _focus.requestFocus(), child: _timeline()),
      ),
    ],
  );

  /// Gelber Hinweis über der Vorschau: was zu sehen ist – und dass noch nichts geändert wurde.
  Widget _banner() {
    final e = _entry;
    if (e == null) return const SizedBox.shrink();
    return Center(
      child: Container(
        margin: const EdgeInsets.fromLTRB(20, 14, 20, 0),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(color: const Color(0xFFFFF4DE), borderRadius: BorderRadius.circular(18)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.visibility_outlined, size: 18, color: Color(0xFF6B4A00)),
          const SizedBox(width: 10),
          Flexible(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(
                'Früherer Stand: ${e.name ?? e.label} (${historyTime(e.time, _now)})',
                key: const ValueKey('history-banner'),
                style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: Color(0xFF6B4A00)),
              ),
              Text(
                e.deleted.isEmpty
                    ? 'Nur zum Ansehen – noch nichts geändert.'
                    : 'Nur zum Ansehen – noch nichts geändert. Gestrichelt: was gelöscht wurde.',
                style: const TextStyle(fontSize: 12, color: Color(0xFF6B4A00)),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _preview() {
    final d = _selected == null ? widget.controller.doc : _shown;
    if (d == null && _unreadable) {
      return const Center(
        child: Text(
          'Dieser Stand lässt sich nicht lesen. Bitte einen anderen wählen.',
          key: ValueKey('history-unreadable'),
          style: TextStyle(fontSize: 14, color: Ui.muted),
        ),
      );
    }
    if (d == null) return const Center(child: CircularProgressIndicator());
    final images = documentImages(d);
    return LayoutBuilder(
      builder: (context, box) {
        final width = widget.zoom != null
            ? math.max(100.0, math.min(d.pageWidth * mmToPt * widget.zoom!, box.maxWidth - 64))
            : math.max(100.0, math.min(d.orientation == PageOrientation.landscape ? 900.0 : 560.0, box.maxWidth - 64));
        final scale = width / (d.pageWidth * mmToPt);
        return ListView.builder(
          key: const ValueKey('history-pages'),
          padding: const EdgeInsets.symmetric(vertical: 20),
          itemCount: d.pages.length,
          itemBuilder: (context, p) => Column(
            children: [
              Material(
                elevation: 3,
                child: SizedBox(
                  width: width,
                  height: d.pageHeight * mmToPt * scale,
                  child: FittedBox(
                    child: SizedBox(
                      width: d.pageWidth * mmToPt,
                      height: d.pageHeight * mmToPt,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          StaticPage(page: d.page(p), images: images, widthMm: d.pageWidth, heightMm: d.pageHeight),
                          for (final g in _ghosts)
                            if (g.page == d.page(p).id) _ghost(g.element, scale),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 6, bottom: 18),
                child: Text('Seite ${p + 1}', style: const TextStyle(fontSize: 12, color: Ui.muted)),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Gestrichelter Umriss, wo ein gelöschtes Element war (nur Markierung, keine Aktion).
  Widget _ghost(DocElement e, double scale) {
    final s = 1 / scale.clamp(.3, 3);
    final r = elementRectPt(e).inflate(3);
    return Positioned.fromRect(
      key: ValueKey('history-ghost-${e.id}'),
      rect: Rect.fromLTWH(r.left, r.top, math.max(r.width, 24), math.max(r.height, 14)),
      child: IgnorePointer(
        child: CustomPaint(
          painter: _DashedRect(color: _red, width: 1.6 * s, dash: 6 * s),
          child: Align(
            alignment: Alignment.topLeft,
            child: Transform.translate(
              offset: Offset(0, -16 * s),
              child: Transform.scale(
                scale: s,
                alignment: Alignment.topLeft,
                child: const Text(
                  'gelöscht',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: _red),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ---------- Tage ----------

  static DateTime _dayOf(DateTime t) => DateTime(t.year, t.month, t.day);
  static const _weekdays = ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'];
  static const _months = ['Jan.', 'Feb.', 'März', 'Apr.', 'Mai', 'Juni', 'Juli', 'Aug.', 'Sep.', 'Okt.', 'Nov.', 'Dez.'];

  /// «Heute», «Gestern», «Mo 9. Nov.» (ein anderes Jahr mit Jahreszahl).
  String _dayName(DateTime d) {
    final today = _dayOf(_now);
    final diff = today.difference(d).inDays;
    if (diff == 0) return 'Heute';
    if (diff == 1) return 'Gestern';
    return '${_weekdays[d.weekday - 1]} ${d.day}. ${_months[d.month - 1]}${d.year == today.year ? '' : ' ${d.year}'}';
  }

  /// Alle Tage mit gemerkten Ständen, dazu heute («Jetzt»); älteste zuerst.
  List<DateTime> get _days {
    final s = <DateTime>{for (final e in _entries) _dayOf(e.time), _dayOf(_now)};
    return s.toList()..sort();
  }

  DateTime get _shownDay => _entry == null ? _dayOf(_now) : _dayOf(_entry!.time);

  /// Tag wählen: heute → «Jetzt», sonst der letzte Stand dieses Tages.
  void _pickDay(DateTime d) {
    if (d == _dayOf(_now)) {
      _select(null);
      return;
    }
    final last = _entries.lastWhere((e) => _dayOf(e.time) == d, orElse: () => _entries.last);
    _select(last.n);
  }

  String _dayKey(DateTime d) => 'history-day-${d.year}-${d.month}-${d.day}';

  Widget _dayChip(DateTime d, bool on) {
    final count = _entries.where((e) => _dayOf(e.time) == d).length;
    final today = d == _dayOf(_now);
    return Material(
      key: ValueKey(_dayKey(d)),
      color: on ? Ui.accent : Ui.field,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _pickDay(d),
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (today) ...[
              Container(width: 7, height: 7, decoration: const BoxDecoration(color: Color(0xFF1B6B47), shape: BoxShape.circle)),
              const SizedBox(width: 7),
            ],
            Text(_dayName(d), style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: on ? Colors.white : Ui.ink)),
            if (count > 0) ...[
              const SizedBox(width: 6),
              Text('$count', style: TextStyle(fontSize: 12, color: on ? Colors.white70 : Ui.muted)),
            ],
          ]),
        ),
      ),
    );
  }

  /// Oben: Tage als Knöpfe (die letzten vier), ältere unter «Älter ▾».
  Widget _dayRow() {
    final days = _days;
    final shown = _shownDay;
    var visible = days.length <= 4 ? days : days.sublist(days.length - 4);
    if (!visible.contains(shown)) visible = [shown, ...visible.skip(1)];
    final older = [for (final d in days) if (!visible.contains(d)) d];
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 6,
      children: [
        if (older.isNotEmpty)
          PopupMenuButton<DateTime>(
            key: const ValueKey('history-day-older'),
            tooltip: 'Ältere Tage',
            onSelected: _pickDay,
            itemBuilder: (_) => [
              for (final d in older.reversed)
                PopupMenuItem(
                  key: ValueKey('${_dayKey(d)}-item'),
                  value: d,
                  child: Text('${_dayName(d)}  ·  ${_entries.where((e) => _dayOf(e.time) == d).length}'),
                ),
            ],
            child: Container(
              height: 32,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), border: Border.all(color: Ui.line)),
              child: const Row(mainAxisSize: MainAxisSize.min, children: [
                Text('Älter', style: TextStyle(fontSize: 12.5, color: Ui.muted)),
                Icon(Icons.expand_more_rounded, size: 16, color: Ui.muted),
              ]),
            ),
          ),
        for (final d in visible) _dayChip(d, d == shown),
      ],
    );
  }

  // ---------- Zeitstrahl eines Tages ----------

  /// Lage der Punkte des gezeigten Tages: nach Uhrzeit, lange Pausen (über 45 Minuten) verkürzt.
  /// Ergibt Abstände in Bildpunkten zwischen aufeinanderfolgenden Punkten und ob es eine Pause ist.
  static List<({double px, bool pause})> _gaps(List<DateTime> times) => [
    for (var i = 1; i < times.length; i++)
      () {
        final m = times[i].difference(times[i - 1]).inSeconds / 60;
        if (m > 45) return (px: 84.0, pause: true);
        return (px: (48 + m / 45 * 112).clamp(48.0, 160.0), pause: false);
      }(),
  ];

  /// Zeitstrahl: oben die Tage, darunter die Stände des gewählten Tages mit Uhrzeit, unten die Entscheidung.
  Widget _timeline() {
    final now = _now;
    final day = _shownDay;
    final isToday = day == _dayOf(now);
    final dayEntries = [for (final e in _entries) if (_dayOf(e.time) == day) e];
    // Punkte dieses Tages; heute kommt «Jetzt» dazu
    final stops = <int?>[for (final e in dayEntries) e.n, if (isToday) null];
    final times = [for (final e in dayEntries) e.time, if (isToday) now];
    final gaps = _gaps(times);
    final all = _stops;
    final idx = all.indexOf(_selected);
    final e = _entry;

    final decision = e == null
        ? Column(mainAxisSize: MainAxisSize.min, children: [
            const Text(
              'Du arbeitest am aktuellen Stand. Klicke auf einen Punkt, um einen früheren Stand anzusehen.',
              key: ValueKey('history-point-label'),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Ui.muted),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              key: const ValueKey('history-close'),
              onPressed: widget.onClose,
              style: _secondary,
              child: const Text('Zeitstrahl schliessen'),
            ),
          ])
        : Column(mainAxisSize: MainAxisSize.min, children: [
            Text.rich(
              TextSpan(children: [
                TextSpan(
                  text: e.name ?? e.label,
                  style: TextStyle(fontWeight: FontWeight.w700, color: e.kind == 'delete' ? Ui.danger : Ui.accent),
                ),
                TextSpan(
                  text: ' · ${e.from != null && _hm(e.from!) != _hm(e.time) ? '${_hm(e.from!)} – ${_hm(e.time)}' : historyTime(e.time, now)}',
                  style: const TextStyle(color: Ui.muted),
                ),
              ]),
              key: const ValueKey('history-point-label'),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 10),
            Wrap(alignment: WrapAlignment.center, spacing: 14, runSpacing: 8, children: [
              OutlinedButton.icon(
                key: const ValueKey('history-to-now'),
                onPressed: widget.onClose,
                style: _secondary,
                icon: const Icon(Icons.arrow_back_rounded, size: 18),
                label: const Text('Zurück zu meinem aktuellen Dokument'),
              ),
              FilledButton(
                key: const ValueKey('history-tl-restore'),
                onPressed: () => _restoreThis(e),
                style: FilledButton.styleFrom(
                  backgroundColor: Ui.accent,
                  minimumSize: const Size(0, 44),
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  textStyle: const TextStyle(fontFamily: Ui.fontFamily, fontSize: 14, fontWeight: FontWeight.w600),
                ),
                child: const Text('Mit diesem Stand weiterarbeiten'),
              ),
            ]),
            const SizedBox(height: 6),
            const Text(
              'Weiterarbeiten ersetzt den aktuellen Stand. Er bleibt unter «Heute» als Punkt erhalten – Rückgängig (Strg+Z) geht auch.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Ui.muted),
            ),
          ]);

    return Container(
      key: _tlKey,
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Stack(children: [
            const Positioned(
              left: 4,
              top: 7,
              child: Text('Frühere Stände', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Ui.ink)),
            ),
            Padding(padding: const EdgeInsets.symmetric(horizontal: 130), child: Center(child: _dayRow())),
          ]),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: _stepButton('history-back', Icons.chevron_left_rounded, 'Ein Stand zurück (←)', idx > 0 ? () => _step(-1) : null),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, box) {
                    const pad = 26.0, marker = 30.0;
                    final natural = gaps.fold(0.0, (s, g) => s + g.px) + 2 * pad;
                    final width = math.max(box.maxWidth, natural);
                    final start = (width - natural) / 2 + pad; // wenige Punkte: mittig
                    final xs = <double>[];
                    for (var i = 0; i < stops.length; i++) {
                      xs.add(i == 0 ? start : xs[i - 1] + gaps[i - 1].px);
                    }
                    _tlXs = {for (var i = 0; i < stops.length; i++) stops[i]: xs[i]};
                    final sel = stops.indexOf(_selected);
                    void pick(double px) {
                      if (stops.isEmpty) return;
                      var best = 0;
                      for (var i = 1; i < stops.length; i++) {
                        if ((xs[i] - px).abs() < (xs[best] - px).abs()) best = i;
                      }
                      if (stops[best] != _selected) _select(stops[best]);
                    }

                    final overflow = natural > box.maxWidth + .5;
                    return Listener(
                      // Mausrad (auch senkrecht) schiebt den Zeitstrahl seitwärts
                      onPointerSignal: (ev) {
                        if (ev is PointerScrollEvent && overflow && _tl.hasClients) {
                          final d = ev.scrollDelta.dx != 0 ? ev.scrollDelta.dx : ev.scrollDelta.dy;
                          _tl.jumpTo((_tl.offset + d).clamp(0.0, _tl.position.maxScrollExtent));
                        }
                      },
                      child: Scrollbar(
                      controller: _tl,
                      thumbVisibility: overflow,
                      trackVisibility: overflow,
                      thickness: 8,
                      radius: const Radius.circular(4),
                      child: SingleChildScrollView(
                        controller: _tl,
                        scrollDirection: Axis.horizontal,
                        child: SizedBox(
                          width: width,
                          // Platz unter den Uhrzeiten für den Scrollbalken
                          height: overflow ? 88 : 66,
                          child: GestureDetector(
                            key: const ValueKey('history-timeline'),
                            behavior: HitTestBehavior.opaque,
                            onTapDown: (d) => pick(d.localPosition.dx),
                            onHorizontalDragUpdate: (d) => pick(d.localPosition.dx),
                            child: Stack(
                              clipBehavior: Clip.none,
                              children: [
                                // Linie; Pausen hell gestrichelt mit «Pause»
                                for (var i = 1; i < stops.length; i++)
                                  Positioned(
                                    left: xs[i - 1],
                                    width: xs[i] - xs[i - 1],
                                    top: 17,
                                    height: 4,
                                    child: gaps[i - 1].pause
                                        ? const CustomPaint(painter: _PauseLine())
                                        : const DecoratedBox(decoration: BoxDecoration(color: Color(0xFFDCE3EE))),
                                  ),
                                for (var i = 1; i < stops.length; i++)
                                  if (gaps[i - 1].pause)
                                    Positioned(
                                      left: xs[i - 1],
                                      width: xs[i] - xs[i - 1],
                                      top: 24,
                                      child: const Text('Pause', textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: Ui.muted)),
                                    ),
                                for (var i = 0; i < stops.length; i++) ...[
                                  Positioned(
                                    left: xs[i] - marker / 2,
                                    top: 4,
                                    child: Tooltip(
                                      message: stops[i] == null
                                          ? 'Jetzt – aktueller Stand'
                                          : '${dayEntries[i].name ?? dayEntries[i].label}\n${historyTime(dayEntries[i].time, now)}',
                                      child: KeyedSubtree(
                                        key: ValueKey(stops[i] == null ? 'history-mark-now' : 'history-mark-${stops[i]}'),
                                        child: stops[i] == null
                                            ? NowPictogram(size: marker, selected: i == sel)
                                            : HistoryPictogram(dayEntries[i], size: marker, selected: i == sel),
                                      ),
                                    ),
                                  ),
                                  Positioned(
                                    key: i == sel ? const ValueKey('history-handle') : null,
                                    left: xs[i] - 30,
                                    width: 60,
                                    top: 42,
                                    child: Text(
                                      stops[i] == null ? 'Jetzt' : _hm(dayEntries[i].time),
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: i == sel ? FontWeight.w700 : FontWeight.w500,
                                        color: i == sel ? Ui.accent : Ui.muted,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(width: 12),
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: _stepButton(
                  'history-forward',
                  Icons.chevron_right_rounded,
                  'Ein Stand vor (→)',
                  idx >= 0 && idx < all.length - 1 ? () => _step(1) : null,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          decision,
        ],
      ),
    );
  }

  static final _secondary = OutlinedButton.styleFrom(
    foregroundColor: Ui.ink,
    minimumSize: const Size(0, 44),
    padding: const EdgeInsets.symmetric(horizontal: 16),
    side: const BorderSide(color: Color(0xFFC9D2E0), width: 1.5),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    textStyle: const TextStyle(fontFamily: Ui.fontFamily, fontSize: 14, fontWeight: FontWeight.w600),
  );

  Widget _stepButton(String key, IconData icon, String tip, VoidCallback? onTap) => Tooltip(
    message: tip,
    child: OutlinedButton(
      key: ValueKey(key),
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(44, 44),
        padding: EdgeInsets.zero,
        foregroundColor: Ui.ink,
        side: const BorderSide(color: Color(0xFFD0D5DD)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      child: Icon(icon),
    ),
  );
}

/// Gestrichelter Rahmen.
class _DashedRect extends CustomPainter {
  const _DashedRect({required this.color, required this.width, required this.dash});

  final Color color;
  final double width;
  final double dash;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = width
      ..style = PaintingStyle.stroke;
    final path = Path()..addRRect(RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(dash / 2)));
    for (final m in path.computeMetrics()) {
      for (var d = 0.0; d < m.length; d += dash * 2) {
        canvas.drawPath(m.extractPath(d, math.min(d + dash, m.length)), paint);
      }
    }
    canvas.drawRect(Offset.zero & size, Paint()..color = color.withValues(alpha: .05));
  }

  @override
  bool shouldRepaint(_DashedRect old) => old.color != color || old.width != width || old.dash != dash;
}

/// Gestrichelte, helle Linie für eine Arbeitspause auf dem Zeitstrahl.
class _PauseLine extends CustomPainter {
  const _PauseLine();

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = const Color(0xFFDCE3EE);
    for (var x = 0.0; x < size.width; x += 8) {
      canvas.drawRect(Rect.fromLTWH(x, 0, math.min(4, size.width - x), size.height), p);
    }
  }

  @override
  bool shouldRepaint(_PauseLine old) => false;
}
