import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../app_controller.dart';
import '../core/backup/backup_manager.dart';
import '../core/db/application_repository.dart';
import '../core/db/credential_store.dart';
import '../core/services/search_service.dart';
import 'attachments_section.dart';
import 'common.dart';
import 'credentials_section.dart';
import 'dashboard_screen.dart';
import 'environments_section.dart';
import 'hosting_screen.dart';
import 'links_section.dart';
import 'repositories_section.dart';
import 'search_dialog.dart';
import 'settings_dialog.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.controller});
  final AppController controller;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

enum _Tab { dashboard, applications, hosting }

class _HomeScreenState extends State<HomeScreen> {
  final _filter = TextEditingController();
  bool _showArchived = false;
  String? _selectedId;
  String? _selectedHostingId;
  _Tab _tab = _Tab.dashboard;

  AppController get c => widget.controller;
  ApplicationRepository get _repo => c.applications;

  @override
  void initState() {
    super.initState();
    c.addListener(_onController);
  }

  void _onController() {
    if (mounted && c.vault.isUnlocked) {
      setState(() {}); // e.g. backup status changed
    }
  }

  @override
  void dispose() {
    c.removeListener(_onController);
    _filter.dispose();
    super.dispose();
  }

  void _openApplication(String id) => setState(() {
    _tab = _Tab.applications;
    _showArchived = false;
    _filter.clear();
    _selectedId = id;
  });

  void _openHosting(String id) => setState(() {
    _tab = _Tab.hosting;
    _selectedHostingId = id;
  });

  Future<void> _globalSearch() async {
    final hit = await showSearchDialog(context, c);
    if (hit == null || !mounted) return;
    if (hit.kind == HitKind.hostingTarget && hit.hostingTargetId != null) {
      _openHosting(hit.hostingTargetId!);
    } else if (hit.applicationId != null) {
      _openApplication(hit.applicationId!);
    } else if (hit.hostingTargetId != null) {
      _openHosting(hit.hostingTargetId!);
    }
  }

  Future<void> _editApplication([Application? existing]) async {
    final result = await showDialog<Application>(
      context: context,
      builder: (_) => _ApplicationDialog(existing: existing),
    );
    if (result == null) return;
    if (existing == null) {
      final created = _repo.create(
        name: result.name,
        description: result.description,
        status: result.status,
        tags: result.tags,
        notes: result.notes,
        criticality: result.criticality,
        owner: result.owner,
      );
      _selectedId = created.id;
    } else {
      _repo.update(result);
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AppMan'),
        actions: [
          _BackupIndicator(controller: c),
          IconButton(
            tooltip: 'Search everything (Ctrl+K)',
            icon: const Icon(Icons.search),
            onPressed: _globalSearch,
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => showSettingsDialog(context, c),
          ),
          IconButton(
            tooltip: 'Lock',
            icon: const Icon(Icons.lock_outline),
            onPressed: c.lock,
          ),
        ],
      ),
      body: Shortcuts(
        shortcuts: {
          const SingleActivator(LogicalKeyboardKey.keyK, control: true):
              const _SearchIntent(),
        },
        child: Actions(
          actions: {
            _SearchIntent: CallbackAction<_SearchIntent>(
              onInvoke: (_) => _globalSearch(),
            ),
          },
          child: Focus(
            autofocus: true,
            child: Row(
              children: [
                NavigationRail(
                  selectedIndex: _tab.index,
                  labelType: NavigationRailLabelType.all,
                  onDestinationSelected: (i) =>
                      setState(() => _tab = _Tab.values[i]),
                  destinations: const [
                    NavigationRailDestination(
                      icon: Icon(Icons.dashboard_outlined),
                      selectedIcon: Icon(Icons.dashboard),
                      label: Text('Dashboard'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.apps_outlined),
                      selectedIcon: Icon(Icons.apps),
                      label: Text('Applications'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.dns_outlined),
                      selectedIcon: Icon(Icons.dns),
                      label: Text('Hosting'),
                    ),
                  ],
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: switch (_tab) {
                    _Tab.dashboard => DashboardScreen(
                      controller: c,
                      onOpenApplication: _openApplication,
                      onOpenHosting: _openHosting,
                    ),
                    _Tab.hosting => HostingScreen(
                      key: ValueKey('hosting-$_selectedHostingId'),
                      controller: c,
                      onOpenApplication: _openApplication,
                      initialSelectedId: _selectedHostingId,
                    ),
                    _Tab.applications => _applications(),
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _applications() {
    final apps = _repo.list(query: _filter.text, archived: _showArchived);
    final selected = apps.where((a) => a.id == _selectedId).firstOrNull;
    return Scaffold(
      floatingActionButton: _showArchived
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _editApplication(),
              icon: const Icon(Icons.add),
              label: const Text('New application'),
            ),
      body: Row(
        children: [
          SizedBox(
            width: 340,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                  child: TextField(
                    controller: _filter,
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.filter_list),
                      hintText: 'Filter name, tags, notes',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: false, label: Text('Active')),
                      ButtonSegment(value: true, label: Text('Archived')),
                    ],
                    selected: {_showArchived},
                    onSelectionChanged: (s) => setState(() {
                      _showArchived = s.first;
                      _selectedId = null;
                    }),
                  ),
                ),
                Expanded(
                  child: apps.isEmpty
                      ? Center(
                          child: Text(
                            _showArchived
                                ? 'Nothing archived'
                                : 'No applications yet',
                          ),
                        )
                      : ListView.builder(
                          itemCount: apps.length,
                          itemBuilder: (_, i) {
                            final a = apps[i];
                            return ListTile(
                              selected: a.id == _selectedId,
                              title: Text(a.name),
                              subtitle: Text(
                                a.tags.isEmpty
                                    ? a.status
                                    : '${a.status} · ${a.tags.join(', ')}',
                              ),
                              onTap: () => setState(() => _selectedId = a.id),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: selected == null
                ? const Center(child: Text('Select an application'))
                : _ApplicationDetail(
                    key: ValueKey('detail-${selected.id}'),
                    controller: c,
                    app: selected,
                    onEdit: () => _editApplication(selected),
                    onArchive: () async {
                      if (await confirmDialog(
                        context,
                        'Archive "${selected.name}"?',
                        'It and its repositories, environments and secrets are hidden until restored. Revoke its credentials at the providers if it is retired.',
                        'Archive',
                      )) {
                        _repo.setArchived(selected.id, true);
                        setState(() => _selectedId = null);
                      }
                    },
                    onRestore: () {
                      _repo.setArchived(selected.id, false);
                      setState(() => _selectedId = null);
                    },
                    onPurge: () async {
                      if (await confirmDialog(
                        context,
                        'Permanently delete "${selected.name}"?',
                        'This cannot be undone. All its repositories, environments, secrets and attachments are erased.',
                        'Delete forever',
                      )) {
                        _repo.purge(selected.id);
                        setState(() => _selectedId = null);
                      }
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _SearchIntent extends Intent {
  const _SearchIntent();
}

/// Small status chip for backups; tap opens the Backup settings.
class _BackupIndicator extends StatelessWidget {
  const _BackupIndicator({required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final b = controller.backup;
    final (icon, label, color) = switch (b?.state) {
      null || BackupState.idle => (Icons.cloud_queue, 'Backup', null),
      BackupState.pending => (Icons.schedule, 'Backup pending', null),
      BackupState.running => (Icons.sync, 'Backing up…', null),
      BackupState.ok => (Icons.cloud_done_outlined, 'Backed up', null),
      BackupState.offline => (
        Icons.cloud_off_outlined,
        'Offline',
        Colors.orange.shade800,
      ),
      BackupState.error => (
        Icons.error_outline,
        'Backup error',
        Theme.of(context).colorScheme.error,
      ),
      BackupState.conflict => (
        Icons.warning_amber_outlined,
        'Backup conflict',
        Theme.of(context).colorScheme.error,
      ),
    };
    final when = b?.lastBackupAt == null
        ? ''
        : '\nLast: ${DateFormat('yyyy-MM-dd HH:mm').format(b!.lastBackupAt!)}';
    return Tooltip(
      message: '$label$when${b?.lastError == null ? '' : '\n${b!.lastError}'}',
      child: TextButton.icon(
        onPressed: () => showSettingsDialog(context, controller),
        icon: Icon(icon, size: 18, color: color),
        label: Text(label, style: TextStyle(color: color)),
      ),
    );
  }
}

class _ApplicationDetail extends StatelessWidget {
  const _ApplicationDetail({
    super.key,
    required this.controller,
    required this.app,
    required this.onEdit,
    required this.onArchive,
    required this.onRestore,
    required this.onPurge,
  });
  final AppController controller;
  final Application app;
  final VoidCallback onEdit, onArchive, onRestore, onPurge;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    Widget field(String label, String value) => value.isEmpty
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: t.labelMedium),
                SelectableText(value),
              ],
            ),
          );
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            Expanded(child: Text(app.name, style: t.headlineMedium)),
            if (!app.archived)
              OutlinedButton.icon(
                onPressed: onEdit,
                icon: const Icon(Icons.edit),
                label: const Text('Edit'),
              ),
            const SizedBox(width: 8),
            if (!app.archived)
              OutlinedButton.icon(
                onPressed: onArchive,
                icon: const Icon(Icons.archive_outlined),
                label: const Text('Archive'),
              )
            else ...[
              OutlinedButton.icon(
                onPressed: onRestore,
                icon: const Icon(Icons.unarchive_outlined),
                label: const Text('Restore'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: onPurge,
                icon: const Icon(Icons.delete_forever_outlined),
                label: const Text('Delete forever'),
              ),
            ],
          ],
        ),
        const SizedBox(height: 16),
        field('Description', app.description),
        field('Status', app.status),
        field('Tags', app.tags.join(', ')),
        field('Criticality', app.criticality),
        field('Owner / client', app.owner),
        field('Notes (Markdown)', app.notes),
        const Divider(height: 32),
        RepositoriesSection(
          key: ValueKey('repos-${app.id}'),
          controller: controller,
          applicationId: app.id,
          readOnly: app.archived,
        ),
        const SizedBox(height: 16),
        EnvironmentsSection(
          key: ValueKey('envs-${app.id}'),
          controller: controller,
          applicationId: app.id,
          readOnly: app.archived,
        ),
        const Divider(height: 32),
        CredentialsSection(
          key: ValueKey('creds-${app.id}'),
          controller: controller,
          owner: Owner.application(app.id),
          purpose: CredentialPurpose.access,
          title: 'Credentials',
          readOnly: app.archived,
        ),
        const SizedBox(height: 16),
        LinksSection(
          key: ValueKey('links-${app.id}'),
          controller: controller,
          owner: Owner.application(app.id),
          readOnly: app.archived,
        ),
        const SizedBox(height: 16),
        AttachmentsSection(
          key: ValueKey('files-${app.id}'),
          controller: controller,
          owner: Owner.application(app.id),
          readOnly: app.archived,
        ),
        const SizedBox(height: 16),
        _ActivityLog(controller: controller, applicationId: app.id),
      ],
    );
  }
}

class _ActivityLog extends StatelessWidget {
  const _ActivityLog({required this.controller, required this.applicationId});
  final AppController controller;
  final String applicationId;

  @override
  Widget build(BuildContext context) {
    final entries = controller.audit.forEntity(
      'application',
      applicationId,
      limit: 30,
    );
    final fmt = DateFormat('yyyy-MM-dd HH:mm');
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: const Text('History'),
      children: [
        if (entries.isEmpty)
          const ListTile(title: Text('No changes recorded.')),
        for (final e in entries)
          ListTile(
            dense: true,
            title: Text(
              '${e.action}${e.summary.isEmpty ? '' : ' · ${e.summary}'}',
            ),
            subtitle: Text(fmt.format(e.ts)),
          ),
      ],
    );
  }
}

class _ApplicationDialog extends StatefulWidget {
  const _ApplicationDialog({this.existing});
  final Application? existing;

  @override
  State<_ApplicationDialog> createState() => _ApplicationDialogState();
}

class _ApplicationDialogState extends State<_ApplicationDialog> {
  late final _name = TextEditingController(text: widget.existing?.name);
  late final _desc = TextEditingController(text: widget.existing?.description);
  late final _tags = TextEditingController(
    text: widget.existing?.tags.join(', '),
  );
  late final _owner = TextEditingController(text: widget.existing?.owner);
  late final _crit = TextEditingController(text: widget.existing?.criticality);
  late final _notes = TextEditingController(text: widget.existing?.notes);
  late String _status = widget.existing?.status ?? 'active';
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _desc, _tags, _owner, _crit, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'Name is required');
      return;
    }
    final base =
        widget.existing ??
        Application(id: '', name: '', createdAt: 0, updatedAt: 0);
    Navigator.pop(
      context,
      base.copyWith(
        name: _name.text,
        description: _desc.text,
        status: _status,
        tags: Application.parseTags(_tags.text),
        notes: _notes.text,
        criticality: _crit.text,
        owner: _owner.text,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.existing == null ? 'New application' : 'Edit application',
      ),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              labeledField('Name', _name, error: _error),
              labeledField('Description', _desc),
              DropdownButtonFormField<String>(
                initialValue: _status,
                decoration: const InputDecoration(
                  labelText: 'Status',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(value: 'active', child: Text('Active')),
                  DropdownMenuItem(value: 'idea', child: Text('Idea')),
                ],
                onChanged: (v) => setState(() => _status = v ?? 'active'),
              ),
              const SizedBox(height: 12),
              labeledField('Tags (comma separated)', _tags),
              labeledField('Criticality', _crit),
              labeledField('Owner / client', _owner),
              labeledField('Notes (Markdown)', _notes, lines: 5),
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
