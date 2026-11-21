import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'dpapi.dart';

/// Token store backed by the OS keyring (libsecret / Secret Service on Linux).
/// Like the DPAPI store, it lives outside the vault and is never backed up.
class KeyringTokenStore implements TokenStore {
  KeyringTokenStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();
  final FlutterSecureStorage _storage;

  String _k(String key) => 'appman.$key';

  @override
  Future<String?> read(String key) async {
    try {
      return await _storage.read(key: _k(key));
    } catch (_) {
      return null; // keyring locked or unavailable: treat as "not connected"
    }
  }

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: _k(key), value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: _k(key));
}

/// DPAPI file on Windows, OS keyring elsewhere.
TokenStore platformTokenStore(String vaultDir) =>
    Platform.isWindows ? DpapiTokenStore(vaultDir) : KeyringTokenStore();
