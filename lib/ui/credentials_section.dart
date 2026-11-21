import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_controller.dart';
import '../core/db/credential_store.dart';
import '../core/secrets/password_generator.dart';
import 'common.dart';

final _dateFmt = DateFormat('yyyy-MM-dd');

/// Access credentials or per-environment runtime secrets for one owner (spec F5).
class CredentialsSection extends StatefulWidget {
  const CredentialsSection({
    super.key,
    required this.controller,
    required this.owner,
    required this.purpose,
    required this.title,
    required this.readOnly,
    this.extraActions = const [],
    this.onChanged,
  });
  final AppController controller;
  final Owner owner;
  final CredentialPurpose purpose;
  final String title;
  final bool readOnly;

  /// Extra buttons next to "Add" (e.g. .env import/export for runtime secrets).
  final List<Widget> extraActions;
  final VoidCallback? onChanged;

  @override
  State<CredentialsSection> createState() => CredentialsSectionState();
}

class CredentialsSectionState extends State<CredentialsSection> {
  CredentialStore get _store => widget.controller.credentials;

  void refresh() {
    setState(() {});
    widget.onChanged?.call();
  }

  Future<void> _add() async {
    final result = await showDialog<Credential>(
      context: context,
      builder: (_) => CredentialDialog(purpose: widget.purpose),
    );
    if (result == null) return;
    _store.create(
      owner: widget.owner,
      purpose: widget.purpose,
      type: result.type,
      label: result.label,
      keyName: result.keyName,
      username: result.username,
      secret: result.secret,
      url: result.url,
      expiresAt: result.expiresAt,
      rotationNotes: result.rotationNotes,
      customFields: result.customFields,
      notes: result.notes,
    );
    refresh();
  }

  @override
  Widget build(BuildContext context) {
    final items = _store.listFor(
      widget.owner,
      purpose: widget.purpose,
      archived: widget.readOnly,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          widget.title,
          action: widget.readOnly
              ? null
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ...widget.extraActions,
                    TextButton.icon(
                      onPressed: _add,
                      icon: const Icon(Icons.add),
                      label: const Text('Add'),
                    ),
                  ],
                ),
        ),
        if (items.isEmpty)
          Text(
            widget.readOnly
                ? 'None'
                : widget.purpose == CredentialPurpose.runtime
                ? 'No runtime secrets yet (DB user/password, API keys, env vars).'
                : 'No credentials yet.',
          ),
        for (final c in items)
          CredentialTile(
            key: ValueKey(c.id),
            controller: widget.controller,
            credential: c,
            readOnly: widget.readOnly,
            onChanged: refresh,
          ),
      ],
    );
  }
}

class CredentialTile extends StatefulWidget {
  const CredentialTile({
    super.key,
    required this.controller,
    required this.credential,
    required this.readOnly,
    required this.onChanged,
  });
  final AppController controller;
  final Credential credential;
  final bool readOnly;
  final VoidCallback onChanged;

  @override
  State<CredentialTile> createState() => _CredentialTileState();
}

class _CredentialTileState extends State<CredentialTile> {
  bool _revealed = false;
  Timer? _hide;

  Credential get c => widget.credential;
  AppController get ctl => widget.controller;

  @override
  void dispose() {
    _hide?.cancel();
    super.dispose();
  }

  void _toggleReveal() {
    _hide?.cancel();
    if (_revealed) {
      setState(() => _revealed = false);
      return;
    }
    ctl.credentials.markAccessed(c.id, how: 'reveal');
    setState(() => _revealed = true);
    final secs = ctl.settings.getInt('reveal_seconds');
    if (secs > 0) {
      _hide = Timer(Duration(seconds: secs), () {
        if (mounted) setState(() => _revealed = false);
      });
    }
  }

  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(m), duration: const Duration(seconds: 2)),
  );

  Future<void> _copySecret() async {
    await ctl.copySecret(c);
    final secs = ctl.settings.getInt('clipboard_seconds');
    _toast(secs > 0 ? 'Copied. Clipboard clears in ${secs}s.' : 'Copied.');
  }

  Future<void> _openAndCopy() async {
    await _copySecret();
    if (mounted) await openUrl(context, c.url);
  }

  Future<void> _edit() async {
    final r = await showDialog<Credential>(
      context: context,
      builder: (_) => CredentialDialog(purpose: c.purpose, existing: c),
    );
    if (r == null) return;
    ctl.credentials.update(r);
    widget.onChanged();
  }

  Future<void> _archive() async {
    if (!await confirmDialog(
      context,
      'Archive "${c.displayName}"?',
      'It is hidden until restored. Rotate or revoke it at the provider if it is no longer needed.',
      'Archive',
    )) {
      return;
    }
    ctl.credentials.setArchived(c.id, true);
    widget.onChanged();
  }

  Future<void> _history() async {
    await showDialog<void>(
      context: context,
      builder: (_) => _HistoryDialog(controller: ctl, credential: c),
    );
  }

  Future<void> _rotated() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      helpText: 'New expiry date (optional)',
      initialDate: now.add(const Duration(days: 90)),
      firstDate: now,
      lastDate: DateTime(now.year + 10),
    );
    ctl.credentials.markRotated(c.id, newExpiry: d);
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final scheme = t.colorScheme;
    final now = DateTime.now();
    final days = c.expiresAt?.difference(now).inDays;
    final expiryColor = c.expiresAt == null
        ? null
        : c.isExpired(now)
        ? scheme.error
        : (days! <= 30 ? Colors.orange.shade800 : null);
    final hasSecret = c.secret.isNotEmpty;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  c.purpose == CredentialPurpose.runtime
                      ? Icons.key
                      : Icons.vpn_key_outlined,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(c.displayName, style: t.textTheme.titleSmall),
                ),
                Chip(
                  label: Text(credentialTypes[c.type] ?? c.type),
                  visualDensity: VisualDensity.compact,
                ),
                if (c.expiresAt != null) ...[
                  const SizedBox(width: 6),
                  Chip(
                    visualDensity: VisualDensity.compact,
                    avatar: Icon(Icons.schedule, size: 16, color: expiryColor),
                    label: Text(
                      c.isExpired(now)
                          ? 'Expired ${_dateFmt.format(c.expiresAt!)}'
                          : 'Expires ${_dateFmt.format(c.expiresAt!)}',
                      style: TextStyle(color: expiryColor),
                    ),
                  ),
                ],
              ],
            ),
            if (c.username.isNotEmpty)
              Row(
                children: [
                  Expanded(child: SelectableText('User: ${c.username}')),
                  IconButton(
                    tooltip: 'Copy username',
                    icon: const Icon(Icons.person_outline, size: 18),
                    onPressed: () => ctl.clipboard
                        .copyPlain(c.username)
                        .then((_) => _toast('Username copied')),
                  ),
                ],
              ),
            if (hasSecret)
              Row(
                children: [
                  Expanded(
                    child: _revealed
                        ? SelectableText(
                            c.secret,
                            style: const TextStyle(fontFamily: 'Consolas'),
                          )
                        : const Text(
                            '••••••••••••',
                            style: TextStyle(letterSpacing: 2),
                          ),
                  ),
                  IconButton(
                    tooltip: _revealed ? 'Hide' : 'Reveal',
                    icon: Icon(
                      _revealed
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      size: 18,
                    ),
                    onPressed: _toggleReveal,
                  ),
                  IconButton(
                    tooltip: 'Copy secret',
                    icon: const Icon(Icons.copy, size: 18),
                    onPressed: _copySecret,
                  ),
                  if (c.url.isNotEmpty && !widget.readOnly)
                    IconButton(
                      tooltip: 'Open the URL and copy the secret',
                      icon: const Icon(Icons.login, size: 18),
                      onPressed: _openAndCopy,
                    ),
                ],
              ),
            if (c.url.isNotEmpty)
              InkWell(
                onTap: () => openUrl(context, c.url),
                child: Text(c.url, style: TextStyle(color: scheme.primary)),
              ),
            for (final e in c.customFields.entries)
              SelectableText('${e.key}: ${e.value}'),
            if (c.notes.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(c.notes),
              ),
            if (c.rotationNotes.isNotEmpty)
              Text(
                'Rotation: ${c.rotationNotes}',
                style: t.textTheme.bodySmall,
              ),
            if (c.lastAccessedAt != null)
              Text(
                'Last accessed ${DateFormat('yyyy-MM-dd HH:mm').format(c.lastAccessedAt!)}',
                style: t.textTheme.bodySmall,
              ),
            if (!widget.readOnly)
              Wrap(
                spacing: 4,
                children: [
                  TextButton.icon(
                    onPressed: _edit,
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('Edit'),
                  ),
                  TextButton.icon(
                    onPressed: _history,
                    icon: const Icon(Icons.history, size: 18),
                    label: const Text('History'),
                  ),
                  TextButton.icon(
                    onPressed: _rotated,
                    icon: const Icon(Icons.autorenew, size: 18),
                    label: const Text('Mark rotated'),
                  ),
                  TextButton.icon(
                    onPressed: _archive,
                    icon: const Icon(Icons.archive_outlined, size: 18),
                    label: const Text('Archive'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _HistoryDialog extends StatefulWidget {
  const _HistoryDialog({required this.controller, required this.credential});
  final AppController controller;
  final Credential credential;

  @override
  State<_HistoryDialog> createState() => _HistoryDialogState();
}

class _HistoryDialogState extends State<_HistoryDialog> {
  final _shown = <String>{};

  @override
  Widget build(BuildContext context) {
    final history = widget.controller.credentials.history(widget.credential.id);
    return AlertDialog(
      title: Text('History: ${widget.credential.displayName}'),
      content: SizedBox(
        width: 460,
        child: history.isEmpty
            ? const Text('No previous values.')
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final h in history)
                    ListTile(
                      dense: true,
                      title: Text(
                        _shown.contains(h.id) ? h.secret : '••••••••••••',
                        style: const TextStyle(fontFamily: 'Consolas'),
                      ),
                      subtitle: Text(
                        'Replaced ${DateFormat('yyyy-MM-dd HH:mm').format(h.changedAt)}',
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: Icon(
                              _shown.contains(h.id)
                                  ? Icons.visibility_off_outlined
                                  : Icons.visibility_outlined,
                            ),
                            onPressed: () => setState(
                              () => _shown.contains(h.id)
                                  ? _shown.remove(h.id)
                                  : _shown.add(h.id),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.copy),
                            onPressed: () =>
                                widget.controller.clipboard.copy(h.secret),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

/// Create/edit a credential or runtime secret. Returns the edited value (id '' when creating).
class CredentialDialog extends StatefulWidget {
  const CredentialDialog({super.key, required this.purpose, this.existing});
  final CredentialPurpose purpose;
  final Credential? existing;

  @override
  State<CredentialDialog> createState() => _CredentialDialogState();
}

class _CredentialDialogState extends State<CredentialDialog> {
  late final _label = TextEditingController(text: widget.existing?.label);
  late final _key = TextEditingController(text: widget.existing?.keyName);
  late final _user = TextEditingController(text: widget.existing?.username);
  late final _secret = TextEditingController(text: widget.existing?.secret);
  late final _url = TextEditingController(text: widget.existing?.url);
  late final _notes = TextEditingController(text: widget.existing?.notes);
  late final _rotation = TextEditingController(
    text: widget.existing?.rotationNotes,
  );
  late String _type =
      widget.existing?.type ??
      (widget.purpose == CredentialPurpose.runtime ? 'envVar' : 'password');
  late DateTime? _expires = widget.existing?.expiresAt;
  late final List<(TextEditingController, TextEditingController)> _custom = [
    for (final e
        in (widget.existing?.customFields ?? const <String, String>{}).entries)
      (
        TextEditingController(text: e.key),
        TextEditingController(text: e.value),
      ),
  ];
  bool _showSecret = false;
  String? _error;
  PasswordOptions _gen = const PasswordOptions();

  bool get _runtime => widget.purpose == CredentialPurpose.runtime;
  bool get _multiline =>
      const {'sshKey', 'deployKey', 'certificate'}.contains(_type);

  @override
  void dispose() {
    for (final c in [_label, _key, _user, _secret, _url, _notes, _rotation]) {
      c.dispose();
    }
    for (final (k, v) in _custom) {
      k.dispose();
      v.dispose();
    }
    super.dispose();
  }

  void _onTypeChanged(String t) {
    setState(() {
      _type = t;
      if (t == 'dbCredentials' && _custom.isEmpty) {
        for (final k in ['host', 'port', 'database']) {
          _custom.add((
            TextEditingController(text: k),
            TextEditingController(),
          ));
        }
      }
    });
  }

  void _generate() => setState(() {
    _secret.text = generatePassword(_gen);
    _showSecret = true;
  });

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _expires ?? now.add(const Duration(days: 90)),
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 20),
    );
    if (d != null) setState(() => _expires = d);
  }

  void _save() {
    if (_runtime && _key.text.trim().isEmpty) {
      setState(() => _error = 'Key name is required (e.g. DB_PASSWORD)');
      return;
    }
    if (!_runtime && _label.text.trim().isEmpty) {
      setState(() => _error = 'Label is required');
      return;
    }
    final base =
        widget.existing ??
        Credential(id: '', purpose: widget.purpose, type: _type, label: '');
    final custom = <String, String>{
      for (final (k, v) in _custom)
        if (k.text.trim().isNotEmpty) k.text.trim(): v.text,
    };
    Navigator.pop(
      context,
      base.copyWith(
        type: _type,
        label: _label.text.trim().isEmpty
            ? _key.text.trim()
            : _label.text.trim(),
        keyName: _runtime ? _key.text.trim() : '',
        username: _user.text.trim(),
        secret: _secret.text,
        url: _url.text.trim(),
        expiresAt: _expires,
        rotationNotes: _rotation.text,
        customFields: custom,
        notes: _notes.text,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final strength = secretStrength(_secret.text);
    return AlertDialog(
      title: Text(
        widget.existing == null
            ? (_runtime ? 'Add runtime secret' : 'Add credential')
            : (_runtime ? 'Edit runtime secret' : 'Edit credential'),
      ),
      content: SizedBox(
        width: 540,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: _type,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Type',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final e in credentialTypes.entries)
                    DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
                onChanged: (v) => v == null ? null : _onTypeChanged(v),
              ),
              const SizedBox(height: 12),
              if (_runtime)
                labeledField(
                  'Key name',
                  _key,
                  error: _error,
                  hint: 'DB_PASSWORD',
                ),
              labeledField(
                _runtime ? 'Label (optional)' : 'Label',
                _label,
                error: _runtime ? null : _error,
              ),
              if (_type != 'envVar' || !_runtime)
                labeledField('Username', _user),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: TextField(
                  controller: _secret,
                  obscureText: !_showSecret && !_multiline,
                  minLines: _multiline ? 5 : 1,
                  maxLines: _multiline ? 12 : 1,
                  onChanged: (_) => setState(() {}),
                  style: const TextStyle(fontFamily: 'Consolas'),
                  decoration: InputDecoration(
                    labelText: _multiline ? 'Key / certificate text' : 'Secret',
                    border: const OutlineInputBorder(),
                    suffixIcon: _multiline
                        ? null
                        : IconButton(
                            icon: Icon(
                              _showSecret
                                  ? Icons.visibility_off_outlined
                                  : Icons.visibility_outlined,
                            ),
                            onPressed: () =>
                                setState(() => _showSecret = !_showSecret),
                          ),
                  ),
                ),
              ),
              if (_secret.text.isNotEmpty && !_multiline)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Strength: ${['Very weak', 'Weak', 'Fair', 'Good', 'Strong'][strength]}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              if (!_multiline)
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: const Text('Password generator'),
                  children: [
                    Row(
                      children: [
                        const Text('Length'),
                        Expanded(
                          child: Slider(
                            value: _gen.length.toDouble(),
                            min: 8,
                            max: 64,
                            divisions: 56,
                            label: '${_gen.length}',
                            onChanged: (v) => setState(
                              () => _gen = PasswordOptions(
                                length: v.round(),
                                lower: _gen.lower,
                                upper: _gen.upper,
                                digits: _gen.digits,
                                symbols: _gen.symbols,
                                avoidAmbiguous: _gen.avoidAmbiguous,
                              ),
                            ),
                          ),
                        ),
                        Text('${_gen.length}'),
                      ],
                    ),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final (label, get, set)
                            in <(String, bool, PasswordOptions Function(bool))>[
                              (
                                'a-z',
                                _gen.lower,
                                (v) => PasswordOptions(
                                  length: _gen.length,
                                  lower: v,
                                  upper: _gen.upper,
                                  digits: _gen.digits,
                                  symbols: _gen.symbols,
                                  avoidAmbiguous: _gen.avoidAmbiguous,
                                ),
                              ),
                              (
                                'A-Z',
                                _gen.upper,
                                (v) => PasswordOptions(
                                  length: _gen.length,
                                  lower: _gen.lower,
                                  upper: v,
                                  digits: _gen.digits,
                                  symbols: _gen.symbols,
                                  avoidAmbiguous: _gen.avoidAmbiguous,
                                ),
                              ),
                              (
                                '0-9',
                                _gen.digits,
                                (v) => PasswordOptions(
                                  length: _gen.length,
                                  lower: _gen.lower,
                                  upper: _gen.upper,
                                  digits: v,
                                  symbols: _gen.symbols,
                                  avoidAmbiguous: _gen.avoidAmbiguous,
                                ),
                              ),
                              (
                                '!@#',
                                _gen.symbols,
                                (v) => PasswordOptions(
                                  length: _gen.length,
                                  lower: _gen.lower,
                                  upper: _gen.upper,
                                  digits: _gen.digits,
                                  symbols: v,
                                  avoidAmbiguous: _gen.avoidAmbiguous,
                                ),
                              ),
                              (
                                'no look-alikes',
                                _gen.avoidAmbiguous,
                                (v) => PasswordOptions(
                                  length: _gen.length,
                                  lower: _gen.lower,
                                  upper: _gen.upper,
                                  digits: _gen.digits,
                                  symbols: _gen.symbols,
                                  avoidAmbiguous: v,
                                ),
                              ),
                            ])
                          FilterChip(
                            label: Text(label),
                            selected: get,
                            onSelected: (v) => setState(() => _gen = set(v)),
                          ),
                      ],
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: _generate,
                        icon: const Icon(Icons.casino_outlined),
                        label: const Text('Generate into the secret field'),
                      ),
                    ),
                  ],
                ),
              const SizedBox(height: 8),
              labeledField('URL', _url),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _expires == null
                          ? 'Expiry: none'
                          : 'Expires ${_dateFmt.format(_expires!)}',
                    ),
                  ),
                  TextButton(
                    onPressed: _pickDate,
                    child: const Text('Set expiry'),
                  ),
                  if (_expires != null)
                    TextButton(
                      onPressed: () => setState(() => _expires = null),
                      child: const Text('Clear'),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Custom fields',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              for (var i = 0; i < _custom.length; i++)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _custom[i].$1,
                          decoration: const InputDecoration(
                            labelText: 'Name',
                            isDense: true,
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 2,
                        child: TextField(
                          controller: _custom[i].$2,
                          decoration: const InputDecoration(
                            labelText: 'Value',
                            isDense: true,
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => setState(() {
                          final (k, v) = _custom.removeAt(i);
                          k.dispose();
                          v.dispose();
                        }),
                      ),
                    ],
                  ),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => setState(
                    () => _custom.add((
                      TextEditingController(),
                      TextEditingController(),
                    )),
                  ),
                  icon: const Icon(Icons.add),
                  label: const Text('Add field'),
                ),
              ),
              labeledField('Rotation notes', _rotation),
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
