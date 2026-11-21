import 'dart:io';

import 'package:crypto/crypto.dart';

import '../db/app_database.dart';

/// One backup version: a consistent encrypted DB snapshot plus the key file (both ciphertext-only).
class BackupVersion {
  BackupVersion({
    required this.id,
    required this.createdAt,
    required this.dir,
    required this.dbBytes,
  });

  /// Sortable id, e.g. `20261121-180042-123`.
  final String id;
  final DateTime createdAt;
  final String dir;
  final int dbBytes;

  String get dbPath => '$dir${Platform.pathSeparator}vault.db';
  String get keysPath => '$dir${Platform.pathSeparator}vault.keys';
}

class LocalBackup {
  LocalBackup(this.backupsDir);
  final String backupsDir;

  static String _two(int n) => n.toString().padLeft(2, '0');
  static String idFor(DateTime t) =>
      '${t.year}${_two(t.month)}${_two(t.day)}-${_two(t.hour)}${_two(t.minute)}${_two(t.second)}-${t.millisecond.toString().padLeft(3, '0')}';
  static DateTime? parseId(String id) {
    final m = RegExp(r'^(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})-(\d{3})$')
        .firstMatch(id);
    if (m == null) return null;
    final g = [for (var i = 1; i <= 7; i++) int.parse(m.group(i)!)];
    return DateTime(g[0], g[1], g[2], g[3], g[4], g[5], g[6]);
  }

  /// Takes a snapshot of the open database and copies [keysPath] next to it.
  BackupVersion create(AppDatabase db, String keysPath, {DateTime? now}) {
    final t = now ?? DateTime.now();
    final id = idFor(t);
    final dir = Directory('$backupsDir${Platform.pathSeparator}$id')
      ..createSync(recursive: true);
    final v = BackupVersion(id: id, createdAt: t, dir: dir.path, dbBytes: 0);
    try {
      db.snapshotTo(v.dbPath);
      File(keysPath).copySync(v.keysPath);
    } catch (_) {
      dir.deleteSync(recursive: true);
      rethrow;
    }
    return BackupVersion(
      id: id,
      createdAt: t,
      dir: dir.path,
      dbBytes: File(v.dbPath).lengthSync(),
    );
  }

  /// Newest first. Directories that are incomplete are ignored.
  List<BackupVersion> list() {
    final root = Directory(backupsDir);
    if (!root.existsSync()) return const [];
    final out = <BackupVersion>[];
    for (final e in root.listSync().whereType<Directory>()) {
      final id = e.path.split(Platform.pathSeparator).last;
      final t = parseId(id);
      if (t == null) continue;
      final db = File('${e.path}${Platform.pathSeparator}vault.db');
      final keys = File('${e.path}${Platform.pathSeparator}vault.keys');
      if (!db.existsSync() || !keys.existsSync()) continue;
      out.add(
        BackupVersion(
          id: id,
          createdAt: t,
          dir: e.path,
          dbBytes: db.lengthSync(),
        ),
      );
    }
    out.sort((a, b) => b.id.compareTo(a.id));
    return out;
  }

  /// Keeps the newest [keep] versions, deletes the rest. Returns how many were deleted.
  int prune(int keep) {
    final all = list();
    var n = 0;
    for (final v in all.skip(keep < 1 ? 1 : keep)) {
      Directory(v.dir).deleteSync(recursive: true);
      n++;
    }
    return n;
  }

  /// Replaces the live vault files with [v]. The vault must be locked/closed first.
  /// The current files are saved as a safety copy `pre-restore-<ts>` inside the backups folder.
  void restore(
    BackupVersion v, {
    required String dbPath,
    required String keysPath,
    DateTime? now,
  }) {
    final safety = Directory(
      '$backupsDir${Platform.pathSeparator}pre-restore-${idFor(now ?? DateTime.now())}',
    )..createSync(recursive: true);
    if (File(dbPath).existsSync()) {
      File(dbPath).copySync('${safety.path}${Platform.pathSeparator}vault.db');
    }
    if (File(keysPath).existsSync()) {
      File(keysPath)
          .copySync('${safety.path}${Platform.pathSeparator}vault.keys');
    }
    // Copy to temp names then rename so a crash never leaves a half-written vault.
    File(v.dbPath).copySync('$dbPath.restoring');
    File(v.keysPath).copySync('$keysPath.restoring');
    File('$dbPath.restoring').renameSync(dbPath);
    File('$keysPath.restoring').renameSync(keysPath);
  }

  static String sha256Of(List<int> bytes) => sha256.convert(bytes).toString();
}
