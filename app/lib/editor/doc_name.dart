import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'toolbar_widgets.dart';

/// Dokumentname mitten im Kopf: «Dokument: Name ✎». Klick auf den Namen oder den Stift macht daraus ein
/// Eingabefeld; Enter oder Klick daneben übernimmt, Esc bricht ab. Leer übernommen folgt der Name wieder
/// dem ersten Text. Ohne [onRename] (Datei ausserhalb von «Meine Dokumente») nur Anzeige.
class DocName extends StatefulWidget {
  const DocName({super.key, required this.name, this.onRename, this.tooltip, this.trailing});
  final String name;
  final ValueChanged<String>? onRename;
  final String? tooltip;

  /// z. B. ein Hinweis «Nicht gespeichert» rechts neben dem Namen.
  final Widget? trailing;

  @override
  State<DocName> createState() => _DocNameState();
}

class _DocNameState extends State<DocName> {
  bool _editing = false;
  final _text = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus && _editing) _commit();
    });
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _start() {
    setState(() => _editing = true);
    _text.text = widget.name;
    _text.selection = TextSelection(baseOffset: 0, extentOffset: _text.text.length);
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  void _commit() {
    if (!_editing) return;
    setState(() => _editing = false);
    final v = _text.text.trim();
    if (v != widget.name) widget.onRename?.call(v);
  }

  void _cancel() {
    setState(() => _editing = false);
    _focus.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    const label = Text('Dokument:', style: TextStyle(fontSize: 12.5, color: Ui.muted));
    final canRename = widget.onRename != null;
    if (_editing) {
      return Container(
        key: const ValueKey('doc-name'),
        height: 36,
        padding: const EdgeInsets.only(left: 12, right: 4),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: Ui.accent, width: 2),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          label,
          const SizedBox(width: 8),
          SizedBox(
            width: 260,
            child: CallbackShortcuts(
              bindings: {const SingleActivator(LogicalKeyboardKey.escape): _cancel},
              child: TextField(
                key: const ValueKey('doc-name-field'),
                controller: _text,
                focusNode: _focus,
                maxLength: 80,
                onSubmitted: (_) => _commit(),
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Ui.ink),
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  counterText: '',
                  hintText: 'Name folgt dem ersten Text',
                  contentPadding: EdgeInsets.symmetric(vertical: 6),
                ),
              ),
            ),
          ),
          IconButton(
            key: const ValueKey('doc-name-ok'),
            onPressed: _commit,
            tooltip: 'Namen übernehmen',
            style: IconButton.styleFrom(
              backgroundColor: Ui.accent,
              foregroundColor: Colors.white,
              minimumSize: const Size(32, 32),
              fixedSize: const Size(32, 32),
              padding: EdgeInsets.zero,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
            ),
            icon: const Icon(Icons.check_rounded, size: 18),
          ),
        ]),
      );
    }
    final content = Row(mainAxisSize: MainAxisSize.min, children: [
      label,
      const SizedBox(width: 8),
      Flexible(
        child: Text(
          widget.name,
          key: const ValueKey('doc-title'),
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15, color: Ui.ink),
        ),
      ),
      if (canRename) ...[
        const SizedBox(width: 6),
        const Icon(Icons.edit_outlined, key: ValueKey('doc-rename'), size: 16, color: Ui.accent),
      ],
      if (widget.trailing != null) ...[const SizedBox(width: 10), Flexible(child: widget.trailing!)],
    ]);
    final box = Material(
        key: const ValueKey('doc-name'),
        color: Ui.field.withValues(alpha: .6),
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          borderRadius: BorderRadius.circular(9),
          onTap: canRename ? _start : null,
          child: Container(
            height: 34,
            padding: EdgeInsets.only(left: 12, right: canRename ? 10 : 12),
            child: content,
          ),
        ),
    );
    final tip = widget.tooltip ?? (canRename ? 'Namen ändern' : null);
    return tip == null ? box : Tooltip(message: tip, child: box);
  }
}
