import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_controller.dart';
import '../core/backup/backup_manager.dart';
import '../core/backup/drive_sync.dart';
import '../core/backup/google_drive_backend.dart';
import '../core/backup/local_backup.dart';
import '../core/crypto/wrap.dart';
import 'common.dart';
import 'reauth.dart';
import 'setup_screen.dart' show minPasswordLength;

Future<void> showSettingsDialog(
  BuildContext context,
  AppController controller,
) => showDialog<void>(
  context: context,
  builder: (_) => SettingsDialog(controller: controller),
);

class SettingsDialog extends StatelessWidget {
  const SettingsDialog({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760, maxHeight: 680),
        child: DefaultTabController(
          length: 4,
          child: Column(
            children: [
              AppBar(
                automaticallyImplyLeading: false,
                title: const Text('Settings'),
                actions: [
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
                bottom: const TabBar(
                  tabs: [
                    Tab(text: 'Security'),
                    Tab(text: 'Backup'),
                    Tab(text: 'Data'),
                    Tab(text: 'Activity'),
                  ],
                ),
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _SecurityTab(controller: controller),
                    _BackupTab(controller: controller),
                    _DataTab(controller: controller),
                    _ActivityTab(controller: controller),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _stamp(DateTime t) => DateFormat('yyyyMMdd-HHmm').format(t);

Future<void> _saveText(
  BuildContext context,
  String suggestedName,
  String content,
) async {
  final loc = await getSaveLocation(suggestedName: suggestedName);
  if (loc == null) return;
  await File(loc.path).writeAsString(content, flush: true);
  if (context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('Saved ${loc.path}')));
  }
}

// ---------------------------------------------------------------------------------------- Security

class _SecurityTab extends StatefulWidget {
  const _SecurityTab({required this.controller});
  final AppController controller;

  @override
  State<_SecurityTab> createState() => _SecurityTabState();
}

class _SecurityTabState extends State<_SecurityTab> {
  final _old = TextEditingController();
  final _new = TextEditingController();
  String? _msg;
  bool _msgIsError = false;
  bool _busy = false;

  AppController get c => widget.controller;

  @override
  void dispose() {
    _old.dispose();
    _new.dispose();
    super.dispose();
  }

  Widget _choice(String label, String key, List<(String, String)> options) {
    final current = c.settings.get(key);
    final values = options.map((o) => o.$2).toList();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DropdownButtonFormField<String>(
        initialValue: values.contains(current) ? current : null,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
        ),
        items: [
          for (final o in options)
            DropdownMenuItem(value: o.$2, child: Text(o.$1)),
        ],
        onChanged: (v) {
          if (v == null) return;
          c.settings.set(key, v);
          c.settingsChanged();
          setState(() {});
        },
      ),
    );
  }

  Future<void> _change() async {
    if (_new.text.length < minPasswordLength) {
      setState(() {
        _msg = 'New password needs at least $minPasswordLength characters.';
        _msgIsError = true;
      });
      return;
    }
    setState(() => _busy = true);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    try {
      await c.changePassword(_old.text, _new.text);
      _old.clear();
      _new.clear();
      setState(() {
        _msg = 'Master password changed.';
        _msgIsError = false;
      });
    } on WrongKeyException {
      setState(() {
        _msg = 'Current password is wrong.';
        _msgIsError = true;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _regenerate() async {
    if (!await confirmDialog(
      context,
      'Generate a new recovery key?',
      'The current recovery key stops working immediately. Make sure you can store the new one.',
      'Generate',
    )) {
      return;
    }
    await c.regenerateRecoveryKey();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _choice('Auto-lock after inactivity', 'autolock_minutes', const [
          ('1 minute', '1'),
          ('2 minutes', '2'),
          ('5 minutes', '5'),
          ('10 minutes', '10'),
          ('15 minutes', '15'),
          ('30 minutes', '30'),
          ('1 hour', '60'),
          ('Never', '0'),
        ]),
        _choice(
          'Clear copied secrets from the clipboard after',
          'clipboard_seconds',
          const [
            ('10 seconds', '10'),
            ('20 seconds', '20'),
            ('30 seconds', '30'),
            ('60 seconds', '60'),
            ('Never', '0'),
          ],
        ),
        _choice('Hide revealed secrets again after', 'reveal_seconds', const [
          ('5 seconds', '5'),
          ('15 seconds', '15'),
          ('30 seconds', '30'),
          ('60 seconds', '60'),
          ('Never', '0'),
        ]),
        const Text('The vault also locks when Windows locks or the PC sleeps.'),
        const Divider(height: 32),
        Text(
          'Change master password',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _old,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'Current password',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _new,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'New password',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton(
            onPressed: _busy ? null : _change,
            child: _busy
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Change password'),
          ),
        ),
        if (_msg != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _msg!,
              style: TextStyle(
                color: _msgIsError ? Theme.of(context).colorScheme.error : null,
              ),
            ),
          ),
        const Divider(height: 32),
        Text('Recovery key', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
            onPressed: _regenerate,
            child: const Text('Generate new recovery key'),
          ),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------------------------------------ Backup

class _BackupTab extends StatefulWidget {
  const _BackupTab({required this.controller});
  final AppController controller;

  @override
  State<_BackupTab> createState() => _BackupTabState();
}

class _BackupTabState extends State<_BackupTab> {
  late final _clientId = TextEditingController(
    text: c.settings.get('drive_client_id'),
  );
  late final _clientSecret = TextEditingController(
    text: c.settings.get('drive_client_secret'),
  );
  List<RemoteVersion>? _remote;
  String? _driveMsg;
  bool _driveBusy = false;

  AppController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    c.removeListener(_changed);
    _clientId.dispose();
    _clientSecret.dispose();
    super.dispose();
  }

  static final _fmt = DateFormat('yyyy-MM-dd HH:mm:ss');

  String _status() {
    final b = c.backup;
    if (b == null) return 'Not running';
    return switch (b.state) {
      BackupState.idle => 'Idle',
      BackupState.pending => 'Changes pending: backing up shortly',
      BackupState.running => 'Backing up…',
      BackupState.ok =>
        'Backed up${b.lastBackupAt == null ? '' : ' at ${_fmt.format(b.lastBackupAt!)}'}'
            '${b.lastDriveUploadAt == null ? '' : ' · Drive ${_fmt.format(b.lastDriveUploadAt!)}'}',
      BackupState.offline =>
        'Offline: saved locally, Drive upload will retry (${b.lastError ?? ''})',
      BackupState.error => 'Error: ${b.lastError}',
      BackupState.conflict =>
        'Another installation has a newer backup on Drive',
    };
  }

  Future<void> _restoreLocal(BackupVersion v) async {
    if (!await confirmDialog(
      context,
      'Restore this backup?',
      'The vault is replaced by the version from ${_fmt.format(v.createdAt)} and locked. Your current vault is kept as a safety copy in the backups folder. '
          'Unlock with the password or recovery key that vault had at that time.',
      'Restore',
    )) {
      return;
    }
    await c.restoreFromLocal(v);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _connect() async {
    c.settings.set('drive_client_id', _clientId.text.trim());
    c.settings.set('drive_client_secret', _clientSecret.text.trim());
    setState(() {
      _driveBusy = true;
      _driveMsg = 'Complete the sign-in in your browser…';
    });
    try {
      await c.connectDrive();
      setState(
        () => _driveMsg = 'Connected. Backups now also go to Google Drive.',
      );
    } catch (e) {
      setState(
        () => _driveMsg =
            'Could not connect: ${e is FormatException ? e.message : describeDriveError(e)}',
      );
    } finally {
      if (mounted) setState(() => _driveBusy = false);
    }
  }

  Future<void> _loadRemote() async {
    setState(() {
      _driveBusy = true;
      _driveMsg = null;
    });
    try {
      _remote = await c.driveVersions();
    } catch (e) {
      _driveMsg = 'Could not list Drive versions: ${describeDriveError(e)}';
    } finally {
      if (mounted) setState(() => _driveBusy = false);
    }
  }

  Future<void> _restoreRemote(RemoteVersion v) async {
    if (!await confirmDialog(
      context,
      'Restore from Google Drive?',
      'The vault is replaced by the Drive version from ${_fmt.format(v.createdAt)} and locked. Your current vault is kept as a safety copy. '
          'Unlock with the password or recovery key that version had.',
      'Restore',
    )) {
      return;
    }
    try {
      await c.restoreFromDrive(v);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() => _driveMsg = 'Restore failed: ${describeDriveError(e)}');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = c.backup;
    final local = c.localBackups.list();
    final t = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Row(
          children: [
            Expanded(child: Text(_status())),
            FilledButton(
              onPressed: b == null || b.state == BackupState.running
                  ? null
                  : () => b.backupNow(),
              child: const Text('Back up now'),
            ),
          ],
        ),
        if (b?.state == BackupState.conflict)
          Card(
            color: Theme.of(context).colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'The newest backup on Drive (${_fmt.format(b!.conflict!.createdAt)}) was written by another installation of AppMan.',
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Uploading adds a new version and never overwrites old ones. If that other copy matters, restore it first (below).',
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: b.resolveConflictUploadAnyway,
                    child: const Text('Upload anyway'),
                  ),
                ],
              ),
            ),
          ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Back up automatically after changes'),
          value: c.settings.getBool('backup_on_save'),
          onChanged: (v) {
            c.settings.setBool('backup_on_save', v);
            setState(() {});
          },
        ),
        DropdownButtonFormField<String>(
          initialValue:
              {
                '5',
                '10',
                '20',
                '30',
              }.contains(c.settings.get('backup_retention'))
              ? c.settings.get('backup_retention')
              : '10',
          decoration: const InputDecoration(
            labelText: 'Versions to keep (locally and on Drive)',
            border: OutlineInputBorder(),
          ),
          items: [
            for (final n in ['5', '10', '20', '30'])
              DropdownMenuItem(value: n, child: Text(n)),
          ],
          onChanged: (v) {
            if (v == null) return;
            c.settings.set('backup_retention', v);
            setState(() {});
          },
        ),
        const SectionHeader('Local versions'),
        Text(
          'Stored in ${c.vault.paths.dir}${Platform.pathSeparator}backups (still encrypted).',
          style: t.bodySmall,
        ),
        if (local.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('None yet.'),
          ),
        for (final v in local)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.history),
            title: Text(_fmt.format(v.createdAt)),
            subtitle: Text('${(v.dbBytes / 1024).toStringAsFixed(0)} KB'),
            trailing: TextButton(
              onPressed: () => _restoreLocal(v),
              child: const Text('Restore'),
            ),
          ),
        const Divider(height: 32),
        const SectionHeader('Google Drive (hidden app folder)'),
        const Text(
          'Only encrypted files are uploaded, to a private app folder that cannot see the rest of your Drive. '
          'In Google Cloud Console enable the Drive API and create an OAuth client of type "Desktop app", then paste its details here.',
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _clientId,
          decoration: const InputDecoration(
            labelText: 'OAuth client ID',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _clientSecret,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'OAuth client secret',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        FutureBuilder<bool>(
          future: c.driveAuth.isConnected(),
          builder: (context, snap) {
            final connected = snap.data ?? false;
            return Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton(
                  onPressed: _driveBusy ? null : _connect,
                  child: Text(connected ? 'Reconnect' : 'Connect Google Drive'),
                ),
                if (connected)
                  OutlinedButton(
                    onPressed: _driveBusy
                        ? null
                        : () async {
                            await c.disconnectDrive();
                            setState(() => _driveMsg = 'Disconnected.');
                          },
                    child: const Text('Disconnect'),
                  ),
                if (connected)
                  OutlinedButton(
                    onPressed: _driveBusy ? null : _loadRemote,
                    child: const Text('Show Drive versions'),
                  ),
                Text(connected ? 'Connected' : 'Not connected'),
              ],
            );
          },
        ),
        if (_driveMsg != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_driveMsg!),
          ),
        if (_driveBusy)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: LinearProgressIndicator(),
          ),
        if (_remote != null) ...[
          const SizedBox(height: 8),
          if (_remote!.isEmpty) const Text('No versions on Drive yet.'),
          for (final v in _remote!)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.cloud_outlined),
              title: Text(_fmt.format(v.createdAt)),
              subtitle: Text(
                '${(v.size / 1024).toStringAsFixed(0)} KB${v.deviceId == c.backup?.deviceId ? ' · this installation' : ' · another installation'}',
              ),
              trailing: TextButton(
                onPressed: () => _restoreRemote(v),
                child: const Text('Restore'),
              ),
            ),
        ],
      ],
    );
  }
}

// -------------------------------------------------------------------------------------------- Data

class _DataTab extends StatefulWidget {
  const _DataTab({required this.controller});
  final AppController controller;

  @override
  State<_DataTab> createState() => _DataTabState();
}

class _DataTabState extends State<_DataTab> {
  AppController get c => widget.controller;

  void _toast(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _fullExport() async {
    final ok = await reauthenticate(
      context,
      c,
      reason: 'This export contains every secret, in plain text. Enter your master password to continue.',
    );
    if (!ok || !mounted) return;
    if (!await confirmDialog(
      context,
      'Plaintext file with all secrets',
      'The file is NOT encrypted. Store it somewhere safe and delete it when you no longer need it.',
      'Export',
    )) {
      return;
    }
    if (!mounted) return;
    await _saveText(
      context,
      'appman-full-export-${_stamp(DateTime.now())}.json',
      c.exporter.toJson(includeSecrets: true),
    );
  }

  Future<void> _import({required bool csv}) async {
    final f = await openFile(
      acceptedTypeGroups: [
        XTypeGroup(
          label: csv ? 'CSV' : 'JSON',
          extensions: [csv ? 'csv' : 'json'],
        ),
      ],
    );
    if (f == null) return;
    try {
      final text = utf8.decode(await f.readAsBytes(), allowMalformed: true);
      final max = c.settings.getInt('attachment_max_kb') * 1024;
      final res = csv
          ? c.exporter.importApplicationsCsv(text)
          : c.exporter.importJson(text, maxAttachmentBytes: max);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Import finished'),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(res.summary),
                if (res.warnings.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  const Text('Warnings:'),
                  for (final w in res.warnings.take(12)) Text('• $w'),
                  if (res.warnings.length > 12)
                    Text('…and ${res.warnings.length - 12} more'),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } on FormatException catch (e) {
      _toast(e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final now = DateTime.now();
    final kb = c.settings.get('attachment_max_kb');
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('Reports (no secrets)', style: t.titleSmall),
        const SizedBox(height: 4),
        const Text(
          'Applications, repositories, environments, console links and credential names, without any secret value.',
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            OutlinedButton(
              onPressed: () => _saveText(
                context,
                'appman-report-${_stamp(now)}.md',
                c.exporter.reportMarkdown(),
              ),
              child: const Text('Markdown'),
            ),
            OutlinedButton(
              onPressed: () => _saveText(
                context,
                'appman-report-${_stamp(now)}.csv',
                c.exporter.reportCsv(),
              ),
              child: const Text('CSV'),
            ),
            OutlinedButton(
              onPressed: () => _saveText(
                context,
                'appman-report-${_stamp(now)}.json',
                c.exporter.toJson(includeSecrets: false),
              ),
              child: const Text('JSON'),
            ),
          ],
        ),
        const Divider(height: 32),
        Text('Full export (with secrets)', style: t.titleSmall),
        const SizedBox(height: 4),
        const Text('Needs your master password again. The file is plaintext.'),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
            onPressed: _fullExport,
            child: const Text('Export everything…'),
          ),
        ),
        const Divider(height: 32),
        Text('Import', style: t.titleSmall),
        const SizedBox(height: 4),
        const Text(
          'Adds records; nothing existing is changed or deleted. Hosting targets with the same name and provider are reused.',
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            OutlinedButton(
              onPressed: () => _import(csv: false),
              child: const Text('AppMan JSON export…'),
            ),
            OutlinedButton(
              onPressed: () => _import(csv: true),
              child: const Text('Applications from CSV…'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'CSV columns: name (required), description, status, tags, notes, owner, criticality.',
          style: t.bodySmall,
        ),
        const Divider(height: 32),
        DropdownButtonFormField<String>(
          initialValue: {'256', '1024', '4096', '10240'}.contains(kb)
              ? kb
              : '1024',
          decoration: const InputDecoration(
            labelText: 'Largest attachment',
            border: OutlineInputBorder(),
          ),
          items: const [
            DropdownMenuItem(value: '256', child: Text('256 KB')),
            DropdownMenuItem(value: '1024', child: Text('1 MB')),
            DropdownMenuItem(value: '4096', child: Text('4 MB')),
            DropdownMenuItem(value: '10240', child: Text('10 MB')),
          ],
          onChanged: (v) {
            if (v == null) return;
            c.settings.set('attachment_max_kb', v);
            setState(() {});
          },
        ),
        const SizedBox(height: 4),
        Text(
          'Attachments live inside the vault file and are included in every backup.',
          style: t.bodySmall,
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------------------- Activity

class _ActivityTab extends StatelessWidget {
  const _ActivityTab({required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final entries = controller.audit.recent(limit: 300);
    final fmt = DateFormat('yyyy-MM-dd HH:mm:ss');
    if (entries.isEmpty) return const Center(child: Text('No activity yet.'));
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(8, 8, 8, 12),
          child: Text(
            'Changes and secret reveals/copies. Secret values are never recorded here.',
          ),
        ),
        for (final e in entries)
          ListTile(
            dense: true,
            title: Text(
              '${e.action} · ${e.entity}${e.summary.isEmpty ? '' : ' · ${e.summary}'}',
            ),
            subtitle: Text(fmt.format(e.ts)),
          ),
      ],
    );
  }
}
