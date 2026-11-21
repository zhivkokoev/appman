import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../core/crypto/wrap.dart';
import 'setup_screen.dart' show minPasswordLength;

class UnlockScreen extends StatefulWidget {
  const UnlockScreen({super.key, required this.controller});
  final AppController controller;

  @override
  State<UnlockScreen> createState() => _UnlockScreenState();
}

class _UnlockScreenState extends State<UnlockScreen> {
  final _pw = TextEditingController();
  final _rk = TextEditingController();
  final _newPw = TextEditingController();
  bool _recovery = false;
  bool _busy = false;
  String? _error;
  int _failures = 0;

  @override
  void dispose() {
    _pw.dispose();
    _rk.dispose();
    _newPw.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_recovery && _newPw.text.length < minPasswordLength) {
      setState(
        () => _error =
            'New password needs at least $minPasswordLength characters.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    await Future<void>.delayed(const Duration(milliseconds: 50));
    try {
      if (_recovery) {
        await widget.controller.unlockWithRecovery(_rk.text, _newPw.text);
      } else {
        await widget.controller.unlock(_pw.text);
      }
      _failures = 0;
    } on WrongKeyException {
      _failures++;
      // Local brute-force friction: 1s, 2s, 4s ... capped at 30s.
      final delay = Duration(
        seconds: (1 << (_failures - 1).clamp(0, 5)).clamp(1, 30),
      );
      await Future<void>.delayed(delay);
      if (mounted) {
        setState(
          () => _error = _recovery ? 'Wrong recovery key.' : 'Wrong password.',
        );
      }
    } on FormatException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not open vault: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.lock_outline, size: 48),
                const SizedBox(height: 12),
                Text(
                  'AppMan is locked',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 24),
                if (!_recovery)
                  TextField(
                    controller: _pw,
                    obscureText: true,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: 'Master password',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _busy ? null : _submit(),
                  )
                else ...[
                  TextField(
                    controller: _rk,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: 'Recovery key',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _newPw,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'New master password',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _busy ? null : _submit(),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _busy ? null : _submit,
                  child: _busy
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(
                          _recovery ? 'Recover and set new password' : 'Unlock',
                        ),
                ),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                          _recovery = !_recovery;
                          _error = null;
                        }),
                  child: Text(
                    _recovery ? 'Use master password' : 'Use recovery key',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
