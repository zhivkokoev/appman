import 'dart:convert';
import 'dart:io';

import 'package:appman/core/platform/win_native.dart';
import 'package:flutter_test/flutter_test.dart';

/// Talks to the real Windows clipboard; skipped elsewhere.
void main() {
  final onWindows = Platform.isWindows;

  test('workstation is not locked while the test runs', () {
    expect(WinNative.instance.isWorkstationLocked(), isFalse);
  }, skip: !onWindows);

  test('sensitive copy lands on the clipboard and carries the history/cloud exclusion formats', () {
    const secret = 'AppMan-test-Σ-ключ-12345'; // Greek + Cyrillic
    expect(WinNative.instance.setClipboardText(secret), isTrue);

    final ps = Process.runSync('powershell', [
      '-NoProfile',
      '-Command',
      r'''
Add-Type -AssemblyName System.Windows.Forms
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$d = [System.Windows.Forms.Clipboard]::GetDataObject()
"TEXT=" + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([System.Windows.Forms.Clipboard]::GetText()))
"EXCL=" + $d.GetDataPresent('ExcludeClipboardContentFromMonitorProcessing')
"HIST=" + $d.GetDataPresent('CanIncludeInClipboardHistory')
"CLOUD=" + $d.GetDataPresent('CanUploadToCloudClipboard')
''',
    ], stdoutEncoding: const SystemEncoding());
    final out = ps.stdout.toString();
    expect(out, contains('TEXT=${base64Encode(utf8.encode(secret))}'));
    expect(out, contains('EXCL=True'));
    expect(
      out,
      contains('HIST=True'),
    ); // format present, with value 0 = "do not include"
    expect(out, contains('CLOUD=True'));
  }, skip: !onWindows);

  test('non-sensitive copy has no exclusion formats', () {
    expect(
      WinNative.instance.setClipboardText(
        'https://example.org',
        sensitive: false,
      ),
      isTrue,
    );
    final ps = Process.runSync('powershell', [
      '-NoProfile',
      '-Command',
      r'''
Add-Type -AssemblyName System.Windows.Forms
$d = [System.Windows.Forms.Clipboard]::GetDataObject()
"EXCL=" + $d.GetDataPresent('ExcludeClipboardContentFromMonitorProcessing')
''',
    ]);
    expect(ps.stdout.toString(), contains('EXCL=False'));
  }, skip: !onWindows);
}
