import 'package:uuid/uuid.dart';

import 'app_database.dart';
import 'audit_log.dart';

class HostingTarget {
  HostingTarget({
    required this.id,
    required this.name,
    this.provider = 'other',
    this.accountId = '',
    this.region = '',
    this.consoleUrl = '',
    this.notes = '',
    this.archived = false,
  });

  final String id;
  final String name;
  final String provider; // template id, see hosting_templates.dart
  final String accountId;
  final String region;
  final String consoleUrl;
  final String notes;
  final bool archived;

  HostingTarget copyWith({
    String? name,
    String? provider,
    String? accountId,
    String? region,
    String? consoleUrl,
    String? notes,
  }) => HostingTarget(
    id: id,
    name: name ?? this.name,
    provider: provider ?? this.provider,
    accountId: accountId ?? this.accountId,
    region: region ?? this.region,
    consoleUrl: consoleUrl ?? this.consoleUrl,
    notes: notes ?? this.notes,
    archived: archived,
  );
}

/// What runs on a hosting target (reverse view, spec F3).
class HostedEnvironment {
  HostedEnvironment(
    this.applicationId,
    this.applicationName,
    this.environmentId,
    this.environmentName,
    this.urls,
  );
  final String applicationId, applicationName, environmentId, environmentName;
  final List<String> urls;
}

class HostingTargetStore {
  HostingTargetStore(this._db) : _log = AuditLog(_db);
  final AppDatabase _db;
  final AuditLog _log;
  static const _uuid = Uuid();

  static HostingTarget _fromRow(Map<String, Object?> r) => HostingTarget(
    id: r['id'] as String,
    name: r['name'] as String,
    provider: r['provider'] as String,
    accountId: r['account_id'] as String,
    region: r['region'] as String,
    consoleUrl: r['console_url'] as String,
    notes: r['notes'] as String,
    archived: (r['archived'] as int) == 1,
  );

  List<HostingTarget> list({bool archived = false}) => _db.raw
      .select(
        'SELECT * FROM hosting_targets WHERE archived=? ORDER BY name COLLATE NOCASE',
        [archived ? 1 : 0],
      )
      .map((r) => _fromRow(r))
      .toList();

  HostingTarget? get(String id) {
    final rows = _db.raw.select('SELECT * FROM hosting_targets WHERE id=?', [
      id,
    ]);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  HostingTarget create({
    required String name,
    String provider = 'other',
    String accountId = '',
    String region = '',
    String consoleUrl = '',
    String notes = '',
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = _uuid.v4();
    _db.raw.execute(
      '''INSERT INTO hosting_targets(id,name,provider,account_id,region,console_url,notes,created_at,updated_at)
         VALUES(?,?,?,?,?,?,?,?,?)''',
      [
        id,
        name.trim(),
        provider,
        accountId,
        region,
        consoleUrl.trim(),
        notes,
        now,
        now,
      ],
    );
    _log.record('hosting_target', id, 'create', name.trim());
    return get(id)!;
  }

  void update(HostingTarget t) {
    _update(t);
    _log.record('hosting_target', t.id, 'update', t.name);
  }

  void _update(HostingTarget t) => _db.raw.execute(
    '''UPDATE hosting_targets SET name=?, provider=?, account_id=?, region=?, console_url=?, notes=?, updated_at=?
           WHERE id=?''',
    [
      t.name.trim(),
      t.provider,
      t.accountId,
      t.region,
      t.consoleUrl.trim(),
      t.notes,
      DateTime.now().millisecondsSinceEpoch,
      t.id,
    ],
  );

  /// Active (non-archived) environments of non-archived applications using this target.
  List<HostedEnvironment> hostedEnvironments(String targetId) => _db.raw
      .select(
        '''SELECT a.id AS aid, a.name AS aname, e.id AS eid, e.name AS ename, e.urls AS urls
           FROM environments e JOIN applications a ON a.id = e.application_id
           WHERE e.hosting_target_id=? AND e.archived=0 AND a.archived=0
           ORDER BY a.name COLLATE NOCASE, e.name''',
        [targetId],
      )
      .map(
        (r) => HostedEnvironment(
          r['aid'] as String,
          r['aname'] as String,
          r['eid'] as String,
          r['ename'] as String,
          (r['urls'] as String)
              .split('\n')
              .where((u) => u.trim().isNotEmpty)
              .toList(),
        ),
      )
      .toList();

  /// Shared targets are never archived by cascade; archiving one that is still in use is refused.
  void setArchived(String id, bool archived) {
    if (archived && hostedEnvironments(id).isNotEmpty) {
      throw StateError('Hosting target is still used by active environments');
    }
    _db.raw.execute(
      'UPDATE hosting_targets SET archived=?, updated_at=? WHERE id=?',
      [archived ? 1 : 0, DateTime.now().millisecondsSinceEpoch, id],
    );
    _log.record('hosting_target', id, archived ? 'archive' : 'restore');
  }

  /// Only archived, completely unreferenced targets can be purged.
  void purge(String id) {
    final t = get(id);
    if (t == null) return;
    if (!t.archived) {
      throw StateError('Only archived hosting targets can be purged');
    }
    final refs =
        _db.raw
                .select(
                  '''SELECT (SELECT count(*) FROM environments WHERE hosting_target_id=?) +
                  (SELECT count(*) FROM credentials WHERE hosting_target_id=?) +
                  (SELECT count(*) FROM console_links WHERE hosting_target_id=?) +
                  (SELECT count(*) FROM attachments WHERE hosting_target_id=?) AS n''',
                  [id, id, id, id],
                )
                .first['n']
            as int;
    if (refs > 0) {
      throw StateError('Hosting target is still referenced by $refs record(s)');
    }
    _db.raw.execute('DELETE FROM hosting_targets WHERE id=?', [id]);
    _log.record('hosting_target', id, 'purge', t.name);
  }
}
