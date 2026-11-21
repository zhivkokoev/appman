import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../core/db/console_link_store.dart';
import '../core/db/credential_store.dart';
import 'common.dart';

/// Labeled, categorised admin-console links for an application, environment or hosting target (spec F4).
class LinksSection extends StatefulWidget {
  const LinksSection({
    super.key,
    required this.controller,
    required this.owner,
    required this.readOnly,
    this.title = 'Console links',
  });
  final AppController controller;
  final Owner owner;
  final bool readOnly;
  final String title;

  @override
  State<LinksSection> createState() => _LinksSectionState();
}

class _LinksSectionState extends State<LinksSection> {
  ConsoleLinkStore get _store => widget.controller.consoleLinks;

  Future<void> _edit([ConsoleLink? existing]) async {
    final r = await showDialog<ConsoleLink>(
      context: context,
      builder: (_) => _LinkDialog(existing: existing),
    );
    if (r == null) return;
    if (existing == null) {
      _store.create(
        owner: widget.owner,
        label: r.label,
        url: r.url,
        type: r.type,
      );
    } else {
      _store.update(r);
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final links = _store.listFor(widget.owner, archived: widget.readOnly);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          widget.title,
          action: widget.readOnly
              ? null
              : TextButton.icon(
                  onPressed: () => _edit(),
                  icon: const Icon(Icons.add),
                  label: const Text('Add'),
                ),
        ),
        if (links.isEmpty)
          Text(
            widget.readOnly ? 'None' : 'No links yet (hosting panel, database admin, DNS, monitoring...).',
          ),
        for (final l in links)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.dashboard_outlined),
            title: Text(l.label),
            subtitle: Text(
              '${l.type} · ${l.url}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => openUrl(context, l.url),
            trailing: widget.readOnly
                ? null
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Open',
                        icon: const Icon(Icons.open_in_new),
                        onPressed: () => openUrl(context, l.url),
                      ),
                      IconButton(
                        tooltip: 'Edit',
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () => _edit(l),
                      ),
                      IconButton(
                        tooltip: 'Archive',
                        icon: const Icon(Icons.archive_outlined),
                        onPressed: () {
                          _store.setArchived(l.id, true);
                          setState(() {});
                        },
                      ),
                    ],
                  ),
          ),
      ],
    );
  }
}

class _LinkDialog extends StatefulWidget {
  const _LinkDialog({this.existing});
  final ConsoleLink? existing;

  @override
  State<_LinkDialog> createState() => _LinkDialogState();
}

class _LinkDialogState extends State<_LinkDialog> {
  late final _label = TextEditingController(text: widget.existing?.label);
  late final _url = TextEditingController(text: widget.existing?.url);
  late String _type = widget.existing?.type ?? 'hosting';
  String? _error;

  @override
  void dispose() {
    _label.dispose();
    _url.dispose();
    super.dispose();
  }

  void _save() {
    final uri = Uri.tryParse(_url.text.trim());
    if (_label.text.trim().isEmpty) {
      setState(() => _error = 'Label is required');
      return;
    }
    if (uri == null ||
        !(uri.scheme == 'https' || uri.scheme == 'http') ||
        uri.host.isEmpty) {
      setState(() => _error = 'Enter a full http(s) URL');
      return;
    }
    final base = widget.existing ?? ConsoleLink(id: '', label: '', url: '');
    Navigator.pop(
      context,
      base.copyWith(label: _label.text, url: _url.text, type: _type),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.existing == null ? 'Add console link' : 'Edit console link',
      ),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            labeledField('Label', _label),
            labeledField('URL', _url, hint: 'https://…', error: _error),
            DropdownButtonFormField<String>(
              initialValue: _type,
              decoration: const InputDecoration(
                labelText: 'Type',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final t in consoleLinkTypes)
                  DropdownMenuItem(value: t, child: Text(t)),
              ],
              onChanged: (v) => setState(() => _type = v ?? 'other'),
            ),
          ],
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
