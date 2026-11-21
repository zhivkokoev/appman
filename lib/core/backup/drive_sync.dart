import 'dart:io';
import 'dart:typed_data';

import 'local_backup.dart';

/// A file in the remote app-private storage (Google Drive `appDataFolder`).
class RemoteFile {
  RemoteFile({
    required this.id,
    required this.name,
    required this.createdTime,
    required this.size,
    this.properties = const {},
  });
  final String id, name;
  final DateTime createdTime;
  final int size;
  final Map<String, String> properties;
}

/// Transport abstraction so the sync logic is testable without Google.
abstract class DriveBackend {
  Future<List<RemoteFile>> list();
  Future<RemoteFile> upload(
    String name,
    Uint8List bytes, {
    Map<String, String> properties = const {},
  });
  Future<Uint8List> download(String id);
  Future<void> delete(String id);
}

/// A remote version = the `.db` and `.keys` files that share a `version` property.
class RemoteVersion {
  RemoteVersion({
    required this.version,
    required this.createdAt,
    required this.deviceId,
    required this.db,
    required this.keys,
  });
  final String version;
  final DateTime createdAt;
  final String deviceId;
  final RemoteFile db, keys;
  int get size => db.size + keys.size;
}

/// Raised when the newest remote backup was written by a different installation (spec F8 safety check).
class ForeignBackupException implements Exception {
  ForeignBackupException(this.latest);
  final RemoteVersion latest;
  @override
  String toString() =>
      'A newer backup from another installation exists (${latest.version}).';
}

class DriveSync {
  DriveSync(
    this.backend, {
    required this.deviceId,
    this.retention = 10,
    this.close,
  });
  final DriveBackend backend;
  final String deviceId;
  int retention;

  /// Releases the transport (e.g. the HTTP client) when the caller is done.
  final void Function()? close;

  static const _versionKey = 'version';
  static const _deviceKey = 'device';

  Future<List<RemoteVersion>> versions() async {
    final files = await backend.list();
    final byVersion = <String, Map<String, RemoteFile>>{};
    for (final f in files) {
      final v = f.properties[_versionKey];
      if (v == null) continue;
      final kind = f.name.endsWith('.keys') ? 'keys' : 'db';
      byVersion.putIfAbsent(v, () => {})[kind] = f;
    }
    final out = <RemoteVersion>[];
    for (final e in byVersion.entries) {
      final db = e.value['db'], keys = e.value['keys'];
      if (db == null || keys == null) {
        continue; // incomplete upload: ignored (and cleaned by prune)
      }
      out.add(
        RemoteVersion(
          version: e.key,
          createdAt: LocalBackup.parseId(e.key) ?? db.createdTime,
          deviceId: db.properties[_deviceKey] ?? '',
          db: db,
          keys: keys,
        ),
      );
    }
    out.sort((a, b) => b.version.compareTo(a.version));
    return out;
  }

  /// Uploads [v]. If the newest remote version is from another installation and newer than
  /// [lastSeenRemoteVersion], throws [ForeignBackupException] unless [force].
  /// Uploads the `.keys` file last so a version is only complete once both parts exist.
  Future<RemoteVersion> upload(
    BackupVersion v, {
    String? lastSeenRemoteVersion,
    bool force = false,
  }) async {
    final existing = await versions();
    if (!force && existing.isNotEmpty) {
      final latest = existing.first;
      final seen = lastSeenRemoteVersion ?? '';
      if (latest.deviceId != deviceId && latest.version.compareTo(seen) > 0) {
        throw ForeignBackupException(latest);
      }
    }
    final props = {_versionKey: v.id, _deviceKey: deviceId};
    final db = await backend.upload(
      'vault-${v.id}.db',
      File(v.dbPath).readAsBytesSync(),
      properties: props,
    );
    final keys = await backend.upload(
      'vault-${v.id}.keys',
      File(v.keysPath).readAsBytesSync(),
      properties: props,
    );
    await prune();
    return RemoteVersion(
      version: v.id,
      createdAt: v.createdAt,
      deviceId: deviceId,
      db: db,
      keys: keys,
    );
  }

  /// Keeps the newest [retention] complete versions; removes older ones and orphaned halves.
  Future<int> prune() async {
    final files = await backend.list();
    final complete = await versions();
    final keepIds = complete
        .take(retention < 1 ? 1 : retention)
        .map((v) => v.version)
        .toSet();
    var removed = 0;
    for (final f in files) {
      final v = f.properties[_versionKey];
      if (v == null) continue;
      final isOrphan = !complete.any((c) => c.version == v);
      // Never delete an in-flight upload of the version just written: it is "orphan" only until its keys land.
      if (!keepIds.contains(v) &&
          (!isOrphan ||
              DateTime.now().difference(f.createdTime) >
                  const Duration(hours: 1))) {
        await backend.delete(f.id);
        removed++;
      }
    }
    return removed;
  }

  /// Downloads [v] into [destDir] as `vault.db` / `vault.keys` (a [BackupVersion] layout).
  Future<BackupVersion> download(RemoteVersion v, String destDir) async {
    final dir = Directory('$destDir${Platform.pathSeparator}${v.version}')
      ..createSync(recursive: true);
    final db = File('${dir.path}${Platform.pathSeparator}vault.db')
      ..writeAsBytesSync(await backend.download(v.db.id));
    File('${dir.path}${Platform.pathSeparator}vault.keys')
        .writeAsBytesSync(await backend.download(v.keys.id));
    return BackupVersion(
      id: v.version,
      createdAt: v.createdAt,
      dir: dir.path,
      dbBytes: db.lengthSync(),
    );
  }
}
