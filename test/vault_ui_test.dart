import 'dart:io';

import 'package:appman/app_controller.dart';
import 'package:appman/core/crypto/kdf.dart';
import 'package:appman/core/db/credential_store.dart';
import 'package:appman/core/platform/secure_clipboard.dart';
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

class FakeClipboard implements ClipboardBackend {
  String? text;
  @override
  Future<void> setText(String t, {bool sensitive = true}) async => text = t;
  @override
  Future<String?> getText() async => text;
}

const password = 'a long passphrase here';
const secretValue = 'S3cret-Value!42';

class Harness {
  Harness(this.controller, this.clipboard, this.appId, this.envId);
  final AppController controller;
  final FakeClipboard clipboard;
  final String appId, envId;
}

Future<Harness> boot(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1600, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final dir = Directory.systemTemp.createTempSync('appman_vui_');
  final clip = FakeClipboard();
  final controller = AppController(
    VaultService(VaultPaths(dir.path), FastKdf()),
    clipboardBackend: clip,
  );
  addTearDown(() {
    controller.dispose();
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // a still-open SQLite handle on Windows; the OS temp cleaner will remove it
    }
  });
  await tester.runAsync(() => controller.createVault(password));
  controller.acknowledgeRecoveryKey();
  final app = controller.applications.create(name: 'My Shop');
  final env = controller.environments.create(
    applicationId: app.id,
    name: 'production',
  );
  await tester.pumpWidget(AppManApp(controller: controller));
  await tester.pumpAndSettle();
  return Harness(controller, clip, app.id, env.id);
}

Future<void> openShop(WidgetTester tester) async {
  await tester.tap(
    find.descendant(
      of: find.byType(NavigationRail),
      matching: find.text('Applications'),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('My Shop'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'credential: add, masked by default, reveal, copy, auto-clear, last accessed',
    (tester) async {
      final h = await boot(tester);
      h.controller.settings.set('clipboard_seconds', '1');
      await openShop(tester);

      await tester.tap(
        find.text('Add').at(2),
      ); // Repositories, Environments, Credentials
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Label'),
        'Registrar',
      );
      await tester.enterText(find.widgetWithText(TextField, 'Username'), 'zk');
      await tester.enterText(
        find.widgetWithText(TextField, 'Secret'),
        secretValue,
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.text('Registrar'), findsOneWidget);
      expect(find.text(secretValue), findsNothing, reason: 'masked by default');
      expect(find.text('••••••••••••'), findsOneWidget);

      await tester.tap(find.byTooltip('Reveal'));
      await tester.pump();
      expect(find.text(secretValue), findsOneWidget);
      await tester.tap(find.byTooltip('Hide'));
      await tester.pump();
      expect(find.text(secretValue), findsNothing);

      await tester.tap(find.byTooltip('Copy secret'));
      await tester.pump();
      expect(h.clipboard.text, secretValue);
      final stored = h.controller.credentials
          .listFor(Owner.application(h.appId))
          .single;
      expect(stored.lastAccessedAt, isNotNull);

      await tester.pump(const Duration(seconds: 2)); // auto-clear timer
      await tester.pump();
      expect(
        h.clipboard.text,
        '',
        reason: 'clipboard cleared after the configured delay',
      );

      final actions = h.controller.audit
          .forEntity('credential', stored.id)
          .map((e) => e.action)
          .toSet();
      expect(actions, containsAll(['create', 'copy']));
      h.controller.lock();
    },
  );

  testWidgets('revealed secret hides itself after the configured time', (
    tester,
  ) async {
    final h = await boot(tester);
    h.controller.settings.set('reveal_seconds', '5');
    h.controller.credentials.create(
      owner: Owner.application(h.appId),
      purpose: CredentialPurpose.access,
      type: 'password',
      label: 'Bank',
      secret: secretValue,
    );
    await openShop(tester);
    await tester.tap(find.byTooltip('Reveal'));
    await tester.pump();
    expect(find.text(secretValue), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    expect(find.text(secretValue), findsNothing);
    h.controller.lock();
  });

  testWidgets(
    'runtime secrets: import .env, change, export needs the master password',
    (tester) async {
      final h = await boot(tester);
      await openShop(tester);

      await tester.tap(find.text('Secrets, credentials, links & files'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Import .env'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).last,
        'DB_USER=shop\nDB_PASSWORD=pw-one\n',
      );
      await tester.pump();
      expect(find.textContaining('DB_PASSWORD · added'), findsOneWidget);
      await tester.tap(find.textContaining('Import 2 variable'));
      await tester.pumpAndSettle();
      expect(find.text('DB_PASSWORD'), findsOneWidget);
      expect(find.text('pw-one'), findsNothing);

      // Re-import with a changed value: shown as "updated" in the preview.
      await tester.tap(find.text('Import .env'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).last,
        'DB_USER=shop\nDB_PASSWORD=pw-two\n',
      );
      await tester.pump();
      expect(find.textContaining('DB_PASSWORD · updated'), findsOneWidget);
      expect(find.textContaining('DB_USER · unchanged'), findsOneWidget);
      await tester.tap(find.textContaining('Import 2 variable'));
      await tester.pumpAndSettle();
      final pw = h.controller.credentials
          .listFor(
            Owner.environment(h.envId),
            purpose: CredentialPurpose.runtime,
          )
          .firstWhere((c) => c.keyName == 'DB_PASSWORD');
      expect(pw.secret, 'pw-two');
      expect(h.controller.credentials.history(pw.id).single.secret, 'pw-one');

      // Export: wrong password is refused, right password shows the file.
      await tester.tap(find.text('Export .env'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Master password'),
        'wrong wrong wrong',
      );
      await tester.tap(find.text('Confirm'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 1)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Wrong password.'), findsOneWidget);
      expect(find.textContaining('DB_PASSWORD=pw-two'), findsNothing);

      await tester.enterText(
        find.widgetWithText(TextField, 'Master password'),
        password,
      );
      await tester.tap(find.text('Confirm'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 1)),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('DB_PASSWORD=pw-two'), findsOneWidget);
      await tester.tap(find.text('Copy'));
      await tester.pumpAndSettle();
      expect(h.clipboard.text, contains('DB_PASSWORD=pw-two'));
      h.controller.lock();
    },
  );

  testWidgets(
    'global search finds credentials by name but never by secret value',
    (tester) async {
      final h = await boot(tester);
      h.controller.credentials.create(
        owner: Owner.application(h.appId),
        purpose: CredentialPurpose.access,
        type: 'password',
        label: 'Registrar login',
        secret: secretValue,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Search everything (Ctrl+K)'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'registrar');
      await tester.pump();
      expect(find.text('Registrar login'), findsOneWidget);
      await tester.enterText(find.byType(TextField).last, 'S3cret');
      await tester.pump();
      expect(find.text('Registrar login'), findsNothing);
      expect(find.text('No results.'), findsOneWidget);

      // Selecting a hit opens the application.
      await tester.enterText(find.byType(TextField).last, 'registrar');
      await tester.pump();
      await tester.tap(find.text('Registrar login'));
      await tester.pumpAndSettle();
      expect(find.text('Repositories'), findsOneWidget);
      h.controller.lock();
    },
  );

  testWidgets('dashboard flags expiring credentials and weak secrets', (
    tester,
  ) async {
    final h = await boot(tester);
    h.controller.credentials.create(
      owner: Owner.application(h.appId),
      purpose: CredentialPurpose.access,
      type: 'apiKey',
      label: 'Payment API',
      secret: 'abc123',
      expiresAt: DateTime.now().add(const Duration(days: 5)),
    );
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationRail),
        matching: find.text('Applications'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationRail),
        matching: find.text('Dashboard'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Needs attention'), findsOneWidget);
    expect(find.text('Payment API'), findsWidgets);
    expect(find.textContaining('Weak secrets (1)'), findsOneWidget);
    expect(find.text('No credentials expire within 30 days.'), findsNothing);
    h.controller.lock();
  });

  testWidgets('locking clears a copied secret and stops backups', (
    tester,
  ) async {
    final h = await boot(tester);
    h.controller.credentials.create(
      owner: Owner.application(h.appId),
      purpose: CredentialPurpose.access,
      type: 'password',
      label: 'X',
      secret: secretValue,
    );
    final c = h.controller.credentials.listAll().single;
    await tester.runAsync(() => h.controller.copySecret(c));
    expect(h.clipboard.text, secretValue);
    expect(h.controller.backup, isNotNull);
    await tester.runAsync(() async {
      h.controller.lock();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(
      h.clipboard.text,
      '',
      reason: 'a copied secret must not outlive the unlocked session',
    );
    expect(h.controller.backup, isNull);
    expect(find.text('AppMan is locked'), findsOneWidget);
  });
}
