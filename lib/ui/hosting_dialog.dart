import 'package:flutter/material.dart';

import '../core/db/hosting_target_store.dart';
import '../core/providers/hosting_templates.dart';
import 'common.dart';

/// Create/edit a hosting target. Returns the edited value (id is '' when creating).
Future<HostingTarget?> showHostingDialog(
  BuildContext context, {
  HostingTarget? existing,
}) => showDialog<HostingTarget>(
  context: context,
  builder: (_) => _HostingDialog(existing: existing),
);

class _HostingDialog extends StatefulWidget {
  const _HostingDialog({this.existing});
  final HostingTarget? existing;

  @override
  State<_HostingDialog> createState() => _HostingDialogState();
}

class _HostingDialogState extends State<_HostingDialog> {
  late final _name = TextEditingController(text: widget.existing?.name);
  late final _account = TextEditingController(text: widget.existing?.accountId);
  late final _region = TextEditingController(text: widget.existing?.region);
  late final _console = TextEditingController(
    text: widget.existing?.consoleUrl,
  );
  late final _notes = TextEditingController(text: widget.existing?.notes);
  late String _provider = widget.existing?.provider ?? 'digitalocean';
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.existing == null) _applyTemplate(_provider);
  }

  @override
  void dispose() {
    for (final c in [_name, _account, _region, _console, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Pre-fill the console URL (and name) when the user has not typed their own.
  void _applyTemplate(String id) {
    final t = templateFor(id);
    final previous = templateFor(_provider);
    if (_console.text.isEmpty || _console.text == previous.consoleUrl) {
      _console.text = t.consoleUrl;
    }
    if (_name.text.isEmpty || _name.text == previous.label) {
      _name.text = t.label;
    }
  }

  void _save() {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'Name is required');
      return;
    }
    Navigator.pop(
      context,
      HostingTarget(
        id: widget.existing?.id ?? '',
        name: _name.text.trim(),
        provider: _provider,
        accountId: _account.text.trim(),
        region: _region.text.trim(),
        consoleUrl: _console.text.trim(),
        notes: _notes.text,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tpl = templateFor(_provider);
    return AlertDialog(
      title: Text(
        widget.existing == null ? 'New hosting target' : 'Edit hosting target',
      ),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: _provider,
                decoration: const InputDecoration(
                  labelText: 'Provider',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final t in hostingTemplates)
                    DropdownMenuItem(value: t.id, child: Text(t.label)),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  setState(() {
                    _applyTemplate(v);
                    _provider = v;
                  });
                },
              ),
              if (tpl.hint.isNotEmpty)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      tpl.hint,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              labeledField(
                'Name',
                _name,
                error: _error,
                hint: 'e.g. DigitalOcean – personal',
              ),
              labeledField('Account / project id', _account),
              labeledField('Region', _region),
              labeledField('Console URL', _console),
              labeledField('Billing / other notes', _notes, lines: 3),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
