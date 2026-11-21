import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'kdf.dart';

class WrongKeyException implements Exception {
  @override
  String toString() => 'Wrong password or recovery key';
}

/// AES-256-GCM wrapped key (nonce + ciphertext + tag), JSON/base64 serializable.
class WrappedKey {
  WrappedKey(this.nonce, this.cipherText, this.mac);
  final Uint8List nonce;
  final Uint8List cipherText;
  final Uint8List mac;

  Map<String, Object?> toJson() => {
    'nonce': base64Encode(nonce),
    'ct': base64Encode(cipherText),
    'mac': base64Encode(mac),
  };

  factory WrappedKey.fromJson(Map<String, Object?> j) => WrappedKey(
    base64Decode(j['nonce'] as String),
    base64Decode(j['ct'] as String),
    base64Decode(j['mac'] as String),
  );
}

final _aes = AesGcm.with256bits();

/// [aad] binds the wrap to its purpose so a password wrap cannot be swapped for a recovery wrap.
Future<WrappedKey> wrapKey(
  Uint8List key,
  Uint8List wrappingKey,
  String aad,
) async {
  final nonce = randomBytes(12);
  final box = await _aes.encrypt(
    key,
    secretKey: SecretKey(wrappingKey),
    nonce: nonce,
    aad: utf8.encode(aad),
  );
  return WrappedKey(
    nonce,
    Uint8List.fromList(box.cipherText),
    Uint8List.fromList(box.mac.bytes),
  );
}

Future<Uint8List> unwrapKey(
  WrappedKey w,
  Uint8List wrappingKey,
  String aad,
) async {
  try {
    final clear = await _aes.decrypt(
      SecretBox(w.cipherText, nonce: w.nonce, mac: Mac(w.mac)),
      secretKey: SecretKey(wrappingKey),
      aad: utf8.encode(aad),
    );
    return Uint8List.fromList(clear);
  } on SecretBoxAuthenticationError {
    throw WrongKeyException();
  }
}
