import 'dart:async';

import 'package:flutter/services.dart';

import 'win_native.dart';

abstract class ClipboardBackend {
  /// Writes text; [sensitive] asks the OS not to retain it in history/cloud sync where supported.
  Future<void> setText(String text, {bool sensitive = true});
  Future<String?> getText();
}

class SystemClipboardBackend implements ClipboardBackend {
  @override
  Future<void> setText(String text, {bool sensitive = true}) async {
    if (sensitive && WinNative.instance.setClipboardText(text)) return;
    await Clipboard.setData(ClipboardData(text: text));
  }

  @override
  Future<String?> getText() async =>
      (await Clipboard.getData(Clipboard.kTextPlain))?.text;
}

/// Copies secrets and clears them again after a delay (spec F5/F11) — but only if the clipboard
/// still holds what we put there, so we never wipe something the user copied afterwards.
class SecureClipboard {
  SecureClipboard(this._backend, {required this._clearAfter});
  final ClipboardBackend _backend;
  final Duration Function() _clearAfter;

  Timer? _timer;
  String? _pending;

  /// Seconds left until the pending clear, or null if nothing is pending.
  bool get hasPending => _pending != null;

  Future<void> copy(String text) async {
    _timer?.cancel();
    await _backend.setText(text, sensitive: true);
    _pending = text;
    final d = _clearAfter();
    if (d > Duration.zero) _timer = Timer(d, clearNow);
  }

  /// Plain, non-sensitive copy (URLs etc.): no auto-clear.
  Future<void> copyPlain(String text) =>
      _backend.setText(text, sensitive: false);

  Future<void> clearNow() async {
    _timer?.cancel();
    final mine = _pending;
    _pending = null;
    if (mine == null) return;
    final current = await _backend.getText();
    if (current == mine) await _backend.setText('', sensitive: true);
  }

  void dispose() => _timer?.cancel();
}
