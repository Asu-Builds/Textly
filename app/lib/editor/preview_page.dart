import 'dart:math' as math;

import 'package:doc_model/doc_model.dart';
import 'package:doc_render/doc_render.dart';
import 'package:flutter/material.dart';

import 'toolbar_widgets.dart';

const _bg = Color(0xFFE8EBEF);
const _panel = Color(0xFFF8F9FB);
const _severe = Color(0xFFC0392B);
const _warn = Color(0xFFD98A00);

/// «Fertigstellen» (Spezifikation 9.2): ein Weg für alles, was am Schluss mit dem Dokument passiert.
/// 1. Prüfen: alle Seiten so, wie sie gedruckt werden, mit Hinweisen auf Probleme
///    (ein Klick auf einen Hinweis kehrt zum Editor zurück und wählt das Element aus).
/// 2. Wählen: Drucken, als PDF speichern, per E-Mail senden, als Datei weitergeben, PowerPoint.
class PreviewPage extends StatelessWidget {
  const PreviewPage({
    super.key,
    required this.doc,
    required this.onPdf,
    required this.onPrint,
    this.name,
    this.onEmail,
    this.onTextly,
    this.onTemplate,
    this.onPowerPoint,
  });

  final TextlyDocument doc;
  final String? name;
  final Future<void> Function() onPdf;
  final Future<void> Function() onPrint;
  final Future<void> Function()? onEmail;
  final Future<void> Function()? onTextly;

  /// «Als Vorlage speichern» (nur für Dokumente aus «Meine Dokumente»).
  final Future<void> Function()? onTemplate;
  final Future<void> Function()? onPowerPoint;

  @override
  Widget build(BuildContext context) {
    final issues = printIssues(doc);
    final images = documentImages(doc);
    final n = doc.pages.length;
    final format = '${doc.paper.label} ${doc.orientation == PageOrientation.landscape ? 'Querformat' : 'Hochformat'}';
    return _BusyScope(
      child: Scaffold(
      backgroundColor: _bg,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(56),
        child: Container(
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: const BoxDecoration(color: Colors.white, border: Border(bottom: BorderSide(color: Ui.line))),
          child: Row(children: [
            TextButton.icon(
              key: const ValueKey('preview-close'),
              onPressed: () => Navigator.pop(context),
              style: TextButton.styleFrom(
                backgroundColor: Ui.field,
                foregroundColor: Ui.ink,
                minimumSize: const Size(0, 36),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                textStyle: const TextStyle(fontFamily: Ui.fontFamily, fontSize: 13, fontWeight: FontWeight.w500),
              ),
              icon: const Icon(Icons.chevron_left_rounded, size: 20),
              label: const Text('Weiter bearbeiten'),
            ),
            const SizedBox(width: 14),
            const Text('Fertigstellen', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Ui.ink)),
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                '${name == null ? '' : '$name · '}$n ${n == 1 ? 'Seite' : 'Seiten'} · $format',
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, color: Ui.muted),
              ),
            ),
          ]),
        ),
      ),
      body: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(width: 290, child: _IssueList(issues: issues)),
        const VerticalDivider(width: 1, color: Color(0xFFD5DAE1)),
        Expanded(
          child: LayoutBuilder(builder: (context, box) {
            // Querformat darf breiter werden, damit die Schrift gleich gross erscheint
            final width = math.max(120.0, math.min(doc.orientation == PageOrientation.landscape ? 900.0 : 620.0, box.maxWidth - 56));
            final scale = width / (doc.pageWidth * mmToPt);
            return ListView.builder(
              key: const ValueKey('preview-pages'),
              padding: const EdgeInsets.symmetric(vertical: 24),
              itemCount: n,
              itemBuilder: (context, p) => Column(children: [
                Material(
                  elevation: 3,
                  child: SizedBox(
                    width: width,
                    height: doc.pageHeight * mmToPt * scale,
                    child: FittedBox(
                      child: Stack(children: [
                        StaticPage(
                          key: ValueKey('preview-page-$p'),
                          page: doc.page(p),
                          images: images,
                          widthMm: doc.pageWidth,
                          heightMm: doc.pageHeight,
                        ),
                        // betroffene Elemente markieren (nur hier, nicht im Druck)
                        for (final i in issues.where((i) => i.pageIndex == p))
                          if (doc.page(p).find(i.elementId) case final e?)
                            Positioned.fromRect(
                              rect: elementRectPt(e).inflate(2),
                              child: IgnorePointer(
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    border: Border.all(color: i.isSevere ? _severe : _warn, width: 2),
                                    color: (i.isSevere ? _severe : _warn).withValues(alpha: .06),
                                  ),
                                ),
                              ),
                            ),
                      ]),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 6, bottom: 22),
                  child: Text('Seite ${p + 1}', style: const TextStyle(color: Ui.muted, fontSize: 12)),
                ),
              ]),
            );
          }),
        ),
        const VerticalDivider(width: 1, color: Color(0xFFD5DAE1)),
        SizedBox(
          width: 360,
          child: Container(
            color: _panel,
            child: ListView(padding: const EdgeInsets.fromLTRB(18, 18, 18, 18), children: [
              const _Step(number: 2, title: 'Was möchtest du damit tun?'),
              const SizedBox(height: 12),
              _Option(
                key: const ValueKey('preview-print'),
                icon: Icons.print_outlined,
                color: Ui.accent,
                title: 'Drucken',
                subtitle: switch (doc.paper) {
                  // A3 und A5 brauchen passendes Papier; sonst verkleinert bzw. vergrössert der Drucker auf A4
                  PaperSize.a3 => 'A3 braucht einen grossen Drucker. Sonst im Druckfenster «An Seite anpassen» wählen – dann wird es A4.',
                  PaperSize.a5 => 'Im Druckfenster Papier A5 wählen; auf A4-Papier wird sonst vergrössert.',
                  PaperSize.a4 => 'Auf deinem Drucker, $n ${n == 1 ? 'Seite' : 'Seiten'}',
                },
                primary: true,
                onTap: onPrint,
              ),
              _Option(
                key: const ValueKey('preview-pdf'),
                icon: Icons.picture_as_pdf_outlined,
                color: const Color(0xFFC2410C),
                title: 'Als PDF speichern',
                subtitle: 'Zum Aufbewahren oder für die Druckerei',
                onTap: onPdf,
              ),
              if (onEmail != null)
                _Option(
                  key: const ValueKey('finish-email'),
                  icon: Icons.mail_outline_rounded,
                  color: const Color(0xFF2457D6),
                  title: 'Per E-Mail senden',
                  subtitle: 'Legt das PDF bereit, du hängst es in deinem Mailprogramm an',
                  onTap: onEmail!,
                ),
              if (onTextly != null)
                _Option(
                  key: const ValueKey('finish-textly'),
                  icon: Icons.drive_file_move_outline,
                  color: const Color(0xFF1F9D63),
                  title: 'Zum Weiterbearbeiten weitergeben',
                  subtitle: 'Textly-Datei, z. B. für den USB-Stick – ohne Verlauf',
                  onTap: onTextly!,
                ),
              if (onTemplate != null)
                _Option(
                  key: const ValueKey('finish-template'),
                  icon: Icons.dashboard_customize_outlined,
                  color: const Color(0xFF7A4CC2),
                  title: 'Als Vorlage speichern',
                  subtitle: 'Für ähnliche Dokumente – erscheint unter «Neu beginnen»',
                  onTap: onTemplate!,
                ),
              if (onPowerPoint != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    key: const ValueKey('finish-pptx'),
                    onPressed: onPowerPoint,
                    style: TextButton.styleFrom(foregroundColor: Ui.accent, textStyle: const TextStyle(fontFamily: Ui.fontFamily, fontSize: 13)),
                    child: const Text('Als PowerPoint speichern …'),
                  ),
                ),
            ]),
          ),
        ),
      ]),
    ),
    );
  }
}

/// Nummerierter Schritt («1 Prüfen», «2 Was möchtest du damit tun?»).
class _Step extends StatelessWidget {
  const _Step({required this.number, required this.title});
  final int number;
  final String title;

  @override
  Widget build(BuildContext context) => Row(children: [
        Container(
          width: 26,
          height: 26,
          alignment: Alignment.center,
          decoration: const BoxDecoration(color: Ui.accent, shape: BoxShape.circle),
          child: Text('$number', style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700)),
        ),
        const SizedBox(width: 10),
        Expanded(child: Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Ui.ink))),
      ]);
}

/// Eine Wahl im Schritt 2: rundes Symbol, Titel, kurze Erklärung.
class _Option extends StatelessWidget {
  const _Option({
    super.key,
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.primary = false,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final Future<void> Function() onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    // Läuft gerade eine Aktion? Dann zeigt diese Option «Wird vorbereitet …», die anderen sind gesperrt.
    final busy = _Busy.of(context);
    final me = busy?.value == title;
    final blocked = busy?.value != null && !me;
    return Opacity(
      opacity: blocked ? .45 : 1,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Material(
          color: primary ? Ui.accentSoft : Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: primary ? Ui.accent : Ui.line, width: primary ? 1.5 : 1),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: blocked || me
                ? null
                : () async {
                    busy?.value = title;
                    try {
                      await onTap();
                    } finally {
                      if (busy?.value == title) busy?.value = null;
                    }
                  },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: primary ? color : Color.lerp(color, Colors.white, .86)),
                  child: Icon(icon, size: 21, color: primary ? Colors.white : color),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Ui.ink)),
                    const SizedBox(height: 2),
                    Text(me ? 'Wird vorbereitet … einen Moment.' : subtitle, style: const TextStyle(fontSize: 12, height: 1.35, color: Ui.muted)),
                  ]),
                ),
                if (me) ...[
                  const SizedBox(width: 10),
                  const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.6)),
                ],
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// Merkt sich, welche Option gerade arbeitet (für Fortschrittsanzeige und gegen Doppelklicks).
class _BusyScope extends StatefulWidget {
  const _BusyScope({required this.child});
  final Widget child;

  @override
  State<_BusyScope> createState() => _BusyScopeState();
}

class _BusyScopeState extends State<_BusyScope> {
  final _busy = ValueNotifier<String?>(null);

  @override
  void dispose() {
    _busy.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _Busy(notifier: _busy, child: widget.child);
}

class _Busy extends InheritedNotifier<ValueNotifier<String?>> {
  const _Busy({required super.notifier, required super.child});

  static ValueNotifier<String?>? of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_Busy>()?.notifier;
}

class _IssueList extends StatelessWidget {
  const _IssueList({required this.issues});
  final List<PrintIssue> issues;

  @override
  Widget build(BuildContext context) {
    final th = Theme.of(context).textTheme;
    return Container(
      color: _panel,
      child: ListView(padding: const EdgeInsets.all(18), children: [
        const _Step(number: 1, title: 'Prüfen: so wird es gedruckt'),
        const SizedBox(height: 12),
        if (issues.isEmpty)
          Container(
            key: const ValueKey('preview-ok'),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: const Color(0xFFE7F3EC), borderRadius: BorderRadius.circular(8)),
            child: const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.check_circle_outline, color: Color(0xFF1F7A5A), size: 20),
              SizedBox(width: 8),
              Expanded(
                child: Text('Keine Probleme gefunden. Alle Elemente liegen im druckbaren Bereich.', style: TextStyle(fontSize: 13, color: Color(0xFF1F5A44))),
              ),
            ]),
          )
        else ...[
          Text(
            '${issues.length} ${issues.length == 1 ? 'Hinweis' : 'Hinweise'}. Klicke auf einen Hinweis, um das Element zu bearbeiten.',
            style: th.bodySmall?.copyWith(color: Ui.muted),
          ),
          const SizedBox(height: 10),
          for (final (n, i) in issues.indexed)
            Card(
              key: ValueKey('issue-$n'),
              elevation: 0,
              color: Colors.white,
              margin: const EdgeInsets.only(bottom: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
                side: BorderSide(color: (i.isSevere ? _severe : _warn).withValues(alpha: .5)),
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => Navigator.pop(context, i),
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(i.isSevere ? Icons.error_outline : Icons.warning_amber_rounded, color: i.isSevere ? _severe : _warn, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(i.message, style: const TextStyle(fontSize: 13)),
                        const SizedBox(height: 3),
                        Text('Seite ${i.pageIndex + 1} · bearbeiten', style: const TextStyle(fontSize: 12, color: Ui.muted)),
                      ]),
                    ),
                  ]),
                ),
              ),
            ),
        ],
        const Divider(height: 28),
        Text(
          'Die Seiten erscheinen ohne Raster, Hilfslinien und Auswahl – so, wie sie gedruckt werden. '
          'Markierungen um betroffene Elemente erscheinen nur hier.',
          style: th.bodySmall?.copyWith(color: Ui.muted),
        ),
      ]),
    );
  }
}
