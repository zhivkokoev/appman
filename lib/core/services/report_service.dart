import '../db/app_database.dart';
import '../secrets/password_generator.dart';

/// Where a credential lives, in human terms ("Shop › production").
class CredentialRef {
  CredentialRef({
    required this.id,
    required this.name,
    required this.type,
    required this.where,
    this.applicationId,
    this.hostingTargetId,
    this.expiresAt,
    this.lastAccessedAt,
    this.updatedAt,
  });
  final String id, name, type, where;
  final String? applicationId, hostingTargetId;
  final DateTime? expiresAt, lastAccessedAt, updatedAt;
}

class CompletenessHint {
  CompletenessHint(this.applicationId, this.applicationName, this.message);
  final String applicationId, applicationName, message;
}

class DashboardData {
  DashboardData({
    required this.expiring,
    required this.recent,
    required this.hints,
    required this.archivedApplications,
    required this.activeApplications,
    required this.hostingTargets,
    required this.credentials,
  });
  final List<CredentialRef> expiring;
  final List<CredentialRef> recent;
  final List<CompletenessHint> hints;
  final int archivedApplications,
      activeApplications,
      hostingTargets,
      credentials;
}

class HygieneReport {
  HygieneReport({
    required this.weak,
    required this.reused,
    required this.old,
    required this.expired,
  });
  final List<CredentialRef> weak;

  /// Groups of credentials sharing the same secret (values are never exposed).
  final List<List<CredentialRef>> reused;
  final List<CredentialRef> old;
  final List<CredentialRef> expired;
  bool get isClean =>
      weak.isEmpty && reused.isEmpty && old.isEmpty && expired.isEmpty;
}

/// Dashboard, data-completeness hints and the weak/reused/old credential report (spec F6, F11).
class ReportService {
  ReportService(this._db);
  final AppDatabase _db;

  static DateTime? _ts(Object? v) =>
      v == null ? null : DateTime.fromMillisecondsSinceEpoch(v as int);

  static const _credSelect = '''
    SELECT c.id, c.label, c.key_name, c.purpose, c.type, c.secret, c.expires_at, c.last_accessed_at, c.updated_at,
           COALESCE(c.application_id, e.application_id, rp.application_id) AS aid, a.name AS aname,
           e.name AS ename, c.hosting_target_id AS hid, h.name AS hname
    FROM credentials c
    LEFT JOIN environments e ON e.id=c.environment_id
    LEFT JOIN repositories rp ON rp.id=c.repository_id
    LEFT JOIN applications a ON a.id=COALESCE(c.application_id, e.application_id, rp.application_id)
    LEFT JOIN hosting_targets h ON h.id=c.hosting_target_id
    WHERE c.archived=0 AND (a.id IS NULL OR a.archived=0)''';

  CredentialRef _ref(Map<String, Object?> r) {
    final name =
        (r['purpose'] == 'runtime' && (r['key_name'] as String).isNotEmpty)
        ? r['key_name']
        : r['label'];
    final where = [
      r['aname'],
      r['ename'],
      if (r['aname'] == null) r['hname'],
    ].whereType<String>().join(' › ');
    return CredentialRef(
      id: r['id'] as String,
      name: name as String,
      type: r['type'] as String,
      where: where,
      applicationId: r['aid'] as String?,
      hostingTargetId: r['hid'] as String?,
      expiresAt: _ts(r['expires_at']),
      lastAccessedAt: _ts(r['last_accessed_at']),
      updatedAt: _ts(r['updated_at']),
    );
  }

  DashboardData dashboard({DateTime? now, int expiryDays = 30}) {
    final t = now ?? DateTime.now();
    final limit = t.add(Duration(days: expiryDays)).millisecondsSinceEpoch;
    final expiring = _db.raw
        .select(
          '$_credSelect AND c.expires_at IS NOT NULL AND c.expires_at<=? ORDER BY c.expires_at',
          [limit],
        )
        .map(_ref)
        .toList();
    final recent = _db.raw
        .select(
          '$_credSelect AND c.last_accessed_at IS NOT NULL ORDER BY c.last_accessed_at DESC LIMIT 8',
        )
        .map(_ref)
        .toList();

    final hints = <CompletenessHint>[];
    for (final a in _db.raw.select(
      'SELECT id,name FROM applications WHERE archived=0 AND status!=\'idea\' ORDER BY name COLLATE NOCASE',
    )) {
      final id = a['id'] as String;
      void hint(String m) =>
          hints.add(CompletenessHint(id, a['name'] as String, m));
      final repos =
          _db.raw.select(
                'SELECT count(*) c FROM repositories WHERE application_id=? AND archived=0',
                [id],
              ).first['c']
              as int;
      final envs =
          _db.raw.select(
                'SELECT count(*) c FROM environments WHERE application_id=? AND archived=0',
                [id],
              ).first['c']
              as int;
      final creds =
          _db.raw
                  .select(
                    '''SELECT count(*) c FROM credentials WHERE archived=0 AND (application_id=? OR environment_id IN
                 (SELECT id FROM environments WHERE application_id=? AND archived=0))''',
                    [id, id],
                  )
                  .first['c']
              as int;
      if (repos == 0) hint('No repository recorded');
      if (envs == 0) {
        hint('No environment recorded');
      } else {
        final noHost = _db.raw
            .select(
              'SELECT name FROM environments WHERE application_id=? AND archived=0 AND hosting_target_id IS NULL',
              [id],
            )
            .map((r) => r['name'] as String)
            .toList();
        if (noHost.isNotEmpty) {
          hint('No hosting target for: ${noHost.join(', ')}');
        }
      }
      if (creds == 0) hint('No credentials or secrets stored');
    }

    int n(String sql) => _db.raw.select(sql).first.values.first as int;
    return DashboardData(
      expiring: expiring,
      recent: recent,
      hints: hints,
      archivedApplications: n(
        'SELECT count(*) FROM applications WHERE archived=1',
      ),
      activeApplications: n(
        'SELECT count(*) FROM applications WHERE archived=0',
      ),
      hostingTargets: n(
        'SELECT count(*) FROM hosting_targets WHERE archived=0',
      ),
      credentials: n('SELECT count(*) FROM credentials WHERE archived=0'),
    );
  }

  /// Weak/reused/old/expired credentials. [oldAfterDays] applies to secrets not changed for that long.
  HygieneReport hygiene({DateTime? now, int oldAfterDays = 365}) {
    final t = now ?? DateTime.now();
    final rows = _db.raw.select('$_credSelect AND c.secret != \'\'').toList();
    final weak = <CredentialRef>[];
    final old = <CredentialRef>[];
    final expired = <CredentialRef>[];
    final bySecret = <String, List<CredentialRef>>{};
    const strengthTypes = {
      'password',
      'apiKey',
      'dbCredentials',
      'secret',
      'oauthClient',
      'envVar',
    };
    for (final r in rows) {
      final ref = _ref(r);
      final secret = r['secret'] as String;
      final type = r['type'] as String;
      if (strengthTypes.contains(type) && secretStrength(secret) <= 1) {
        weak.add(ref);
      }
      if (ref.updatedAt != null &&
          t.difference(ref.updatedAt!).inDays >= oldAfterDays) {
        old.add(ref);
      }
      if (ref.expiresAt != null && ref.expiresAt!.isBefore(t)) expired.add(ref);
      if (secret.length >= 6) bySecret.putIfAbsent(secret, () => []).add(ref);
    }
    return HygieneReport(
      weak: weak,
      reused: bySecret.values.where((g) => g.length > 1).toList(),
      old: old,
      expired: expired,
    );
  }
}
