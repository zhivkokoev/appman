import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_controller.dart';
import '../core/db/environment_store.dart';
import '../core/db/hosting_target_store.dart';
import '../core/providers/hosting_templates.dart';
import '../core/db/credential_store.dart';
import 'attachments_section.dart';
import 'common.dart';
import 'credentials_section.dart';
import 'env_secrets.dart';
import 'hosting_dialog.dart';
import 'links_section.dart';

class EnvironmentsSection extends StatefulWidget {
  const EnvironmentsSection({
    super.key,
    required this.controller,
    required this.applicationId,
    required this.readOnly,
  });
  final AppController controller;
  final String applicationId;
  final bool readOnly;

  @override
  State<EnvironmentsSection> createState() => _EnvironmentsSectionState();
}

class _EnvironmentsSectionState extends State<EnvironmentsSection> {
  EnvironmentStore get _store => widget.controller.environments;

  Future<void> _edit([AppEnvironment? existing]) async {
    final result = await showDialog<AppEnvironment>(
      context: context,
      builder: (_) => _EnvironmentDialog(
        controller: widget.controller,
        applicationId: widget.applicationId,
        existing: existing,
      ),
    );
    if (result == null) return;
    if (existing == null) {
      _store.create(
        applicationId: widget.applicationId,
        name: result.name,
        hostingTargetId: result.hostingTargetId,
        urls: result.urls,
        region: result.region,
        deployMethod: result.deployMethod,
        deployInstructions: result.deployInstructions,
        version: result.version,
        lastDeployed: result.lastDeployed,
        notes: result.notes,
      );
    } else {
      _store.update(result);
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final envs = _store.listForApplication(
      widget.applicationId,
      archived: widget.readOnly,
    );
    final targets = {
      for (final t in [
        ...widget.controller.hostingTargets.list(),
        ...widget.controller.hostingTargets.list(archived: true),
      ])
        t.id: t,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          'Environments',
          action: widget.readOnly
              ? null
              : TextButton.icon(
                  onPressed: () => _edit(),
                  icon: const Icon(Icons.add),
                  label: const Text('Add'),
                ),
        ),
        if (envs.isEmpty)
          Text(
            widget.readOnly
                ? 'None'
                : 'No environment yet (production, staging...).',
          ),
        for (final e in envs)
          _EnvironmentCard(
            controller: widget.controller,
            env: e,
            target: targets[e.hostingTargetId],
            readOnly: widget.readOnly,
            onEdit: () => _edit(e),
            onArchive: () async {
              if (await confirmDialog(
                context,
                'Archive environment "${e.name}"?',
                'Its runtime secrets are archived with it.',
                'Archive',
              )) {
                _store.setArchived(e.id, true);
                setState(() {});
              }
            },
            onMarkDeployed: () {
              _store.update(e.copyWith(lastDeployed: DateTime.now()));
              setState(() {});
            },
          ),
      ],
    );
  }
}

class _EnvironmentCard extends StatelessWidget {
  const _EnvironmentCard({
    required this.controller,
    required this.env,
    required this.target,
    required this.readOnly,
    required this.onEdit,
    required this.onArchive,
    required this.onMarkDeployed,
  });
  final AppController controller;
  final AppEnvironment env;
  final HostingTarget? target;
  final bool readOnly;
  final VoidCallback onEdit, onArchive, onMarkDeployed;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final deployed = env.lastDeployed == null
        ? null
        : DateFormat('yyyy-MM-dd HH:mm').format(env.lastDeployed!);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(env.name, style: t.titleMedium)),
                if (target != null)
                  Chip(
                    label: Text(target!.name),
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
            for (final u in env.urls)
              InkWell(
                onTap: () => openUrl(context, u),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    u,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
              ),
            Text(
              [
                if (env.deployMethod.isNotEmpty) 'Deploy: ${env.deployMethod}',
                if (env.region.isNotEmpty) 'Region: ${env.region}',
                if (env.version.isNotEmpty) 'Version: ${env.version}',
                if (deployed != null) 'Last deployed: $deployed',
              ].join(' · '),
            ),
            if (env.deployInstructions.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('How to deploy', style: t.labelMedium),
              SelectableText(env.deployInstructions),
            ],
            if (env.notes.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(env.notes),
            ],
            Wrap(
              spacing: 4,
              children: [
                if (target != null && target!.consoleUrl.isNotEmpty)
                  TextButton.icon(
                    onPressed: () => openUrl(context, target!.consoleUrl),
                    icon: const Icon(Icons.dashboard_outlined, size: 18),
                    label: const Text('Open console'),
                  ),
                if (!readOnly)
                  TextButton.icon(
                    onPressed: onMarkDeployed,
                    icon: const Icon(Icons.check_circle_outline, size: 18),
                    label: const Text('Mark deployed now'),
                  ),
              ],
            ),
            ExpansionTile(
              key: PageStorageKey('env-details-${env.id}'),
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 8),
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              title: const Text('Secrets, credentials, links & files'),
              children: [
                EnvironmentSecrets(
                  controller: controller,
                  environmentId: env.id,
                  readOnly: readOnly,
                ),
                const SizedBox(height: 8),
                CredentialsSection(
                  controller: controller,
                  owner: Owner.environment(env.id),
                  purpose: CredentialPurpose.access,
                  title: 'Access credentials (SSH, admin logins...)',
                  readOnly: readOnly,
                ),
                const SizedBox(height: 8),
                LinksSection(
                  controller: controller,
                  owner: Owner.environment(env.id),
                  readOnly: readOnly,
                ),
                const SizedBox(height: 8),
                AttachmentsSection(
                  controller: controller,
                  owner: Owner.environment(env.id),
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

class _EnvironmentDialog extends StatefulWidget {
  const _EnvironmentDialog({
    required this.controller,
    required this.applicationId,
    this.existing,
  });
  final AppController controller;
  final String applicationId;
  final AppEnvironment? existing;

  @override
  State<_EnvironmentDialog> createState() => _EnvironmentDialogState();
}

class _EnvironmentDialogState extends State<_EnvironmentDialog> {
  late final _name = TextEditingController(text: widget.existing?.name);
  late final _urls = TextEditingController(
    text: widget.existing?.urls.join('\n'),
  );
  late final _region = TextEditingController(text: widget.existing?.region);
  late final _instructions = TextEditingController(
    text: widget.existing?.deployInstructions,
  );
  late final _version = TextEditingController(text: widget.existing?.version);
  late final _notes = TextEditingController(text: widget.existing?.notes);
  late String? _targetId = widget.existing?.hostingTargetId;
  late String _method = widget.existing?.deployMethod ?? '';
  late DateTime? _lastDeployed = widget.existing?.lastDeployed;
  String? _error;

  HostingTargetStore get _hosts => widget.controller.hostingTargets;

  @override
  void dispose() {
    for (final c in [_name, _urls, _region, _instructions, _version, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  List<String> _methodOptions() {
    final target = _targetId == null ? null : _hosts.get(_targetId!);
    final suggested = target == null
        ? <String>[]
        : templateFor(target.provider).deployMethods;
    final all = {
      ...suggested,
      ...baseDeployMethods,
      if (_method.isNotEmpty) _method,
    };
    return all.toList();
  }

  Future<void> _newTarget() async {
    final t = await showHostingDialog(context);
    if (t == null) return;
    final created = _hosts.create(
      name: t.name,
      provider: t.provider,
      accountId: t.accountId,
      region: t.region,
      consoleUrl: t.consoleUrl,
      notes: t.notes,
    );
    setState(() => _targetId = created.id);
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _lastDeployed ?? now,
      firstDate: DateTime(2000),
      lastDate: now.add(const Duration(days: 1)),
    );
    if (d != null) setState(() => _lastDeployed = d);
  }

  void _save() {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'Name is required');
      return;
    }
    final base =
        widget.existing ??
        AppEnvironment(id: '', applicationId: widget.applicationId, name: '');
    Navigator.pop(
      context,
      base.copyWith(
        name: _name.text,
        hostingTargetId: _targetId,
        urls: AppEnvironment.parseUrls(_urls.text),
        region: _region.text.trim(),
        deployMethod: _method,
        deployInstructions: _instructions.text,
        version: _version.text.trim(),
        lastDeployed: _lastDeployed,
        notes: _notes.text,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final targets = _hosts.list();
    if (_targetId != null && !targets.any((t) => t.id == _targetId)) {
      final current = _hosts.get(_targetId!);
      if (current != null) {
        targets.add(current); // keep showing an archived target already in use
      }
    }
    return AlertDialog(
      title: Text(
        widget.existing == null ? 'Add environment' : 'Edit environment',
      ),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              labeledField(
                'Name',
                _name,
                error: _error,
                onChanged: (_) => setState(() => _error = null),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Wrap(
                    spacing: 6,
                    children: [
                      for (final s in environmentNameSuggestions)
                        ActionChip(
                          label: Text(s),
                          visualDensity: VisualDensity.compact,
                          onPressed: () => setState(() {
                            _name.text = s;
                            _error = null;
                          }),
                        ),
                    ],
                  ),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String?>(
                      initialValue: _targetId,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Hosting target',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        const DropdownMenuItem<String?>(
                          value: null,
                          child: Text('None'),
                        ),
                        for (final t in targets)
                          DropdownMenuItem<String?>(
                            value: t.id,
                            child: Text(t.name),
                          ),
                      ],
                      onChanged: (v) => setState(() => _targetId = v),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _newTarget,
                    icon: const Icon(Icons.add),
                    label: const Text('New'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              labeledField('URLs (one per line)', _urls, lines: 3),
              DropdownButtonFormField<String>(
                initialValue: _method,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Deploy method',
                  border: OutlineInputBorder(),
                ),
                items: [
                  const DropdownMenuItem(value: '', child: Text('Not set')),
                  for (final m in _methodOptions())
                    DropdownMenuItem(value: m, child: Text(m)),
                ],
                onChanged: (v) => setState(() => _method = v ?? ''),
              ),
              const SizedBox(height: 12),
              labeledField(
                'Deploy command / instructions',
                _instructions,
                lines: 4,
              ),
              Row(
                children: [
                  Expanded(child: labeledField('Region', _region)),
                  const SizedBox(width: 8),
                  Expanded(child: labeledField('Version', _version)),
                ],
              ),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _lastDeployed == null
                          ? 'Last deployed: not set'
                          : 'Last deployed: ${DateFormat('yyyy-MM-dd').format(_lastDeployed!)}',
                    ),
                  ),
                  TextButton(
                    onPressed: _pickDate,
                    child: const Text('Pick date'),
                  ),
                  if (_lastDeployed != null)
                    TextButton(
                      onPressed: () => setState(() => _lastDeployed = null),
                      child: const Text('Clear'),
                    ),
                ],
              ),
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
