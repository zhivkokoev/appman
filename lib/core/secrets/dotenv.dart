class EnvEntry {
  EnvEntry(this.key, this.value);
  final String key;
  final String value;
  @override
  String toString() => '$key=$value';
}

class EnvParseResult {
  EnvParseResult(this.entries, this.errors);
  final List<EnvEntry> entries;

  /// Human readable problems ("line 3: ..."), the rest of the file is still parsed.
  final List<String> errors;
}

final _keyRe = RegExp(r'^[A-Za-z_][A-Za-z0-9_.-]*$');

/// Parses `.env` text: comments, blank lines, optional `export `, single/double quotes,
/// escapes inside double quotes, inline comments after unquoted values, multi-line double-quoted values.
/// Later duplicates win. Never throws.
EnvParseResult parseDotEnv(String text) {
  final map = <String, String>{};
  final order = <String>[];
  final errors = <String>[];
  final lines = text
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n');

  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    if (line.startsWith('export ')) line = line.substring(7).trimLeft();
    final eq = line.indexOf('=');
    if (eq <= 0) {
      errors.add('line ${i + 1}: expected KEY=value');
      continue;
    }
    final key = line.substring(0, eq).trim();
    var raw = line.substring(eq + 1).trimLeft();
    if (!_keyRe.hasMatch(key)) {
      errors.add('line ${i + 1}: invalid key "$key"');
      continue;
    }

    String value;
    if (raw.startsWith('"')) {
      // Double-quoted: may continue on following lines until the closing quote.
      var buf = raw.substring(1);
      var startLine = i;
      var closed = _findClosingQuote(buf);
      while (closed < 0 && i + 1 < lines.length) {
        i++;
        buf = '$buf\n${lines[i]}';
        closed = _findClosingQuote(buf);
      }
      if (closed < 0) {
        errors.add('line ${startLine + 1}: unterminated quote for $key');
        continue;
      }
      value = _unescape(buf.substring(0, closed));
    } else if (raw.startsWith("'")) {
      final end = raw.indexOf("'", 1);
      if (end < 0) {
        errors.add('line ${i + 1}: unterminated quote for $key');
        continue;
      }
      value = raw.substring(1, end);
    } else {
      final hash = raw.indexOf(RegExp(r'\s#'));
      if (hash >= 0) raw = raw.substring(0, hash);
      value = raw.trim();
    }
    if (!map.containsKey(key)) order.add(key);
    map[key] = value;
  }
  return EnvParseResult([for (final k in order) EnvEntry(k, map[k]!)], errors);
}

int _findClosingQuote(String s) {
  for (var i = 0; i < s.length; i++) {
    if (s[i] == r'\') {
      i++;
    } else if (s[i] == '"') {
      return i;
    }
  }
  return -1;
}

String _unescape(String s) {
  final out = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (s[i] == r'\' && i + 1 < s.length) {
      final n = s[++i];
      out.write(switch (n) {
        'n' => '\n',
        'r' => '\r',
        't' => '\t',
        '"' => '"',
        r'\' => r'\',
        _ => '\\$n',
      });
    } else {
      out.write(s[i]);
    }
  }
  return out.toString();
}

/// Serialises entries, quoting only when needed so the output parses back to the same values.
String formatDotEnv(Iterable<EnvEntry> entries) {
  final b = StringBuffer();
  for (final e in entries) {
    b.writeln('${e.key}=${_quote(e.value)}');
  }
  return b.toString();
}

String _quote(String v) {
  if (v.isEmpty) return '';
  final needs =
      RegExp(r'''[\s#"'\\$`]''').hasMatch(v) || v.startsWith('export');
  if (!needs) return v;
  final esc = v
      .replaceAll(r'\', r'\\')
      .replaceAll('"', r'\"')
      .replaceAll('\n', r'\n')
      .replaceAll('\r', r'\r')
      .replaceAll('\t', r'\t');
  return '"$esc"';
}
