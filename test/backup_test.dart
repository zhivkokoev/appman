import 'dart:io';
import 'dart:typed_data';

import 'package:appman/core/backup/backup_manager.dart';
import 'package:appman/core/backup/drive_sync.dart';
import 'package:appman/core/backup/local_backup.dart';
import 'package:appman/core/crypto/kdf.dart';
import 'package:appman/core/db/application_repository.dart';
import 'package:appman/core/db/settings_store.dart';
import 'package:appman/core/vault/vault_service.dart';
import 'package:flutter_test/flutter_test.dart';

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

class FakeDrive implements DriveBackend {
  final files = <String, (RemoteFile, Uint8List)>{};
  var _n = 0;
  Object? failWith; // set to simulate network errors
  int uploads = 0;

  @override
  Future<List<RemoteFile>> list() async {
    if (failWith != null) throw failWith!;
    return [for (final f in files.values) f.$1];
  }

  @override
  Future<RemoteFile> upload(
    String name,
    Uint8List bytes, {
    Map<String, String> properties = const {},
  }) async {
    if (failWith != null) throw failWith!;
    uploads++;
    final f = RemoteFile(
      id: 'f${_n++}',
      name: name,
      createdTime: DateTime.now(),
      size: bytes.length,
      properties: properties,
    );
    files[f.id] = (f, bytes);
    return f;
  }

  @override
  Future<Uint8List> download(String id) async => files[id]!.$2;

  @override
  Future<void> delete(String id) async => files.remove(id);
}

void main() {
  late Directory dir;
  late VaultService vault;
  late VaultPaths paths;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('appman_backup_');
    paths = VaultPaths(dir.path);
    vault = VaultService(paths, FastKdf());
    await vault.create('a long passphrase here');
    ApplicationRepository(vault.db).create(name: 'Shop');
  });
  tearDown(() {
    if (vault.isUnlocked) vault.lock();
    dir.deleteSync(recursive: true);
  });

  group('LocalBackup', () {
    test('snapshot is encrypted, listed newest first, pruned to N', () {
      final lb = LocalBackup('${dir.path}/backups');
      final t0 = DateTime(2026, 11, 21, 10);
      for (var i = 0; i < 5; i++) {
        lb.create(vault.db, paths.keys, now: t0.add(Duration(minutes: i)));
      }
      final list = lb.list();
      expect(list.length, 5);
      expect(list.first.createdAt, t0.add(const Duration(minutes: 4)));
      final head = File(list.first.dbPath).openSync();
      final bytes = head.readSync(16);
      head.closeSync();
      expect(String.fromCharCodes(bytes), isNot(startsWith('SQLite format 3')));
      expect(lb.prune(3), 2);
      expect(lb.list().map((v) => v.createdAt), [
        t0.add(const Duration(minutes: 4)),
        t0.add(const Duration(minutes: 3)),
        t0.add(const Duration(minutes: 2)),
      ]);
    });

    test('incomplete backup folders and foreign folders are ignored', () {
      final lb = LocalBackup('${dir.path}/backups');
      lb.create(vault.db, paths.keys, now: DateTime(2026, 1, 1));
      Directory('${dir.path}/backups/20260102-000000-000')
          .createSync(); // empty
      Directory('${dir.path}/backups/notes').createSync();
      expect(lb.list().length, 1);
    });

    test('restore brings back old data and keeps a safety copy', () async {
      final lb = LocalBackup('${dir.path}/backups');
      final v = lb.create(vault.db, paths.keys, now: DateTime(2026, 1, 1));
      final repo = ApplicationRepository(vault.db);
      repo.create(name: 'Added later');
      expect(repo.list().length, 2);
      vault.lock();

      lb.restore(
        v,
        dbPath: paths.db,
        keysPath: paths.keys,
        now: DateTime(2026, 1, 2),
      );
      await vault.unlockWithPassword('a long passphrase here');
      expect(ApplicationRepository(vault.db).list().map((a) => a.name), [
        'Shop',
      ]);
      expect(
        Directory('${dir.path}/backups')
            .listSync()
            .any((e) => e.path.contains('pre-restore-')),
        isTrue,
      );
    });
  });

  group('DriveSync', () {
    late FakeDrive drive;
    late LocalBackup lb;
    BackupVersion snap(DateTime t) => lb.create(vault.db, paths.keys, now: t);

    setUp(() {
      drive = FakeDrive();
      lb = LocalBackup('${dir.path}/backups');
    });

    test('uploads db + keys as one version and lists it', () async {
      final sync = DriveSync(drive, deviceId: 'A');
      final up = await sync.upload(snap(DateTime(2026, 5, 1)));
      expect(drive.files.length, 2);
      final vs = await sync.versions();
      expect(vs.single.version, up.version);
      expect(vs.single.deviceId, 'A');
    });

    test('retention keeps only the newest N complete versions', () async {
      final sync = DriveSync(drive, deviceId: 'A', retention: 3);
      for (var i = 1; i <= 6; i++) {
        await sync.upload(
          snap(DateTime(2026, 5, i)),
          lastSeenRemoteVersion: 'zzz',
        );
      }
      final vs = await sync.versions();
      expect(vs.length, 3);
      expect(vs.first.createdAt, DateTime(2026, 5, 6));
      expect(drive.files.length, 6); // 3 versions x 2 files
    });

    test('a newer backup from another installation raises a warning; force overrides', () async {
      final other = DriveSync(drive, deviceId: 'B');
      await other.upload(snap(DateTime(2026, 5, 1)));
      final mine = DriveSync(drive, deviceId: 'A');
      await expectLater(
        mine.upload(snap(DateTime(2026, 5, 2))),
        throwsA(isA<ForeignBackupException>()),
      );
      expect(drive.files.length, 2, reason: 'nothing was uploaded');

      // Once I have seen that remote version, uploading is fine.
      final seen = (await mine.versions()).first.version;
      await mine.upload(
        snap(DateTime(2026, 5, 3)),
        lastSeenRemoteVersion: seen,
      );
      expect(drive.files.length, 4);

      // Another installation wrote again after I last looked: warning, then force.
      await other.upload(snap(DateTime(2026, 5, 4)), force: true);
      await expectLater(
        mine.upload(snap(DateTime(2026, 5, 5)), lastSeenRemoteVersion: seen),
        throwsA(isA<ForeignBackupException>()),
      );
      await mine.upload(
        snap(DateTime(2026, 5, 6)),
        lastSeenRemoteVersion: seen,
        force: true,
      );
      expect((await mine.versions()).first.deviceId, 'A');
    });

    test('download reproduces an openable vault', () async {
      final sync = DriveSync(drive, deviceId: 'A');
      await sync.upload(snap(DateTime(2026, 5, 1)));
      final remote = (await sync.versions()).first;
      final dl = await sync.download(remote, '${dir.path}/downloaded');
      vault.lock();
      final fresh = Directory.systemTemp.createTempSync('appman_restore_');
      addTearDown(() => fresh.deleteSync(recursive: true));
      final p2 = VaultPaths(fresh.path);
      LocalBackup('${fresh.path}/b')
          .restore(dl, dbPath: p2.db, keysPath: p2.keys);
      final v2 = VaultService(p2, FastKdf());
      await v2.unlockWithPassword('a long passphrase here');
      expect(ApplicationRepository(v2.db).list().single.name, 'Shop');
      v2.lock();
    });

    test(
      'incomplete uploads (db without keys) are not listed as versions',
      () async {
        final sync = DriveSync(drive, deviceId: 'A');
        await drive.upload(
          'vault-x.db',
          Uint8List(3),
          properties: {'version': '20260101-000000-000', 'device': 'A'},
        );
        expect(await sync.versions(), isEmpty);
      },
    );
  });

  group('BackupManager', () {
    late FakeDrive drive;
    BackupManager make({bool drive_ = false}) {
      drive = FakeDrive();
      final s = SettingsStore(vault.db);
      s.setBool('drive_enabled', drive_);
      return BackupManager(
        db: vault.db,
        vaultDir: dir.path,
        keysPath: paths.keys,
        dbPath: paths.db,
        driveFactory: (settings, deviceId) async =>
            DriveSync(drive, deviceId: deviceId, retention: 5),
        debounce: const Duration(milliseconds: 60),
        retryOffline: const Duration(milliseconds: 80),
      );
    }

    test('manual backup creates a local version and sets ok', () async {
      final m = make();
      await m.backupNow();
      expect(m.state, BackupState.ok);
      expect(m.local.list().length, 1);
      expect(m.lastBackupAt, isNotNull);
      m.dispose();
    });

    test('changes trigger a single debounced backup', () async {
      final m = make();
      m.start();
      await Future<void>.delayed(
        const Duration(milliseconds: 200),
      ); // startup backup (no backup existed)
      final before = m.local.list().length;
      final app = ApplicationRepository(vault.db);
      app.create(name: 'one');
      app.create(name: 'two');
      app.create(name: 'three');
      await Future<void>.delayed(
        Duration.zero,
      ); // sqlite's update stream is delivered asynchronously
      expect(m.state, BackupState.pending);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(m.state, BackupState.ok);
      expect(
        m.local.list().length,
        before + 1,
        reason: 'three writes, one backup',
      );
      m.dispose();
    });

    test(
      'startup does nothing when nothing changed since the last backup',
      () async {
        final m = make();
        await m.backupNow();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        m.stop();
        final count = m.local.list().length;
        final m2 = make();
        m2.start();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(m2.local.list().length, count);
        m2.dispose();
        m.dispose();
      },
    );

    test('drive upload on success, and last-seen is recorded', () async {
      final m = make(drive_: true);
      await m.backupNow();
      expect(m.state, BackupState.ok);
      expect(drive.files.length, 2);
      expect(m.settings.getState('drive_last_seen'), isNotNull);
      expect(m.lastDriveUploadAt, isNotNull);
      m.dispose();
    });

    test(
      'offline: local backup still made, state offline, retried later',
      () async {
        final m = make(drive_: true);
        drive.failWith = const SocketException('no network');
        await m.backupNow();
        expect(m.state, BackupState.offline);
        expect(
          m.local.list().length,
          1,
          reason: 'local backup does not depend on the network',
        );
        drive.failWith = null;
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(m.state, BackupState.ok);
        expect(drive.files.length, 2);
        m.dispose();
      },
    );

    test(
      'foreign backup -> conflict state; upload anyway resolves it',
      () async {
        final m = make(drive_: true);
        await DriveSync(drive, deviceId: 'OTHER').upload(
          LocalBackup('${dir.path}/other')
              .create(vault.db, paths.keys, now: DateTime(2026, 1, 1)),
        );
        await m.backupNow();
        expect(m.state, BackupState.conflict);
        expect(m.conflict, isNotNull);
        await m.resolveConflictUploadAnyway();
        expect(m.state, BackupState.ok);
        expect(m.conflict, isNull);
        m.dispose();
      },
    );

    test('unexpected errors surface as error state without throwing', () async {
      final m = make(drive_: true);
      drive.failWith = StateError('boom');
      await m.backupNow();
      expect(m.state, BackupState.error);
      expect(m.lastError, contains('boom'));
      m.dispose();
    });
  });
}
