import 'dart:math';

import 'package:appman/core/secrets/dotenv.dart';
import 'package:appman/core/secrets/password_generator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('password generator', () {
    test('length and character classes are respected', () {
      for (var i = 0; i < 50; i++) {
        final p = generatePassword(const PasswordOptions(length: 20));
        expect(p.length, 20);
        expect(RegExp(r'[a-z]').hasMatch(p), isTrue);
        expect(RegExp(r'[A-Z]').hasMatch(p), isTrue);
        expect(RegExp(r'\d').hasMatch(p), isTrue);
        expect(RegExp(r'[^A-Za-z0-9]').hasMatch(p), isTrue);
        expect(
          RegExp(r'[Il1O0o]').hasMatch(p),
          isFalse,
          reason: 'ambiguous chars avoided',
        );
      }
    });

    test('digits only', () {
      final p = generatePassword(
        const PasswordOptions(
          length: 12,
          lower: false,
          upper: false,
          symbols: false,
        ),
      );
      expect(RegExp(r'^\d{12}$').hasMatch(p), isTrue);
    });

    test('invalid options', () {
      expect(
        () => generatePassword(
          const PasswordOptions(
            lower: false,
            upper: false,
            digits: false,
            symbols: false,
          ),
        ),
        throwsArgumentError,
      );
      expect(
        () => generatePassword(const PasswordOptions(length: 2)),
        throwsArgumentError,
      );
    });

    test('passwords differ', () {
      final r = Random(1);
      expect(
        generatePassword(const PasswordOptions(), r),
        isNot(generatePassword(const PasswordOptions(), r)),
      );
    });

    test('strength heuristic', () {
      expect(secretStrength(''), 0);
      expect(secretStrength('aaaaaaaaaaaa'), 0);
      expect(secretStrength('password'), lessThan(2));
      expect(secretStrength(generatePassword()), 4);
    });
  });

  group('dotenv', () {
    test('basic parsing, comments, export, quotes', () {
      final r = parseDotEnv('''
# comment
DB_HOST=localhost
export DB_PORT=5432
EMPTY=
QUOTED="hello world"
SINGLE='no \$expansion here'
INLINE=value # trailing comment
URL=https://x.example/?a=1#frag
''');
      expect(r.errors, isEmpty);
      final m = {for (final e in r.entries) e.key: e.value};
      expect(m['DB_HOST'], 'localhost');
      expect(m['DB_PORT'], '5432');
      expect(m['EMPTY'], '');
      expect(m['QUOTED'], 'hello world');
      expect(m['SINGLE'], r'no $expansion here');
      expect(m['INLINE'], 'value');
      expect(
        m['URL'],
        'https://x.example/?a=1#frag',
      ); // # without a preceding space is part of the value
    });

    test('escapes and multi-line values', () {
      final r = parseDotEnv(
        'A="line1\\nline2"\nKEY="-----BEGIN\nabc\n-----END"\nQ="say \\"hi\\""\n',
      );
      final m = {for (final e in r.entries) e.key: e.value};
      expect(m['A'], 'line1\nline2');
      expect(m['KEY'], '-----BEGIN\nabc\n-----END');
      expect(m['Q'], 'say "hi"');
    });

    test('duplicates: last wins, order of first appearance; CRLF', () {
      final r = parseDotEnv('A=1\r\nB=2\r\nA=3\r\n');
      expect(r.entries.map((e) => '${e.key}=${e.value}'), ['A=3', 'B=2']);
    });

    test('bad lines are reported, rest still parsed', () {
      final r = parseDotEnv('GOOD=1\nnonsense\n1BAD=2\nUNTERM="abc\n');
      expect(r.entries.map((e) => e.key), ['GOOD']);
      expect(r.errors.length, 3);
    });

    test('format -> parse roundtrip for tricky values', () {
      final entries = [
        EnvEntry('PLAIN', 'abc123'),
        EnvEntry('SPACES', 'a b c'),
        EnvEntry('HASH', 'pass#word'),
        EnvEntry('QUOTES', 'he said "hi" and \'bye\''),
        EnvEntry('BACKSLASH', r'C:\path\to'),
        EnvEntry('NEWLINE', 'a\nb'),
        EnvEntry('DOLLAR', r'$HOME'),
        EnvEntry('EMPTY', ''),
      ];
      final back = parseDotEnv(formatDotEnv(entries));
      expect(back.errors, isEmpty);
      expect(
        {for (final e in back.entries) e.key: e.value},
        {for (final e in entries) e.key: e.value},
      );
    });
  });
}
