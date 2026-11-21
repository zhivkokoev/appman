import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' show ClientException;
import 'package:uuid/uuid.dart';

import '../db/app_database.dart';
import '../db/settings_store.dart';
import 'drive_sync.dart';
import 'local_backup.dart';

enum BackupState { idle, pending, running, ok, offline, error, conflict }

/// Creates a Drive transport on demand (null when Drive is not configured/connected).
typedef DriveSyncFactory = Future<DriveSync?> Function(
  SettingsStore settings,
  String deviceId,
);

/// Orchestrates backups (spec F8): debounced on save, on startup, and manual.
///
/// Every backup first writes a local rolling snapshot (always works, offline too); if Drive is enabled the
/// same version is uploaded. Failures never affect normal use; the state is exposed for the UI.
class BackupManager extends ChangeNotifier {
  BackupManager({
    required AppDatabase db,
    required this.vaultDir,
    required this.keysPath,
    required this.dbPath,
    this.driveFactory,
    this.debounce = const Duration(seconds: 8),
    this.retryOffline = const Duration(minutes: 2),
  }) : _db = db,
       settings = SettingsStore(db),
       local = LocalBackup('$vaultDir${Platform.pathSeparator}backups');

  final AppDatabase _db;
  final String vaultDir, keysPath, dbPath;
  final DriveSyncFactory? driveFactory;
  final Duration debounce, retryOffline;
  final SettingsStore settings;
  final LocalBackup local;

  BackupState state = BackupState.idle;
  String? lastError;
  DateTime? lastBackupAt;
  DateTime? lastDriveUploadAt;
  RemoteVersion? conflict;

  StreamSubscription<Object?>? _sub;
  Timer? _debounceTimer, _retryTimer;
  bool _running = false,
      _dirtyWhileRunning = false,
      _disposed = false,
      _stopped = false;

  String get deviceId {
    var id = settings.getState('device_id');
    if (id == null) {
      id = const Uuid().v4();
      settings.setState('device_id', id);
    }
    return id;
  }

  /// Starts watching for changes. Call once after unlock.
  void start() {
    _stopped = false;
    // Ignore `meta`: our own bookkeeping (last backup time, last seen remote version) is written there and
    // must not count as a vault change, or every backup would trigger another one.
    _sub ??= _db.raw.updates.listen((u) {
      if (u.tableName != 'meta') _markDirty();
    });
    final lastMs = int.tryParse(settings.getState('last_backup_ms') ?? '');
    if (lastMs != null) {
      lastBackupAt = DateTime.fromMillisecondsSinceEpoch(lastMs);
    }
    // Startup check: back up if there is none yet, or the vault changed since the last backup.
    // "Changed" is a logical revision (highest change_log id), not the file's mtime: our own bookkeeping
    // writes also touch the file, which would otherwise look like a change on every start.
    final lastRev = int.tryParse(settings.getState('last_backup_rev') ?? '');
    final changed =
        lastBackupAt == null || lastRev == null || _revision() > lastRev;
    if (changed && settings.getBool('backup_on_save')) {
      _markDirty(immediate: true);
    }
  }

  int _revision() =>
      (_db.raw.select('SELECT max(id) m FROM change_log').first['m'] as int?) ??
      0;

  void _markDirty({bool immediate = false}) {
    if (_disposed || _stopped) return;
    if (!immediate && !settings.getBool('backup_on_save')) return;
    if (_running) {
      _dirtyWhileRunning = true;
      return;
    }
    _debounceTimer?.cancel();
    _set(BackupState.pending);
    _debounceTimer = Timer(
      immediate ? Duration.zero : debounce,
      () => backupNow(),
    );
  }

  void _set(BackupState s, {String? error}) {
    state = s;
    lastError = error;
    if (!_disposed) notifyListeners();
  }

  /// Runs a backup now. [forceDrive] overwrites a foreign-installation warning.
  Future<void> backupNow({bool forceDrive = false}) async {
    if (_running || _disposed || _stopped) return;
    _running = true;
    _debounceTimer?.cancel();
    _retryTimer?.cancel();
    _set(BackupState.running);
    try {
      final rev = _revision();
      final version = local.create(_db, keysPath);
      local.prune(settings.getInt('backup_retention'));
      lastBackupAt = version.createdAt;
      settings.setState(
        'last_backup_ms',
        '${version.createdAt.millisecondsSinceEpoch}',
      );
      settings.setState('last_backup_rev', '$rev');

      if (settings.getBool('drive_enabled') && driveFactory != null) {
        final sync = await driveFactory!(settings, deviceId);
        if (sync != null) {
          sync.retention = settings.getInt('backup_retention');
          try {
            final up = await sync.upload(
              version,
              lastSeenRemoteVersion: settings.getState('drive_last_seen'),
              force: forceDrive,
            );
            settings.setState('drive_last_seen', up.version);
            lastDriveUploadAt = DateTime.now();
            conflict = null;
          } on ForeignBackupException catch (e) {
            conflict = e.latest;
            _set(BackupState.conflict);
            return;
          } finally {
            sync.close?.call();
          }
        }
      }
      _set(BackupState.ok);
    } on SocketException catch (e) {
      _set(BackupState.offline, error: e.message);
      _retryTimer = Timer(retryOffline, () => backupNow());
    } on ClientException catch (e) {
      _set(BackupState.offline, error: e.toString());
      _retryTimer = Timer(retryOffline, () => backupNow());
    } catch (e) {
      _set(BackupState.error, error: e.toString());
    } finally {
      _running = false;
      if (_dirtyWhileRunning && !_disposed) {
        _dirtyWhileRunning = false;
        _markDirty();
      }
    }
  }

  /// Acknowledges the "other installation" warning and uploads anyway.
  Future<void> resolveConflictUploadAnyway() => backupNow(forceDrive: true);

  /// Stops watching and cancels timers. Must be called before the database is closed (lock).
  void stop() {
    _stopped = true;
    _sub?.cancel();
    _sub = null;
    _debounceTimer?.cancel();
    _retryTimer?.cancel();
  }

  @override
  void dispose() {
    _disposed = true;
    stop();
    super.dispose();
  }
}
