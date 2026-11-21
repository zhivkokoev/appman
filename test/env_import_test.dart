import 'dart:io';

import 'package:appman/core/crypto/kdf.dart';
import 'package:appman/core/db/app_database.dart';
import 'package:appman/core/db/application_repository.dart';
import 'package:appman/core/db/credential_store.dart';
import 'package:appman/core/db/environment_store.dart';
import 'package:appman/core/secrets/dotenv.dart';
import 'package:appman/core/secrets/env_import.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  late AppDatabase db;
  late CredentialStore store;
  late String envId;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('appman_envimp_');
    db = AppDatabase.open('${dir.path}/v.db', randomBytes(32));
    store = CredentialStore(db);
    final app = ApplicationRepository(db).create(name: 'A');
    envId = EnvironmentStore(db).create(applicationId: app.id, name: 'prod').id;
  });
  tearDown(() {
    db.close();
    dir.deleteSync(recursive: true);
  });

  test('first import creates runtime secrets typed as envVar', () {
    final imp = EnvImporter(store, envId);
    final entries = parseDotEnv('DB_HOST=localhost\nDB_PASSWORD=pw1\n').entries;
    expect(imp.plan(entries).map((p) => p.change), [
      EnvChange.added,
      EnvChange.added,
    ]);
    final s = imp.apply(entries);
    expect((s.added, s.updated, s.unchanged), (2, 0, 0));
    final list = store.listFor(
      Owner.environment(envId),
      purpose: CredentialPurpose.runtime,
    );
    expect(list.map((c) => c.keyName).toSet(), {'DB_HOST', 'DB_PASSWORD'});
    expect(list.every((c) => c.type == 'envVar'), isTrue);
  });

  test('re-import: unchanged stay, changed values update with history, new keys are added', () {
    final imp = EnvImporter(store, envId);
    imp.apply(parseDotEnv('A=1\nB=2\n').entries);
    final before = store
        .listFor(Owner.environment(envId))
        .firstWhere((c) => c.keyName == 'B');
    store.update(before.copyWith(notes: 'keep me', expiresAt: DateTime(2030)));

    final next = parseDotEnv('A=1\nB=22\nC=3\n').entries;
    expect(imp.plan(next).map((p) => '${p.key}:${p.change.name}'), [
      'A:unchanged',
      'B:updated',
      'C:added',
    ]);
    final s = imp.apply(next);
    expect(s.text, '1 added, 1 updated, 1 unchanged');

    final b = store
        .listFor(Owner.environment(envId))
        .firstWhere((c) => c.keyName == 'B');
    expect(b.id, before.id, reason: 'same record is updated, not replaced');
    expect(b.secret, '22');
    expect(b.notes, 'keep me');
    expect(b.expiresAt, DateTime(2030));
    expect(store.history(b.id).single.secret, '2');
    expect(store.listFor(Owner.environment(envId)).length, 3);
  });

  test('archived secrets are not matched, importing the same key creates a fresh one', () {
    final imp = EnvImporter(store, envId);
    imp.apply(parseDotEnv('A=1\n').entries);
    store.setArchived(store.listFor(Owner.environment(envId)).single.id, true);
    final s = imp.apply(parseDotEnv('A=1\n').entries);
    expect(s.added, 1);
  });
}
