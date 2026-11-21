import 'dart:convert';

import 'package:uuid/uuid.dart';

import 'app_database.dart';
import 'audit_log.dart';

enum CredentialPurpose { access, runtime }

/// Credential/secret types (spec F5).
const credentialTypes = <String, String>{
  'password': 'Username / password',
  'apiKey': 'API key / token',
  'dbCredentials': 'Database credentials',
  'sshKey': 'SSH key',
  'deployKey': 'Deploy key',
  'certificate': 'Certificate',
  'oauthClient': 'OAuth client',
  'envVar': 'Environment variable',
  'secret': 'Free-form secret',
};

/// Where a credential/link/attachment hangs; exactly one is set.
class Owner {
  const Owner.application(this.id) : kind = OwnerKind.application;
  const Owner.environment(this.id) : kind = OwnerKind.environment;
  const Owner.hosting(this.id) : kind = OwnerKind.hosting;
  const Owner.repository(this.id) : kind = OwnerKind.repository;
  final OwnerKind kind;
  final String id;

  String get column => switch (kind) {
    OwnerKind.application => 'application_id',
    OwnerKind.environment => 'environment_id',
    OwnerKind.hosting => 'hosting_target_id',
    OwnerKind.repository => 'repository_id',
  };
}

enum OwnerKind { application, environment, hosting, repository }

class Credential {
  Credential({
    required this.id,
    required this.purpose,
    required this.type,
    required this.label,
    this.keyName = '',
    this.username = '',
    this.secret = '',
    this.url = '',
    this.expiresAt,
    this.rotationNotes = '',
    this.customFields = const {},
    this.notes = '',
    this.applicationId,
    this.environmentId,
    this.hostingTargetId,
    this.repositoryId,
    this.lastAccessedAt,
    this.archived = false,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final CredentialPurpose purpose;
  final String type;
  final String label;
  final String keyName; // e.g. DB_PASSWORD for runtime secrets
  final String username;
  final String secret;
  final String url;
  final DateTime? expiresAt;
  final String rotationNotes;
  final Map<String, String> customFields;
  final String notes;
  final String? applicationId, environmentId, hostingTargetId, repositoryId;
  final DateTime? lastAccessedAt;
  final bool archived;
  final DateTime? createdAt, updatedAt;

  String get displayName =>
      keyName.isNotEmpty && purpose == CredentialPurpose.runtime
      ? keyName
      : label;

  bool isExpired([DateTime? now]) =>
      expiresAt != null && expiresAt!.isBefore(now ?? DateTime.now());

  Credential copyWith({
    CredentialPurpose? purpose,
    String? type,
    String? label,
    String? keyName,
    String? username,
    String? secret,
    String? url,
    Object? expiresAt = _keep,
    String? rotationNotes,
    Map<String, String>? customFields,
    String? notes,
  }) => Credential(
    id: id,
    purpose: purpose ?? this.purpose,
    type: type ?? this.type,
    label: label ?? this.label,
    keyName: keyName ?? this.keyName,
    username: username ?? this.username,
    secret: secret ?? this.secret,
    url: url ?? this.url,
    expiresAt: identical(expiresAt, _keep)
        ? this.expiresAt
        : expiresAt as DateTime?,
    rotationNotes: rotationNotes ?? this.rotationNotes,
    customFields: customFields ?? this.customFields,
    notes: notes ?? this.notes,
    applicationId: applicationId,
    environmentId: environmentId,
    hostingTargetId: hostingTargetId,
    repositoryId: repositoryId,
    lastAccessedAt: lastAccessedAt,
    archived: archived,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );

  static const Object _keep = Object();
}

class PasswordHistoryEntry {
  PasswordHistoryEntry(this.id, this.secret, this.changedAt);
  final String id, secret;
  final DateTime changedAt;
}

class CredentialStore {
  CredentialStore(this._db) : _log = AuditLog(_db);
  final AppDatabase _db;
  final AuditLog _log;
  static const _uuid = Uuid();

  static DateTime? _ts(Object? v) =>
      v == null ? null : DateTime.fromMillisecondsSinceEpoch(v as int);

  static Credential _fromRow(Map<String, Object?> r) => Credential(
    id: r['id'] as String,
    purpose: r['purpose'] == 'runtime'
        ? CredentialPurpose.runtime
        : CredentialPurpose.access,
    type: r['type'] as String,
    label: r['label'] as String,
    keyName: r['key_name'] as String,
    username: r['username'] as String,
    secret: r['secret'] as String,
    url: r['url'] as String,
    expiresAt: _ts(r['expires_at']),
    rotationNotes: r['rotation_notes'] as String,
    customFields: (jsonDecode(r['custom_fields'] as String) as Map)
        .cast<String, String>(),
    notes: r['notes'] as String,
    applicationId: r['application_id'] as String?,
    environmentId: r['environment_id'] as String?,
    hostingTargetId: r['hosting_target_id'] as String?,
    repositoryId: r['repository_id'] as String?,
    lastAccessedAt: _ts(r['last_accessed_at']),
    archived: (r['archived'] as int) == 1,
    createdAt: _ts(r['created_at']),
    updatedAt: _ts(r['updated_at']),
  );

  Credential? get(String id) {
    final rows = _db.raw.select('SELECT * FROM credentials WHERE id=?', [id]);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  List<Credential> listFor(
    Owner owner, {
    CredentialPurpose? purpose,
    bool archived = false,
  }) {
    final rows = _db.raw.select(
      'SELECT * FROM credentials WHERE ${owner.column}=? AND archived=? '
      '${purpose == null ? '' : "AND purpose='${purpose.name}'"} ORDER BY label COLLATE NOCASE, key_name COLLATE NOCASE',
      [owner.id, archived ? 1 : 0],
    );
    return rows.map((r) => _fromRow(r)).toList();
  }

  /// All non-archived credentials (for reports and global search).
  List<Credential> listAll({bool archived = false}) => _db.raw
      .select(
        'SELECT * FROM credentials WHERE archived=? ORDER BY label COLLATE NOCASE',
        [archived ? 1 : 0],
      )
      .map((r) => _fromRow(r))
      .toList();

  Credential create({
    required Owner owner,
    required CredentialPurpose purpose,
    required String type,
    required String label,
    String keyName = '',
    String username = '',
    String secret = '',
    String url = '',
    DateTime? expiresAt,
    String rotationNotes = '',
    Map<String, String> customFields = const {},
    String notes = '',
  }) {
    if (purpose == CredentialPurpose.runtime &&
        owner.kind != OwnerKind.environment) {
      throw ArgumentError('Runtime secrets must belong to an environment');
    }
    if (label.trim().isEmpty && keyName.trim().isEmpty) {
      throw ArgumentError('A label or key name is required');
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = _uuid.v4();
    _db.raw.execute(
      '''INSERT INTO credentials(id,purpose,type,label,key_name,username,secret,url,expires_at,rotation_notes,
           custom_fields,notes,${owner.column},created_at,updated_at)
         VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)''',
      [
        id,
        purpose.name,
        type,
        label.trim().isEmpty ? keyName.trim() : label.trim(),
        keyName.trim(),
        username,
        secret,
        url.trim(),
        expiresAt?.millisecondsSinceEpoch,
        rotationNotes,
        jsonEncode(customFields),
        notes,
        owner.id,
        now,
        now,
      ],
    );
    _log.record(
      'credential',
      id,
      'create',
      label.trim().isEmpty ? keyName.trim() : label.trim(),
    );
    return get(id)!;
  }

  /// Saves edits. If the secret changed, the previous value is kept in the history table.
  void update(Credential c) {
    final old = get(c.id);
    if (old == null) throw StateError('Credential not found');
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.raw.execute('BEGIN;');
    try {
      if (old.secret != c.secret && old.secret.isNotEmpty) {
        _db.raw.execute(
          'INSERT INTO credential_history(id,credential_id,secret,changed_at) VALUES(?,?,?,?)',
          [_uuid.v4(), c.id, old.secret, now],
        );
      }
      _db.raw.execute(
        '''UPDATE credentials SET type=?, label=?, key_name=?, username=?, secret=?, url=?, expires_at=?,
             rotation_notes=?, custom_fields=?, notes=?, updated_at=? WHERE id=?''',
        [
          c.type,
          c.label.trim(),
          c.keyName.trim(),
          c.username,
          c.secret,
          c.url.trim(),
          c.expiresAt?.millisecondsSinceEpoch,
          c.rotationNotes,
          jsonEncode(c.customFields),
          c.notes,
          now,
          c.id,
        ],
      );
      _db.raw.execute('COMMIT;');
    } catch (_) {
      _db.raw.execute('ROLLBACK;');
      rethrow;
    }
    _log.record(
      'credential',
      c.id,
      'update',
      c.displayName + (old.secret != c.secret ? ' (secret changed)' : ''),
    );
  }

  List<PasswordHistoryEntry> history(String credentialId) => _db.raw
      .select(
        'SELECT * FROM credential_history WHERE credential_id=? ORDER BY changed_at DESC, rowid DESC',
        [credentialId],
      )
      .map(
        (r) => PasswordHistoryEntry(
          r['id'] as String,
          r['secret'] as String,
          DateTime.fromMillisecondsSinceEpoch(r['changed_at'] as int),
        ),
      )
      .toList();

  /// Marks a reveal/copy ("last accessed", spec F10) and logs it without the value.
  void markAccessed(String id, {String how = 'reveal'}) {
    _db.raw.execute('UPDATE credentials SET last_accessed_at=? WHERE id=?', [
      DateTime.now().millisecondsSinceEpoch,
      id,
    ]);
    _log.record('credential', id, how);
  }

  /// Rotated = new secret saved. Clears nothing else; sets a new expiry if given.
  void markRotated(String id, {DateTime? newExpiry}) {
    final c = get(id);
    if (c == null) return;
    update(
      c.copyWith(
        expiresAt: newExpiry,
        rotationNotes:
            'Rotated ${DateTime.now().toIso8601String().substring(0, 10)}',
      ),
    );
  }

  void setArchived(String id, bool archived) {
    _db.raw.execute(
      'UPDATE credentials SET archived=?, updated_at=? WHERE id=?',
      [archived ? 1 : 0, DateTime.now().millisecondsSinceEpoch, id],
    );
    _log.record('credential', id, archived ? 'archive' : 'restore');
  }

  void purge(String id) {
    final c = get(id);
    if (c == null) return;
    if (!c.archived) {
      throw StateError('Only archived credentials can be purged');
    }
    _db.raw.execute('DELETE FROM credential_history WHERE credential_id=?', [
      id,
    ]);
    _db.raw.execute('DELETE FROM credentials WHERE id=?', [id]);
    _log.record('credential', id, 'purge', c.displayName);
  }

  /// Credentials expiring within [days] (including already expired), soonest first.
  List<Credential> expiring({int days = 30, DateTime? now}) {
    final limit = (now ?? DateTime.now())
        .add(Duration(days: days))
        .millisecondsSinceEpoch;
    return _db.raw
        .select(
          'SELECT * FROM credentials WHERE archived=0 AND expires_at IS NOT NULL AND expires_at<=? ORDER BY expires_at',
          [limit],
        )
        .map((r) => _fromRow(r))
        .toList();
  }

  List<Credential> recentlyAccessed({int limit = 8}) => _db.raw
      .select(
        'SELECT * FROM credentials WHERE archived=0 AND last_accessed_at IS NOT NULL ORDER BY last_accessed_at DESC LIMIT ?',
        [limit],
      )
      .map((r) => _fromRow(r))
      .toList();
}
