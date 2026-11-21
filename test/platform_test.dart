import 'package:appman/core/platform/secure_clipboard.dart';
import 'package:appman/core/platform/session_monitor.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeClipboard implements ClipboardBackend {
  String? text;
  final writes = <String>[];
  @override
  Future<void> setText(String t, {bool sensitive = true}) async {
    text = t;
    writes.add(t);
  }

  @override
  Future<String?> getText() async => text;
}

void main() {
  group('SecureClipboard', () {
    test('clears our value after the delay', () async {
      final fake = FakeClipboard();
      final c = SecureClipboard(
        fake,
        clearAfter: () => const Duration(milliseconds: 50),
      );
      await c.copy('s3cret');
      expect(fake.text, 's3cret');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(fake.text, '');
      expect(c.hasPending, isFalse);
    });

    test('does not wipe something the user copied afterwards', () async {
      final fake = FakeClipboard();
      final c = SecureClipboard(
        fake,
        clearAfter: () => const Duration(milliseconds: 50),
      );
      await c.copy('s3cret');
      fake.text = 'user copied something else';
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(fake.text, 'user copied something else');
    });

    test('a second copy restarts the timer', () async {
      final fake = FakeClipboard();
      final c = SecureClipboard(
        fake,
        clearAfter: () => const Duration(milliseconds: 120),
      );
      await c.copy('one');
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await c.copy('two');
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(fake.text, 'two'); // the first timer would have fired by now
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(fake.text, '');
    });

    test('zero delay disables auto-clear; clearNow works; copyPlain never schedules', () async {
      final fake = FakeClipboard();
      final c = SecureClipboard(fake, clearAfter: () => Duration.zero);
      await c.copy('x');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(fake.text, 'x');
      await c.clearNow();
      expect(fake.text, '');
      await c.copyPlain('https://example.org');
      expect(c.hasPending, isFalse);
    });
  });

  group('SessionMonitor', () {
    test('locks when the workstation is locked', () {
      var locked = false;
      final reasons = <String>[];
      final m = SessionMonitor(
        onLockTrigger: reasons.add,
        isLocked: () => locked,
        now: () => DateTime(2026),
      );
      m.tick();
      expect(reasons, isEmpty);
      locked = true;
      m.tick();
      expect(reasons, ['workstation locked']);
    });

    test('locks after a sleep-sized time gap', () {
      var t = DateTime(2026, 1, 1, 12);
      final reasons = <String>[];
      final m = SessionMonitor(
        onLockTrigger: reasons.add,
        isLocked: () => false,
        now: () => t,
      );
      m.tick();
      t = t.add(const Duration(seconds: 2));
      m.tick();
      expect(reasons, isEmpty);
      t = t.add(const Duration(minutes: 30));
      m.tick();
      expect(reasons.single, contains('sleep'));
    });
  });
}
