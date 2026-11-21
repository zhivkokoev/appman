import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../crypto/kdf.dart';
import '../crypto/recovery_key.dart';
import '../crypto/wrap.dart';
import '../db/app_database.dart';
import 'key_file.dart';

class VaultPaths {
  VaultPaths(this.dir);
  final String dir;
  String get db => '$dir${Platform.pathSeparator}vault.db';
  String get keys => '$dir${Platform.pathSeparator}vault.keys';

  /// Default location: `%APPDATA%\AppMan` on Windows, `$XDG_DATA_HOME/AppMan`
  /// (default `~/.local/share/AppMan`) on Linux, or `$APPMAN_HOME` if set
  /// (used for development/tests).
  factory VaultPaths.defaultLocation() {
    final env = Platform.environment;
    final override = env['APPMAN_HOME'];
    if (override != null && override.isNotEmpty) return VaultPaths(override);
    final sep = Platform.pathSeparator;
    String? base;
    if (Platform.isWindows) {
      base = env['APPDATA'];
    } else {
      final xdg = env['XDG_DATA_HOME'];
      final home = env['HOME'];
      if (xdg != null && xdg.isNotEmpty) {
        base = xdg;
      } else if (home != null && home.isNotEmpty) {
        base = '$home$sep.local${sep}share';
      }
    }
    base ??= Directory.current.path;
    return VaultPaths('$base${sep}AppMan');
  }
}

/// Owns the key hierarchy and the open database.
///
/// Data key (DK, random 256-bit) encrypts the DB. The password-derived key and the
/// recovery key each wrap the same DK, so changing either never re-encrypts the DB.
class VaultService extends ChangeNotifier {
  VaultService(this.paths, this.kdf);

  final VaultPaths paths;
  final Kdf kdf;

  Uint8List? _dataKey;
  AppDatabase? _db;

  bool get exists =>
      File(paths.keys).existsSync() && File(paths.db).existsSync();
  bool get isUnlocked => _db != null;
  AppDatabase get db => _db ?? (throw StateError('Vault is locked'));

  Uint8List _pw(String s) => Uint8List.fromList(utf8.encode(s));

  /// Creates a new vault and leaves it unlocked. Returns the recovery key (show once).
  Future<String> create(String password) async {
    if (exists) throw StateError('A vault already exists at ${paths.dir}');
    Directory(paths.dir).createSync(recursive: true);
    final dk = randomBytes(32);
    final recovery = RecoveryKey.generate();
    final params = await kdf.calibrate();
    final kek = await kdf.derive(_pw(password), params);

    final keyFile = VaultKeyFile(
      kdf: params,
      passwordWrap: await wrapKey(dk, kek, VaultKeyFile.passwordAad),
      recoveryWrap: await wrapKey(dk, recovery.bytes, VaultKeyFile.recoveryAad),
    );
    // DB first, key file last: the key file's existence marks a complete vault.
    final db = AppDatabase.open(paths.db, dk);
    keyFile.write(paths.keys);
    _dataKey = dk;
    _db = db;
    notifyListeners();
    return recovery.format();
  }

  Future<void> unlockWithPassword(String password) async {
    final kf = VaultKeyFile.read(paths.keys);
    final kek = await kdf.derive(_pw(password), kf.kdf);
    final dk = await unwrapKey(kf.passwordWrap, kek, VaultKeyFile.passwordAad);
    _open(dk);
  }

  /// Unlocks with the recovery key and immediately sets a new master password.
  /// The recovery key itself stays valid; regenerate it afterwards if desired.
  Future<void> unlockWithRecoveryKey(
    String recoveryKey,
    String newPassword,
  ) async {
    final kf = VaultKeyFile.read(paths.keys);
    final rk = RecoveryKey.parse(recoveryKey);
    final dk = await unwrapKey(
      kf.recoveryWrap,
      rk.bytes,
      VaultKeyFile.recoveryAad,
    );
    _open(dk);
    await _rewrapPassword(dk, newPassword, kf);
  }

  void _open(Uint8List dk) {
    final db = AppDatabase.open(paths.db, dk);
    _dataKey = dk;
    _db = db;
    notifyListeners();
  }

  /// Closes the DB and drops key references. Best effort only: Dart gives no
  /// guarantee the key bytes are erased from memory (out of scope, see spec §7).
  void lock() {
    _db?.close();
    _db = null;
    _dataKey?.fillRange(0, _dataKey!.length, 0);
    _dataKey = null;
    notifyListeners();
  }

  /// Re-checks the master password without touching the open database (used before exporting secrets).
  Future<bool> verifyPassword(String password) async {
    try {
      final kf = VaultKeyFile.read(paths.keys);
      final kek = await kdf.derive(_pw(password), kf.kdf);
      await unwrapKey(kf.passwordWrap, kek, VaultKeyFile.passwordAad);
      return true;
    } on WrongKeyException {
      return false;
    }
  }

  Future<void> changePassword(String oldPassword, String newPassword) async {
    final kf = VaultKeyFile.read(paths.keys);
    final oldKek = await kdf.derive(_pw(oldPassword), kf.kdf);
    final dk = await unwrapKey(
      kf.passwordWrap,
      oldKek,
      VaultKeyFile.passwordAad,
    ); // verifies old password
    await _rewrapPassword(dk, newPassword, kf);
  }

  Future<void> _rewrapPassword(
    Uint8List dk,
    String newPassword,
    VaultKeyFile old,
  ) async {
    final params = await kdf.calibrate();
    final kek = await kdf.derive(_pw(newPassword), params);
    final updated = VaultKeyFile(
      kdf: params,
      passwordWrap: await wrapKey(dk, kek, VaultKeyFile.passwordAad),
      recoveryWrap: old.recoveryWrap,
    );
    updated.write(paths.keys);
  }

  /// Generates a new recovery key and invalidates the previous one. Requires an unlocked vault.
  Future<String> regenerateRecoveryKey() async {
    final dk = _dataKey ?? (throw StateError('Vault is locked'));
    final kf = VaultKeyFile.read(paths.keys);
    final rk = RecoveryKey.generate();
    final updated = VaultKeyFile(
      kdf: kf.kdf,
      passwordWrap: kf.passwordWrap,
      recoveryWrap: await wrapKey(dk, rk.bytes, VaultKeyFile.recoveryAad),
    );
    updated.write(paths.keys); // atomic replace; no old copy kept, so the old recovery key is really dead
    return rk.format();
  }
}
