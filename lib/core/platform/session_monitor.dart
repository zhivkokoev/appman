import 'dart:async';

import 'win_native.dart';

/// Locks the vault when the Windows session is locked or the machine slept (spec F7/F11).
///
/// Session lock: polled via OpenInputDesktop (fails while the lock screen/secure desktop is up).
/// Sleep/hibernate: detected as a gap between ticks much larger than the poll interval.
class SessionMonitor {
  SessionMonitor({
    required this.onLockTrigger,
    bool Function()? isLocked,
    DateTime Function()? now,
    this.interval = const Duration(seconds: 2),
    this.sleepGap = const Duration(seconds: 15),
  }) : _isLocked = isLocked ?? WinNative.instance.isWorkstationLocked,
       _now = now ?? DateTime.now;

  final void Function(String reason) onLockTrigger;
  final bool Function() _isLocked;
  final DateTime Function() _now;
  final Duration interval;
  final Duration sleepGap;

  Timer? _timer;
  DateTime? _last;

  void start() {
    _timer?.cancel();
    _last = _now();
    _timer = Timer.periodic(interval, (_) => tick());
  }

  /// Exposed for tests.
  void tick() {
    final now = _now();
    final last = _last;
    _last = now;
    if (last != null && now.difference(last) > sleepGap) {
      onLockTrigger('system resumed from sleep');
      return;
    }
    if (_isLocked()) onLockTrigger('workstation locked');
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}
