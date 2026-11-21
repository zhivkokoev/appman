import 'app_database.dart';

/// User settings (spec F12), persisted in the encrypted `meta` table so they travel with backups.
class SettingsStore {
  SettingsStore(this._db);
  final AppDatabase _db;

  static const defaults = <String, String>{
    'autolock_minutes': '5',
    'clipboard_seconds': '20',
    'reveal_seconds': '15',
    'backup_retention': '10',
    'attachment_max_kb': '1024',
    'backup_on_save': '1',
    'drive_enabled': '0',
    'drive_client_id': '',
    'drive_client_secret': '',
  };

  String get(String key) {
    final r = _db.raw.select('SELECT value FROM meta WHERE key=?', ['s.$key']);
    return r.isEmpty ? (defaults[key] ?? '') : r.first['value'] as String;
  }

  void set(String key, String value) => _db.raw.execute(
    'INSERT INTO meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',
    ['s.$key', value],
  );

  int getInt(String key) =>
      int.tryParse(get(key)) ?? int.parse(defaults[key] ?? '0');
  bool getBool(String key) => get(key) == '1';
  void setBool(String key, bool v) => set(key, v ? '1' : '0');

  // Internal (non-user) state.
  String? getState(String key) {
    final r = _db.raw.select('SELECT value FROM meta WHERE key=?', ['x.$key']);
    return r.isEmpty ? null : r.first['value'] as String;
  }

  void setState(String key, String value) => _db.raw.execute(
    'INSERT INTO meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',
    ['x.$key', value],
  );
}
