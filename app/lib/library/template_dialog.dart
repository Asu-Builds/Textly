import 'package:flutter/material.dart';

import '../editor/toolbar_widgets.dart';
import 'templates.dart';

/// «Als Vorlage speichern»: Name und Art der Vorlage wählen. Ergibt null bei «Abbrechen».
Future<({String name, TemplateKind kind})?> showSaveTemplateDialog(BuildContext context, {required String name, Widget? preview}) =>
    showDialog<({String name, TemplateKind kind})>(context: context, builder: (_) => _SaveTemplateDialog(name: name, preview: preview));

class _SaveTemplateDialog extends StatefulWidget {
  const _SaveTemplateDialog({required this.name, this.preview});
  final String name;
  final Widget? preview;

  @override
  State<_SaveTemplateDialog> createState() => _SaveTemplateDialogState();
}

class _SaveTemplateDialogState extends State<_SaveTemplateDialog> {
  late final _name = TextEditingController(text: widget.name);
  TemplateKind _kind = TemplateKind.andere;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _ok() => Navigator.pop(context, (name: _name.text.trim().isEmpty ? widget.name : _name.text.trim(), kind: _kind));

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Als Vorlage speichern'),
    content: SizedBox(
      width: 480,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.preview != null) ...[
            Container(
              width: 130,
              height: 170,
              decoration: BoxDecoration(color: const Color(0xFFE9EDF3), borderRadius: BorderRadius.circular(10)),
              alignment: Alignment.center,
              child: widget.preview,
            ),
            const SizedBox(width: 18),
          ],
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  key: const ValueKey('tpl-name'),
                  controller: _name,
                  autofocus: true,
                  onSubmitted: (_) => _ok(),
                  decoration: const InputDecoration(labelText: 'Name der Vorlage', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 16),
                const Text('Art', style: TextStyle(fontSize: 12.5, color: Ui.muted)),
                const SizedBox(height: 6),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final k in TemplateKind.values)
                    ChoiceChip(
                      key: ValueKey('tpl-kind-${k.name}'),
                      label: Text(k.label),
                      selected: _kind == k,
                      showCheckmark: false,
                      onSelected: (_) => setState(() => _kind = k),
                    ),
                ]),
                const SizedBox(height: 14),
                const Text(
                  'Das Dokument selbst bleibt unverändert. Die Vorlage erscheint unter «Neu beginnen» und «Vorlagen».',
                  style: TextStyle(fontSize: 12, color: Ui.muted, height: 1.4),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Abbrechen')),
      FilledButton(key: const ValueKey('tpl-save'), onPressed: _ok, child: const Text('Vorlage speichern')),
    ],
  );
}
