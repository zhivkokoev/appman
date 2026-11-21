import 'package:uuid/uuid.dart';

import 'app_database.dart';
import 'audit_log.dart';

class Application {
  Application({
    required this.id,
    required this.name,
    this.description = '',
    this.status = 'active',
    this.tags = const [],
    this.notes = '',
    this.criticality = '',
    this.owner = '',
    this.archived = false,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final String description;
  final String status; // active | idea
  final List<String> tags;
  final String notes;
  final String criticality;
  final String owner;
  final bool archived;
  final int createdAt;
  final int updatedAt;

  Application copyWith({
    String? name,
    String? description,
    String? status,
    List<String>? tags,
    String? notes,
    String? criticality,
    String? owner,
  }) => Application(
    id: id,
    name: name ?? this.name,
    description: description ?? this.description,
    status: status ?? this.status,
    tags: tags ?? this.tags,
    notes: notes ?? this.notes,
    criticality: criticality ?? this.criticality,
    owner: owner ?? this.owner,
    archived: archived,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );

  static List<String> parseTags(String s) =>
      s.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
}

class ApplicationRepository {
  ApplicationRepository(this._db) : _log = AuditLog(_db);
  final AppDatabase _db;
  final AuditLog _log;
  static const _uuid = Uuid();

  static Application _fromRow(Map<String, Object?> r) => Application(
    id: r['id'] as String,
    name: r['name'] as String,
    description: r['description'] as String,
    status: r['status'] as String,
    tags: Application.parseTags(r['tags'] as String),
    notes: r['notes'] as String,
    criticality: r['criticality'] as String,
    owner: r['owner'] as String,
    archived: (r['archived'] as int) == 1,
    createdAt: r['created_at'] as int,
    updatedAt: r['updated_at'] as int,
  );

  /// Name/description/tags/notes search (secrets are never searched). Case-insensitive.
  List<Application> list({String query = '', bool archived = false}) {
    final q = '%${query.trim().replaceAll('%', r'\%').replaceAll('_', r'\_')}%';
    final rows = _db.raw.select(
      '''SELECT * FROM applications
         WHERE archived = ?
           AND (name LIKE ? ESCAPE '\\' OR description LIKE ? ESCAPE '\\'
                OR tags LIKE ? ESCAPE '\\' OR notes LIKE ? ESCAPE '\\' OR owner LIKE ? ESCAPE '\\')
         ORDER BY name COLLATE NOCASE''',
      [archived ? 1 : 0, q, q, q, q, q],
    );
    return rows.map((r) => _fromRow(r)).toList();
  }

  Application? get(String id) {
    final rows = _db.raw.select('SELECT * FROM applications WHERE id = ?', [
      id,
    ]);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  Application create({
    required String name,
    String description = '',
    String status = 'active',
    List<String> tags = const [],
    String notes = '',
    String criticality = '',
    String owner = '',
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = _uuid.v4();
    _db.raw.execute(
      '''INSERT INTO applications(id,name,description,status,tags,notes,criticality,owner,created_at,updated_at)
         VALUES(?,?,?,?,?,?,?,?,?,?)''',
      [
        id,
        name.trim(),
        description,
        status,
        tags.join(', '),
        notes,
        criticality,
        owner,
        now,
        now,
      ],
    );
    _log.record('application', id, 'create', name.trim());
    return get(id)!;
  }

  void update(Application a) {
    _db.raw.execute(
      '''UPDATE applications SET name=?, description=?, status=?, tags=?, notes=?, criticality=?, owner=?, updated_at=?
         WHERE id=?''',
      [
        a.name.trim(),
        a.description,
        a.status,
        a.tags.join(', '),
        a.notes,
        a.criticality,
        a.owner,
        DateTime.now().millisecondsSinceEpoch,
        a.id,
      ],
    );
    _log.record('application', a.id, 'update', a.name);
  }

  /// Archive = soft delete (spec F10). Children are archived/restored together.
  void setArchived(String id, bool archived) {
    final flag = archived ? 1 : 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.raw.execute('BEGIN;');
    try {
      for (final t in ['applications', 'repositories', 'environments']) {
        final col = t == 'applications' ? 'id' : 'application_id';
        _db.raw.execute('UPDATE $t SET archived=?, updated_at=? WHERE $col=?', [
          flag,
          now,
          id,
        ]);
      }
      for (final t in ['credentials', 'console_links', 'attachments']) {
        _db.raw.execute(
          'UPDATE $t SET archived=?, updated_at=? WHERE application_id=?',
          [flag, now, id],
        );
      }
      // Credentials/attachments/links attached to this app's environments or repositories.
      for (final t in ['credentials', 'console_links', 'attachments']) {
        _db.raw.execute(
          'UPDATE $t SET archived=?, updated_at=? WHERE environment_id IN (SELECT id FROM environments WHERE application_id=?)',
          [flag, now, id],
        );
      }
      for (final t in ['credentials', 'attachments']) {
        _db.raw.execute(
          'UPDATE $t SET archived=?, updated_at=? WHERE repository_id IN (SELECT id FROM repositories WHERE application_id=?)',
          [flag, now, id],
        );
      }
      _db.raw.execute('COMMIT;');
    } catch (_) {
      _db.raw.execute('ROLLBACK;');
      rethrow;
    }
    _log.record(
      'application',
      id,
      archived ? 'archive' : 'restore',
      get(id)?.name ?? '',
    );
  }

  /// Permanent delete; only allowed for already-archived applications (spec F10).
  void purge(String id) {
    final a = get(id);
    if (a == null) return;
    if (!a.archived) {
      throw StateError('Only archived applications can be purged');
    }
    _db.raw.execute('BEGIN;');
    try {
      final envs = '(SELECT id FROM environments WHERE application_id=?)';
      final repos = '(SELECT id FROM repositories WHERE application_id=?)';
      _db.raw.execute(
        'DELETE FROM credential_history WHERE credential_id IN '
        '(SELECT id FROM credentials WHERE application_id=? OR environment_id IN $envs OR repository_id IN $repos)',
        [id, id, id],
      );
      _db.raw.execute(
        'DELETE FROM credentials WHERE application_id=? OR environment_id IN $envs OR repository_id IN $repos',
        [id, id, id],
      );
      _db.raw.execute(
        'DELETE FROM attachments WHERE application_id=? OR environment_id IN $envs OR repository_id IN $repos',
        [id, id, id],
      );
      _db.raw.execute(
        'DELETE FROM console_links WHERE application_id=? OR environment_id IN $envs',
        [id, id],
      );
      _db.raw.execute('DELETE FROM environments WHERE application_id=?', [id]);
      _db.raw.execute('DELETE FROM repositories WHERE application_id=?', [id]);
      _db.raw.execute('DELETE FROM applications WHERE id=?', [id]);
      _db.raw.execute('COMMIT;');
      _log.record('application', id, 'purge', a.name);
    } catch (_) {
      _db.raw.execute('ROLLBACK;');
      rethrow;
    }
  }
}
