import 'package:dargon2_flutter/dargon2_flutter.dart';
import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'core/crypto/kdf.dart';
import 'core/vault/vault_service.dart';
import 'ui/home_screen.dart';
import 'ui/recovery_key_screen.dart';
import 'ui/setup_screen.dart';
import 'ui/unlock_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  DArgon2Flutter.init();
  final controller = AppController(
    VaultService(VaultPaths.defaultLocation(), NativeArgon2Kdf()),
    enableSessionMonitor: true, // lock on Windows lock / sleep
  );
  runApp(AppManApp(controller: controller));
}

class AppManApp extends StatelessWidget {
  const AppManApp({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AppMan',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: Listener(
        // Any pointer/key activity resets the auto-lock timer.
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => controller.touch(),
        onPointerMove: (_) => controller.touch(),
        child: Focus(
          onKeyEvent: (_, _) {
            controller.touch();
            return KeyEventResult.ignored;
          },
          child: ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              if (controller.recoveryKeyToShow != null) {
                return RecoveryKeyScreen(controller: controller);
              }
              if (controller.vault.isUnlocked) {
                return HomeScreen(controller: controller);
              }
              if (controller.vault.exists) {
                return UnlockScreen(controller: controller);
              }
              return SetupScreen(controller: controller);
            },
          ),
        ),
      ),
    );
  }
}
