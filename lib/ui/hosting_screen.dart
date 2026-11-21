import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../core/db/credential_store.dart';
import '../core/db/hosting_target_store.dart';
import '../core/providers/hosting_templates.dart';
import 'attachments_section.dart';
import 'common.dart';
import 'credentials_section.dart';
import 'hosting_dialog.dart';
import 'links_section.dart';

/// Shared hosting targets with a reverse view of what runs on each (spec F3).
class HostingScreen extends StatefulWidget {
  const HostingScreen({
    super.key,
    required this.controller,
    required this.onOpenApplication,
    this.initialSelectedId,
  });
  final AppController controller;
  final void Function(String applicationId) onOpenApplication;
  final String? initialSelectedId;

  @override
  State<HostingScreen> createState() => _HostingScreenState();
}

class _HostingScreenState extends State<HostingScreen> {
  bool _archived = false;
  late String? _selectedId = widget.initialSelectedId;

  HostingTargetStore get _store => widget.controller.hostingTargets;

  Future<void> _edit([HostingTarget? existing]) async {
    final t = await showHostingDialog(context, existing: existing);
    if (t == null) return;
    if (existing == null) {
      _selectedId = _store
          .create(
            name: t.name,
            provider: t.provider,
            accountId: t.accountId,
            region: t.region,
            consoleUrl: t.consoleUrl,
            notes: t.notes,
          )
          .id;
    } else {
      _store.update(t);
    }
    setState(() {});
  }

  void _toast(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  @override
  Widget build(BuildContext context) {
    final targets = _store.list(archived: _archived);
    final selected = targets.where((t) => t.id == _selectedId).firstOrNull;
    return Scaffold(
      floatingActionButton: _archived
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _edit(),
              icon: const Icon(Icons.add),
              label: const Text('New hosting target'),
            ),
      body: Row(
        children: [
          SizedBox(
            width: 340,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: false, label: Text('Active')),
                      ButtonSegment(value: true, label: Text('Archived')),
                    ],
                    selected: {_archived},
                    onSelectionChanged: (s) => setState(() {
                      _archived = s.first;
                      _selectedId = null;
                    }),
                  ),
                ),
                Expanded(
                  child: targets.isEmpty
                      ? Center(
                          child: Text(
                            _archived
                                ? 'Nothing archived'
                                : 'No hosting targets yet',
                          ),
                        )
                      : ListView(
                          children: [
                            for (final t in targets)
                              ListTile(
                                selected: t.id == _selectedId,
                                title: Text(t.name),
                                subtitle: Text(
                                  '${templateFor(t.provider).label} · ${_store.hostedEnvironments(t.id).length} environment(s)',
                                ),
                                onTap: () => setState(() => _selectedId = t.id),
                              ),
                          ],
                        ),
                ),
              ],
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: selected == null
                ? const Center(child: Text('Select a hosting target'))
                : _detail(selected),
          ),
        ],
      ),
    );
  }

  Widget _detail(HostingTarget t) {
    final hosted = _store.hostedEnvironments(t.id);
    final tt = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            Expanded(child: Text(t.name, style: tt.headlineMedium)),
            if (!t.archived) ...[
              OutlinedButton.icon(
                onPressed: () => _edit(t),
                icon: const Icon(Icons.edit),
                label: const Text('Edit'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: () {
                  try {
                    _store.setArchived(t.id, true);
                    setState(() => _selectedId = null);
                  } on StateError {
                    _toast(
                      'Still used by ${hosted.length} active environment(s). Move or archive them first.',
                    );
                  }
                },
                icon: const Icon(Icons.archive_outlined),
                label: const Text('Archive'),
              ),
            ] else ...[
              OutlinedButton.icon(
                onPressed: () {
                  _store.setArchived(t.id, false);
                  setState(() => _selectedId = null);
                },
                icon: const Icon(Icons.unarchive_outlined),
                label: const Text('Restore'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: () async {
                  if (!await confirmDialog(
                    context,
                    'Permanently delete "${t.name}"?',
                    'This cannot be undone.',
                    'Delete forever',
                  )) {
                    return;
                  }
                  try {
                    _store.purge(t.id);
                    setState(() => _selectedId = null);
                  } on StateError catch (e) {
                    _toast(e.message);
                  }
                },
                icon: const Icon(Icons.delete_forever_outlined),
                label: const Text('Delete forever'),
              ),
            ],
          ],
        ),
        const SizedBox(height: 12),
        Text(
          '${templateFor(t.provider).label}${t.region.isEmpty ? '' : ' · ${t.region}'}${t.accountId.isEmpty ? '' : ' · ${t.accountId}'}',
        ),
        if (t.consoleUrl.isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => openUrl(context, t.consoleUrl),
              icon: const Icon(Icons.dashboard_outlined),
              label: Text('Open console (${t.consoleUrl})'),
            ),
          ),
        if (t.notes.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SelectableText(t.notes),
          ),
        const SectionHeader('Runs here'),
        if (hosted.isEmpty)
          const Text('No active environments use this target.'),
        for (final h in hosted)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('${h.applicationName} · ${h.environmentName}'),
            subtitle: h.urls.isEmpty ? null : Text(h.urls.join('  ')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => widget.onOpenApplication(h.applicationId),
          ),
        const Divider(height: 32),
        CredentialsSection(
          key: ValueKey('host-creds-${t.id}'),
          controller: widget.controller,
          owner: Owner.hosting(t.id),
          purpose: CredentialPurpose.access,
          title: 'Account credentials',
          readOnly: t.archived,
        ),
        const SizedBox(height: 16),
        LinksSection(
          key: ValueKey('host-links-${t.id}'),
          controller: widget.controller,
          owner: Owner.hosting(t.id),
          readOnly: t.archived,
        ),
        const SizedBox(height: 16),
        AttachmentsSection(
          key: ValueKey('host-files-${t.id}'),
          controller: widget.controller,
          owner: Owner.hosting(t.id),
          readOnly: t.archived,
        ),
      ],
    );
  }
}
