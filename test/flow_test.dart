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
  testWidgets('setup -> recovery key -> create app -> lock -> unlock', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final dir = Directory.systemTemp.createTempSync('appman_flow_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final controller = AppController(
      VaultService(VaultPaths(dir.path), FastKdf()),
    );
    addTearDown(controller.lock);

    await tester.pumpWidget(AppManApp(controller: controller));
    expect(find.text('Create your vault'), findsOneWidget);

    // Too short is rejected.
    await tester.enterText(
      find.widgetWithText(TextField, 'Master password'),
      'short',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Confirm password'),
      'short',
    );
    await tester.tap(find.text('Create vault'));
    await tester.pump();
    expect(find.textContaining('at least 12'), findsOneWidget);

    const pw = 'a long passphrase here';
    await tester.enterText(
      find.widgetWithText(TextField, 'Master password'),
      pw,
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Confirm password'),
      pw,
    );
    await tester.tap(find.text('Create vault'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 2)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Your recovery key'), findsOneWidget);
    final continueBtn = find.widgetWithText(FilledButton, 'Continue');
    expect(
      tester.widget<FilledButton>(continueBtn).onPressed,
      isNull,
    ); // needs confirmation
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    await tester.tap(continueBtn);
    await tester.pumpAndSettle();

    expect(find.text('Dashboard'), findsWidgets); // lands on the dashboard
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationRail),
        matching: find.text('Applications'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('New application'), findsOneWidget);
    await tester.tap(find.text('New application'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'My Shop');
    await tester.enterText(
      find.widgetWithText(TextField, 'Tags (comma separated)'),
      'web, php',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('My Shop'), findsWidgets);

    await tester.tap(find.byIcon(Icons.lock_outline));
    await tester.pumpAndSettle();
    expect(find.text('AppMan is locked'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, 'Master password'),
      pw,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Unlock'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 2)),
    );
    await tester.pumpAndSettle();
    expect(find.text('My Shop'), findsWidgets);

    controller.lock(); // cancels the idle timer before the test's timer invariants are checked
  });
}
