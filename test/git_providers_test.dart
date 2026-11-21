import 'package:appman/core/providers/git_providers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RepoRef.parse', () {
    test('https URL with and without .git', () {
      for (final u in [
        'https://github.com/zk/shop',
        'https://github.com/zk/shop.git',
        'https://github.com/zk/shop/',
        'https://www.github.com/zk/shop/tree/main/src',
        '  https://github.com/zk/shop  ',
      ]) {
        final r = RepoRef.parse(u)!;
        expect(
          [r.provider, r.owner, r.name],
          [GitProvider.github, 'zk', 'shop'],
          reason: u,
        );
      }
    });

    test('scp-style and ssh:// URLs', () {
      expect(RepoRef.parse('git@github.com:zk/shop.git')!.fullName, 'zk/shop');
      final r = RepoRef.parse('ssh://git@github.com/zk/shop.git')!;
      expect(r.fullName, 'zk/shop');
      expect(r.host, 'github.com');
    });

    test('owner/repo shorthand is GitHub', () {
      final r = RepoRef.parse('zk/my.repo-1')!;
      expect(r.provider, GitProvider.github);
      expect(r.name, 'my.repo-1');
    });

    test('derived URLs', () {
      final r = RepoRef.parse('https://github.com/zk/shop')!;
      expect(r.httpsClone, 'https://github.com/zk/shop.git');
      expect(r.sshClone, 'git@github.com:zk/shop.git');
      expect(r.actionsUrl, 'https://github.com/zk/shop/actions');
      expect(r.deployKeysUrl, 'https://github.com/zk/shop/settings/keys');
      expect(
        r.secretsUrl,
        'https://github.com/zk/shop/settings/secrets/actions',
      );
    });

    test('other providers detected, no GitHub deep links', () {
      final gl = RepoRef.parse('https://gitlab.com/g/p.git')!;
      expect(gl.provider, GitProvider.gitlab);
      expect(gl.actionsUrl, isNull);
      expect(
        RepoRef.parse('https://git.example.org/a/b')!.provider,
        GitProvider.other,
      );
      expect(
        RepoRef.parse('git@bitbucket.org:a/b.git')!.provider,
        GitProvider.bitbucket,
      );
    });

    test('invalid input returns null', () {
      for (final u in [
        '',
        '   ',
        'github.com',
        'https://github.com/onlyowner',
        'not a url',
        'https:///x/y',
      ]) {
        expect(RepoRef.parse(u), isNull, reason: u);
      }
    });
  });
}
