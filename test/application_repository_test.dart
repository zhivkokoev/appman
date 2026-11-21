import 'dart:io';

import 'package:appman/core/crypto/kdf.dart';
import 'package:appman/core/db/app_database.dart';
import 'package:appman/core/db/application_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  late AppDatabase db;
  late ApplicationRepository repo;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('appman_repo_');
    db = AppDatabase.open('${dir.path}/v.db', randomBytes(32));
    repo = ApplicationRepository(db);
  });
  tearDown(() {
    db.close();
    dir.deleteSync(recursive: true);
  });

  test('create, get, update', () {
    final a = repo.create(
      name: ' Shop ',
      tags: ['web', 'php'],
      notes: 'runbook',
    );
    expect(a.name, 'Shop');
    expect(repo.get(a.id)!.tags, ['web', 'php']);
    repo.update(a.copyWith(name: 'Shop v2', description: 'd'));
    expect(repo.get(a.id)!.name, 'Shop v2');
    expect(repo.get(a.id)!.description, 'd');
  });

  test(
    'search matches name, tags and notes case-insensitively; escapes wildcards',
    () {
      repo.create(name: 'Alpha', tags: ['digitalocean']);
      repo.create(name: 'Beta', notes: 'uses Superhosting');
      repo.create(name: '100% done');
      expect(repo.list(query: 'alp').map((a) => a.name), ['Alpha']);
      expect(repo.list(query: 'DIGITAL').map((a) => a.name), ['Alpha']);
      expect(repo.list(query: 'superhosting').map((a) => a.name), ['Beta']);
      expect(repo.list(query: '%').map((a) => a.name), ['100% done']);
      expect(repo.list().length, 3);
    },
  );

  test('archive hides, restore returns, cascades to children', () {
    final a = repo.create(name: 'App');
    final now = DateTime.now().millisecondsSinceEpoch;
    db.raw.execute(
      "INSERT INTO repositories(id,application_id,url,created_at,updated_at) VALUES('r1','${a.id}','https://github.com/x/y',$now,$now)",
    );
    db.raw.execute(
      "INSERT INTO environments(id,application_id,name,created_at,updated_at) VALUES('e1','${a.id}','prod',$now,$now)",
    );
    db.raw.execute(
      "INSERT INTO credentials(id,label,purpose,environment_id,created_at,updated_at) VALUES('c1','DB_PASSWORD','runtime','e1',$now,$now)",
    );

    repo.setArchived(a.id, true);
    expect(repo.list(), isEmpty);
    expect(repo.list(archived: true).single.id, a.id);
    expect(
      db.raw.select('SELECT archived FROM credentials WHERE id=?', [
        'c1',
      ]).first['archived'],
      1,
    );
    expect(
      db.raw.select('SELECT archived FROM repositories').first['archived'],
      1,
    );

    repo.setArchived(a.id, false);
    expect(repo.list().single.id, a.id);
    expect(
      db.raw.select('SELECT archived FROM credentials WHERE id=?', [
        'c1',
      ]).first['archived'],
      0,
    );
  });

  test('purge only works on archived apps and removes everything', () {
    final a = repo.create(name: 'App');
    final now = DateTime.now().millisecondsSinceEpoch;
    db.raw.execute(
      "INSERT INTO environments(id,application_id,name,created_at,updated_at) VALUES('e1','${a.id}','prod',$now,$now)",
    );
    db.raw.execute(
      "INSERT INTO credentials(id,label,environment_id,created_at,updated_at) VALUES('c1','x','e1',$now,$now)",
    );
    db.raw.execute(
      "INSERT INTO credential_history(id,credential_id,secret,changed_at) VALUES('h1','c1','old',$now)",
    );

    expect(() => repo.purge(a.id), throwsStateError);
    repo.setArchived(a.id, true);
    repo.purge(a.id);
    expect(repo.get(a.id), isNull);
    for (final t in ['environments', 'credentials', 'credential_history']) {
      expect(
        db.raw.select('SELECT count(*) c FROM $t').first['c'],
        0,
        reason: t,
      );
    }
  });
}
