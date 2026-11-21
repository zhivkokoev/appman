import '../db/app_database.dart';

enum HitKind {
  application,
  repository,
  environment,
  hostingTarget,
  consoleLink,
  credential,
  attachment,
}

class SearchHit {
  SearchHit({
    required this.kind,
    required this.id,
    required this.title,
    required this.subtitle,
    this.applicationId,
    this.hostingTargetId,
    this.url,
  });
  final HitKind kind;
  final String id;
  final String title;
  final String subtitle;

  /// Application to open when the hit is selected (null for hosting-only hits).
  final String? applicationId;
  final String? hostingTargetId;

  /// Set for hits that can be launched directly (console links, environment URLs).
  final String? url;
}

/// Global search across all entities (spec F6). Secret values and attachment contents are never searched.
class SearchService {
  SearchService(this._db);
  final AppDatabase _db;

  static String _like(String q) =>
      '%${q.trim().replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_')}%';

  List<SearchHit> search(String query, {int limit = 60}) {
    if (query.trim().isEmpty) return const [];
    final q = _like(query);
    final hits = <SearchHit>[];
    String l(List<String> cols) =>
        cols.map((c) => "$c LIKE ? ESCAPE '\\'").join(' OR ');
    List<Object?> args(int n) => List.filled(n, q);

    for (final r in _db.raw.select(
      'SELECT id,name,description,tags FROM applications WHERE archived=0 AND (${l(['name', 'description', 'tags', 'notes', 'owner'])}) '
      'ORDER BY name COLLATE NOCASE',
      args(5),
    )) {
      hits.add(
        SearchHit(
          kind: HitKind.application,
          id: r['id'] as String,
          title: r['name'] as String,
          subtitle: [
            r['description'],
            r['tags'],
          ].where((e) => (e as String).isNotEmpty).join(' · '),
          applicationId: r['id'] as String,
        ),
      );
    }

    for (final r in _db.raw.select(
      '''SELECT r.id, r.url, a.id AS aid, a.name AS aname FROM repositories r JOIN applications a ON a.id=r.application_id
         WHERE r.archived=0 AND a.archived=0 AND (${l(['r.url', 'r.notes', 'r.local_path'])})''',
      args(3),
    )) {
      hits.add(
        SearchHit(
          kind: HitKind.repository,
          id: r['id'] as String,
          title: (r['url'] as String).replaceFirst(RegExp(r'^https?://'), ''),
          subtitle: 'Repository · ${r['aname']}',
          applicationId: r['aid'] as String,
          url: r['url'] as String,
        ),
      );
    }

    for (final r in _db.raw.select(
      '''SELECT e.id, e.name, e.urls, a.id AS aid, a.name AS aname FROM environments e JOIN applications a ON a.id=e.application_id
         WHERE e.archived=0 AND a.archived=0 AND (${l(['e.name', 'e.urls', 'e.notes', 'e.deploy_instructions', 'e.deploy_method'])})''',
      args(5),
    )) {
      final urls = (r['urls'] as String)
          .split('\n')
          .where((u) => u.trim().isNotEmpty)
          .toList();
      hits.add(
        SearchHit(
          kind: HitKind.environment,
          id: r['id'] as String,
          title: '${r['aname']} · ${r['name']}',
          subtitle: urls.isEmpty ? 'Environment' : urls.join('  '),
          applicationId: r['aid'] as String,
          url: urls.isEmpty ? null : urls.first,
        ),
      );
    }

    for (final r in _db.raw.select(
      'SELECT id,name,provider,console_url FROM hosting_targets WHERE archived=0 AND (${l(['name', 'provider', 'account_id', 'notes', 'console_url'])})',
      args(5),
    )) {
      hits.add(
        SearchHit(
          kind: HitKind.hostingTarget,
          id: r['id'] as String,
          title: r['name'] as String,
          subtitle: 'Hosting target · ${r['provider']}',
          hostingTargetId: r['id'] as String,
          url: (r['console_url'] as String).isEmpty
              ? null
              : r['console_url'] as String,
        ),
      );
    }

    for (final r in _db.raw.select(
      '''SELECT c.id, c.label, c.url, c.type,
                COALESCE(c.application_id, e.application_id) AS aid, a.name AS aname, c.hosting_target_id AS hid, h.name AS hname
         FROM console_links c
         LEFT JOIN environments e ON e.id=c.environment_id
         LEFT JOIN applications a ON a.id=COALESCE(c.application_id, e.application_id)
         LEFT JOIN hosting_targets h ON h.id=c.hosting_target_id
         WHERE c.archived=0 AND (a.id IS NULL OR a.archived=0) AND (${l(['c.label', 'c.url', 'c.type'])})''',
      args(3),
    )) {
      hits.add(
        SearchHit(
          kind: HitKind.consoleLink,
          id: r['id'] as String,
          title: r['label'] as String,
          subtitle:
              'Console (${r['type']}) · ${r['aname'] ?? r['hname'] ?? ''}',
          applicationId: r['aid'] as String?,
          hostingTargetId: r['hid'] as String?,
          url: r['url'] as String,
        ),
      );
    }

    // Credentials: label, key name, username, url and notes only. Never the secret.
    for (final r in _db.raw.select(
      '''SELECT c.id, c.label, c.key_name, c.purpose, c.url,
                COALESCE(c.application_id, e.application_id, rp.application_id) AS aid, a.name AS aname,
                c.hosting_target_id AS hid, h.name AS hname
         FROM credentials c
         LEFT JOIN environments e ON e.id=c.environment_id
         LEFT JOIN repositories rp ON rp.id=c.repository_id
         LEFT JOIN applications a ON a.id=COALESCE(c.application_id, e.application_id, rp.application_id)
         LEFT JOIN hosting_targets h ON h.id=c.hosting_target_id
         WHERE c.archived=0 AND (a.id IS NULL OR a.archived=0)
           AND (${l(['c.label', 'c.key_name', 'c.username', 'c.url', 'c.notes'])})''',
      args(5),
    )) {
      final name =
          (r['purpose'] == 'runtime' && (r['key_name'] as String).isNotEmpty)
          ? r['key_name']
          : r['label'];
      hits.add(
        SearchHit(
          kind: HitKind.credential,
          id: r['id'] as String,
          title: name as String,
          subtitle:
              '${r['purpose'] == 'runtime' ? 'Runtime secret' : 'Credential'} · ${r['aname'] ?? r['hname'] ?? ''}',
          applicationId: r['aid'] as String?,
          hostingTargetId: r['hid'] as String?,
          url: (r['url'] as String).isEmpty ? null : r['url'] as String,
        ),
      );
    }

    for (final r in _db.raw.select(
      '''SELECT t.id, t.name, COALESCE(t.application_id, e.application_id, rp.application_id) AS aid, a.name AS aname,
                t.hosting_target_id AS hid
         FROM attachments t
         LEFT JOIN environments e ON e.id=t.environment_id
         LEFT JOIN repositories rp ON rp.id=t.repository_id
         LEFT JOIN applications a ON a.id=COALESCE(t.application_id, e.application_id, rp.application_id)
         WHERE t.archived=0 AND (a.id IS NULL OR a.archived=0) AND t.name LIKE ? ESCAPE '\\'
''',
      [q],
    )) {
      hits.add(
        SearchHit(
          kind: HitKind.attachment,
          id: r['id'] as String,
          title: r['name'] as String,
          subtitle: 'Attachment · ${r['aname'] ?? ''}',
          applicationId: r['aid'] as String?,
          hostingTargetId: r['hid'] as String?,
        ),
      );
    }

    return hits.take(limit).toList();
  }
}
