import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

final class _DataBlob extends Struct {
  @Uint32()
  external int cbData;
  external Pointer<Uint8> pbData;
}

typedef _ProtectC = Int32 Function(
  Pointer<_DataBlob>,
  Pointer<Utf16>,
  Pointer<_DataBlob>,
  Pointer<Void>,
  Pointer<Void>,
  Uint32,
  Pointer<_DataBlob>,
);
typedef _ProtectD = int Function(
  Pointer<_DataBlob>,
  Pointer<Utf16>,
  Pointer<_DataBlob>,
  Pointer<Void>,
  Pointer<Void>,
  int,
  Pointer<_DataBlob>,
);
typedef _UnprotectC = Int32 Function(
  Pointer<_DataBlob>,
  Pointer<Pointer<Utf16>>,
  Pointer<_DataBlob>,
  Pointer<Void>,
  Pointer<Void>,
  Uint32,
  Pointer<_DataBlob>,
);
typedef _UnprotectD = int Function(
  Pointer<_DataBlob>,
  Pointer<Pointer<Utf16>>,
  Pointer<_DataBlob>,
  Pointer<Void>,
  Pointer<Void>,
  int,
  Pointer<_DataBlob>,
);

/// Windows DPAPI (CryptProtectData): data can only be decrypted by the same Windows user on this machine.
class Dpapi {
  Dpapi._();
  static final Dpapi instance = Dpapi._();

  static const _uiForbidden = 0x1;

  /// App-specific entropy so other programs of the same user cannot trivially unwrap our blobs.
  static final Uint8List _entropy = Uint8List.fromList(
    'AppMan.token.v1'.codeUnits,
  );

  late final _protect = DynamicLibrary.open('crypt32.dll')
      .lookupFunction<_ProtectC, _ProtectD>('CryptProtectData');
  late final _unprotect = DynamicLibrary.open('crypt32.dll')
      .lookupFunction<_UnprotectC, _UnprotectD>('CryptUnprotectData');
  late final _localFree = DynamicLibrary.open('kernel32.dll')
      .lookupFunction<IntPtr Function(IntPtr), int Function(int)>('LocalFree');

  bool get isAvailable => Platform.isWindows;

  Uint8List protect(Uint8List data) => _run(data, protect: true);

  /// Throws [FormatException] if the blob was not protected by this user on this machine.
  Uint8List unprotect(Uint8List data) => _run(data, protect: false);

  Uint8List _run(Uint8List data, {required bool protect}) {
    if (!isAvailable) {
      throw UnsupportedError('DPAPI is only available on Windows');
    }
    final inBlob = calloc<_DataBlob>();
    final entropy = calloc<_DataBlob>();
    final out = calloc<_DataBlob>();
    final inBuf = calloc<Uint8>(data.isEmpty ? 1 : data.length);
    final entBuf = calloc<Uint8>(_entropy.length);
    try {
      inBuf.asTypedList(data.length).setAll(0, data);
      entBuf.asTypedList(_entropy.length).setAll(0, _entropy);
      inBlob.ref
        ..cbData = data.length
        ..pbData = inBuf;
      entropy.ref
        ..cbData = _entropy.length
        ..pbData = entBuf;
      final ok = protect
          ? _protect(
              inBlob,
              nullptr,
              entropy,
              nullptr,
              nullptr,
              _uiForbidden,
              out,
            )
          : _unprotect(
              inBlob,
              nullptr,
              entropy,
              nullptr,
              nullptr,
              _uiForbidden,
              out,
            );
      if (ok == 0) {
        throw FormatException(
          protect ? 'DPAPI could not protect the data' : 'DPAPI could not unprotect the data (different user or machine?)',
        );
      }
      final result = Uint8List.fromList(
        out.ref.pbData.asTypedList(out.ref.cbData),
      );
      _localFree(out.ref.pbData.address);
      return result;
    } finally {
      calloc.free(inBlob);
      calloc.free(entropy);
      calloc.free(out);
      calloc.free(inBuf);
      calloc.free(entBuf);
    }
  }
}

/// Where small secrets such as the Google refresh token are kept.
abstract class TokenStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// One DPAPI-protected file per key inside [dir] (outside the vault: it is not synced or backed up).
class DpapiTokenStore implements TokenStore {
  DpapiTokenStore(this.dir);
  final String dir;

  File _file(String key) => File(
    '$dir${Platform.pathSeparator}${key.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')}.dpapi',
  );

  @override
  Future<String?> read(String key) async {
    final f = _file(key);
    if (!f.existsSync()) return null;
    try {
      return String.fromCharCodes(
        Dpapi.instance.unprotect(f.readAsBytesSync()),
      );
    } on FormatException {
      return null; // unreadable here (other user/machine): treat as "not connected"
    }
  }

  @override
  Future<void> write(String key, String value) async {
    Directory(dir).createSync(recursive: true);
    final f = _file(key);
    final tmp = File('${f.path}.tmp')
      ..writeAsBytesSync(
        Dpapi.instance.protect(Uint8List.fromList(utf8.encode(value))),
        flush: true,
      );
    tmp.renameSync(f.path);
  }

  @override
  Future<void> delete(String key) async {
    final f = _file(key);
    if (f.existsSync()) f.deleteSync();
  }
}

class MemoryTokenStore implements TokenStore {
  final Map<String, String> values = {};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}
