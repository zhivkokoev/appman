import 'app_database.dart';

class LogEntry {
  LogEntry(
    this.id,
    this.ts,
    this.entity,
    this.entityId,
    this.action,
    this.summary,
  );
  final int id;
  final DateTime ts;
  final String entity, entityId, action, summary;
}

/// Local change log (spec F10). Callers must never put secret values in [summary].
class AuditLog {
  AuditLog(this._db);
  final AppDatabase _db;

  void record(
    String entity,
    String entityId,
    String action, [
    String summary = '',
  ]) {
    _db.raw.execute(
      'INSERT INTO change_log(ts, entity, entity_id, action, summary) VALUES(?,?,?,?,?)',
      [
        DateTime.now().millisecondsSinceEpoch,
        entity,
        entityId,
        action,
        summary,
      ],
    );
  }

  List<LogEntry> forEntity(String entity, String entityId, {int limit = 100}) =>
      _db.raw
          .select(
            'SELECT * FROM change_log WHERE entity=? AND entity_id=? ORDER BY id DESC LIMIT ?',
            [entity, entityId, limit],
          )
          .map(_row)
          .toList();

  List<LogEntry> recent({int limit = 200}) => _db.raw
      .select('SELECT * FROM change_log ORDER BY id DESC LIMIT ?', [limit])
      .map(_row)
      .toList();

  static LogEntry _row(Map<String, Object?> r) => LogEntry(
    r['id'] as int,
    DateTime.fromMillisecondsSinceEpoch(r['ts'] as int),
    r['entity'] as String,
    r['entity_id'] as String,
    r['action'] as String,
    r['summary'] as String,
  );

  /// Drops log rows older than [days] (keeps the DB small).
  void prune({int days = 365}) => _db.raw.execute(
    'DELETE FROM change_log WHERE ts < ?',
    [DateTime.now().subtract(Duration(days: days)).millisecondsSinceEpoch],
  );
}
