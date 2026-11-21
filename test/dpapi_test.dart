import 'dart:io';
import 'dart:typed_data';

import 'package:appman/core/platform/dpapi.dart';
import 'package:flutter_test/flutter_test.dart';

/// Uses the real Windows DPAPI; skipped elsewhere.
void main() {
  final onWindows = Platform.isWindows;

  test('protect/unprotect roundtrip; ciphertext differs from plaintext', () {
    final plain = Uint8List.fromList('1//0g-refresh-token-VALUE'.codeUnits);
    final blob = Dpapi.instance.protect(plain);
    expect(blob, isNot(plain));
    expect(String.fromCharCodes(blob).contains('refresh-token-VALUE'), isFalse);
    expect(Dpapi.instance.unprotect(blob), plain);
  }, skip: !onWindows);

  test('empty data and unicode', () {
    expect(
      Dpapi.instance.unprotect(Dpapi.instance.protect(Uint8List(0))),
      isEmpty,
    );
    final u = Uint8List.fromList(
      'ключ-Σ'.codeUnits.expand((c) => [c & 0xff, c >> 8]).toList(),
    );
    expect(Dpapi.instance.unprotect(Dpapi.instance.protect(u)), u);
  }, skip: !onWindows);

  test('tampered or foreign data is rejected, not returned as garbage', () {
    final blob = Dpapi.instance.protect(Uint8List.fromList([1, 2, 3, 4]));
    final bad = Uint8List.fromList(blob)..[blob.length - 1] ^= 0xff;
    expect(() => Dpapi.instance.unprotect(bad), throwsFormatException);
    expect(
      () => Dpapi.instance.unprotect(Uint8List.fromList([9, 9, 9])),
      throwsFormatException,
    );
  }, skip: !onWindows);

  test(
    'DpapiTokenStore persists encrypted on disk and survives a new instance',
    () async {
      final dir = Directory.systemTemp.createTempSync('appman_tok_');
      addTearDown(() => dir.deleteSync(recursive: true));
      await DpapiTokenStore(dir.path)
          .write('appman.drive.refresh_token', '1//secret-token');
      final onDisk = dir
          .listSync()
          .whereType<File>()
          .map((f) => f.readAsBytesSync())
          .expand((b) => b)
          .toList();
      expect(
        String.fromCharCodes(onDisk).contains('secret-token'),
        isFalse,
        reason: 'not stored in plaintext',
      );
      expect(
        await DpapiTokenStore(dir.path).read('appman.drive.refresh_token'),
        '1//secret-token',
      );
      expect(await DpapiTokenStore(dir.path).read('missing'), isNull);
      await DpapiTokenStore(dir.path).delete('appman.drive.refresh_token');
      expect(
        await DpapiTokenStore(dir.path).read('appman.drive.refresh_token'),
        isNull,
      );
    },
    skip: !onWindows,
  );

  test('a corrupted token file reads as "not connected"', () async {
    final dir = Directory.systemTemp.createTempSync('appman_tok_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final s = DpapiTokenStore(dir.path);
    await s.write('k', 'v');
    final f = dir.listSync().whereType<File>().single;
    f.writeAsBytesSync([1, 2, 3, 4, 5]);
    expect(await s.read('k'), isNull);
  }, skip: !onWindows);
}
