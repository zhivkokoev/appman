import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Minimal dart:ffi bindings for the few Win32 calls AppMan needs.
/// Everything here is a no-op / returns a neutral value on other platforms.
class WinNative {
  WinNative._() {
    if (!Platform.isWindows) return;
    final user32 = DynamicLibrary.open('user32.dll');
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    _openClipboard = user32
        .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
          'OpenClipboard',
        );
    _closeClipboard = user32.lookupFunction<Int32 Function(), int Function()>(
      'CloseClipboard',
    );
    _emptyClipboard = user32.lookupFunction<Int32 Function(), int Function()>(
      'EmptyClipboard',
    );
    _setClipboardData = user32
        .lookupFunction<
          IntPtr Function(Uint32, IntPtr),
          int Function(int, int)
        >('SetClipboardData');
    _registerFormat = user32
        .lookupFunction<
          Uint32 Function(Pointer<Utf16>),
          int Function(Pointer<Utf16>)
        >('RegisterClipboardFormatW');
    _openInputDesktop = user32
        .lookupFunction<
          IntPtr Function(Uint32, Int32, Uint32),
          int Function(int, int, int)
        >('OpenInputDesktop');
    _closeDesktop = user32
        .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
          'CloseDesktop',
        );
    _globalAlloc = kernel32
        .lookupFunction<
          IntPtr Function(Uint32, IntPtr),
          int Function(int, int)
        >('GlobalAlloc');
    _globalLock = kernel32
        .lookupFunction<
          Pointer<Void> Function(IntPtr),
          Pointer<Void> Function(int)
        >('GlobalLock');
    _globalUnlock = kernel32
        .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
          'GlobalUnlock',
        );
    _globalFree = kernel32
        .lookupFunction<IntPtr Function(IntPtr), int Function(int)>(
          'GlobalFree',
        );
  }
  static final WinNative instance = WinNative._();

  late final int Function(int) _openClipboard;
  late final int Function() _closeClipboard;
  late final int Function() _emptyClipboard;
  late final int Function(int, int) _setClipboardData;
  late final int Function(Pointer<Utf16>) _registerFormat;
  late final int Function(int, int, int) _openInputDesktop;
  late final int Function(int) _closeDesktop;
  late final int Function(int, int) _globalAlloc;
  late final Pointer<Void> Function(int) _globalLock;
  late final int Function(int) _globalUnlock;
  late final int Function(int) _globalFree;

  static const _cfUnicodeText = 13;
  static const _gmemMoveable = 0x0002;
  static const _desktopSwitchDesktop = 0x0100;

  /// Allocates a movable global block with [bytes]; returns the handle (0 on failure).
  int _alloc(List<int> bytes) {
    final h = _globalAlloc(_gmemMoveable, bytes.length);
    if (h == 0) return 0;
    final p = _globalLock(h).cast<Uint8>();
    p.asTypedList(bytes.length).setAll(0, bytes);
    _globalUnlock(h);
    return h;
  }

  /// Puts [text] on the clipboard. With [sensitive], also asks Windows to keep it out of
  /// clipboard history (Win+V), cloud clipboard sync and clipboard monitors.
  /// Returns false if the clipboard could not be opened (e.g. held by another app).
  bool setClipboardText(String text, {bool sensitive = true}) {
    if (!Platform.isWindows) return false;
    // Retry briefly: another process may hold the clipboard open.
    var opened = false;
    for (var i = 0; i < 10 && !opened; i++) {
      opened = _openClipboard(0) != 0;
      if (!opened) sleep(const Duration(milliseconds: 20));
    }
    if (!opened) return false;
    try {
      _emptyClipboard();
      final units = text.codeUnits;
      final bytes = <int>[
        for (final u in units) ...[u & 0xff, u >> 8],
        0,
        0,
      ]; // UTF-16LE + NUL
      final h = _alloc(bytes);
      if (h == 0) return false;
      if (_setClipboardData(_cfUnicodeText, h) == 0) {
        _globalFree(h);
        return false;
      }
      if (sensitive) {
        for (final (name, value) in const [
          ('ExcludeClipboardContentFromMonitorProcessing', 1),
          ('CanIncludeInClipboardHistory', 0),
          ('CanUploadToCloudClipboard', 0),
        ]) {
          final fmtName = name.toNativeUtf16();
          final fmt = _registerFormat(fmtName);
          calloc.free(fmtName);
          if (fmt == 0) continue;
          final hv = _alloc([value, 0, 0, 0]);
          if (hv != 0 && _setClipboardData(fmt, hv) == 0) _globalFree(hv);
        }
      }
      return true;
    } finally {
      _closeClipboard();
    }
  }

  /// True when the interactive desktop is not accessible, i.e. the workstation is locked
  /// (or a secure desktop such as UAC is showing). False on non-Windows platforms.
  bool isWorkstationLocked() {
    if (!Platform.isWindows) return false;
    final h = _openInputDesktop(0, 0, _desktopSwitchDesktop);
    if (h == 0) return true;
    _closeDesktop(h);
    return false;
  }
}
