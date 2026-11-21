import 'package:uuid/uuid.dart';

import '../providers/git_providers.dart';
import 'app_database.dart';
import 'audit_log.dart';

class GitRepo {
  GitRepo({
    required this.id,
    required this.applicationId,
    required this.provider,
    required this.url,
    this.defaultBranch = 'main',
    this.visibility = '',
    this.localPath = '',
    this.notes = '',
    this.archived = false,
  });

  final String id;
  final String applicationId;
  final GitProvider provider;
  final String url;
  final String defaultBranch;
  final String visibility; // public | private | ''
  final String localPath;
  final String notes;
  final bool archived;

  RepoRef? get ref => RepoRef.parse(url);

  GitRepo copyWith({
    GitProvider? provider,
    String? url,
    String? defaultBranch,
    String? visibility,
    String? localPath,
    String? notes,
  }) => GitRepo(
    id: id,
    applicationId: applicationId,
    provider: provider ?? this.provider,
    url: url ?? this.url,
    defaultBranch: defaultBranch ?? this.defaultBranch,
    visibility: visibility ?? this.visibility,
    localPath: localPath ?? this.localPath,
    notes: notes ?? this.notes,
    archived: archived,
  );
}

class RepositoryStore {
  RepositoryStore(this._db) : _log = AuditLog(_db);
  final AppDatabase _db;
  final AuditLog _log;
  static const _uuid = Uuid();

  static GitRepo _fromRow(Map<String, Object?> r) => GitRepo(
    id: r['id'] as String,
    applicationId: r['application_id'] as String,
    provider: GitProviderX.fromId(r['provider'] as String),
    url: r['url'] as String,
    defaultBranch: r['default_branch'] as String,
    visibility: r['visibility'] as String,
    localPath: r['local_path'] as String,
    notes: r['notes'] as String,
    archived: (r['archived'] as int) == 1,
  );

  List<GitRepo> listForApplication(
    String applicationId, {
    bool archived = false,
  }) => _db.raw
      .select(
        'SELECT * FROM repositories WHERE application_id=? AND archived=? ORDER BY created_at',
        [applicationId, archived ? 1 : 0],
      )
      .map((r) => _fromRow(r))
      .toList();

  GitRepo? get(String id) {
    final rows = _db.raw.select('SELECT * FROM repositories WHERE id=?', [id]);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  /// Provider is detected from the URL when it can be parsed; otherwise the given one is kept.
  GitRepo create({
    required String applicationId,
    required String url,
    GitProvider? provider,
    String defaultBranch = 'main',
    String visibility = '',
    String localPath = '',
    String notes = '',
  }) {
    final ref = RepoRef.parse(url);
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = _uuid.v4();
    _db.raw.execute(
      '''INSERT INTO repositories(id,application_id,provider,url,default_branch,visibility,local_path,notes,created_at,updated_at)
         VALUES(?,?,?,?,?,?,?,?,?,?)''',
      [
        id,
        applicationId,
        (ref?.provider ?? provider ?? GitProvider.other).id,
        ref?.webUrl ?? url.trim(),
        defaultBranch,
        visibility,
        localPath,
        notes,
        now,
        now,
      ],
    );
    _log.record('repository', id, 'create', ref?.fullName ?? url.trim());
    return get(id)!;
  }

  void update(GitRepo r) {
    final ref = RepoRef.parse(r.url);
    _db.raw.execute(
      '''UPDATE repositories SET provider=?, url=?, default_branch=?, visibility=?, local_path=?, notes=?, updated_at=?
         WHERE id=?''',
      [
        (ref?.provider ?? r.provider).id,
        ref?.webUrl ?? r.url.trim(),
        r.defaultBranch,
        r.visibility,
        r.localPath,
        r.notes,
        DateTime.now().millisecondsSinceEpoch,
        r.id,
      ],
    );
    _log.record('repository', r.id, 'update', ref?.fullName ?? r.url);
  }

  /// Also archives credentials/attachments attached directly to the repository (e.g. a deploy key).
  void setArchived(String id, bool archived) {
    final flag = archived ? 1 : 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.raw.execute('BEGIN;');
    try {
      _db.raw.execute(
        'UPDATE repositories SET archived=?, updated_at=? WHERE id=?',
        [flag, now, id],
      );
      for (final t in ['credentials', 'attachments']) {
        _db.raw.execute(
          'UPDATE $t SET archived=?, updated_at=? WHERE repository_id=?',
          [flag, now, id],
        );
      }
      _db.raw.execute('COMMIT;');
    } catch (_) {
      _db.raw.execute('ROLLBACK;');
      rethrow;
    }
    _log.record('repository', id, archived ? 'archive' : 'restore');
  }

  void purge(String id) {
    final r = get(id);
    if (r == null) return;
    if (!r.archived) {
      throw StateError('Only archived repositories can be purged');
    }
    _db.raw.execute('BEGIN;');
    try {
      _db.raw.execute(
        'DELETE FROM credential_history WHERE credential_id IN (SELECT id FROM credentials WHERE repository_id=?)',
        [id],
      );
      _db.raw.execute('DELETE FROM credentials WHERE repository_id=?', [id]);
      _db.raw.execute('DELETE FROM attachments WHERE repository_id=?', [id]);
      _db.raw.execute('DELETE FROM repositories WHERE id=?', [id]);
      _db.raw.execute('COMMIT;');
      _log.record('repository', id, 'purge', r.url);
    } catch (_) {
      _db.raw.execute('ROLLBACK;');
      rethrow;
    }
  }
}
