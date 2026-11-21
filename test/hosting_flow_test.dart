import 'dart:io';

import 'package:appman/app_controller.dart';
import 'package:appman/core/crypto/kdf.dart';
import 'package:appman/core/vault/vault_service.dart';
import 'package:appman/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class FastKdf extends DartArgon2Kdf {
  @override
  Future<KdfParams> calibrate({
    int targetMs = 700,
    int memoryKiB = 262144,
    int parallelism = 4,
  }) async => KdfParams(
    memoryKiB: 64,
    iterations: 1,
    parallelism: 1,
    salt: randomBytes(16),
  );
}

void main() {
  testWidgets('repository, environment with new hosting target, reverse view', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final dir = Directory.systemTemp.createTempSync('appman_hflow_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final controller = AppController(
      VaultService(VaultPaths(dir.path), FastKdf()),
    );
    await tester.runAsync(
      () => controller.createVault('a long passphrase here'),
    );
    controller.acknowledgeRecoveryKey();
    controller.applications.create(name: 'My Shop');

    await tester.pumpWidget(AppManApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationRail),
        matching: find.text('Applications'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('My Shop'));
    await tester.pumpAndSettle();

    // Repository: SSH-style input is normalised and recognised as GitHub.
    await tester.tap(find.text('Add').first);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Repository URL'),
      'git@github.com:zk/shop.git',
    );
    await tester.pump();
    expect(find.textContaining('Detected: GitHub · zk/shop'), findsOneWidget);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('zk/shop'), findsOneWidget);
    expect(find.text('Copy SSH'), findsOneWidget);
    expect(find.text('Actions'), findsOneWidget);

    // Environment with a brand new DigitalOcean hosting target.
    await tester.tap(
      find.text('Add').at(1),
    ); // Repositories, Environments, Credentials, Links...
    await tester.pumpAndSettle();
    await tester.tap(find.text('production')); // suggestion chip
    await tester.pump();
    await tester.tap(find.text('New'));
    await tester.pumpAndSettle();
    expect(
      find.widgetWithText(TextField, 'Console URL'),
      findsOneWidget,
    ); // hosting dialog open
    final console = tester.widget<TextField>(
      find.widgetWithText(TextField, 'Console URL'),
    );
    expect(console.controller!.text, 'https://cloud.digitalocean.com');
    await tester.tap(find.text('Save').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'URLs (one per line)'),
      'https://shop.example',
    );
    await tester.tap(find.text('Save').last);
    await tester.pumpAndSettle();
    expect(find.text('production'), findsOneWidget);
    expect(find.text('https://shop.example'), findsOneWidget);
    expect(find.text('Open console'), findsOneWidget);

    // Reverse view on the Hosting tab.
    await tester.tap(find.text('Hosting'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('DigitalOcean'));
    await tester.pumpAndSettle();
    expect(find.text('Runs here'), findsOneWidget);
    expect(find.text('My Shop · production'), findsOneWidget);

    // Jump from the reverse view back to the application.
    await tester.tap(find.text('My Shop · production'));
    await tester.pumpAndSettle();
    expect(find.text('Repositories'), findsOneWidget);

    controller.lock();
  });
}
