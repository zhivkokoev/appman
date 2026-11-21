import 'package:flutter/material.dart';

import '../app_controller.dart';

/// Asks for the master password again before showing/exporting secrets in bulk (spec F9).
/// Returns true only if the password is correct.
Future<bool> reauthenticate(
  BuildContext context,
  AppController controller, {
  required String reason,
}) async {
  return await showDialog<bool>(
        context: context,
        builder: (_) => _ReauthDialog(controller: controller, reason: reason),
      ) ??
      false;
}

class _ReauthDialog extends StatefulWidget {
  const _ReauthDialog({required this.controller, required this.reason});
  final AppController controller;
  final String reason;

  @override
  State<_ReauthDialog> createState() => _ReauthDialogState();
}

class _ReauthDialogState extends State<_ReauthDialog> {
  final _pw = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _pw.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final ok = await widget.controller.verifyPassword(_pw.text);
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context, true);
    } else {
      setState(() {
        _busy = false;
        _error = 'Wrong password.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Confirm master password'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.reason),
            const SizedBox(height: 12),
            TextField(
              controller: _pw,
              obscureText: true,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Master password',
                border: const OutlineInputBorder(),
                errorText: _error,
              ),
              onSubmitted: (_) => _busy ? null : _check(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _check,
          child: _busy
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Confirm'),
        ),
      ],
    );
  }
}
