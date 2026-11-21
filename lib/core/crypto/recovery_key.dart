import 'dart:typed_data';

import 'kdf.dart';

const _alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

/// 256-bit random recovery key, rendered as 52 base32 chars in groups of 4.
class RecoveryKey {
  RecoveryKey(this.bytes);
  final Uint8List bytes;

  factory RecoveryKey.generate() => RecoveryKey(randomBytes(32));

  String format() {
    final s = _b32encode(bytes);
    return [
      for (var i = 0; i < s.length; i += 4)
        s.substring(i, i + 4 > s.length ? s.length : i + 4),
    ].join('-');
  }

  /// Accepts dashes/spaces/lowercase. Throws [FormatException] if invalid.
  static RecoveryKey parse(String text) {
    final s = text.replaceAll(RegExp(r'[\s-]'), '').toUpperCase();
    final bytes = _b32decode(s);
    if (bytes.length != 32) {
      throw const FormatException('Recovery key must be 256 bits');
    }
    return RecoveryKey(bytes);
  }
}

String _b32encode(Uint8List data) {
  final out = StringBuffer();
  var buffer = 0, bits = 0;
  for (final b in data) {
    buffer = (buffer << 8) | b;
    bits += 8;
    while (bits >= 5) {
      out.write(_alphabet[(buffer >> (bits - 5)) & 31]);
      bits -= 5;
    }
    buffer &= (1 << bits) - 1;
  }
  if (bits > 0) out.write(_alphabet[(buffer << (5 - bits)) & 31]);
  return out.toString();
}

Uint8List _b32decode(String s) {
  final out = <int>[];
  var buffer = 0, bits = 0;
  for (final ch in s.split('')) {
    final v = _alphabet.indexOf(ch);
    if (v < 0) throw FormatException('Invalid character "$ch" in recovery key');
    buffer = (buffer << 5) | v;
    bits += 5;
    if (bits >= 8) {
      out.add((buffer >> (bits - 8)) & 255);
      bits -= 8;
    }
    buffer &= (1 << bits) - 1;
  }
  return Uint8List.fromList(out);
}
