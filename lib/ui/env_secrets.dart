import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../core/db/credential_store.dart';
import '../core/secrets/dotenv.dart';
import '../core/secrets/env_import.dart';
import 'credentials_section.dart';
import 'reauth.dart';

/// Runtime secrets of one environment with `.env` import/export (spec F5, F9).
class EnvironmentSecrets extends StatefulWidget {
  const EnvironmentSecrets({
    super.key,
    required this.controller,
    required this.environmentId,
    required this.readOnly,
  });
  final AppController controller;
  final String environmentId;
  final bool readOnly;

  @override
  State<EnvironmentSecrets> createState() => _EnvironmentSecretsState();
}

class _EnvironmentSecretsState extends State<EnvironmentSecrets> {
  final _section = GlobalKey<CredentialsSectionState>();

  void _toast(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _import() async {
    final entries = await showDialog<List<EnvEntry>>(
      context: context,
      builder: (_) => _ImportDialog(
        controller: widget.controller,
        environmentId: widget.environmentId,
      ),
    );
    if (entries == null) return;
    final summary = EnvImporter(
      widget.controller.credentials,
      widget.environmentId,
    ).apply(entries);
    _section.currentState?.refresh();
    if (mounted) _toast('.env imported: ${summary.text}');
  }

  Future<void> _export() async {
    final ok = await reauthenticate(
      context,
      widget.controller,
      reason: 'Exporting runtime secrets as a .env file reveals every value. Enter your master password to continue.',
    );
    if (!ok || !mounted) return;
    final text = widget.controller.exporter.environmentAsDotEnv(
      widget.environmentId,
    );
    for (final c in widget.controller.credentials.listFor(
      Owner.environment(widget.environmentId),
      purpose: CredentialPurpose.runtime,
    )) {
      widget.controller.credentials.markAccessed(c.id, how: 'export');
    }
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Export .env'),
        content: SizedBox(
          width: 560,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'These are plaintext secrets. Copy goes to the clipboard and is cleared automatically; a saved file is NOT encrypted.',
              ),
              const SizedBox(height: 8),
              Flexible(
                child: SingleChildScrollView(
                  child: SelectableText(
                    text.isEmpty ? '(no runtime secrets)' : text,
                    style: const TextStyle(fontFamily: 'Consolas'),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: text.isEmpty
                ? null
                : () async {
                    await widget.controller.clipboard.copy(text);
                    if (ctx.mounted) Navigator.pop(ctx);
                    if (mounted) {
                      _toast('Copied. Clipboard clears automatically.');
                    }
                  },
            child: const Text('Copy'),
          ),
          TextButton(
            onPressed: text.isEmpty
                ? null
                : () async {
                    final loc = await getSaveLocation(suggestedName: '.env');
                    if (loc == null) return;
                    await File(loc.path).writeAsString(text, flush: true);
                    if (ctx.mounted) Navigator.pop(ctx);
                    if (mounted) {
                      _toast(
                        'Saved to ${loc.path} (unencrypted). Delete it when done.',
                      );
                    }
                  },
            child: const Text('Save to file…'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CredentialsSection(
      key: _section,
      controller: widget.controller,
      owner: Owner.environment(widget.environmentId),
      purpose: CredentialPurpose.runtime,
      title: 'Runtime secrets',
      readOnly: widget.readOnly,
      extraActions: [
        TextButton.icon(
          onPressed: _import,
          icon: const Icon(Icons.upload_file),
          label: const Text('Import .env'),
        ),
        TextButton.icon(
          onPressed: _export,
          icon: const Icon(Icons.download),
          label: const Text('Export .env'),
        ),
      ],
    );
  }
}

class _ImportDialog extends StatefulWidget {
  const _ImportDialog({required this.controller, required this.environmentId});
  final AppController controller;
  final String environmentId;

  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _loadFile() async {
    final f = await openFile();
    if (f == null) return;
    final content = utf8.decode(await f.readAsBytes(), allowMalformed: true);
    if (mounted) setState(() => _text.text = content);
  }

  @override
  Widget build(BuildContext context) {
    final parsed = parseDotEnv(_text.text);
    final plan = EnvImporter(
      widget.controller.credentials,
      widget.environmentId,
    ).plan(parsed.entries);
    final icon = {
      EnvChange.added: Icons.add_circle_outline,
      EnvChange.updated: Icons.sync,
      EnvChange.unchanged: Icons.check,
    };
    return AlertDialog(
      title: const Text('Import .env'),
      content: SizedBox(
        width: 600,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Paste the contents of a .env file, or load one.',
                  ),
                ),
                TextButton.icon(
                  onPressed: _loadFile,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Load file…'),
                ),
              ],
            ),
            TextField(
              controller: _text,
              minLines: 6,
              maxLines: 10,
              onChanged: (_) => setState(() {}),
              style: const TextStyle(fontFamily: 'Consolas'),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'KEY=value',
              ),
            ),
            const SizedBox(height: 8),
            if (parsed.errors.isNotEmpty)
              Text(
                'Problems: ${parsed.errors.join('; ')}',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (plan.isNotEmpty)
              Flexible(
                child: SingleChildScrollView(
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final p in plan)
                        Chip(
                          visualDensity: VisualDensity.compact,
                          avatar: Icon(icon[p.change], size: 16),
                          label: Text('${p.key} · ${p.change.name}'),
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: parsed.entries.isEmpty
              ? null
              : () => Navigator.pop(context, parsed.entries),
          child: Text('Import ${parsed.entries.length} variable(s)'),
        ),
      ],
    );
  }
}
