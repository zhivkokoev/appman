import 'dart:convert';
import 'dart:typed_data';

import 'package:intl/intl.dart';

import '../db/app_database.dart';
import '../db/application_repository.dart';
import '../db/attachment_store.dart';
import '../db/console_link_store.dart';
import '../db/credential_store.dart';
import '../db/environment_store.dart';
import '../db/hosting_target_store.dart';
import '../db/repository_store.dart';
import '../providers/git_providers.dart';
import '../providers/hosting_templates.dart';
import '../secrets/dotenv.dart';

class ImportResult {
  int applications = 0,
      hostingTargets = 0,
      repositories = 0,
      environments = 0,
      links = 0,
      credentials = 0,
      attachments = 0;
  final warnings = <String>[];
  String get summary =>
      'Imported $applications application(s), $repositories repo(s), $environments environment(s), '
      '$credentials credential(s), $links link(s), $attachments attachment(s), $hostingTargets new hosting target(s).';
}

/// Export and import (spec F9). Reports never contain secrets; the full JSON export does only on request
/// (the UI must re-ask for the master password first).
class ExportService {
  ExportService(this._db)
    : _apps = ApplicationRepository(_db),
      _repos = RepositoryStore(_db),
      _envs = EnvironmentStore(_db),
      _hosts = HostingTargetStore(_db),
      _creds = CredentialStore(_db),
      _links = ConsoleLinkStore(_db),
      _files = AttachmentStore(_db);

  final AppDatabase _db;
  final ApplicationRepository _apps;
  final RepositoryStore _repos;
  final EnvironmentStore _envs;
  final HostingTargetStore _hosts;
  final CredentialStore _creds;
  final ConsoleLinkStore _links;
  final AttachmentStore _files;

  static final _date = DateFormat('yyyy-MM-dd');
  static String _d(DateTime? t) => t == null ? '' : _date.format(t);

  // ---------------------------------------------------------------- plaintext report (no secrets)

  String reportMarkdown({DateTime? now}) {
    final b = StringBuffer(
      '# AppMan report\n\nGenerated ${_date.format(now ?? DateTime.now())}. Contains no secret values.\n',
    );
    final hosts = _hosts.list();
    final hostName = {for (final h in hosts) h.id: h.name};

    for (final a in _apps.list()) {
      b.writeln('\n## ${a.name}\n');
      if (a.description.isNotEmpty) b.writeln(a.description);
      b.writeln('\n- Status: ${a.status}');
      if (a.tags.isNotEmpty) b.writeln('- Tags: ${a.tags.join(', ')}');
      if (a.owner.isNotEmpty) b.writeln('- Owner / client: ${a.owner}');
      if (a.criticality.isNotEmpty) {
        b.writeln('- Criticality: ${a.criticality}');
      }
      final repos = _repos.listForApplication(a.id);
      if (repos.isNotEmpty) {
        b.writeln('\n### Repositories\n');
        for (final r in repos) {
          b.writeln(
            '- ${r.url} (${r.provider.label}, branch `${r.defaultBranch}`)',
          );
        }
      }
      final envs = _envs.listForApplication(a.id);
      if (envs.isNotEmpty) {
        b.writeln('\n### Environments\n');
        for (final e in envs) {
          b.writeln('#### ${e.name}\n');
          if (e.hostingTargetId != null) {
            b.writeln(
              '- Hosting: ${hostName[e.hostingTargetId] ?? '(archived target)'}',
            );
          }
          for (final u in e.urls) {
            b.writeln('- URL: $u');
          }
          if (e.deployMethod.isNotEmpty) {
            b.writeln('- Deploy method: ${e.deployMethod}');
          }
          if (e.version.isNotEmpty) b.writeln('- Version: ${e.version}');
          if (e.lastDeployed != null) {
            b.writeln('- Last deployed: ${_d(e.lastDeployed)}');
          }
          if (e.deployInstructions.isNotEmpty) {
            b.writeln(
              '\nDeploy instructions:\n\n```\n${e.deployInstructions}\n```',
            );
          }
          final secrets = _creds.listFor(
            Owner.environment(e.id),
            purpose: CredentialPurpose.runtime,
          );
          if (secrets.isNotEmpty) {
            b.writeln(
              '- Runtime secrets (names only): ${secrets.map((s) => s.displayName).join(', ')}',
            );
          }
          _writeLinks(b, _links.listFor(Owner.environment(e.id)));
          b.writeln();
        }
      }
      _writeLinks(b, _links.listFor(Owner.application(a.id)));
      final access = [
        ..._creds.listFor(Owner.application(a.id)),
        for (final r in repos) ..._creds.listFor(Owner.repository(r.id)),
        for (final e in envs)
          ..._creds.listFor(
            Owner.environment(e.id),
            purpose: CredentialPurpose.access,
          ),
      ];
      if (access.isNotEmpty) {
        b.writeln('\n### Credentials (no secrets)\n');
        for (final c in access) {
          b.writeln(
            '- ${c.label} [${credentialTypes[c.type] ?? c.type}]'
            '${c.username.isEmpty ? '' : ', user `${c.username}`'}${c.url.isEmpty ? '' : ', ${c.url}'}'
            '${c.expiresAt == null ? '' : ', expires ${_d(c.expiresAt)}'}',
          );
        }
      }
      if (a.notes.isNotEmpty) b.writeln('\n### Notes\n\n${a.notes}');
    }

    if (hosts.isNotEmpty) {
      b.writeln('\n## Hosting targets\n');
      for (final h in hosts) {
        b.writeln(
          '### ${h.name}\n\n- Provider: ${templateFor(h.provider).label}',
        );
        if (h.region.isNotEmpty) b.writeln('- Region: ${h.region}');
        if (h.accountId.isNotEmpty) {
          b.writeln('- Account / project: ${h.accountId}');
        }
        if (h.consoleUrl.isNotEmpty) b.writeln('- Console: ${h.consoleUrl}');
        final hosted = _hosts.hostedEnvironments(h.id);
        if (hosted.isNotEmpty) {
          b.writeln(
            '- Runs: ${hosted.map((e) => '${e.applicationName} (${e.environmentName})').join(', ')}',
          );
        }
        b.writeln();
      }
    }
    return b.toString();
  }

  void _writeLinks(StringBuffer b, List<ConsoleLink> links) {
    if (links.isEmpty) return;
    b.writeln('\nConsole links:\n');
    for (final l in links) {
      b.writeln('- [${l.label}](${l.url}) (${l.type})');
    }
  }

  /// Flat CSV (one row per item) for spreadsheets. No secrets.
  String reportCsv() {
    final rows = <List<String>>[
      ['application', 'environment', 'kind', 'name', 'url', 'details'],
    ];
    final hostName = {for (final h in _hosts.list()) h.id: h.name};
    for (final a in _apps.list()) {
      rows.add([
        a.name,
        '',
        'application',
        a.name,
        '',
        '${a.status}; tags: ${a.tags.join(' ')}',
      ]);
      for (final r in _repos.listForApplication(a.id)) {
        rows.add([
          a.name,
          '',
          'repository',
          r.ref?.fullName ?? r.url,
          r.url,
          r.provider.label,
        ]);
      }
      for (final e in _envs.listForApplication(a.id)) {
        rows.add([
          a.name,
          e.name,
          'environment',
          e.name,
          e.urls.join(' '),
          '${hostName[e.hostingTargetId] ?? ''}; ${e.deployMethod}'.trim(),
        ]);
        for (final c in _creds.listFor(Owner.environment(e.id))) {
          rows.add([
            a.name,
            e.name,
            c.purpose == CredentialPurpose.runtime
                ? 'runtime-secret'
                : 'credential',
            c.displayName,
            c.url,
            credentialTypes[c.type] ?? c.type,
          ]);
        }
        for (final l in _links.listFor(Owner.environment(e.id))) {
          rows.add([a.name, e.name, 'console', l.label, l.url, l.type]);
        }
      }
      for (final c in _creds.listFor(Owner.application(a.id))) {
        rows.add([
          a.name,
          '',
          'credential',
          c.label,
          c.url,
          '${credentialTypes[c.type] ?? c.type}; user: ${c.username}',
        ]);
      }
      for (final l in _links.listFor(Owner.application(a.id))) {
        rows.add([a.name, '', 'console', l.label, l.url, l.type]);
      }
    }
    return writeCsv(rows);
  }

  // ---------------------------------------------------------------- JSON export

  /// Structured export. With [includeSecrets], secrets, history-free current values and attachment bytes
  /// are included, so the output must be treated like the vault itself.
  Map<String, Object?> toJsonMap({
    required bool includeSecrets,
    DateTime? now,
  }) {
    Map<String, Object?> cred(Credential c) => {
      'purpose': c.purpose.name,
      'type': c.type,
      'label': c.label,
      'keyName': c.keyName,
      'username': c.username,
      if (includeSecrets) 'secret': c.secret,
      'url': c.url,
      'expiresAt': c.expiresAt?.toIso8601String(),
      'rotationNotes': c.rotationNotes,
      'customFields': includeSecrets
          ? c.customFields
          : {for (final k in c.customFields.keys) k: ''},
      'notes': c.notes,
    };
    Map<String, Object?> link(ConsoleLink l) => {
      'label': l.label,
      'url': l.url,
      'type': l.type,
    };
    Map<String, Object?> file(Attachment a) => {
      'name': a.name,
      'mimeType': a.mimeType,
      'size': a.size,
      if (includeSecrets)
        'dataBase64': base64Encode(_files.data(a.id) ?? Uint8List(0)),
    };

    final hosts = _hosts.list();
    return {
      'format': 'appman-export',
      'version': 1,
      'exportedAt': (now ?? DateTime.now()).toIso8601String(),
      'includesSecrets': includeSecrets,
      'hostingTargets': [
        for (final h in hosts)
          {
            'key': h.id,
            'name': h.name,
            'provider': h.provider,
            'accountId': h.accountId,
            'region': h.region,
            'consoleUrl': h.consoleUrl,
            'notes': h.notes,
            'credentials': [
              for (final c in _creds.listFor(Owner.hosting(h.id))) cred(c),
            ],
            'consoleLinks': [
              for (final l in _links.listFor(Owner.hosting(h.id))) link(l),
            ],
            'attachments': [
              for (final f in _files.listFor(Owner.hosting(h.id))) file(f),
            ],
          },
      ],
      'applications': [
        for (final a in _apps.list())
          {
            'name': a.name,
            'description': a.description,
            'status': a.status,
            'tags': a.tags,
            'notes': a.notes,
            'criticality': a.criticality,
            'owner': a.owner,
            'repositories': [
              for (final r in _repos.listForApplication(a.id))
                {
                  'provider': r.provider.id,
                  'url': r.url,
                  'defaultBranch': r.defaultBranch,
                  'visibility': r.visibility,
                  'localPath': r.localPath,
                  'notes': r.notes,
                  'credentials': [
                    for (final c in _creds.listFor(Owner.repository(r.id)))
                      cred(c),
                  ],
                },
            ],
            'environments': [
              for (final e in _envs.listForApplication(a.id))
                {
                  'name': e.name,
                  'hostingTarget': e.hostingTargetId,
                  'urls': e.urls,
                  'region': e.region,
                  'deployMethod': e.deployMethod,
                  'deployInstructions': e.deployInstructions,
                  'version': e.version,
                  'lastDeployed': e.lastDeployed?.toIso8601String(),
                  'notes': e.notes,
                  'credentials': [
                    for (final c in _creds.listFor(Owner.environment(e.id)))
                      cred(c),
                  ],
                  'consoleLinks': [
                    for (final l in _links.listFor(Owner.environment(e.id)))
                      link(l),
                  ],
                  'attachments': [
                    for (final f in _files.listFor(Owner.environment(e.id)))
                      file(f),
                  ],
                },
            ],
            'credentials': [
              for (final c in _creds.listFor(Owner.application(a.id))) cred(c),
            ],
            'consoleLinks': [
              for (final l in _links.listFor(Owner.application(a.id))) link(l),
            ],
            'attachments': [
              for (final f in _files.listFor(Owner.application(a.id))) file(f),
            ],
          },
      ],
    };
  }

  String toJson({required bool includeSecrets, DateTime? now}) =>
      const JsonEncoder.withIndent('  ')
          .convert(toJsonMap(includeSecrets: includeSecrets, now: now));

  /// A `.env` file for one environment from its runtime secrets (sensitive: callers must re-verify the password).
  String environmentAsDotEnv(String environmentId) {
    final secrets = _creds.listFor(
      Owner.environment(environmentId),
      purpose: CredentialPurpose.runtime,
    );
    return formatDotEnv([
      for (final s in secrets)
        EnvEntry(s.keyName.isEmpty ? s.label : s.keyName, s.secret),
    ]);
  }

  // ---------------------------------------------------------------- JSON import

  /// Adds everything from an AppMan export as new records. Hosting targets are matched by name and
  /// provider (reused when they exist). Never overwrites or deletes existing data.
  ImportResult importJson(String text, {int maxAttachmentBytes = 1024 * 1024}) {
    final res = ImportResult();
    final Object? root;
    try {
      root = jsonDecode(text);
    } on FormatException catch (e) {
      throw FormatException('Not valid JSON: ${e.message}');
    }
    if (root is! Map || root['format'] != 'appman-export') {
      throw const FormatException('This file is not an AppMan export.');
    }
    if (root['version'] != 1) {
      throw FormatException('Unsupported export version ${root['version']}.');
    }
    final withSecrets = root['includesSecrets'] == true;
    if (!withSecrets) {
      res.warnings.add(
        'The file has no secret values; credentials were created empty.',
      );
    }

    String s(Object? v) => v is String ? v : '';
    DateTime? dt(Object? v) => v is String ? DateTime.tryParse(v) : null;
    List<Map<String, Object?>> list(Object? v) => [
      for (final e in (v is List ? v : const []))
        if (e is Map) e.cast<String, Object?>(),
    ];

    void addCred(Owner owner, Map<String, Object?> c) {
      final purpose = c['purpose'] == 'runtime'
          ? CredentialPurpose.runtime
          : CredentialPurpose.access;
      try {
        _creds.create(
          owner: owner,
          purpose: purpose,
          type: credentialTypes.containsKey(c['type'])
              ? c['type'] as String
              : 'secret',
          label: s(c['label']),
          keyName: s(c['keyName']),
          username: s(c['username']),
          secret: s(c['secret']),
          url: s(c['url']),
          expiresAt: dt(c['expiresAt']),
          rotationNotes: s(c['rotationNotes']),
          customFields: {
            for (final e in ((c['customFields'] as Map?) ?? const {}).entries)
              '${e.key}': '${e.value}',
          },
          notes: s(c['notes']),
        );
        res.credentials++;
      } on ArgumentError catch (e) {
        res.warnings.add('Skipped a credential: ${e.message}');
      }
    }

    void addLinks(Owner owner, Object? v) {
      for (final l in list(v)) {
        if (s(l['label']).isEmpty && s(l['url']).isEmpty) continue;
        _links.create(
          owner: owner,
          label: s(l['label']),
          url: s(l['url']),
          type: s(l['type']).isEmpty ? 'other' : s(l['type']),
        );
        res.links++;
      }
    }

    void addFiles(Owner owner, Object? v) {
      for (final f in list(v)) {
        final data = f['dataBase64'];
        if (data is! String) {
          res.warnings.add(
            'Attachment "${s(f['name'])}" has no content in this export; skipped.',
          );
          continue;
        }
        try {
          _files.add(
            owner: owner,
            name: s(f['name']),
            bytes: base64Decode(data),
            maxBytes: maxAttachmentBytes,
            mimeType: s(f['mimeType']),
          );
          res.attachments++;
        } on AttachmentTooLargeException catch (e) {
          res.warnings.add('Attachment "${s(f['name'])}": $e');
        } on FormatException {
          res.warnings.add('Attachment "${s(f['name'])}" is corrupt; skipped.');
        }
      }
    }

    _db.raw.execute('BEGIN;');
    try {
      final targetIds = <String, String>{}; // export key -> local id
      final existing = _hosts.list();
      for (final h in list(root['hostingTargets'])) {
        final name = s(h['name']);
        final provider = s(h['provider']).isEmpty ? 'other' : s(h['provider']);
        final match = existing
            .where((e) => e.name == name && e.provider == provider)
            .firstOrNull;
        final id =
            match?.id ??
            () {
              res.hostingTargets++;
              final t = _hosts.create(
                name: name,
                provider: provider,
                accountId: s(h['accountId']),
                region: s(h['region']),
                consoleUrl: s(h['consoleUrl']),
                notes: s(h['notes']),
              );
              existing.add(t);
              return t.id;
            }();
        targetIds[s(h['key'])] = id;
        if (match == null) {
          for (final c in list(h['credentials'])) {
            addCred(Owner.hosting(id), c);
          }
          addLinks(Owner.hosting(id), h['consoleLinks']);
          addFiles(Owner.hosting(id), h['attachments']);
        }
      }

      for (final a in list(root['applications'])) {
        if (s(a['name']).trim().isEmpty) {
          res.warnings.add('Skipped an application without a name.');
          continue;
        }
        final app = _apps.create(
          name: s(a['name']),
          description: s(a['description']),
          status: s(a['status']) == 'idea' ? 'idea' : 'active',
          tags: [for (final t in (a['tags'] as List? ?? const [])) '$t'],
          notes: s(a['notes']),
          criticality: s(a['criticality']),
          owner: s(a['owner']),
        );
        res.applications++;
        for (final r in list(a['repositories'])) {
          final repo = _repos.create(
            applicationId: app.id,
            url: s(r['url']),
            defaultBranch: s(r['defaultBranch']).isEmpty
                ? 'main'
                : s(r['defaultBranch']),
            visibility: s(r['visibility']),
            localPath: s(r['localPath']),
            notes: s(r['notes']),
          );
          res.repositories++;
          for (final c in list(r['credentials'])) {
            addCred(Owner.repository(repo.id), c);
          }
        }
        for (final e in list(a['environments'])) {
          final env = _envs.create(
            applicationId: app.id,
            name: s(e['name']).isEmpty ? 'environment' : s(e['name']),
            hostingTargetId: targetIds[s(e['hostingTarget'])],
            urls: [for (final u in (e['urls'] as List? ?? const [])) '$u'],
            region: s(e['region']),
            deployMethod: s(e['deployMethod']),
            deployInstructions: s(e['deployInstructions']),
            version: s(e['version']),
            lastDeployed: dt(e['lastDeployed']),
            notes: s(e['notes']),
          );
          res.environments++;
          for (final c in list(e['credentials'])) {
            addCred(Owner.environment(env.id), c);
          }
          addLinks(Owner.environment(env.id), e['consoleLinks']);
          addFiles(Owner.environment(env.id), e['attachments']);
        }
        for (final c in list(a['credentials'])) {
          addCred(Owner.application(app.id), c);
        }
        addLinks(Owner.application(app.id), a['consoleLinks']);
        addFiles(Owner.application(app.id), a['attachments']);
      }
      _db.raw.execute('COMMIT;');
    } on TypeError catch (e) {
      // A field had the wrong JSON type: reject the whole file, import nothing.
      _db.raw.execute('ROLLBACK;');
      throw FormatException(
        'The export file is malformed ($e). Nothing was imported.',
      );
    } catch (_) {
      _db.raw.execute('ROLLBACK;');
      rethrow;
    }
    return res;
  }

  /// Imports applications from CSV with the header `name,description,status,tags,notes,owner,criticality`
  /// (extra/missing columns are fine; only `name` is required). Tags are separated by `;` or `,` inside the cell.
  ImportResult importApplicationsCsv(String text) {
    final res = ImportResult();
    final rows = parseCsv(text);
    if (rows.isEmpty) throw const FormatException('The CSV file is empty.');
    final header = [for (final h in rows.first) h.trim().toLowerCase()];
    final nameCol = header.indexOf('name');
    if (nameCol < 0) {
      throw const FormatException('The CSV needs a "name" column.');
    }
    String cell(List<String> row, String col) {
      final i = header.indexOf(col);
      return i >= 0 && i < row.length ? row[i].trim() : '';
    }

    _db.raw.execute('BEGIN;');
    try {
      for (var i = 1; i < rows.length; i++) {
        final row = rows[i];
        if (row.every((c) => c.trim().isEmpty)) continue;
        final name = nameCol < row.length ? row[nameCol].trim() : '';
        if (name.isEmpty) {
          res.warnings.add('Row ${i + 1}: no name; skipped.');
          continue;
        }
        _apps.create(
          name: name,
          description: cell(row, 'description'),
          status: cell(row, 'status') == 'idea' ? 'idea' : 'active',
          tags: cell(row, 'tags')
              .split(RegExp(r'[;,]'))
              .map((t) => t.trim())
              .where((t) => t.isNotEmpty)
              .toList(),
          notes: cell(row, 'notes'),
          owner: cell(row, 'owner'),
          criticality: cell(row, 'criticality'),
        );
        res.applications++;
      }
      _db.raw.execute('COMMIT;');
    } catch (_) {
      _db.raw.execute('ROLLBACK;');
      rethrow;
    }
    return res;
  }
}

// ------------------------------------------------------------------ CSV helpers (RFC 4180)

String writeCsv(List<List<String>> rows) {
  String q(String v) =>
      RegExp(r'[",\r\n]').hasMatch(v) ? '"${v.replaceAll('"', '""')}"' : v;
  return '${rows.map((r) => r.map(q).join(',')).join('\r\n')}\r\n';
}

List<List<String>> parseCsv(String text) {
  final rows = <List<String>>[];
  var row = <String>[];
  final cell = StringBuffer();
  var inQuotes = false, any = false;
  final src = text.startsWith('﻿') ? text.substring(1) : text;
  for (var i = 0; i < src.length; i++) {
    final ch = src[i];
    if (inQuotes) {
      if (ch == '"') {
        if (i + 1 < src.length && src[i + 1] == '"') {
          cell.write('"');
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        cell.write(ch);
      }
    } else if (ch == '"') {
      inQuotes = true;
      any = true;
    } else if (ch == ',') {
      row.add(cell.toString());
      cell.clear();
      any = true;
    } else if (ch == '\n' || ch == '\r') {
      if (ch == '\r' && i + 1 < src.length && src[i + 1] == '\n') i++;
      if (any || cell.isNotEmpty) {
        row.add(cell.toString());
        rows.add(row);
      }
      row = <String>[];
      cell.clear();
      any = false;
    } else {
      cell.write(ch);
      any = true;
    }
  }
  if (any || cell.isNotEmpty) {
    row.add(cell.toString());
    rows.add(row);
  }
  return rows;
}
