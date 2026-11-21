import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_controller.dart';

/// Shows a freshly generated recovery key exactly once and requires confirmation.
class RecoveryKeyScreen extends StatefulWidget {
  const RecoveryKeyScreen({super.key, required this.controller, this.onDone});
  final AppController controller;

  /// Overrides the default "acknowledge" action (used when regenerating from Settings).
  final VoidCallback? onDone;

  @override
  State<RecoveryKeyScreen> createState() => _RecoveryKeyScreenState();
}

class _RecoveryKeyScreenState extends State<RecoveryKeyScreen> {
  bool _saved = false;

  @override
  Widget build(BuildContext context) {
    final key = widget.controller.recoveryKeyToShow ?? '';
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Your recovery key',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Print it or write it down and keep it somewhere safe and offline. It is shown only once. '
                  'Anyone holding it can open your vault; without it and your master password, the data is lost.',
                ),
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: Theme.of(context).colorScheme.outline,
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SelectableText(
                    key,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontFamily: 'Consolas',
                      fontSize: 20,
                      letterSpacing: 1.5,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: const Icon(Icons.copy),
                    label: const Text('Copy'),
                    onPressed: () =>
                        Clipboard.setData(ClipboardData(text: key)),
                  ),
                ),
                CheckboxListTile(
                  value: _saved,
                  onChanged: (v) => setState(() => _saved = v ?? false),
                  title: const Text('I have stored the recovery key safely'),
                  controlAffinity: ListTileControlAffinity.leading,
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: _saved
                      ? (widget.onDone ??
                            widget.controller.acknowledgeRecoveryKey)
                      : null,
                  child: const Text('Continue'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
