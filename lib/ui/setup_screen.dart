import 'package:flutter/material.dart';

import '../app_controller.dart';

/// 0 (weak) .. 4 (strong): length plus character variety. Deliberately simple.
int passwordStrength(String p) {
  if (p.isEmpty) return 0;
  var score = 0;
  if (p.length >= 12) score++;
  if (p.length >= 16) score++;
  if (p.length >= 20) score++;
  final classes = [
    r'[a-z]',
    r'[A-Z]',
    r'\d',
    r'[^A-Za-z0-9]',
  ].where((r) => RegExp(r).hasMatch(p)).length;
  if (classes >= 3) score++;
  if (p.length < 12) return 0;
  return score.clamp(0, 4);
}

const minPasswordLength = 12;

class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key, required this.controller});
  final AppController controller;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _pw = TextEditingController();
  final _pw2 = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _pw.dispose();
    _pw2.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (_pw.text.length < minPasswordLength) {
      setState(
        () => _error =
            'Use at least $minPasswordLength characters (a passphrase works well).',
      );
      return;
    }
    if (_pw.text != _pw2.text) {
      setState(() => _error = 'Passwords do not match.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    await Future<void>.delayed(
      const Duration(milliseconds: 50),
    ); // let the spinner paint
    try {
      await widget.controller.createVault(_pw.text);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not create vault: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = passwordStrength(_pw.text);
    const labels = ['Too weak', 'Weak', 'Fair', 'Good', 'Strong'];
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Create your vault',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Everything is encrypted with your master password. There is no reset: if you lose it, '
                  'only the recovery key (shown next) can open the vault.',
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _pw,
                  obscureText: true,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Master password',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value: _pw.text.isEmpty ? 0 : (s + 1) / 5,
                ),
                const SizedBox(height: 4),
                Text(
                  _pw.text.isEmpty ? '' : labels[s],
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _pw2,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Confirm password',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _busy ? null : _create(),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _busy ? null : _create,
                  child: _busy
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Create vault'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
