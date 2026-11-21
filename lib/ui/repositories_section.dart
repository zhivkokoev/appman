import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../core/db/credential_store.dart';
import '../core/db/repository_store.dart';
import '../core/providers/git_providers.dart';
import 'common.dart';
import 'credentials_section.dart';

class RepositoriesSection extends StatefulWidget {
  const RepositoriesSection({
    super.key,
    required this.controller,
    required this.applicationId,
    required this.readOnly,
  });
  final AppController controller;
  final String applicationId;
  final bool readOnly;

  @override
  State<RepositoriesSection> createState() => _RepositoriesSectionState();
}

class _RepositoriesSectionState extends State<RepositoriesSection> {
  RepositoryStore get _store => widget.controller.repositories;

  Future<void> _edit([GitRepo? existing]) async {
    final result = await showDialog<GitRepo>(
      context: context,
      builder: (_) =>
          _RepoDialog(existing: existing, applicationId: widget.applicationId),
    );
    if (result == null) return;
    if (existing == null) {
      _store.create(
        applicationId: widget.applicationId,
        url: result.url,
        provider: result.provider,
        defaultBranch: result.defaultBranch,
        visibility: result.visibility,
        localPath: result.localPath,
        notes: result.notes,
      );
    } else {
      _store.update(result);
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final repos = _store.listForApplication(
      widget.applicationId,
      archived: widget.readOnly,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          'Repositories',
          action: widget.readOnly
              ? null
              : TextButton.icon(
                  onPressed: () => _edit(),
                  icon: const Icon(Icons.add),
                  label: const Text('Add'),
                ),
        ),
        if (repos.isEmpty)
          Text(
            widget.readOnly ? 'None' : 'No repository yet. Add the GitHub URL.',
          ),
        for (final r in repos)
          _RepoCard(
            controller: widget.controller,
            repo: r,
            readOnly: widget.readOnly,
            onEdit: () => _edit(r),
            onArchive: () async {
              if (await confirmDialog(
                context,
                'Archive repository?',
                r.url,
                'Archive',
              )) {
                _store.setArchived(r.id, true);
                setState(() {});
              }
            },
          ),
      ],
    );
  }
}

class _RepoCard extends StatelessWidget {
  const _RepoCard({
    required this.controller,
    required this.repo,
    required this.readOnly,
    required this.onEdit,
    required this.onArchive,
  });
  final AppController controller;
  final GitRepo repo;
  final bool readOnly;
  final VoidCallback onEdit, onArchive;

  @override
  Widget build(BuildContext context) {
    final ref = repo.ref;
    Widget link(String label, String? url, IconData icon) => url == null
        ? const SizedBox.shrink()
        : TextButton.icon(
            onPressed: () => openUrl(context, url),
            icon: Icon(icon, size: 18),
            label: Text(label),
          );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  repo.provider == GitProvider.github
                      ? Icons.code
                      : Icons.folder_outlined,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    ref?.fullName ?? repo.url,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Chip(
                  label: Text(repo.provider.label),
                  visualDensity: VisualDensity.compact,
                ),
                if (!readOnly) ...[
                  IconButton(
                    tooltip: 'Edit',
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: onEdit,
                  ),
                  IconButton(
                    tooltip: 'Archive',
                    icon: const Icon(Icons.archive_outlined),
                    onPressed: onArchive,
                  ),
                ],
              ],
            ),
            Text(
              'Branch: ${repo.defaultBranch}${repo.visibility.isEmpty ? '' : ' · ${repo.visibility}'}'
              '${repo.localPath.isEmpty ? '' : ' · ${repo.localPath}'}',
            ),
            if (repo.notes.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(repo.notes),
              ),
            Wrap(
              spacing: 4,
              children: [
                link(
                  'Open',
                  ref?.webUrl ??
                      (repo.url.startsWith('http') ? repo.url : null),
                  Icons.open_in_new,
                ),
                if (ref != null) ...[
                  TextButton.icon(
                    onPressed: () => copyText(
                      context,
                      ref.httpsClone,
                      label: 'HTTPS clone URL copied',
                    ),
                    icon: const Icon(Icons.copy, size: 18),
                    label: const Text('Copy HTTPS'),
                  ),
                  TextButton.icon(
                    onPressed: () => copyText(
                      context,
                      ref.sshClone,
                      label: 'SSH clone URL copied',
                    ),
                    icon: const Icon(Icons.copy, size: 18),
                    label: const Text('Copy SSH'),
                  ),
                  link('Actions', ref.actionsUrl, Icons.play_circle_outline),
                  link(
                    'Deploy keys',
                    ref.deployKeysUrl,
                    Icons.vpn_key_outlined,
                  ),
                  link('Secrets', ref.secretsUrl, Icons.lock_outline),
                  link('Settings', ref.settingsUrl, Icons.settings_outlined),
                ],
              ],
            ),
            ExpansionTile(
              key: PageStorageKey('repo-details-${repo.id}'),
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 8),
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              title: const Text('Deploy keys & tokens'),
              children: [
                CredentialsSection(
                  controller: controller,
                  owner: Owner.repository(repo.id),
                  purpose: CredentialPurpose.access,
                  title: 'Deploy keys, tokens',
                  readOnly: readOnly,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RepoDialog extends StatefulWidget {
  const _RepoDialog({this.existing, required this.applicationId});
  final GitRepo? existing;
  final String applicationId;

  @override
  State<_RepoDialog> createState() => _RepoDialogState();
}

class _RepoDialogState extends State<_RepoDialog> {
  late final _url = TextEditingController(text: widget.existing?.url);
  late final _branch = TextEditingController(
    text: widget.existing?.defaultBranch ?? 'main',
  );
  late final _path = TextEditingController(text: widget.existing?.localPath);
  late final _notes = TextEditingController(text: widget.existing?.notes);
  late String _visibility = widget.existing?.visibility ?? '';
  String? _error;

  @override
  void dispose() {
    for (final c in [_url, _branch, _path, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    final text = _url.text.trim();
    if (text.isEmpty) {
      setState(() => _error = 'Repository URL is required');
      return;
    }
    final ref = RepoRef.parse(text);
    final base =
        widget.existing ??
        GitRepo(
          id: '',
          applicationId: widget.applicationId,
          provider: GitProvider.other,
          url: '',
        );
    Navigator.pop(
      context,
      base.copyWith(
        url: text,
        provider: ref?.provider ?? GitProvider.other,
        defaultBranch: _branch.text.trim().isEmpty
            ? 'main'
            : _branch.text.trim(),
        visibility: _visibility,
        localPath: _path.text.trim(),
        notes: _notes.text,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ref = RepoRef.parse(_url.text);
    return AlertDialog(
      title: Text(
        widget.existing == null ? 'Add repository' : 'Edit repository',
      ),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              labeledField(
                'Repository URL',
                _url,
                hint: 'https://github.com/owner/repo, git@github.com:owner/repo.git or owner/repo',
                error: _error,
                onChanged: (_) => setState(() => _error = null),
              ),
              if (_url.text.trim().isNotEmpty)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      ref == null
                          ? 'Not recognised as a Git URL; it will be stored as entered.'
                          : 'Detected: ${ref.provider.label} · ${ref.fullName}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ),
              labeledField('Default branch', _branch),
              DropdownButtonFormField<String>(
                initialValue: _visibility,
                decoration: const InputDecoration(
                  labelText: 'Visibility',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(value: '', child: Text('Unknown')),
                  DropdownMenuItem(value: 'private', child: Text('Private')),
                  DropdownMenuItem(value: 'public', child: Text('Public')),
                ],
                onChanged: (v) => setState(() => _visibility = v ?? ''),
              ),
              const SizedBox(height: 12),
              labeledField('Local clone path (optional)', _path),
              labeledField('Notes', _notes, lines: 3),
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
