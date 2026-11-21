import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'core/backup/backup_manager.dart';
import 'core/backup/drive_sync.dart';
import 'core/backup/google_drive_backend.dart';
import 'core/backup/local_backup.dart';
import 'core/db/application_repository.dart';
import 'core/db/attachment_store.dart';
import 'core/db/audit_log.dart';
import 'core/db/console_link_store.dart';
import 'core/db/credential_store.dart';
import 'core/db/environment_store.dart';
import 'core/db/hosting_target_store.dart';
import 'core/db/repository_store.dart';
import 'core/db/settings_store.dart';
import 'core/platform/secure_clipboard.dart';
import 'core/platform/token_store_factory.dart';
import 'core/platform/session_monitor.dart';
import 'core/services/export_service.dart';
import 'core/services/report_service.dart';
import 'core/services/search_service.dart';
import 'core/vault/vault_service.dart';

/// UI-facing state: wraps the vault, owns the services that live while it is unlocked
/// (backups, auto-lock, clipboard) and exposes the data stores.
class AppController extends ChangeNotifier {
  AppController(
    this.vault, {
    ClipboardBackend? clipboardBackend,
    GoogleDriveAuth? driveAuth,
    this.enableSessionMonitor = false,
    this.driveFactoryOverride,
    this.backupDebounce = const Duration(seconds: 8),
  }) : driveAuth =
           driveAuth ?? GoogleDriveAuth(platformTokenStore(vault.paths.dir)) {
    vault.addListener(_vaultChanged);
    clipboard = SecureClipboard(
      clipboardBackend ?? SystemClipboardBackend(),
      clearAfter: () => Duration(
        seconds: vault.isUnlocked ? settings.getInt('clipboard_seconds') : 20,
      ),
    );
    if (enableSessionMonitor) {
      _session = SessionMonitor(onLockTrigger: (_) => lock())..start();
    }
  }

  final VaultService vault;
  final GoogleDriveAuth driveAuth;
  final bool enableSessionMonitor;
  final DriveSyncFactory? driveFactoryOverride;
  final Duration backupDebounce;
  late final SecureClipboard clipboard;
  SessionMonitor? _session;

  /// Set right after vault creation; the UI must show it before anything else.
  String? recoveryKeyToShow;

  Timer? _idle;
  BackupManager? backup;
  bool _wasUnlocked = false;

  // ---- data access (valid only while unlocked)
  ApplicationRepository get applications => ApplicationRepository(vault.db);
  RepositoryStore get repositories => RepositoryStore(vault.db);
  EnvironmentStore get environments => EnvironmentStore(vault.db);
  HostingTargetStore get hostingTargets => HostingTargetStore(vault.db);
  CredentialStore get credentials => CredentialStore(vault.db);
  ConsoleLinkStore get consoleLinks => ConsoleLinkStore(vault.db);
  AttachmentStore get attachments => AttachmentStore(vault.db);
  SettingsStore get settings => SettingsStore(vault.db);
  AuditLog get audit => AuditLog(vault.db);
  SearchService get search => SearchService(vault.db);
  ReportService get reports => ReportService(vault.db);
  ExportService get exporter => ExportService(vault.db);

  // ---- vault lifecycle

  Future<void> createVault(String password) async {
    recoveryKeyToShow = await vault.create(password);
    notifyListeners();
  }

  Future<void> regenerateRecoveryKey() async {
    recoveryKeyToShow = await vault.regenerateRecoveryKey();
    notifyListeners();
  }

  Future<void> changePassword(String oldPassword, String newPassword) =>
      vault.changePassword(oldPassword, newPassword);

  /// For re-authentication before exporting secrets (spec F9).
  Future<bool> verifyPassword(String password) =>
      vault.verifyPassword(password);

  void acknowledgeRecoveryKey() {
    recoveryKeyToShow = null;
    notifyListeners();
  }

  Future<void> unlock(String password) => vault.unlockWithPassword(password);

  Future<void> unlockWithRecovery(String recoveryKey, String newPassword) =>
      vault.unlockWithRecoveryKey(recoveryKey, newPassword);

  void lock() {
    _idle?.cancel();
    recoveryKeyToShow = null;
    if (!vault.isUnlocked) return;
    clipboard.clearNow(); // do not leave a copied secret behind
    _stopServices();
    vault.lock();
  }

  /// Reacts to the vault opening/closing (including closes that did not go through [lock]).
  void _vaultChanged() {
    final unlocked = vault.isUnlocked;
    if (unlocked && !_wasUnlocked) _onUnlocked();
    if (!unlocked && _wasUnlocked) _stopServices();
    _wasUnlocked = unlocked;
    notifyListeners();
  }

  void _onUnlocked() {
    _armIdleTimer();
    backup = BackupManager(
      db: vault.db,
      vaultDir: vault.paths.dir,
      keysPath: vault.paths.keys,
      dbPath: vault.paths.db,
      driveFactory: driveFactoryOverride ?? _driveSync,
      debounce: backupDebounce,
    )..addListener(notifyListeners);
    // Defer so listeners attached to the vault see a consistent state first.
    scheduleMicrotask(() => backup?.start());
  }

  void _stopServices() {
    _idle?.cancel();
    backup?.stop();
    backup?.dispose();
    backup = null;
  }

  Future<DriveSync?> _driveSync(SettingsStore s, String deviceId) async {
    final id = s.get('drive_client_id').trim();
    final secret = s.get('drive_client_secret').trim();
    if (id.isEmpty || !await driveAuth.isConnected()) return null;
    final client = await driveAuth.client(clientId: id, clientSecret: secret);
    final backend = GoogleDriveBackend(client);
    return DriveSync(
      backend,
      deviceId: deviceId,
      retention: s.getInt('backup_retention'),
      close: backend.close,
    );
  }

  /// Opens Google's consent page, stores the refresh token and enables Drive backups.
  Future<void> connectDrive() async {
    final s = settings;
    final id = s.get('drive_client_id').trim();
    if (!looksLikeGoogleClientId(id)) {
      throw const FormatException(
        'Enter the OAuth client ID of a "Desktop app" client (…apps.googleusercontent.com).',
      );
    }
    await driveAuth.connect(
      clientId: id,
      clientSecret: s.get('drive_client_secret').trim(),
      openBrowser: (url) =>
          launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
    );
    s.setBool('drive_enabled', true);
    notifyListeners();
    unawaited(backup?.backupNow());
  }

  Future<void> disconnectDrive() async {
    await driveAuth.disconnect();
    settings.setBool('drive_enabled', false);
    notifyListeners();
  }

  // ---- backups: restore

  LocalBackup get localBackups =>
      LocalBackup('${vault.paths.dir}${Platform.pathSeparator}backups');

  /// Replaces the vault with a local backup version and locks. A safety copy of the current vault is kept.
  /// You unlock the restored vault with the password (or recovery key) it had when it was backed up.
  Future<void> restoreFromLocal(BackupVersion v) async {
    final backups = localBackups;
    lock();
    backups.restore(v, dbPath: vault.paths.db, keysPath: vault.paths.keys);
    notifyListeners();
  }

  Future<List<RemoteVersion>> driveVersions() async {
    final sync = await _driveSync(settings, backup?.deviceId ?? '');
    if (sync == null) throw StateError('Google Drive is not connected');
    try {
      return await sync.versions();
    } finally {
      sync.close?.call();
    }
  }

  Future<void> restoreFromDrive(RemoteVersion v) async {
    final sync = await _driveSync(settings, backup?.deviceId ?? '');
    if (sync == null) throw StateError('Google Drive is not connected');
    final backups = localBackups;
    final tmp =
        '${vault.paths.dir}${Platform.pathSeparator}backups${Platform.pathSeparator}downloaded';
    try {
      final downloaded = await sync.download(v, tmp);
      lock();
      backups.restore(
        downloaded,
        dbPath: vault.paths.db,
        keysPath: vault.paths.keys,
      );
    } finally {
      sync.close?.call();
      final d = Directory(tmp);
      if (d.existsSync()) d.deleteSync(recursive: true);
    }
    notifyListeners();
  }

  // ---- idle auto-lock

  /// Call on any user activity.
  void touch() {
    if (vault.isUnlocked) _armIdleTimer();
  }

  void _armIdleTimer() {
    _idle?.cancel();
    final minutes = vault.isUnlocked ? settings.getInt('autolock_minutes') : 5;
    if (minutes <= 0) return; // 0 = never
    _idle = Timer(Duration(minutes: minutes), lock);
  }

  /// Re-reads the timeout after the user changed it in Settings.
  void settingsChanged() {
    if (vault.isUnlocked) _armIdleTimer();
    notifyListeners();
  }

  // ---- helpers shared by the UI

  /// Copies a credential's secret with auto-clear and records the access.
  Future<void> copySecret(Credential c, {String what = 'copy'}) async {
    await clipboard.copy(c.secret);
    credentials.markAccessed(c.id, how: what);
  }

  @override
  void dispose() {
    _idle?.cancel();
    _session?.stop();
    _stopServices();
    clipboard.dispose();
    vault.removeListener(_vaultChanged);
    super.dispose();
  }
}
