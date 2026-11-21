import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_controller.dart';
import '../core/services/report_service.dart';
import 'common.dart';

/// Attention panel, data-completeness hints, credential hygiene, recent items and quick launch (spec F6, F11).
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({
    super.key,
    required this.controller,
    required this.onOpenApplication,
    required this.onOpenHosting,
  });
  final AppController controller;
  final void Function(String applicationId) onOpenApplication;
  final void Function(String hostingTargetId) onOpenHosting;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  void _open(CredentialRef c) {
    if (c.applicationId != null) {
      widget.onOpenApplication(c.applicationId!);
    } else if (c.hostingTargetId != null) {
      widget.onOpenHosting(c.hostingTargetId!);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.controller.reports.dashboard();
    final h = widget.controller.reports.hygiene();
    final links = widget.controller.consoleLinks.listAll();
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final fmt = DateFormat('yyyy-MM-dd');
    final now = DateTime.now();

    Widget card(
      String title, {
      required List<Widget> children,
      IconData? icon,
      Color? color,
    }) => Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (icon != null) Icon(icon, color: color),
                if (icon != null) const SizedBox(width: 8),
                Text(title, style: t.titleMedium),
              ],
            ),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );

    Widget credTile(CredentialRef c, {String? trailing, Color? color}) =>
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.key, size: 20),
          title: Text(c.name),
          subtitle: Text(c.where.isEmpty ? '—' : c.where),
          trailing: trailing == null
              ? null
              : Text(trailing, style: TextStyle(color: color)),
          onTap: () => _open(c),
        );

    Widget stat(String label, int n) => Expanded(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Text('$n', style: t.headlineMedium),
              Text(label, style: t.bodySmall),
            ],
          ),
        ),
      ),
    );

    final hygieneItems = <(String, List<CredentialRef>)>[
      ('Weak secrets', h.weak),
      ('Expired', h.expired),
      ('Not changed for a year', h.old),
    ];

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('Dashboard', style: t.headlineMedium),
        const SizedBox(height: 12),
        Row(
          children: [
            stat('Applications', d.activeApplications),
            stat('Hosting targets', d.hostingTargets),
            stat('Credentials & secrets', d.credentials),
            stat('Archived apps', d.archivedApplications),
          ],
        ),
        card(
          'Needs attention',
          icon: Icons.warning_amber_outlined,
          color: d.expiring.isEmpty ? null : Colors.orange.shade800,
          children: [
            if (d.expiring.isEmpty)
              const Text('No credentials expire within 30 days.'),
            for (final c in d.expiring)
              credTile(
                c,
                trailing: c.expiresAt!.isBefore(now)
                    ? 'expired ${fmt.format(c.expiresAt!)}'
                    : 'expires ${fmt.format(c.expiresAt!)}',
                color: c.expiresAt!.isBefore(now)
                    ? scheme.error
                    : Colors.orange.shade800,
              ),
          ],
        ),
        card(
          'Credential hygiene',
          icon: h.isClean ? Icons.verified_outlined : Icons.shield_outlined,
          children: [
            if (h.isClean)
              const Text('No weak, reused, expired or old credentials found.'),
            for (final (title, list) in hygieneItems)
              if (list.isNotEmpty)
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text('$title (${list.length})'),
                  children: [for (final c in list) credTile(c)],
                ),
            if (h.reused.isNotEmpty)
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(
                  'Reused secrets (${h.reused.length} group${h.reused.length == 1 ? '' : 's'})',
                ),
                subtitle: const Text(
                  'Different credentials that share the same value',
                ),
                children: [
                  for (final g in h.reused) ...[
                    for (final c in g) credTile(c),
                    const Divider(height: 8),
                  ],
                ],
              ),
          ],
        ),
        card(
          'Completeness hints',
          icon: Icons.checklist,
          children: [
            if (d.hints.isEmpty)
              const Text(
                'Every active application has a repository, environment and credentials.',
              ),
            for (final hint in d.hints)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(hint.applicationName),
                subtitle: Text(hint.message),
                onTap: () => widget.onOpenApplication(hint.applicationId),
              ),
          ],
        ),
        if (d.recent.isNotEmpty)
          card(
            'Recently used',
            icon: Icons.history,
            children: [
              for (final c in d.recent)
                credTile(c, trailing: fmt.format(c.lastAccessedAt!)),
            ],
          ),
        card(
          'Quick launch',
          icon: Icons.rocket_launch_outlined,
          children: [
            if (links.isEmpty)
              const Text(
                'Add console links to applications, environments or hosting targets to launch them here.',
              ),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final l in links)
                  ActionChip(
                    avatar: const Icon(Icons.open_in_new, size: 16),
                    label: Text(l.label),
                    tooltip: l.url,
                    onPressed: () => openUrl(context, l.url),
                  ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}
