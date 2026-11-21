import 'dart:io';

import 'package:appman/core/crypto/kdf.dart';
import 'package:appman/core/db/app_database.dart';
import 'package:appman/core/db/application_repository.dart';
import 'package:appman/core/db/attachment_store.dart';
import 'package:appman/core/db/console_link_store.dart';
import 'package:appman/core/db/credential_store.dart';
import 'package:appman/core/db/environment_store.dart';
import 'package:appman/core/db/hosting_target_store.dart';
import 'package:appman/core/db/repository_store.dart';
import 'package:appman/core/services/report_service.dart';
import 'package:appman/core/services/search_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dart:typed_data';

void main() {
  late Directory dir;
  late AppDatabase db;
  late ApplicationRepository apps;
  late EnvironmentStore envs;
  late CredentialStore creds;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('appman_svc_');
    db = AppDatabase.open('${dir.path}/v.db', randomBytes(32));
    apps = ApplicationRepository(db);
    envs = EnvironmentStore(db);
    creds = CredentialStore(db);
  });
  tearDown(() {
    db.close();
    dir.deleteSync(recursive: true);
  });

  Credential access(
    String appId,
    String label,
    String secret, {
    DateTime? exp,
    String type = 'password',
  }) => creds.create(
    owner: Owner.application(appId),
    purpose: CredentialPurpose.access,
    type: type,
    label: label,
    secret: secret,
    expiresAt: exp,
  );

  group('search', () {
    test('finds across entities, never by secret value, skips archived', () {
      final shop = apps.create(
        name: 'Shop',
        description: 'online store',
        tags: ['php'],
      );
      final env = envs.create(
        applicationId: shop.id,
        name: 'production',
        urls: ['https://shop.example'],
      );
      RepositoryStore(db)
          .create(applicationId: shop.id, url: 'zk/shop-backend');
      final host = HostingTargetStore(db)
          .create(name: 'DO main', provider: 'digitalocean');
      ConsoleLinkStore(db).create(
        owner: Owner.hosting(host.id),
        label: 'Droplets',
        url: 'https://cloud.digitalocean.com',
      );
      creds.create(
        owner: Owner.environment(env.id),
        purpose: CredentialPurpose.runtime,
        type: 'envVar',
        label: '',
        keyName: 'STRIPE_KEY',
        secret: 'sk_live_UNIQUEVALUE',
      );
      AttachmentStore(db).add(
        owner: Owner.environment(env.id),
        name: 'prod.env',
        bytes: Uint8List(10),
        maxBytes: 100,
      );
      final s = SearchService(db);

      expect(
        s.search('shop').map((h) => h.kind).toSet(),
        containsAll([
          HitKind.application,
          HitKind.repository,
          HitKind.environment,
        ]),
      );
      expect(s.search('stripe').single.title, 'STRIPE_KEY');
      expect(
        s.search('stripe').single.applicationId,
        shop.id,
      ); // resolved through the environment
      expect(s.search('droplets').single.hostingTargetId, host.id);
      expect(s.search('prod.env').single.kind, HitKind.attachment);
      expect(
        s.search('UNIQUEVALUE'),
        isEmpty,
        reason: 'secret values are not searchable',
      );
      expect(s.search('  '), isEmpty);
      expect(s.search('100%'), isEmpty); // wildcard characters are escaped

      apps.setArchived(shop.id, true);
      expect(s.search('shop'), isEmpty);
      expect(s.search('stripe'), isEmpty);
      expect(s.search('droplets'), isNotEmpty); // shared hosting stays
    });
  });

  group('dashboard', () {
    test('expiring, recent, completeness hints and counts', () {
      final bare = apps.create(name: 'Bare');
      final ok = apps.create(name: 'Complete');
      apps.create(name: 'Just an idea', status: 'idea');
      RepositoryStore(db).create(applicationId: ok.id, url: 'zk/c');
      final host = HostingTargetStore(db).create(name: 'T');
      final env = envs.create(
        applicationId: ok.id,
        name: 'prod',
        hostingTargetId: host.id,
      );
      final noHostEnv = envs.create(applicationId: ok.id, name: 'staging');
      creds.create(
        owner: Owner.environment(env.id),
        purpose: CredentialPurpose.runtime,
        type: 'envVar',
        label: 'X',
        keyName: 'X',
        secret: 'v',
        expiresAt: DateTime.now().add(const Duration(days: 3)),
      );
      final c = access(
        ok.id,
        'Registrar',
        'pw123456789!',
        exp: DateTime.now().add(const Duration(days: 90)),
      );
      creds.markAccessed(c.id);
      apps.setArchived(apps.create(name: 'Old').id, true);

      final d = ReportService(db).dashboard();
      expect(d.expiring.single.name, 'X');
      expect(d.expiring.single.where, 'Complete › prod');
      expect(d.recent.single.name, 'Registrar');
      expect(d.activeApplications, 3);
      expect(d.archivedApplications, 1);
      expect(d.hostingTargets, 1);

      final bareHints = d.hints
          .where((h) => h.applicationId == bare.id)
          .map((h) => h.message)
          .toList();
      expect(
        bareHints,
        containsAll([
          'No repository recorded',
          'No environment recorded',
          'No credentials or secrets stored',
        ]),
      );
      final okHints = d.hints
          .where((h) => h.applicationId == ok.id)
          .map((h) => h.message)
          .toList();
      expect(okHints, ['No hosting target for: ${noHostEnv.name}']);
      expect(
        d.hints.any((h) => h.applicationName == 'Just an idea'),
        isFalse,
        reason: 'ideas are not nagged',
      );
    });
  });

  group('hygiene report', () {
    test('weak, reused, expired and old credentials; reuse never exposes the value', () {
      final a = apps.create(name: 'A');
      access(a.id, 'weak one', 'abc123');
      access(a.id, 'strong', r'Xk9$mQ2!vLp7#rTz');
      access(a.id, 'dup 1', 'SharedSecret-Value-42!');
      access(a.id, 'dup 2', 'SharedSecret-Value-42!');
      access(
        a.id,
        'expired',
        r'Zq8!wErTy#1234567',
        exp: DateTime.now().subtract(const Duration(days: 1)),
      );
      access(
        a.id,
        'ssh',
        'x',
        type: 'sshKey',
      ); // short, but SSH keys are not judged by strength

      final r = ReportService(db).hygiene();
      expect(r.weak.map((c) => c.name), contains('weak one'));
      expect(r.weak.map((c) => c.name), isNot(contains('strong')));
      expect(r.weak.map((c) => c.name), isNot(contains('ssh')));
      expect(r.reused.single.map((c) => c.name).toSet(), {'dup 1', 'dup 2'});
      expect(r.expired.single.name, 'expired');
      expect(r.old, isEmpty);
      expect(r.isClean, isFalse);

      // Everything is "old" a few years from now.
      final future = ReportService(db)
          .hygiene(now: DateTime.now().add(const Duration(days: 800)));
      expect(future.old.length, 6);
    });

    test('empty vault is clean', () {
      expect(ReportService(db).hygiene().isClean, isTrue);
    });
  });
}
