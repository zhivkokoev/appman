import 'dart:typed_data';

import 'package:googleapis/drive/v3.dart' as drive;
import 'package:googleapis_auth/auth_io.dart';
import 'package:http/http.dart' as http;

import '../platform/dpapi.dart';
import 'drive_sync.dart';

/// OAuth for an installed (desktop) Google client with the minimal `drive.appdata` scope.
/// Only the refresh token is persisted, protected with Windows DPAPI (see [TokenStore]).
class GoogleDriveAuth {
  GoogleDriveAuth(this._storage);
  final TokenStore _storage;

  static const scopes = [drive.DriveApi.driveAppdataScope];
  static const _tokenKey = 'appman.drive.refresh_token';

  Future<bool> isConnected() async => (await _storage.read(_tokenKey)) != null;

  /// Opens [openBrowser] with Google's consent URL and waits for the loopback redirect.
  Future<void> connect({
    required String clientId,
    required String clientSecret,
    required void Function(String url) openBrowser,
  }) async {
    final client = await clientViaUserConsent(
      ClientId(clientId, clientSecret),
      scopes,
      openBrowser,
    );
    try {
      final refresh = client.credentials.refreshToken;
      if (refresh == null) {
        throw StateError(
          'Google did not return a refresh token. Remove AppMan from your Google account permissions and try again.',
        );
      }
      await _storage.write(_tokenKey, refresh);
    } finally {
      client.close();
    }
  }

  Future<void> disconnect() => _storage.delete(_tokenKey);

  /// An authenticated HTTP client that refreshes access tokens on demand.
  Future<AuthClient> client({
    required String clientId,
    required String clientSecret,
  }) async {
    final refresh = await _storage.read(_tokenKey);
    if (refresh == null) throw StateError('Google Drive is not connected');
    final expired = AccessCredentials(
      AccessToken(
        'Bearer',
        '',
        DateTime.now().toUtc().subtract(const Duration(hours: 1)),
      ),
      refresh,
      scopes,
    );
    return autoRefreshingClient(
      ClientId(clientId, clientSecret),
      expired,
      http.Client(),
    );
  }
}

/// [DriveBackend] on Google Drive's hidden per-app `appDataFolder`.
class GoogleDriveBackend implements DriveBackend {
  GoogleDriveBackend(AuthClient client)
    : _client = client,
      _api = drive.DriveApi(client);
  final AuthClient _client;
  final drive.DriveApi _api;

  void close() => _client.close();

  @override
  Future<List<RemoteFile>> list() async {
    final out = <RemoteFile>[];
    String? page;
    do {
      final r = await _api.files.list(
        spaces: 'appDataFolder',
        pageSize: 100,
        pageToken: page,
        $fields: 'nextPageToken, files(id,name,createdTime,size,appProperties)',
      );
      for (final f in r.files ?? const <drive.File>[]) {
        out.add(
          RemoteFile(
            id: f.id!,
            name: f.name ?? '',
            createdTime: f.createdTime ?? DateTime.now(),
            size: int.tryParse(f.size ?? '') ?? 0,
            properties: _props(f.appProperties),
          ),
        );
      }
      page = r.nextPageToken;
    } while (page != null);
    return out;
  }

  @override
  Future<RemoteFile> upload(
    String name,
    Uint8List bytes, {
    Map<String, String> properties = const {},
  }) async {
    final f = await _api.files.create(
      drive.File(
        name: name,
        parents: ['appDataFolder'],
        appProperties: properties,
      ),
      uploadMedia: drive.Media(
        Stream.value(bytes),
        bytes.length,
        contentType: 'application/octet-stream',
      ),
      $fields: 'id,name,createdTime,size,appProperties',
    );
    return RemoteFile(
      id: f.id!,
      name: f.name ?? name,
      createdTime: f.createdTime ?? DateTime.now(),
      size: int.tryParse(f.size ?? '') ?? bytes.length,
      properties: f.appProperties == null
          ? properties
          : _props(f.appProperties),
    );
  }

  @override
  Future<Uint8List> download(String id) async {
    final media = await _api.files.get(
      id,
      downloadOptions: drive.DownloadOptions.fullMedia,
    ) as drive.Media;
    final b = BytesBuilder(copy: false);
    await for (final chunk in media.stream) {
      b.add(chunk);
    }
    return b.takeBytes();
  }

  @override
  Future<void> delete(String id) => _api.files.delete(id);
}

Map<String, String> _props(Map<String, String?>? m) => {
  if (m != null)
    for (final e in m.entries)
      if (e.value != null) e.key: e.value!,
};

String describeDriveError(Object e) {
  if (e is drive.DetailedApiRequestError) {
    return 'Google Drive error ${e.status}: ${e.message}';
  }
  return e.toString();
}

/// Quick check used for UI: does this client id/secret look like a Google desktop client?
bool looksLikeGoogleClientId(String s) => RegExp(
  r'^[0-9]+-[a-z0-9]+\.apps\.googleusercontent\.com$',
  caseSensitive: false,
).hasMatch(s.trim());
