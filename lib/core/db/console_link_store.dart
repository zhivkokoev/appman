import 'package:uuid/uuid.dart';

import 'app_database.dart';
import 'audit_log.dart';
import 'credential_store.dart' show Owner;

const consoleLinkTypes = <String>[
  'hosting',
  'database',
  'dns',
  'monitoring',
  'analytics',
  'mail',
  'repository',
  'ci/cd',
  'other',
];

class ConsoleLink {
  ConsoleLink({
    required this.id,
    required this.label,
    required this.url,
    this.type = 'other',
    this.applicationId,
    this.environmentId,
    this.hostingTargetId,
    this.archived = false,
  });
  final String id, label, url, type;
  final String? applicationId, environmentId, hostingTargetId;
  final bool archived;

  ConsoleLink copyWith({String? label, String? url, String? type}) =>
      ConsoleLink(
        id: id,
        label: label ?? this.label,
        url: url ?? this.url,
        type: type ?? this.type,
        applicationId: applicationId,
        environmentId: environmentId,
        hostingTargetId: hostingTargetId,
        archived: archived,
      );
}

class ConsoleLinkStore {
  ConsoleLinkStore(this._db) : _log = AuditLog(_db);
  final AppDatabase _db;
  final AuditLog _log;
  static const _uuid = Uuid();

  static ConsoleLink _fromRow(Map<String, Object?> r) => ConsoleLink(
    id: r['id'] as String,
    label: r['label'] as String,
    url: r['url'] as String,
    type: r['type'] as String,
    applicationId: r['application_id'] as String?,
    environmentId: r['environment_id'] as String?,
    hostingTargetId: r['hosting_target_id'] as String?,
    archived: (r['archived'] as int) == 1,
  );

  ConsoleLink? get(String id) {
    final rows = _db.raw.select('SELECT * FROM console_links WHERE id=?', [id]);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  /// Links can hang off an application, environment or hosting target (not a repository).
  List<ConsoleLink> listFor(Owner owner, {bool archived = false}) => _db.raw
      .select(
        'SELECT * FROM console_links WHERE ${owner.column}=? AND archived=? ORDER BY label COLLATE NOCASE',
        [owner.id, archived ? 1 : 0],
      )
      .map((r) => _fromRow(r))
      .toList();

  List<ConsoleLink> listAll() => _db.raw
      .select(
        'SELECT * FROM console_links WHERE archived=0 ORDER BY label COLLATE NOCASE',
      )
      .map((r) => _fromRow(r))
      .toList();

  ConsoleLink create({
    required Owner owner,
    required String label,
    required String url,
    String type = 'other',
  }) {
    if (!(owner.column == 'application_id' ||
        owner.column == 'environment_id' ||
        owner.column == 'hosting_target_id')) {
      throw ArgumentError('Console links cannot belong to a repository');
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = _uuid.v4();
    _db.raw.execute(
      'INSERT INTO console_links(id,label,url,type,${owner.column},created_at,updated_at) VALUES(?,?,?,?,?,?,?)',
      [id, label.trim(), url.trim(), type, owner.id, now, now],
    );
    _log.record('console_link', id, 'create', label.trim());
    return get(id)!;
  }

  void update(ConsoleLink l) {
    _db.raw.execute(
      'UPDATE console_links SET label=?, url=?, type=?, updated_at=? WHERE id=?',
      [
        l.label.trim(),
        l.url.trim(),
        l.type,
        DateTime.now().millisecondsSinceEpoch,
        l.id,
      ],
    );
    _log.record('console_link', l.id, 'update', l.label);
  }

  void setArchived(String id, bool archived) {
    _db.raw.execute(
      'UPDATE console_links SET archived=?, updated_at=? WHERE id=?',
      [archived ? 1 : 0, DateTime.now().millisecondsSinceEpoch, id],
    );
    _log.record('console_link', id, archived ? 'archive' : 'restore');
  }

  void purge(String id) {
    final l = get(id);
    if (l == null) return;
    if (!l.archived) throw StateError('Only archived links can be purged');
    _db.raw.execute('DELETE FROM console_links WHERE id=?', [id]);
    _log.record('console_link', id, 'purge', l.label);
  }
}
