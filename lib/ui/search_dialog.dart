import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../core/services/search_service.dart';
import 'common.dart';

/// Global search across everything except secret values (spec F6). Returns the chosen hit.
Future<SearchHit?> showSearchDialog(
  BuildContext context,
  AppController controller,
) => showDialog<SearchHit>(
  context: context,
  builder: (_) => _SearchDialog(controller: controller),
);

class _SearchDialog extends StatefulWidget {
  const _SearchDialog({required this.controller});
  final AppController controller;

  @override
  State<_SearchDialog> createState() => _SearchDialogState();
}

class _SearchDialogState extends State<_SearchDialog> {
  final _q = TextEditingController();

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  static IconData _icon(HitKind k) => switch (k) {
    HitKind.application => Icons.apps,
    HitKind.repository => Icons.code,
    HitKind.environment => Icons.cloud_outlined,
    HitKind.hostingTarget => Icons.dns_outlined,
    HitKind.consoleLink => Icons.dashboard_outlined,
    HitKind.credential => Icons.key,
    HitKind.attachment => Icons.insert_drive_file_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final hits = widget.controller.search.search(_q.text);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _q,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Search applications, repos, environments, links, credentials…',
                  border: OutlineInputBorder(),
                  helperText:
                      'Secret values and file contents are never searched.',
                ),
                onSubmitted: (_) =>
                    hits.isEmpty ? null : Navigator.pop(context, hits.first),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: hits.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          _q.text.trim().isEmpty
                              ? 'Type to search.'
                              : 'No results.',
                        ),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        itemCount: hits.length,
                        itemBuilder: (_, i) {
                          final h = hits[i];
                          return ListTile(
                            dense: true,
                            leading: Icon(_icon(h.kind)),
                            title: Text(h.title),
                            subtitle: Text(
                              h.subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: h.url == null
                                ? null
                                : IconButton(
                                    tooltip: 'Open ${h.url}',
                                    icon: const Icon(Icons.open_in_new),
                                    onPressed: () => openUrl(context, h.url!),
                                  ),
                            onTap: () => Navigator.pop(context, h),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
