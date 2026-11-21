/// Git hosting providers. GitHub is first-class (spec F2); others are detected by host only.
enum GitProvider { github, gitlab, bitbucket, other }

extension GitProviderX on GitProvider {
  String get id => name;
  String get label => switch (this) {
    GitProvider.github => 'GitHub',
    GitProvider.gitlab => 'GitLab',
    GitProvider.bitbucket => 'Bitbucket',
    GitProvider.other => 'Other / self-hosted',
  };
  static GitProvider fromId(String id) => GitProvider.values.firstWhere(
    (p) => p.name == id,
    orElse: () => GitProvider.other,
  );
}

/// A parsed repository reference with derived URLs.
class RepoRef {
  RepoRef({
    required this.provider,
    required this.host,
    required this.owner,
    required this.name,
  });
  final GitProvider provider;
  final String host;
  final String owner;
  final String name;

  String get fullName => '$owner/$name';
  String get webUrl => 'https://$host/$owner/$name';
  String get httpsClone => 'https://$host/$owner/$name.git';
  String get sshClone => 'git@$host:$owner/$name.git';

  // GitHub-specific deep links (null for other providers).
  String? get actionsUrl =>
      provider == GitProvider.github ? '$webUrl/actions' : null;
  String? get settingsUrl =>
      provider == GitProvider.github ? '$webUrl/settings' : null;
  String? get deployKeysUrl =>
      provider == GitProvider.github ? '$webUrl/settings/keys' : null;
  String? get secretsUrl => provider == GitProvider.github
      ? '$webUrl/settings/secrets/actions'
      : null;

  static GitProvider detectProvider(String host) {
    final h = host.toLowerCase();
    if (h == 'github.com' || h == 'www.github.com') return GitProvider.github;
    if (h == 'gitlab.com' || h == 'www.gitlab.com') return GitProvider.gitlab;
    if (h == 'bitbucket.org' || h == 'www.bitbucket.org') {
      return GitProvider.bitbucket;
    }
    return GitProvider.other;
  }

  /// Accepts https/http URLs, `git@host:owner/repo(.git)`, `ssh://git@host/owner/repo`,
  /// and the shorthand `owner/repo` (assumed GitHub). Returns null if it cannot be understood.
  static RepoRef? parse(String input) {
    var s = input.trim();
    if (s.isEmpty) return null;

    String? host, path;
    final scp = RegExp(r'^[\w.-]+@([\w.-]+):(.+)$')
        .firstMatch(s); // git@github.com:owner/repo.git
    if (scp != null) {
      host = scp.group(1);
      path = scp.group(2);
    } else if (s.contains('://')) {
      final uri = Uri.tryParse(s);
      if (uri == null || uri.host.isEmpty) return null;
      host = uri.host;
      path = uri.path;
    } else if (RegExp(r'^[\w.-]+/[\w.-]+$').hasMatch(s)) {
      host = 'github.com';
      path = s;
    } else {
      return null;
    }

    final parts = path!.split('/').where((e) => e.isNotEmpty).toList();
    if (parts.length < 2) return null;
    var name = parts[1];
    if (name.endsWith('.git')) name = name.substring(0, name.length - 4);
    if (name.isEmpty) return null;
    return RepoRef(
      provider: detectProvider(host!),
      host: host.toLowerCase().replaceFirst('www.', ''),
      owner: parts[0],
      name: name,
    );
  }
}
