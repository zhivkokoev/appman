import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens an http(s) URL in the default browser. Refuses other schemes.
Future<void> openUrl(BuildContext context, String url) async {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !(uri.scheme == 'https' || uri.scheme == 'http')) {
    _snack(context, 'Not a web URL: $url');
    return;
  }
  if (!await launchUrl(uri, mode: LaunchMode.externalApplication) &&
      context.mounted) {
    _snack(context, 'Could not open $url');
  }
}

void copyText(BuildContext context, String text, {String label = 'Copied'}) {
  Clipboard.setData(ClipboardData(text: text));
  _snack(context, label);
}

void _snack(BuildContext context, String msg) => ScaffoldMessenger.of(context)
    .showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );

Future<bool> confirmDialog(
  BuildContext context,
  String title,
  String body,
  String action,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;

/// Labeled text field used by the edit dialogs.
Widget labeledField(
  String label,
  TextEditingController c, {
  int lines = 1,
  String? error,
  String? hint,
  void Function(String)? onChanged,
}) => Padding(
  padding: const EdgeInsets.only(bottom: 12),
  child: TextField(
    controller: c,
    minLines: lines,
    maxLines: lines,
    onChanged: onChanged,
    decoration: InputDecoration(
      labelText: label,
      hintText: hint,
      border: const OutlineInputBorder(),
      errorText: error,
    ),
  ),
);

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.action});
  final String title;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 8),
    child: Row(
      children: [
        Expanded(
          child: Text(title, style: Theme.of(context).textTheme.titleLarge),
        ),
        ?action,
      ],
    ),
  );
}
