import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import 'schema.dart';

String hexOf(List<int> b) =>
    b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

class AppDatabase {
  AppDatabase._(this.raw);
  final Database raw;

  /// Opens (creating if needed) the SQLCipher database with the raw 256-bit data key.
  /// Throws [DatabaseKeyException] if the key does not decrypt the file.
  static AppDatabase open(String path, Uint8List dataKey) {
    final db = sqlite3.open(path);
    try {
      final v = db.select('PRAGMA cipher_version;');
      if (v.isEmpty) {
        throw StateError(
          'SQLCipher not available: refusing to use an unencrypted SQLite build',
        );
      }
      db.execute('PRAGMA key = "x\'${hexOf(dataKey)}\'";');
      try {
        db.select(
          'SELECT count(*) FROM sqlite_master;',
        ); // first read fails if the key is wrong
      } on SqliteException catch (e) {
        throw DatabaseKeyException(e.message);
      }
      db.execute(
        'PRAGMA journal_mode = DELETE;',
      ); // keeps the file self-contained for backups
      db.execute('PRAGMA foreign_keys = ON;');
      final a = AppDatabase._(db);
      a._migrate();
      return a;
    } catch (_) {
      db.close();
      rethrow;
    }
  }

  int get schemaVersion =>
      raw.select('PRAGMA user_version;').first.values.first as int;

  void _migrate() {
    var v = schemaVersion;
    while (v < migrations.length) {
      raw.execute('BEGIN;');
      try {
        for (final s in migrations[v]) {
          raw.execute(s);
        }
        v++;
        raw.execute('PRAGMA user_version = $v;');
        raw.execute('COMMIT;');
      } catch (_) {
        raw.execute('ROLLBACK;');
        rethrow;
      }
    }
  }

  /// Consistent, still-encrypted snapshot (used for backups before upload/restore).
  void snapshotTo(String path) {
    raw.execute(
      "VACUUM INTO '${path.replaceAll('\\', '/').replaceAll("'", "''")}';",
    );
  }

  void close() => raw.close();
}

class DatabaseKeyException implements Exception {
  DatabaseKeyException(this.message);
  final String message;
  @override
  String toString() => 'Database could not be decrypted: $message';
}
