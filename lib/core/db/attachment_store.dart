import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import 'app_database.dart';
import 'audit_log.dart';
import 'credential_store.dart' show Owner;

class AttachmentTooLargeException implements Exception {
  AttachmentTooLargeException(this.size, this.limit);
  final int size, limit;
  @override
  String toString() =>
      'File is ${(size / 1024).ceil()} KB; the limit is ${(limit / 1024).floor()} KB (see Settings).';
}

/// Attachment metadata (the blob is loaded on demand).
class Attachment {
  Attachment({
    required this.id,
    required this.name,
    required this.mimeType,
    required this.size,
    this.applicationId,
    this.environmentId,
    this.hostingTargetId,
    this.repositoryId,
    this.archived = false,
    this.createdAt,
  });
  final String id, name, mimeType;
  final int size;
  final String? applicationId, environmentId, hostingTargetId, repositoryId;
  final bool archived;
  final DateTime? createdAt;
}

/// Encrypted files (SSH keys, .env, certificates) stored as BLOBs inside the vault (spec F5).
class AttachmentStore {
  AttachmentStore(this._db) : _log = AuditLog(_db);
  final AppDatabase _db;
  final AuditLog _log;
  static const _uuid = Uuid();

  static Attachment _fromRow(Map<String, Object?> r) => Attachment(
    id: r['id'] as String,
    name: r['name'] as String,
    mimeType: r['mime_type'] as String,
    size: r['size'] as int,
    applicationId: r['application_id'] as String?,
    environmentId: r['environment_id'] as String?,
    hostingTargetId: r['hosting_target_id'] as String?,
    repositoryId: r['repository_id'] as String?,
    archived: (r['archived'] as int) == 1,
    createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
  );

  static const _cols =
      'id,name,mime_type,size,application_id,environment_id,hosting_target_id,repository_id,archived,created_at';

  List<Attachment> listFor(Owner owner, {bool archived = false}) => _db.raw
      .select(
        'SELECT $_cols FROM attachments WHERE ${owner.column}=? AND archived=? ORDER BY name COLLATE NOCASE',
        [owner.id, archived ? 1 : 0],
      )
      .map((r) => _fromRow(r))
      .toList();

  List<Attachment> listAll() => _db.raw
      .select(
        'SELECT $_cols FROM attachments WHERE archived=0 ORDER BY name COLLATE NOCASE',
      )
      .map((r) => _fromRow(r))
      .toList();

  Attachment? get(String id) {
    final rows = _db.raw.select('SELECT $_cols FROM attachments WHERE id=?', [
      id,
    ]);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  Uint8List? data(String id) {
    final rows = _db.raw.select('SELECT data FROM attachments WHERE id=?', [
      id,
    ]);
    if (rows.isEmpty) return null;
    _log.record('attachment', id, 'reveal');
    return Uint8List.fromList(rows.first['data'] as List<int>);
  }

  Attachment add({
    required Owner owner,
    required String name,
    required Uint8List bytes,
    required int maxBytes,
    String? mimeType,
  }) {
    if (bytes.length > maxBytes) {
      throw AttachmentTooLargeException(bytes.length, maxBytes);
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = _uuid.v4();
    _db.raw.execute(
      'INSERT INTO attachments(id,name,mime_type,size,data,${owner.column},created_at,updated_at) VALUES(?,?,?,?,?,?,?,?)',
      [
        id,
        name,
        mimeType ?? guessMime(name),
        bytes.length,
        bytes,
        owner.id,
        now,
        now,
      ],
    );
    _log.record('attachment', id, 'create', name);
    return get(id)!;
  }

  void rename(String id, String name) {
    _db.raw.execute('UPDATE attachments SET name=?, updated_at=? WHERE id=?', [
      name,
      DateTime.now().millisecondsSinceEpoch,
      id,
    ]);
    _log.record('attachment', id, 'update', name);
  }

  void setArchived(String id, bool archived) {
    _db.raw.execute(
      'UPDATE attachments SET archived=?, updated_at=? WHERE id=?',
      [archived ? 1 : 0, DateTime.now().millisecondsSinceEpoch, id],
    );
    _log.record('attachment', id, archived ? 'archive' : 'restore');
  }

  void purge(String id) {
    final a = get(id);
    if (a == null) return;
    if (!a.archived) {
      throw StateError('Only archived attachments can be purged');
    }
    _db.raw.execute('DELETE FROM attachments WHERE id=?', [id]);
    _log.record('attachment', id, 'purge', a.name);
  }

  static String guessMime(String name) {
    final n = name.toLowerCase();
    if (n.endsWith('.pem') ||
        n.endsWith('.crt') ||
        n.endsWith('.cer') ||
        n.endsWith('.key')) {
      return 'application/x-pem-file';
    }
    if (n.endsWith('.json')) return 'application/json';
    if (n == '.env' ||
        n.endsWith('.env') ||
        n.startsWith('.env.') ||
        n.endsWith('.txt') ||
        n.endsWith('.md')) {
      return 'text/plain';
    }
    return 'application/octet-stream';
  }

  /// True if the attachment is likely to be text we can preview.
  static bool isTextLike(Attachment a) =>
      a.mimeType.startsWith('text/') ||
      a.mimeType == 'application/json' ||
      a.mimeType == 'application/x-pem-file';
}
