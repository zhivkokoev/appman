import 'dart:io';

import 'package:appman/core/crypto/kdf.dart';
import 'package:appman/core/db/app_database.dart';
import 'package:appman/core/db/application_repository.dart';
import 'package:appman/core/db/environment_store.dart';
import 'package:appman/core/db/hosting_target_store.dart';
import 'package:appman/core/db/repository_store.dart';
import 'package:appman/core/providers/git_providers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  late AppDatabase db;
  late ApplicationRepository apps;
  late RepositoryStore repos;
  late HostingTargetStore hosts;
  late EnvironmentStore envs;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('appman_stores_');
    db = AppDatabase.open('${dir.path}/v.db', randomBytes(32));
    apps = ApplicationRepository(db);
    repos = RepositoryStore(db);
    hosts = HostingTargetStore(db);
    envs = EnvironmentStore(db);
  });
  tearDown(() {
    db.close();
    dir.deleteSync(recursive: true);
  });

  int count(String table) =>
      db.raw.select('SELECT count(*) c FROM $table').first['c'] as int;

  void addCredential(String id, {String? repo, String? env}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    db.raw.execute(
      'INSERT INTO credentials(id,label,repository_id,environment_id,created_at,updated_at) VALUES(?,?,?,?,?,?)',
      [id, id, repo, env, now, now],
    );
  }

  group('repositories', () {
    test('create normalizes GitHub URLs and detects provider', () {
      final a = apps.create(name: 'A');
      final r = repos.create(
        applicationId: a.id,
        url: 'git@github.com:zk/shop.git',
      );
      expect(r.url, 'https://github.com/zk/shop');
      expect(r.provider, GitProvider.github);
      expect(r.ref!.sshClone, 'git@github.com:zk/shop.git');
    });

    test('unparseable URL is kept verbatim with the given provider', () {
      final a = apps.create(name: 'A');
      final r = repos.create(
        applicationId: a.id,
        url: '/srv/git/bare',
        provider: GitProvider.other,
      );
      expect(r.url, '/srv/git/bare');
      expect(r.ref, isNull);
    });

    test('multiple repos per app, update, archive/restore', () {
      final a = apps.create(name: 'A');
      final r1 = repos.create(applicationId: a.id, url: 'zk/front');
      repos.create(applicationId: a.id, url: 'zk/back');
      expect(repos.listForApplication(a.id).length, 2);
      repos.update(
        r1.copyWith(defaultBranch: 'develop', localPath: r'C:\dev\front'),
      );
      expect(repos.get(r1.id)!.defaultBranch, 'develop');
      repos.setArchived(r1.id, true);
      expect(repos.listForApplication(a.id).length, 1);
      expect(repos.listForApplication(a.id, archived: true).single.id, r1.id);
      repos.setArchived(r1.id, false);
      expect(repos.listForApplication(a.id).length, 2);
    });

    test('purge requires archive and removes attached deploy key', () {
      final a = apps.create(name: 'A');
      final r = repos.create(applicationId: a.id, url: 'zk/front');
      addCredential('deploykey', repo: r.id);
      expect(() => repos.purge(r.id), throwsStateError);
      repos.setArchived(r.id, true);
      expect(
        db.raw
            .select("SELECT archived FROM credentials WHERE id='deploykey'")
            .first['archived'],
        1,
      );
      repos.purge(r.id);
      expect(count('repositories'), 0);
      expect(count('credentials'), 0);
    });
  });

  group('hosting targets and environments', () {
    test('shared target used by two apps; reverse view lists both', () {
      final t = hosts.create(
        name: 'DO main',
        provider: 'digitalocean',
        consoleUrl: 'https://cloud.digitalocean.com',
      );
      final a1 = apps.create(name: 'Alpha');
      final a2 = apps.create(name: 'Beta');
      envs.create(
        applicationId: a1.id,
        name: 'production',
        hostingTargetId: t.id,
        urls: ['https://alpha.example'],
      );
      envs.create(applicationId: a2.id, name: 'staging', hostingTargetId: t.id);
      envs.create(applicationId: a2.id, name: 'dev'); // no target
      final hosted = hosts.hostedEnvironments(t.id);
      expect(hosted.map((h) => '${h.applicationName}/${h.environmentName}'), [
        'Alpha/production',
        'Beta/staging',
      ]);
      expect(hosted.first.urls, ['https://alpha.example']);
    });

    test('reverse view ignores archived apps and environments', () {
      final t = hosts.create(name: 'T');
      final a = apps.create(name: 'A');
      final e = envs.create(
        applicationId: a.id,
        name: 'prod',
        hostingTargetId: t.id,
      );
      apps.setArchived(a.id, true);
      expect(hosts.hostedEnvironments(t.id), isEmpty);
      apps.setArchived(a.id, false);
      expect(hosts.hostedEnvironments(t.id).length, 1);
      envs.setArchived(e.id, true);
      expect(hosts.hostedEnvironments(t.id), isEmpty);
    });

    test(
      'archiving a target in use is refused; purge refused while referenced',
      () {
        final t = hosts.create(name: 'T');
        final a = apps.create(name: 'A');
        final e = envs.create(
          applicationId: a.id,
          name: 'prod',
          hostingTargetId: t.id,
        );
        expect(() => hosts.setArchived(t.id, true), throwsStateError);
        envs.setArchived(e.id, true);
        hosts.setArchived(t.id, true); // now unused by active environments
        expect(
          () => hosts.purge(t.id),
          throwsStateError,
        ); // still referenced by the archived environment
        envs.purge(e.id);
        hosts.purge(t.id);
        expect(count('hosting_targets'), 0);
      },
    );

    test('app archive does not cascade to the shared hosting target', () {
      final t = hosts.create(name: 'T');
      final a = apps.create(name: 'A');
      envs.create(applicationId: a.id, name: 'prod', hostingTargetId: t.id);
      apps.setArchived(a.id, true);
      expect(hosts.get(t.id)!.archived, isFalse);
    });

    test(
      'environment fields roundtrip incl. urls, date and clearing the target',
      () {
        final t = hosts.create(name: 'T');
        final a = apps.create(name: 'A');
        final when = DateTime(2026, 11, 20, 10, 30);
        final e = envs.create(
          applicationId: a.id,
          name: 'production',
          hostingTargetId: t.id,
          urls: ['https://a.example', 'https://www.a.example'],
          deployMethod: 'GitHub Actions',
          deployInstructions: 'push to main',
          version: 'v1.2.0',
          lastDeployed: when,
        );
        final got = envs.get(e.id)!;
        expect(got.urls, ['https://a.example', 'https://www.a.example']);
        expect(got.lastDeployed, when);
        expect(got.hostingTargetId, t.id);

        envs.update(
          got.copyWith(
            hostingTargetId: null,
            lastDeployed: null,
            version: 'v1.3.0',
          ),
        );
        final cleared = envs.get(e.id)!;
        expect(cleared.hostingTargetId, isNull);
        expect(cleared.lastDeployed, isNull);
        expect(cleared.version, 'v1.3.0');
        expect(cleared.deployMethod, 'GitHub Actions'); // untouched fields kept
      },
    );

    test(
      'environment archive cascades to runtime secrets; purge removes them',
      () {
        final a = apps.create(name: 'A');
        final e = envs.create(applicationId: a.id, name: 'prod');
        addCredential('DB_PASSWORD', env: e.id);
        envs.setArchived(e.id, true);
        expect(
          db.raw
              .select("SELECT archived FROM credentials WHERE id='DB_PASSWORD'")
              .first['archived'],
          1,
        );
        expect(() => envs.purge('nope'), returnsNormally);
        envs.purge(e.id);
        expect(count('credentials'), 0);
        expect(count('environments'), 0);
      },
    );

    test('purging an application also removes repo-attached credentials', () {
      final a = apps.create(name: 'A');
      final r = repos.create(applicationId: a.id, url: 'zk/x');
      addCredential('k', repo: r.id);
      apps.setArchived(a.id, true);
      apps.purge(a.id);
      expect(count('repositories'), 0);
      expect(count('credentials'), 0);
    });
  });
}
