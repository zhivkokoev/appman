import 'dart:math';

class PasswordOptions {
  const PasswordOptions({
    this.length = 24,
    this.lower = true,
    this.upper = true,
    this.digits = true,
    this.symbols = true,
    this.avoidAmbiguous = true,
  });
  final int length;
  final bool lower, upper, digits, symbols, avoidAmbiguous;
}

const _lower = 'abcdefghijklmnopqrstuvwxyz';
const _upper = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
const _digits = '0123456789';
const _symbols = '!@#\$%^&*()-_=+[]{};:,.?/~';
const _ambiguous = 'Il1O0o';

/// Cryptographically random password; guarantees one character of every enabled class.
String generatePassword([
  PasswordOptions o = const PasswordOptions(),
  Random? random,
]) {
  final rnd = random ?? Random.secure();
  String clean(String s) => o.avoidAmbiguous
      ? s.split('').where((c) => !_ambiguous.contains(c)).join()
      : s;
  final classes = <String>[
    if (o.lower) clean(_lower),
    if (o.upper) clean(_upper),
    if (o.digits) clean(_digits),
    if (o.symbols) _symbols,
  ];
  if (classes.isEmpty) {
    throw ArgumentError('Select at least one character class');
  }
  if (o.length < classes.length) {
    throw ArgumentError('Length too short for the selected classes');
  }
  final all = classes.join();
  final chars = <String>[for (final c in classes) c[rnd.nextInt(c.length)]];
  while (chars.length < o.length) {
    chars.add(all[rnd.nextInt(all.length)]);
  }
  // Fisher–Yates shuffle so the guaranteed characters are not always first.
  for (var i = chars.length - 1; i > 0; i--) {
    final j = rnd.nextInt(i + 1);
    final t = chars[i];
    chars[i] = chars[j];
    chars[j] = t;
  }
  return chars.join();
}

/// Rough strength 0..4 for the credential report (length + variety), independent of the master password rules.
int secretStrength(String s) {
  if (s.isEmpty) return 0;
  var classes = 0;
  for (final re in [r'[a-z]', r'[A-Z]', r'\d', r'[^A-Za-z0-9]']) {
    if (RegExp(re).hasMatch(s)) classes++;
  }
  var score = 0;
  if (s.length >= 8) score++;
  if (s.length >= 12) score++;
  if (s.length >= 16) score++;
  if (classes >= 3) score++;
  if (RegExp(r'^(.)\1+$').hasMatch(s)) return 0;
  return score.clamp(0, 4);
}
