import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_controller.dart';
import '../core/db/attachment_store.dart';
import '../core/db/credential_store.dart';
import 'common.dart';

/// Encrypted files (SSH keys, .env, certificates) kept inside the vault (spec F5).
class AttachmentsSection extends StatefulWidget {
  const AttachmentsSection({
    super.key,
    required this.controller,
    required this.owner,
    required this.readOnly,
    this.title = 'Attachments',
  });
  final AppController controller;
  final Owner owner;
  final bool readOnly;
  final String title;

  @override
  State<AttachmentsSection> createState() => _AttachmentsSectionState();
}

class _AttachmentsSectionState extends State<AttachmentsSection> {
  AttachmentStore get _store => widget.controller.attachments;

  void _toast(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _add() async {
    final file = await openFile();
    if (file == null) return;
    try {
      final max = widget.controller.settings.getInt('attachment_max_kb') * 1024;
      final bytes = await file.readAsBytes();
      _store.add(
        owner: widget.owner,
        name: file.name,
        bytes: bytes,
        maxBytes: max,
      );
      setState(() {});
    } on AttachmentTooLargeException catch (e) {
      _toast(e.toString());
    } on FileSystemException catch (e) {
      _toast('Could not read the file: ${e.message}');
    }
  }

  Future<void> _view(Attachment a) async {
    final data = _store.data(a.id);
    if (data == null || !mounted) return;
    final text = AttachmentStore.isTextLike(a)
        ? utf8.decode(data, allowMalformed: true)
        : null;
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(a.name),
        content: SizedBox(
          width: 560,
          child: text == null
              ? Text(
                  'Binary file, ${a.size} bytes. Use "Save as…" to export it.',
                )
              : SingleChildScrollView(
                  child: SelectableText(
                    text,
                    style: const TextStyle(fontFamily: 'Consolas'),
                  ),
                ),
        ),
        actions: [
          if (text != null)
            TextButton(
              onPressed: () async {
                await widget.controller.clipboard.copy(text);
                if (mounted) _toast('Copied. Clipboard clears automatically.');
              },
              child: const Text('Copy'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _saveAs(Attachment a) async {
    final loc = await getSaveLocation(suggestedName: a.name);
    if (loc == null) return;
    final data = _store.data(a.id);
    if (data == null) return;
    await File(loc.path).writeAsBytes(data, flush: true);
    if (mounted) {
      _toast(
        'Saved to ${loc.path}. This copy is NOT encrypted: delete it when done.',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final files = _store.listFor(widget.owner, archived: widget.readOnly);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          widget.title,
          action: widget.readOnly
              ? null
              : TextButton.icon(
                  onPressed: _add,
                  icon: const Icon(Icons.attach_file),
                  label: const Text('Add file'),
                ),
        ),
        if (files.isEmpty)
          Text(
            widget.readOnly
                ? 'None'
                : 'No files (SSH keys, .env, certificates).',
          ),
        for (final a in files)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.insert_drive_file_outlined),
            title: Text(a.name),
            subtitle: Text(
              '${(a.size / 1024).toStringAsFixed(1)} KB · added ${DateFormat('yyyy-MM-dd').format(a.createdAt!)}',
            ),
            onTap: () => _view(a),
            trailing: widget.readOnly
                ? null
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'View',
                        icon: const Icon(Icons.visibility_outlined),
                        onPressed: () => _view(a),
                      ),
                      IconButton(
                        tooltip: 'Save as…',
                        icon: const Icon(Icons.save_alt),
                        onPressed: () => _saveAs(a),
                      ),
                      IconButton(
                        tooltip: 'Archive',
                        icon: const Icon(Icons.archive_outlined),
                        onPressed: () {
                          _store.setArchived(a.id, true);
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
