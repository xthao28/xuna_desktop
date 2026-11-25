/// Quote-aware lexer for `exec.run` commands (`ADR-0018`).
///
/// It is not a full shell parser. It splits a command into simple-command
/// segments at every unquoted `;`, newline, `|`, `||`, `&&`, `&`, `(` and
/// `)`, removes quotes and escapes from words, records output-redirect
/// targets, and extracts the bodies of `$(...)`, `` `...` ``, `<(...)` and
/// `>(...)` so the classifier can inspect them too. Anything it cannot
/// represent (unbalanced quotes, heredocs, Windows `^"` or multiline `cmd`,
/// malformed ANSI-C escapes) is flagged so the classifier fails closed.
library;

/// One word after quote removal.
class ExecWord {
  const ExecWord(this.text, {required this.hasExpansion});

  final String text;

  /// The word contains an unquoted or double-quoted `$`/`%VAR%` expansion,
  /// or a command substitution.
  final bool hasExpansion;
}

/// One simple command between separators.
class ExecSegment {
  ExecSegment({required this.pipedFrom});

  /// The segment reads stdin from the previous segment through `|`.
  final bool pipedFrom;
  final List<ExecWord> words = <ExecWord>[];

  /// Targets of `>`, `>>`, `>|`, `&>` redirections.
  final List<ExecWord> writeTargets = <ExecWord>[];

  /// Targets of `<` redirections (read, but still path-checked).
  final List<ExecWord> readTargets = <ExecWord>[];
}

/// Lexer output for one command string.
class ExecLexResult {
  ExecLexResult();

  final List<ExecSegment> segments = <ExecSegment>[];

  /// Bodies of command / process substitutions, classified recursively.
  final List<String> substitutions = <String>[];

  /// Set when quoting is unbalanced, ambiguous (`^"` / multiline on Windows),
  /// or a heredoc is used.
  bool malformed = false;
  bool hasHeredoc = false;
}

/// Splits [command] into segments. [windows] switches to `cmd.exe` rules:
/// `^` escapes, single quotes are literal and `%VAR%` marks an expansion.
ExecLexResult lexExecCommand(String command, {bool windows = false}) {
  final result = ExecLexResult();
  var segment = ExecSegment(pipedFrom: false);
  final word = StringBuffer();
  var wordStarted = false;
  var wordExpansion = false;
  // 0 = word, 1 = write target, 2 = read target.
  var pendingRedirect = 0;

  void endWord() {
    if (!wordStarted) return;
    final w = ExecWord(word.toString(), hasExpansion: wordExpansion);
    if (pendingRedirect == 1) {
      segment.writeTargets.add(w);
    } else if (pendingRedirect == 2) {
      segment.readTargets.add(w);
    } else {
      segment.words.add(w);
    }
    pendingRedirect = 0;
    word.clear();
    wordStarted = false;
    wordExpansion = false;
  }

  void endSegment({required bool nextPiped}) {
    endWord();
    if (pendingRedirect != 0) result.malformed = true;
    pendingRedirect = 0;
    if (segment.words.isNotEmpty ||
        segment.writeTargets.isNotEmpty ||
        segment.readTargets.isNotEmpty) {
      result.segments.add(segment);
    }
    segment = ExecSegment(pipedFrom: nextPiped);
  }

  /// Scans a POSIX backtick substitution starting right after the opening
  /// `` ` `` at [start], respecting `\` escapes (`\$`, `` \` ``, `\\`, and
  /// `\"` when inside double quotes). Returns `(closeIndex, unescapedBody)` or
  /// `null` when unterminated.
  ({int close, String body})? scanBacktick(
    int start, {
    required bool inDoubleQuote,
  }) {
    final buf = StringBuffer();
    var j = start;
    while (j < command.length) {
      final ch = command[j];
      if (ch == r'\') {
        if (j + 1 >= command.length) return null;
        final nx = command[j + 1];
        if (nx == r'$' ||
            nx == '`' ||
            nx == r'\' ||
            (inDoubleQuote && nx == '"')) {
          buf.write(nx);
        } else {
          buf.write(ch);
          buf.write(nx);
        }
        j += 2;
        continue;
      }
      if (ch == '`') {
        return (close: j, body: buf.toString());
      }
      buf.write(ch);
      j++;
    }
    return null;
  }

  /// Finds the matching `)` for a POSIX `$(...)`, `<(...)` or `>(...)`
  /// starting right after `(` at [start], respecting single quotes, ANSI-C
  /// `$'...'`, double quotes, backslash escapes, nested `$(...)` and backticks.
  int scanParenEnd(int start) {
    var depth = 1;
    var j = start;
    var sq = false;
    var asq = false;
    var dq = false;
    while (j < command.length) {
      final ch = command[j];
      final nx = j + 1 < command.length ? command[j + 1] : '';
      if (sq) {
        if (ch == "'") sq = false;
        j++;
        continue;
      }
      if (asq) {
        if (ch == r'\') {
          if (j + 1 >= command.length) return -1;
          j += 2;
          continue;
        }
        if (ch == "'") asq = false;
        j++;
        continue;
      }
      if (dq) {
        if (ch == r'\') {
          if (j + 1 >= command.length) return -1;
          j += 2;
          continue;
        }
        if (ch == r'$' && nx == '(') {
          final inner = scanParenEnd(j + 2);
          if (inner < 0) return -1;
          j = inner + 1;
          continue;
        }
        if (ch == '`') {
          final bt = scanBacktick(j + 1, inDoubleQuote: true);
          if (bt == null) return -1;
          j = bt.close + 1;
          continue;
        }
        if (ch == '"') dq = false;
        j++;
        continue;
      }
      if (ch == r'\') {
        if (j + 1 >= command.length) return -1;
        j += 2;
        continue;
      }
      if (ch == r'$' && nx == "'") {
        asq = true;
        j += 2;
        continue;
      }
      if (ch == "'") {
        sq = true;
        j++;
        continue;
      }
      if (ch == '"') {
        dq = true;
        j++;
        continue;
      }
      if (ch == '`') {
        final bt = scanBacktick(j + 1, inDoubleQuote: false);
        if (bt == null) return -1;
        j = bt.close + 1;
        continue;
      }
      if (ch == '(') {
        depth++;
      } else if (ch == ')') {
        depth--;
        if (depth == 0) return j;
      }
      j++;
    }
    return -1;
  }

  /// Captures a balanced `(...)` body starting after `(` at [start]; returns
  /// the index of the closing paren or -1.
  int captureParen(int start) {
    final close = scanParenEnd(start);
    if (close < 0) return -1;
    result.substitutions.add(command.substring(start, close));
    return close;
  }

  /// Decodes one ANSI-C `$'...'` escape starting at `\` index [pos], writes the
  /// decoded character to [word], and returns the next index (or -1 if
  /// truncated/malformed).
  int consumeAnsiEscape(int pos) {
    if (pos + 1 >= command.length) return -1;
    final esc = command[pos + 1];
    switch (esc) {
      case "'":
      case '"':
      case r'\':
      case '?':
        word.write(esc);
        return pos + 2;
      case 'a':
        word.writeCharCode(0x07);
        return pos + 2;
      case 'b':
        word.writeCharCode(0x08);
        return pos + 2;
      case 'e':
      case 'E':
        word.writeCharCode(0x1B);
        return pos + 2;
      case 'f':
        word.writeCharCode(0x0C);
        return pos + 2;
      case 'n':
        word.write('\n');
        return pos + 2;
      case 'r':
        word.write('\r');
        return pos + 2;
      case 't':
        word.write('\t');
        return pos + 2;
      case 'v':
        word.writeCharCode(0x0B);
        return pos + 2;
      case 'x':
        final end = _scanHexDigits(command, pos + 2, 2);
        if (end == pos + 2) {
          result.malformed = true;
          return pos + 2;
        }
        final code = int.parse(command.substring(pos + 2, end), radix: 16);
        word.writeCharCode(code);
        return end;
      case 'u':
      case 'U':
        final maxDigits = esc == 'u' ? 4 : 8;
        final end = _scanHexDigits(command, pos + 2, maxDigits);
        if (end == pos + 2) {
          result.malformed = true;
          return pos + 2;
        }
        final code = int.parse(command.substring(pos + 2, end), radix: 16);
        if (code >= 0 && code <= 0x10FFFF) {
          word.writeCharCode(code);
        } else {
          result.malformed = true;
        }
        return end;
      case 'c':
        if (pos + 2 >= command.length) return -1;
        wordExpansion = true;
        word.writeCharCode(command.codeUnitAt(pos + 2) & 0x1F);
        return pos + 3;
      default:
        if (_isOctalDigit(esc)) {
          var end = pos + 1;
          while (end < command.length &&
              end < pos + 4 &&
              _isOctalDigit(command[end])) {
            end++;
          }
          final code =
              int.parse(command.substring(pos + 1, end), radix: 8) & 0xFF;
          word.writeCharCode(code);
          return end;
        }
        word.write(r'\');
        word.write(esc);
        return pos + 2;
    }
  }

  var i = 0;
  var inSingle = false;
  var inAnsiSingle = false;
  var inDouble = false;
  while (i < command.length) {
    final c = command[i];
    final next = i + 1 < command.length ? command[i + 1] : '';
    if (windows && (c == '\n' || c == '\r')) {
      // `cmd.exe /c` stops or mis-parses multiline strings: fail closed.
      result.malformed = true;
      endSegment(nextPiped: false);
      i++;
      continue;
    }
    if (inSingle) {
      if (c == "'") {
        inSingle = false;
      } else {
        word.write(c);
      }
      i++;
      continue;
    }
    if (inAnsiSingle) {
      if (c == "'") {
        inAnsiSingle = false;
        i++;
        continue;
      }
      if (c == r'\') {
        final nextIdx = consumeAnsiEscape(i);
        if (nextIdx < 0) {
          result.malformed = true;
          break;
        }
        i = nextIdx;
        continue;
      }
      word.write(c);
      i++;
      continue;
    }
    if (!windows && c == r'$' && next == '(') {
      final close = captureParen(i + 2);
      if (close < 0) {
        result.malformed = true;
        break;
      }
      wordStarted = true;
      wordExpansion = true;
      word.write(r'$()');
      i = close + 1;
      continue;
    }
    if (!windows && c == '`') {
      final bt = scanBacktick(i + 1, inDoubleQuote: inDouble);
      if (bt == null) {
        result.malformed = true;
        break;
      }
      result.substitutions.add(bt.body);
      wordStarted = true;
      wordExpansion = true;
      i = bt.close + 1;
      continue;
    }
    if (inDouble) {
      if (c == '"') {
        inDouble = false;
      } else if (!windows && c == r'\' && next.isNotEmpty) {
        if (next != '\n') word.write(next);
        i++;
      } else {
        if (c == r'$' || (windows && c == '%')) wordExpansion = true;
        word.write(c);
      }
      i++;
      continue;
    }
    if (c == ' ' || c == '\t' || c == '\r') {
      endWord();
      i++;
      continue;
    }
    if (!windows && c == '#' && !wordStarted) {
      final eol = command.indexOf('\n', i);
      i = eol < 0 ? command.length : eol;
      continue;
    }
    if (!windows && c == r'$' && next == "'") {
      inAnsiSingle = true;
      wordStarted = true;
      i += 2;
      continue;
    }
    if ((!windows && c == r'\') || (windows && c == '^')) {
      if (windows && (next.isEmpty || next == '"')) {
        // Caret before `"` or trailing caret in `cmd.exe` is quote-phase
        // ambiguous (and historically abused for bypasses): fail closed to R3.
        result.malformed = true;
      }
      if (next.isNotEmpty && next != '\n') {
        word.write(next);
        wordStarted = true;
      }
      i += 2;
      continue;
    }
    if (c == "'" && !windows) {
      inSingle = true;
      wordStarted = true;
      i++;
      continue;
    }
    if (c == '"') {
      inDouble = true;
      wordStarted = true;
      i++;
      continue;
    }
    if (c == '\n' || c == ';') {
      endSegment(nextPiped: false);
      i++;
      continue;
    }
    if (c == '|') {
      if (next == '|') {
        endSegment(nextPiped: false);
        i += 2;
      } else {
        endSegment(nextPiped: true);
        i += next == '&' ? 2 : 1;
      }
      continue;
    }
    if (c == '&') {
      if (next == '>') {
        endWord();
        pendingRedirect = 1;
        i += command.startsWith('&>>', i) ? 3 : 2;
        continue;
      }
      endSegment(nextPiped: false);
      i += next == '&' ? 2 : 1;
      continue;
    }
    if (!windows && (c == '<' || c == '>') && next == '(') {
      final close = captureParen(i + 2);
      if (close < 0) {
        result.malformed = true;
        break;
      }
      endWord();
      i = close + 1;
      continue;
    }
    if (c == '>' || c == '<') {
      // A word made only of digits right before the operator is an fd number.
      if (wordStarted && RegExp(r'^\d+$').hasMatch(word.toString())) {
        word.clear();
        wordStarted = false;
        wordExpansion = false;
      } else {
        endWord();
      }
      var j = i + 1;
      if (c == '<' && command.startsWith('<<', i)) {
        result.hasHeredoc = true;
        j = command.startsWith('<<<', i) ? i + 3 : i + 2;
        pendingRedirect = 2;
        i = j;
        continue;
      }
      if (c == '>' &&
          j < command.length &&
          (command[j] == '>' || command[j] == '|')) {
        j++;
      }
      if (j < command.length && command[j] == '&') {
        // `>&2`, `2>&1`, `<&0`: duplicates a descriptor, no file target.
        j++;
        while (j < command.length && RegExp(r'[0-9-]').hasMatch(command[j])) {
          j++;
        }
        i = j;
        continue;
      }
      pendingRedirect = c == '>' ? 1 : 2;
      i = j;
      continue;
    }
    if (c == '(' || c == ')') {
      endSegment(nextPiped: false);
      i++;
      continue;
    }
    if (c == r'$' || (windows && (c == '%' || c == '!'))) wordExpansion = true;
    word.write(c);
    wordStarted = true;
    i++;
  }
  if (inSingle || inAnsiSingle || inDouble) result.malformed = true;
  endSegment(nextPiped: false);
  return result;
}

bool _isHexDigit(String ch) {
  final u = ch.codeUnitAt(0);
  return (u >= 0x30 && u <= 0x39) ||
      (u >= 0x41 && u <= 0x46) ||
      (u >= 0x61 && u <= 0x66);
}

bool _isOctalDigit(String ch) {
  final u = ch.codeUnitAt(0);
  return u >= 0x30 && u <= 0x37;
}

int _scanHexDigits(String s, int start, int maxLen) {
  var end = start;
  while (end < s.length && end < start + maxLen && _isHexDigit(s[end])) {
    end++;
  }
  return end;
}
