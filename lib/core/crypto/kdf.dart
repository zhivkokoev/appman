import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as c;
import 'package:dargon2_flutter/dargon2_flutter.dart';

Uint8List randomBytes(int n) {
  final r = Random.secure();
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

/// Argon2id parameters; stored in the key file (not secret).
class KdfParams {
  KdfParams({
    required this.memoryKiB,
    required this.iterations,
    required this.parallelism,
    required this.salt,
  });

  final int memoryKiB;
  final int iterations;
  final int parallelism;
  final Uint8List salt;

  KdfParams copyWith({int? memoryKiB, int? iterations, Uint8List? salt}) =>
      KdfParams(
        memoryKiB: memoryKiB ?? this.memoryKiB,
        iterations: iterations ?? this.iterations,
        parallelism: parallelism,
        salt: salt ?? this.salt,
      );

  Map<String, Object?> toJson() => {
    'alg': 'argon2id',
    'm': memoryKiB,
    't': iterations,
    'p': parallelism,
    'salt': base64Encode(salt),
  };

  factory KdfParams.fromJson(Map<String, Object?> j) {
    if (j['alg'] != 'argon2id') {
      throw FormatException('Unsupported KDF: ${j['alg']}');
    }
    return KdfParams(
      memoryKiB: j['m'] as int,
      iterations: j['t'] as int,
      parallelism: j['p'] as int,
      salt: base64Decode(j['salt'] as String),
    );
  }
}

/// Derives a 32-byte key from a password.
abstract class Kdf {
  Future<Uint8List> derive(Uint8List password, KdfParams params);

  /// Picks iteration count so that one derivation takes about [targetMs].
  Future<KdfParams> calibrate({
    int targetMs = 700,
    int memoryKiB = 262144,
    int parallelism = 4,
  }) async {
    final probe = KdfParams(
      memoryKiB: memoryKiB,
      iterations: 3,
      parallelism: parallelism,
      salt: randomBytes(16),
    );
    final sw = Stopwatch()..start();
    await derive(Uint8List.fromList(utf8.encode('calibration')), probe);
    sw.stop();
    final perIter = max(1, sw.elapsedMilliseconds) / 3;
    final t = (targetMs / perIter).round().clamp(3, 40);
    return probe.copyWith(iterations: t, salt: randomBytes(16));
  }
}

/// Production KDF: native Argon2 via FFI (dargon2_flutter). Call [DArgon2Flutter.init] first.
class NativeArgon2Kdf extends Kdf {
  @override
  Future<Uint8List> derive(Uint8List password, KdfParams p) async {
    final r = await argon2.hashPasswordBytes(
      password,
      salt: Salt(p.salt),
      iterations: p.iterations,
      memory: p.memoryKiB,
      parallelism: p.parallelism,
      length: 32,
      type: Argon2Type.id,
      version: Argon2Version.V13,
    );
    return Uint8List.fromList(r.rawBytes);
  }
}

/// Pure-Dart Argon2id (slow); intended for unit tests with tiny parameters only.
class DartArgon2Kdf extends Kdf {
  @override
  Future<Uint8List> derive(Uint8List password, KdfParams p) async {
    final algo = c.Argon2id(
      memory: p.memoryKiB,
      parallelism: p.parallelism,
      iterations: p.iterations,
      hashLength: 32,
    );
    final key = await algo.deriveKey(
      secretKey: c.SecretKey(password),
      nonce: p.salt,
    );
    return Uint8List.fromList(await key.extractBytes());
  }
}
