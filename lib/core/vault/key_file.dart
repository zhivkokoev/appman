import 'dart:convert';
import 'dart:io';

import '../crypto/kdf.dart';
import '../crypto/wrap.dart';

/// Contents of `vault.keys`: KDF parameters plus the data key wrapped twice
/// (by the password-derived key and by the recovery key). Not secret by itself.
class VaultKeyFile {
  VaultKeyFile({
    required this.kdf,
    required this.passwordWrap,
    required this.recoveryWrap,
  });

  static const int version = 1;
  static const String passwordAad = 'appman-v1-password';
  static const String recoveryAad = 'appman-v1-recovery';

  final KdfParams kdf;
  final WrappedKey passwordWrap;
  final WrappedKey recoveryWrap;

  Map<String, Object?> toJson() => {
    'version': version,
    'kdf': kdf.toJson(),
    'passwordWrap': passwordWrap.toJson(),
    'recoveryWrap': recoveryWrap.toJson(),
  };

  factory VaultKeyFile.fromJson(Map<String, Object?> j) {
    if (j['version'] != version) {
      throw FormatException('Unsupported key file version ${j['version']}');
    }
    return VaultKeyFile(
      kdf: KdfParams.fromJson((j['kdf'] as Map).cast<String, Object?>()),
      passwordWrap: WrappedKey.fromJson(
        (j['passwordWrap'] as Map).cast<String, Object?>(),
      ),
      recoveryWrap: WrappedKey.fromJson(
        (j['recoveryWrap'] as Map).cast<String, Object?>(),
      ),
    );
  }

  static VaultKeyFile read(String path) => VaultKeyFile.fromJson(
    (jsonDecode(File(path).readAsStringSync()) as Map).cast<String, Object?>(),
  );

  /// Atomic write: temp file, flush, rename over the target.
  void write(String path) {
    final tmp = File('$path.tmp');
    final raf = tmp.openSync(mode: FileMode.write);
    try {
      raf.writeStringSync(const JsonEncoder.withIndent('  ').convert(toJson()));
      raf.flushSync();
    } finally {
      raf.closeSync();
    }
    tmp.renameSync(path);
  }
}
