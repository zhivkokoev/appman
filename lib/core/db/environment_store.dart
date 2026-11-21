import 'package:uuid/uuid.dart';

import 'app_database.dart';
import 'audit_log.dart';

class AppEnvironment {
  AppEnvironment({
    required this.id,
    required this.applicationId,
    required this.name,
    this.hostingTargetId,
    this.urls = const [],
    this.region = '',
    this.deployMethod = '',
    this.deployInstructions = '',
    this.version = '',
    this.lastDeployed,
    this.notes = '',
    this.archived = false,
  });

  final String id;
  final String applicationId;
  final String name;
  final String? hostingTargetId;
  final List<String> urls;
  final String region;
  final String deployMethod;
  final String deployInstructions;
  final String version;
  final DateTime? lastDeployed;
  final String notes;
  final bool archived;

  AppEnvironment copyWith({
    String? name,
    Object? hostingTargetId = _keep,
    List<String>? urls,
    String? region,
    String? deployMethod,
    String? deployInstructions,
    String? version,
    Object? lastDeployed = _keep,
    String? notes,
  }) => AppEnvironment(
    id: id,
    applicationId: applicationId,
    name: name ?? this.name,
    hostingTargetId: identical(hostingTargetId, _keep)
        ? this.hostingTargetId
        : hostingTargetId as String?,
    urls: urls ?? this.urls,
    region: region ?? this.region,
    deployMethod: deployMethod ?? this.deployMethod,
    deployInstructions: deployInstructions ?? this.deployInstructions,
    version: version ?? this.version,
    lastDeployed: identical(lastDeployed, _keep)
        ? this.lastDeployed
        : lastDeployed as DateTime?,
    notes: notes ?? this.notes,
    archived: archived,
  );

  static const Object _keep = Object();
  static List<String> parseUrls(String s) => s
      .split(RegExp(r'[\r\n]+'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();
}

class EnvironmentStore {
  EnvironmentStore(this._db) : _log = AuditLog(_db);
  final AppDatabase _db;
  final AuditLog _log;
  static const _uuid = Uuid();

  static AppEnvironment _fromRow(Map<String, Object?> r) => AppEnvironment(
    id: r['id'] as String,
    applicationId: r['application_id'] as String,
    name: r['name'] as String,
    hostingTargetId: r['hosting_target_id'] as String?,
    urls: AppEnvironment.parseUrls(r['urls'] as String),
    region: r['region'] as String,
    deployMethod: r['deploy_method'] as String,
    deployInstructions: r['deploy_instructions'] as String,
    version: r['version'] as String,
    lastDeployed: r['last_deployed'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(r['last_deployed'] as int),
    notes: r['notes'] as String,
    archived: (r['archived'] as int) == 1,
  );

  List<AppEnvironment> listForApplication(
    String applicationId, {
    bool archived = false,
  }) => _db.raw
      .select(
        'SELECT * FROM environments WHERE application_id=? AND archived=? ORDER BY created_at',
        [applicationId, archived ? 1 : 0],
      )
      .map((r) => _fromRow(r))
      .toList();

  AppEnvironment? get(String id) {
    final rows = _db.raw.select('SELECT * FROM environments WHERE id=?', [id]);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  AppEnvironment create({
    required String applicationId,
    required String name,
    String? hostingTargetId,
    List<String> urls = const [],
    String region = '',
    String deployMethod = '',
    String deployInstructions = '',
    String version = '',
    DateTime? lastDeployed,
    String notes = '',
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = _uuid.v4();
    _db.raw.execute(
      '''INSERT INTO environments(id,application_id,hosting_target_id,name,urls,region,deploy_method,
           deploy_instructions,version,last_deployed,notes,created_at,updated_at)
         VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)''',
      [
        id,
        applicationId,
        hostingTargetId,
        name.trim(),
        urls.join('\n'),
        region,
        deployMethod,
        deployInstructions,
        version,
        lastDeployed?.millisecondsSinceEpoch,
        notes,
        now,
        now,
      ],
    );
    _log.record('environment', id, 'create', name.trim());
    return get(id)!;
  }

  void update(AppEnvironment e) {
    _update(e);
    _log.record('environment', e.id, 'update', e.name);
  }

  void _update(AppEnvironment e) => _db.raw.execute(
    '''UPDATE environments SET hosting_target_id=?, name=?, urls=?, region=?, deploy_method=?,
             deploy_instructions=?, version=?, last_deployed=?, notes=?, updated_at=?
           WHERE id=?''',
    [
      e.hostingTargetId,
      e.name.trim(),
      e.urls.join('\n'),
      e.region,
      e.deployMethod,
      e.deployInstructions,
      e.version,
      e.lastDeployed?.millisecondsSinceEpoch,
      e.notes,
      DateTime.now().millisecondsSinceEpoch,
      e.id,
    ],
  );

  /// Archiving an environment also archives its runtime secrets and attached items.
  void setArchived(String id, bool archived) {
    final flag = archived ? 1 : 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.raw.execute('BEGIN;');
    try {
      _db.raw.execute(
        'UPDATE environments SET archived=?, updated_at=? WHERE id=?',
        [flag, now, id],
      );
      for (final t in ['credentials', 'console_links', 'attachments']) {
        _db.raw.execute(
          'UPDATE $t SET archived=?, updated_at=? WHERE environment_id=?',
          [flag, now, id],
        );
      }
      _db.raw.execute('COMMIT;');
    } catch (_) {
      _db.raw.execute('ROLLBACK;');
      rethrow;
    }
    _log.record('environment', id, archived ? 'archive' : 'restore');
  }

  void purge(String id) {
    final e = get(id);
    if (e == null) return;
    if (!e.archived) {
      throw StateError('Only archived environments can be purged');
    }
    _db.raw.execute('BEGIN;');
    try {
      _db.raw.execute(
        'DELETE FROM credential_history WHERE credential_id IN (SELECT id FROM credentials WHERE environment_id=?)',
        [id],
      );
      for (final t in ['credentials', 'console_links', 'attachments']) {
        _db.raw.execute('DELETE FROM $t WHERE environment_id=?', [id]);
      }
      _db.raw.execute('DELETE FROM environments WHERE id=?', [id]);
      _db.raw.execute('COMMIT;');
      _log.record('environment', id, 'purge', e.name);
    } catch (_) {
      _db.raw.execute('ROLLBACK;');
      rethrow;
    }
  }
}
