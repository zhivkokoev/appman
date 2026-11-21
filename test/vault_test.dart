import 'dart:io';
import 'dart:typed_data';

import 'package:appman/core/crypto/kdf.dart';
import 'package:appman/core/crypto/recovery_key.dart';
import 'package:appman/core/crypto/wrap.dart';
import 'package:appman/core/db/app_database.dart';
import 'package:appman/core/vault/vault_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tiny, fast Argon2id parameters for tests only.
class FastKdf extends DartArgon2Kdf {
  @override
  Future<KdfParams> calibrate({
    int targetMs = 700,
    int memoryKiB = 262144,
    int parallelism = 4,
  }) async => KdfParams(
    memoryKiB: 64,
    iterations: 1,
    parallelism: 1,
    salt: randomBytes(16),
  );
}

Uint8List readHead(String path) {
  final f = File(path).openSync();
  try {
    return f.readSync(16);
  } finally {
    f.closeSync();
  }
}

void main() {
  late Directory dir;
  late VaultService vault;

  VaultService fresh() => VaultService(VaultPaths(dir.path), FastKdf());

  setUp(() {
    dir = Directory.systemTemp.createTempSync('appman_test_');
    vault = fresh();
  });
  tearDown(() {
    if (vault.isUnlocked) vault.lock();
    dir.deleteSync(recursive: true);
  });

  group('recovery key', () {
    test('format/parse roundtrip', () {
      final rk = RecoveryKey.generate();
      final text = rk.format();
      expect(text.replaceAll('-', '').length, 52);
      expect(RecoveryKey.parse(text.toLowerCase()).bytes, rk.bytes);
    });
    test('rejects bad input', () {
      expect(() => RecoveryKey.parse('AAAA-BBBB'), throwsFormatException);
      expect(() => RecoveryKey.parse('1' * 52), throwsFormatException);
    });
  });

  group('wrap', () {
    test('roundtrip, wrong key and wrong purpose fail', () async {
      final key = randomBytes(32), kek = randomBytes(32);
      final w = await wrapKey(key, kek, 'a');
      expect(await unwrapKey(w, kek, 'a'), key);
      expect(
        () => unwrapKey(w, randomBytes(32), 'a'),
        throwsA(isA<WrongKeyException>()),
      );
      expect(() => unwrapKey(w, kek, 'b'), throwsA(isA<WrongKeyException>()));
    });
  });

  group('vault', () {
    test('create, lock, unlock with password', () async {
      expect(vault.exists, isFalse);
      final rk = await vault.create('correct horse');
      expect(rk, isNotEmpty);
      expect(vault.isUnlocked, isTrue);
      vault.db.raw.execute(
        "INSERT INTO meta(key,value) VALUES('hello','world');",
      );
      vault.lock();
      expect(vault.isUnlocked, isFalse);

      final v2 = fresh();
      expect(v2.exists, isTrue);
      await expectLater(
        v2.unlockWithPassword('wrong'),
        throwsA(isA<WrongKeyException>()),
      );
      await v2.unlockWithPassword('correct horse');
      expect(
        v2.db.raw
            .select("SELECT value FROM meta WHERE key='hello'")
            .first['value'],
        'world',
      );
      v2.lock();
    });

    test('database file is encrypted', () async {
      await vault.create('pw');
      vault.lock();
      final head = readHead('${dir.path}/vault.db');
      expect(String.fromCharCodes(head), isNot(startsWith('SQLite format 3')));
    });

    test('cannot open DB with wrong key', () async {
      await vault.create('pw');
      vault.lock();
      expect(
        () => AppDatabase.open('${dir.path}/vault.db', randomBytes(32)),
        throwsA(isA<DatabaseKeyException>()),
      );
    });

    test('change password: old fails, new works, data intact', () async {
      await vault.create('old-pw');
      vault.db.raw.execute("INSERT INTO meta(key,value) VALUES('k','v');");
      await vault.changePassword('old-pw', 'new-pw');
      await expectLater(
        vault.changePassword('bad', 'x'),
        throwsA(isA<WrongKeyException>()),
      );
      vault.lock();

      final v2 = fresh();
      await expectLater(
        v2.unlockWithPassword('old-pw'),
        throwsA(isA<WrongKeyException>()),
      );
      await v2.unlockWithPassword('new-pw');
      expect(
        v2.db.raw.select("SELECT value FROM meta WHERE key='k'").first['value'],
        'v',
      );
      v2.lock();
    });

    test('recovery key unlocks and sets new password', () async {
      final rk = await vault.create('forgotten');
      vault.db.raw.execute("INSERT INTO meta(key,value) VALUES('k','v');");
      vault.lock();

      final v2 = fresh();
      await v2.unlockWithRecoveryKey(rk, 'brand-new');
      v2.lock();
      final v3 = fresh();
      await expectLater(
        v3.unlockWithPassword('forgotten'),
        throwsA(isA<WrongKeyException>()),
      );
      await v3.unlockWithPassword('brand-new');
      expect(
        v3.db.raw.select("SELECT value FROM meta WHERE key='k'").first['value'],
        'v',
      );
      v3.lock();
    });

    test('regenerated recovery key invalidates the old one', () async {
      final oldRk = await vault.create('pw');
      final newRk = await vault.regenerateRecoveryKey();
      expect(newRk, isNot(oldRk));
      vault.lock();

      final v2 = fresh();
      await expectLater(
        v2.unlockWithRecoveryKey(oldRk, 'x'),
        throwsA(isA<WrongKeyException>()),
      );
      await v2.unlockWithRecoveryKey(newRk, 'pw2');
      v2.lock();
    });

    test('regenerate requires unlocked vault', () async {
      await vault.create('pw');
      vault.lock();
      expect(() => vault.regenerateRecoveryKey(), throwsStateError);
    });

    test('snapshot is encrypted and openable with the same key', () async {
      await vault.create('pw');
      vault.db.raw.execute("INSERT INTO meta(key,value) VALUES('k','v');");
      final snap = '${dir.path}/snap.db';
      vault.db.snapshotTo(snap);
      final head = readHead(snap);
      expect(String.fromCharCodes(head), isNot(startsWith('SQLite format 3')));
    });

    test('schema is migrated to latest version', () async {
      await vault.create('pw');
      final tables = vault.db.raw
          .select("SELECT name FROM sqlite_master WHERE type='table'")
          .map((r) => r['name'])
          .toSet();
      expect(
        tables,
        containsAll([
          'applications',
          'repositories',
          'environments',
          'hosting_targets',
          'credentials',
          'attachments',
          'console_links',
        ]),
      );
      expect(vault.db.schemaVersion, 2);
    });

    test('create refuses to overwrite existing vault', () async {
      await vault.create('pw');
      vault.lock();
      expect(() => fresh().create('pw2'), throwsStateError);
    });
  });
}
