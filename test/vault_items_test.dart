import 'dart:io';
import 'dart:typed_data';

import 'package:appman/core/crypto/kdf.dart';
import 'package:appman/core/db/app_database.dart';
import 'package:appman/core/db/application_repository.dart';
import 'package:appman/core/db/attachment_store.dart';
import 'package:appman/core/db/audit_log.dart';
import 'package:appman/core/db/console_link_store.dart';
import 'package:appman/core/db/credential_store.dart';
import 'package:appman/core/db/environment_store.dart';
import 'package:appman/core/db/repository_store.dart';
import 'package:appman/core/db/settings_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  late AppDatabase db;
  late ApplicationRepository apps;
  late EnvironmentStore envs;
  late CredentialStore creds;
  late ConsoleLinkStore links;
  late AttachmentStore files;
  late String appId, envId;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('appman_items_');
    db = AppDatabase.open('${dir.path}/v.db', randomBytes(32));
    apps = ApplicationRepository(db);
    envs = EnvironmentStore(db);
    creds = CredentialStore(db);
    links = ConsoleLinkStore(db);
    files = AttachmentStore(db);
    appId = apps.create(name: 'Shop').id;
    envId = envs.create(applicationId: appId, name: 'production').id;
  });
  tearDown(() {
    db.close();
    dir.deleteSync(recursive: true);
  });

  group('credentials', () {
    test(
      'access credential on an application, with custom fields and expiry',
      () {
        final expiry = DateTime.now().add(const Duration(days: 10));
        final c = creds.create(
          owner: Owner.application(appId),
          purpose: CredentialPurpose.access,
          type: 'password',
          label: 'Registrar',
          username: 'zk',
          secret: 's3cret',
          url: 'https://registrar.example',
          expiresAt: expiry,
          customFields: {'pin': '1234'},
        );
        final got = creds.get(c.id)!;
        expect(got.customFields, {'pin': '1234'});
        expect(got.secret, 's3cret');
        expect(got.purpose, CredentialPurpose.access);
        expect(creds.listFor(Owner.application(appId)).single.id, c.id);
        expect(creds.listFor(Owner.environment(envId)), isEmpty);
      },
    );

    test('runtime secrets must belong to an environment', () {
      expect(
        () => creds.create(
          owner: Owner.application(appId),
          purpose: CredentialPurpose.runtime,
          type: 'envVar',
          label: 'x',
          keyName: 'X',
        ),
        throwsArgumentError,
      );
      final c = creds.create(
        owner: Owner.environment(envId),
        purpose: CredentialPurpose.runtime,
        type: 'envVar',
        label: '',
        keyName: 'DB_PASSWORD',
        secret: 'p1',
      );
      expect(c.displayName, 'DB_PASSWORD');
      expect(c.label, 'DB_PASSWORD'); // label defaults to the key name
      expect(
        creds
            .listFor(
              Owner.environment(envId),
              purpose: CredentialPurpose.runtime,
            )
            .length,
        1,
      );
      expect(
        creds.listFor(
          Owner.environment(envId),
          purpose: CredentialPurpose.access,
        ),
        isEmpty,
      );
    });

    test('changing the secret records history, other edits do not', () {
      final c = creds.create(
        owner: Owner.application(appId),
        purpose: CredentialPurpose.access,
        type: 'password',
        label: 'L',
        secret: 'one',
      );
      creds.update(c.copyWith(notes: 'only notes'));
      expect(creds.history(c.id), isEmpty);
      creds.update(creds.get(c.id)!.copyWith(secret: 'two'));
      creds.update(creds.get(c.id)!.copyWith(secret: 'three'));
      expect(creds.history(c.id).map((h) => h.secret), ['two', 'one']);
      expect(creds.get(c.id)!.secret, 'three');
    });

    test('expiring list and recently accessed', () {
      final soon = creds.create(
        owner: Owner.application(appId),
        purpose: CredentialPurpose.access,
        type: 'apiKey',
        label: 'soon',
        secret: 'a',
        expiresAt: DateTime.now().add(const Duration(days: 5)),
      );
      creds.create(
        owner: Owner.application(appId),
        purpose: CredentialPurpose.access,
        type: 'apiKey',
        label: 'far',
        secret: 'b',
        expiresAt: DateTime.now().add(const Duration(days: 200)),
      );
      final past = creds.create(
        owner: Owner.application(appId),
        purpose: CredentialPurpose.access,
        type: 'apiKey',
        label: 'past',
        secret: 'c',
        expiresAt: DateTime.now().subtract(const Duration(days: 2)),
      );
      expect(creds.expiring(days: 30).map((c) => c.label), ['past', 'soon']);
      expect(creds.get(past.id)!.isExpired(), isTrue);
      expect(creds.recentlyAccessed(), isEmpty);
      creds.markAccessed(soon.id, how: 'copy');
      expect(creds.recentlyAccessed().single.id, soon.id);
      expect(creds.get(soon.id)!.lastAccessedAt, isNotNull);
    });

    test('archive hides, purge needs archive and removes history', () {
      final c = creds.create(
        owner: Owner.application(appId),
        purpose: CredentialPurpose.access,
        type: 'password',
        label: 'L',
        secret: 'one',
      );
      creds.update(c.copyWith(secret: 'two'));
      expect(() => creds.purge(c.id), throwsStateError);
      creds.setArchived(c.id, true);
      expect(creds.listFor(Owner.application(appId)), isEmpty);
      expect(creds.listFor(Owner.application(appId), archived: true).length, 1);
      creds.purge(c.id);
      expect(creds.get(c.id), isNull);
      expect(
        db.raw.select('SELECT count(*) c FROM credential_history').first['c'],
        0,
      );
    });
  });

  group('audit log never contains secret values', () {
    test('create/update/reveal entries carry no secret text', () {
      final c = creds.create(
        owner: Owner.application(appId),
        purpose: CredentialPurpose.access,
        type: 'password',
        label: 'Bank',
        secret: 'TOP-SECRET-1',
      );
      creds.update(c.copyWith(secret: 'TOP-SECRET-2'));
      creds.markAccessed(c.id);
      final entries = AuditLog(db).forEntity('credential', c.id);
      expect(entries.map((e) => e.action).toSet(), {
        'create',
        'update',
        'reveal',
      });
      for (final e in entries) {
        expect('${e.summary} ${e.action}', isNot(contains('TOP-SECRET')));
      }
      expect(entries.any((e) => e.summary.contains('secret changed')), isTrue);
    });

    test('other entities are logged too', () {
      final log = AuditLog(db);
      expect(log.forEntity('application', appId).single.action, 'create');
      apps.setArchived(appId, true);
      expect(log.forEntity('application', appId).first.action, 'archive');
      RepositoryStore(db).create(applicationId: appId, url: 'zk/x');
      expect(log.recent().any((e) => e.entity == 'repository'), isTrue);
    });
  });

  group('console links', () {
    test('owners and rules', () {
      links.create(
        owner: Owner.application(appId),
        label: 'Analytics',
        url: 'https://a.example',
        type: 'analytics',
      );
      links.create(
        owner: Owner.environment(envId),
        label: 'DB admin',
        url: 'https://db.example',
        type: 'database',
      );
      expect(links.listFor(Owner.application(appId)).single.label, 'Analytics');
      expect(links.listFor(Owner.environment(envId)).single.type, 'database');
      expect(links.listAll().length, 2);
      expect(
        () => links.create(owner: Owner.repository('x'), label: 'l', url: 'u'),
        throwsArgumentError,
      );
    });

    test('archive and purge', () {
      final l = links.create(
        owner: Owner.application(appId),
        label: 'L',
        url: 'https://x',
      );
      expect(() => links.purge(l.id), throwsStateError);
      links.setArchived(l.id, true);
      expect(links.listFor(Owner.application(appId)), isEmpty);
      links.purge(l.id);
      expect(links.get(l.id), isNull);
    });
  });

  group('attachments', () {
    test('store, load, size limit, archive/purge', () {
      final bytes = Uint8List.fromList(List.generate(500, (i) => i % 256));
      final a = files.add(
        owner: Owner.environment(envId),
        name: '.env',
        bytes: bytes,
        maxBytes: 1024,
      );
      expect(a.size, 500);
      expect(a.mimeType, 'text/plain');
      expect(files.data(a.id), bytes);
      expect(
        () => files.add(
          owner: Owner.environment(envId),
          name: 'big.bin',
          bytes: Uint8List(2000),
          maxBytes: 1024,
        ),
        throwsA(isA<AttachmentTooLargeException>()),
      );
      expect(files.listFor(Owner.environment(envId)).length, 1);
      files.setArchived(a.id, true);
      expect(files.listFor(Owner.environment(envId)), isEmpty);
      files.purge(a.id);
      expect(files.get(a.id), isNull);
    });

    test('blob is not readable from the raw file (encrypted at rest)', () {
      final marker = Uint8List.fromList(
        'PRIVATE-KEY-MARKER-1234567890'.codeUnits,
      );
      files.add(
        owner: Owner.application(appId),
        name: 'id_ed25519',
        bytes: marker,
        maxBytes: 4096,
      );
      db.close();
      final raw = File('${dir.path}/v.db').readAsBytesSync();
      expect(String.fromCharCodes(raw).contains('PRIVATE-KEY-MARKER'), isFalse);
      // reopen is not possible without the key, so recreate for tearDown
      db = AppDatabase.open('${dir.path}/other.db', randomBytes(32));
    });
  });

  group('settings', () {
    test('defaults, set/get, typed access and internal state', () {
      final s = SettingsStore(db);
      expect(s.getInt('autolock_minutes'), 5);
      s.set('autolock_minutes', '15');
      expect(s.getInt('autolock_minutes'), 15);
      s.set('autolock_minutes', 'garbage');
      expect(s.getInt('autolock_minutes'), 5); // falls back to default
      expect(s.getBool('backup_on_save'), isTrue);
      s.setBool('backup_on_save', false);
      expect(s.getBool('backup_on_save'), isFalse);
      expect(s.getState('last_backup'), isNull);
      s.setState('last_backup', '123');
      expect(s.getState('last_backup'), '123');
    });
  });
}
