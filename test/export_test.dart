import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:appman/core/crypto/kdf.dart';
import 'package:appman/core/db/app_database.dart';
import 'package:appman/core/db/application_repository.dart';
import 'package:appman/core/db/attachment_store.dart';
import 'package:appman/core/db/console_link_store.dart';
import 'package:appman/core/db/credential_store.dart';
import 'package:appman/core/db/environment_store.dart';
import 'package:appman/core/db/hosting_target_store.dart';
import 'package:appman/core/db/repository_store.dart';
import 'package:appman/core/secrets/dotenv.dart';
import 'package:appman/core/services/export_service.dart';
import 'package:flutter_test/flutter_test.dart';

const secretValue = 'SUPER-SECRET-VALUE-9876';

AppDatabase newDb(Directory dir, String name) =>
    AppDatabase.open('${dir.path}/$name.db', randomBytes(32));

/// Builds a realistic vault: shared hosting target, app with repo, two environments, secrets, links, files.
String seed(AppDatabase db) {
  final apps = ApplicationRepository(db);
  final host = HostingTargetStore(db).create(
    name: 'DO main',
    provider: 'digitalocean',
    consoleUrl: 'https://cloud.digitalocean.com',
    region: 'fra1',
  );
  CredentialStore(db).create(
    owner: Owner.hosting(host.id),
    purpose: CredentialPurpose.access,
    type: 'password',
    label: 'DO login',
    username: 'zk',
    secret: secretValue,
  );
  final shop = apps.create(
    name: 'Shop',
    description: 'online store',
    tags: ['php', 'web'],
    notes: 'runbook text',
    owner: 'me',
  );
  RepositoryStore(db)
      .create(applicationId: shop.id, url: 'https://github.com/zk/shop');
  final prod = EnvironmentStore(db).create(
    applicationId: shop.id,
    name: 'production',
    hostingTargetId: host.id,
    urls: ['https://shop.example'],
    deployMethod: 'GitHub Actions',
    deployInstructions: 'push to main',
    lastDeployed: DateTime(2026, 11, 1),
  );
  EnvironmentStore(db).create(applicationId: shop.id, name: 'staging');
  CredentialStore(db).create(
    owner: Owner.environment(prod.id),
    purpose: CredentialPurpose.runtime,
    type: 'envVar',
    label: '',
    keyName: 'DB_PASSWORD',
    secret: secretValue,
  );
  CredentialStore(db).create(
    owner: Owner.application(shop.id),
    purpose: CredentialPurpose.access,
    type: 'apiKey',
    label: 'Registrar',
    secret: 'reg-key-1',
    expiresAt: DateTime(2027, 1, 1),
    customFields: {'account': '42'},
  );
  ConsoleLinkStore(db).create(
    owner: Owner.application(shop.id),
    label: 'Analytics',
    url: 'https://analytics.example',
    type: 'analytics',
  );
  AttachmentStore(db).add(
    owner: Owner.environment(prod.id),
    name: '.env',
    bytes: Uint8List.fromList(utf8.encode('A=1\nB=2\n')),
    maxBytes: 4096,
  );
  return shop.id;
}

void main() {
  late Directory dir;
  late AppDatabase db;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('appman_export_');
    db = newDb(dir, 'src');
  });
  tearDown(() {
    db.close();
    dir.deleteSync(recursive: true);
  });

  group('reports contain no secrets', () {
    test('markdown', () {
      seed(db);
      final md = ExportService(db).reportMarkdown(now: DateTime(2026, 11, 21));
      expect(md, contains('## Shop'));
      expect(md, contains('https://github.com/zk/shop'));
      expect(md, contains('DB_PASSWORD'));
      expect(md, contains('Runs: Shop (production)'));
      expect(md, isNot(contains(secretValue)));
      expect(md, isNot(contains('reg-key-1')));
    });

    test('csv', () {
      seed(db);
      final csv = ExportService(db).reportCsv();
      expect(csv, contains('runtime-secret,DB_PASSWORD'));
      expect(csv, isNot(contains(secretValue)));
      final rows = parseCsv(csv);
      expect(rows.first, [
        'application',
        'environment',
        'kind',
        'name',
        'url',
        'details',
      ]);
      expect(rows.every((r) => r.length == 6), isTrue);
    });

    test('json without secrets omits secrets, custom field values and attachment bytes', () {
      seed(db);
      final json = ExportService(db).toJson(includeSecrets: false);
      expect(json, isNot(contains(secretValue)));
      expect(json, isNot(contains('reg-key-1')));
      expect(json, isNot(contains('dataBase64')));
      expect(jsonDecode(json)['includesSecrets'], false);
    });

    test('json with secrets includes them', () {
      seed(db);
      final json = ExportService(db).toJson(includeSecrets: true);
      expect(json, contains(secretValue));
      expect(json, contains('dataBase64'));
    });
  });

  group('.env export', () {
    test('environment secrets round-trip through the dotenv format', () {
      final id = seed(db);
      final prod = EnvironmentStore(db)
          .listForApplication(id)
          .firstWhere((e) => e.name == 'production');
      final env = ExportService(db).environmentAsDotEnv(prod.id);
      expect(env, 'DB_PASSWORD=$secretValue\n');
      expect(parseDotEnv(env).entries.single.value, secretValue);
    });
  });

  group('import', () {
    test('full export -> import into a fresh vault reproduces the data', () {
      seed(db);
      final json = ExportService(db).toJson(includeSecrets: true);

      final db2 = newDb(dir, 'dst');
      addTearDown(db2.close);
      final res = ExportService(db2).importJson(json);
      expect(res.applications, 1);
      expect(res.hostingTargets, 1);
      expect(res.repositories, 1);
      expect(res.environments, 2);
      expect(res.credentials, 3);
      expect(res.links, 1);
      expect(res.attachments, 1);
      expect(res.warnings, isEmpty);

      final app = ApplicationRepository(db2).list().single;
      expect(app.name, 'Shop');
      expect(app.tags, ['php', 'web']);
      final prod = EnvironmentStore(db2)
          .listForApplication(app.id)
          .firstWhere((e) => e.name == 'production');
      expect(prod.lastDeployed, DateTime(2026, 11, 1));
      expect(prod.hostingTargetId, isNotNull);
      expect(
        HostingTargetStore(db2).get(prod.hostingTargetId!)!.name,
        'DO main',
      );
      final secret = CredentialStore(db2)
          .listFor(
            Owner.environment(prod.id),
            purpose: CredentialPurpose.runtime,
          )
          .single;
      expect(secret.keyName, 'DB_PASSWORD');
      expect(secret.secret, secretValue);
      final reg = CredentialStore(db2)
          .listFor(Owner.application(app.id))
          .single;
      expect(reg.customFields, {'account': '42'});
      expect(reg.expiresAt, DateTime(2027, 1, 1));
      final file = AttachmentStore(db2)
          .listFor(Owner.environment(prod.id))
          .single;
      expect(utf8.decode(AttachmentStore(db2).data(file.id)!), 'A=1\nB=2\n');
      // Export of the import equals the original (modulo timestamps/ids).
      Map<String, Object?> norm(AppDatabase d) {
        final m = ExportService(d)
            .toJsonMap(includeSecrets: true, now: DateTime(2026));
        final hosts = (m['hostingTargets'] as List).cast<Map>();
        final keyToName = {for (final h in hosts) h['key']: h['name']};
        for (final h in hosts) {
          h['key'] = h['name'];
        }
        for (final a in (m['applications'] as List).cast<Map>()) {
          for (final e in (a['environments'] as List).cast<Map>()) {
            e['hostingTarget'] = keyToName[e['hostingTarget']];
          }
        }
        return m;
      }

      expect(jsonEncode(norm(db2)), jsonEncode(norm(db)));
    });

    test(
      'importing twice reuses hosting targets and adds applications again',
      () {
        seed(db);
        final json = ExportService(db).toJson(includeSecrets: true);
        final db2 = newDb(dir, 'dst');
        addTearDown(db2.close);
        ExportService(db2).importJson(json);
        final second = ExportService(db2).importJson(json);
        expect(second.hostingTargets, 0);
        expect(HostingTargetStore(db2).list().length, 1);
        expect(ApplicationRepository(db2).list().length, 2);
      },
    );

    test('secret-less export imports with a warning and empty secrets', () {
      seed(db);
      final json = ExportService(db).toJson(includeSecrets: false);
      final db2 = newDb(dir, 'dst');
      addTearDown(db2.close);
      final res = ExportService(db2).importJson(json);
      expect(res.warnings.any((w) => w.contains('no secret values')), isTrue);
      expect(res.attachments, 0);
      expect(
        CredentialStore(db2).listAll().every((c) => c.secret.isEmpty),
        isTrue,
      );
    });

    test('rejects other files and leaves the vault untouched', () {
      final svc = ExportService(db);
      expect(() => svc.importJson('not json'), throwsFormatException);
      expect(
        () => svc.importJson('{"format":"something-else"}'),
        throwsFormatException,
      );
      expect(
        () => svc.importJson('{"format":"appman-export","version":99}'),
        throwsFormatException,
      );
      expect(ApplicationRepository(db).list(), isEmpty);
    });

    test(
      'import is atomic: a malformed record rolls back earlier ones too',
      () {
        final bad = jsonEncode({
          'format': 'appman-export',
          'version': 1,
          'includesSecrets': true,
          'hostingTargets': [],
          'applications': [
            {'name': 'Good', 'environments': []},
            {
              'name': 'Boom',
              'environments': [
                {'name': 'x', 'urls': 5}, // wrong type: must be a list
              ],
            },
          ],
        });
        expect(() => ExportService(db).importJson(bad), throwsFormatException);
        expect(
          ApplicationRepository(db).list(),
          isEmpty,
          reason: '"Good" must not survive a failed import',
        );
        expect(HostingTargetStore(db).list(), isEmpty);
      },
    );

    test('wrongly typed non-list fields are ignored rather than crashing', () {
      final odd = jsonEncode({
        'format': 'appman-export',
        'version': 1,
        'includesSecrets': true,
        'applications': [
          {'name': 'Odd', 'repositories': 'nope', 'environments': 7},
        ],
      });
      final res = ExportService(db).importJson(odd);
      expect(res.applications, 1);
      expect(res.repositories, 0);
    });

    test('attachments over the limit are skipped with a warning', () {
      seed(db);
      final json = ExportService(db).toJson(includeSecrets: true);
      final db2 = newDb(dir, 'dst');
      addTearDown(db2.close);
      final res = ExportService(db2).importJson(json, maxAttachmentBytes: 2);
      expect(res.attachments, 0);
      expect(res.warnings.any((w) => w.contains('limit')), isTrue);
    });
  });

  group('csv', () {
    test('parser handles quotes, commas, newlines, CRLF and BOM', () {
      final rows = parseCsv(
        '﻿a,b,c\r\n"x, y","say ""hi""","line1\nline2"\r\n\r\nlast,,\r\n',
      );
      expect(rows, [
        ['a', 'b', 'c'],
        ['x, y', 'say "hi"', 'line1\nline2'],
        ['last', '', ''],
      ]);
    });

    test('writeCsv/parseCsv roundtrip', () {
      final rows = [
        ['plain', 'with,comma', 'with "quote"', 'multi\nline'],
        ['', ' spaced ', '', 'x'],
      ];
      expect(parseCsv(writeCsv(rows)), rows);
    });

    test('import applications from CSV', () {
      final res = ExportService(db).importApplicationsCsv(
        'Name,Description,Tags,Owner,Status\n"Blog, personal",my blog,"web; php",me,active\n,no name,x,y,\nIdea app,,,,idea\n',
      );
      expect(res.applications, 2);
      expect(res.warnings.single, contains('Row 3'));
      final apps = ApplicationRepository(db).list();
      final blog = apps.firstWhere((a) => a.name == 'Blog, personal');
      expect(blog.tags, ['web', 'php']);
      expect(blog.owner, 'me');
      expect(apps.firstWhere((a) => a.name == 'Idea app').status, 'idea');
    });

    test('CSV without a name column is rejected', () {
      expect(
        () => ExportService(db).importApplicationsCsv('title,tags\nx,y\n'),
        throwsFormatException,
      );
      expect(
        () => ExportService(db).importApplicationsCsv(''),
        throwsFormatException,
      );
    });
  });
}
