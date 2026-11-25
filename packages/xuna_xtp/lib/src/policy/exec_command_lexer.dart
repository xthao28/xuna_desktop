/// Quote-aware lexer for `exec.run` commands (`ADR-0018`).
///
/// It is not a full shell parser. It splits a command into simple-command
/// segments at every unquoted `;`, newline, `|`, `||`, `&&`, `&`, `(` and
/// `)`, removes quotes and escapes from words, records output-redirect
/// targets, and extracts the bodies of `$(...)`, `` `...` ``, `<(...)` and
/// `>(...)` so the classifier can inspect them too. Anything it cannot
/// represent is flagged so the classifier fails closed.
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

  /// Set when quoting is unbalanced or a heredoc is used.
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

  /// Captures a balanced `(...)` body starting after the opening paren at
  /// [start]; returns the index of the closing paren or -1.
  int captureParen(int start) {
    var depth = 1;
    for (var j = start; j < command.length; j++) {
      final c = command[j];
      if (c == '(') depth++;
      if (c == ')') {
        depth--;
        if (depth == 0) {
          result.substitutions.add(command.substring(start, j));
          return j;
        }
      }
    }
    return -1;
  }

  var i = 0;
  var inSingle = false;
  var inDouble = false;
  while (i < command.length) {
    final c = command[i];
    final next = i + 1 < command.length ? command[i + 1] : '';
    if (inSingle) {
      if (c == "'") {
        inSingle = false;
      } else {
        word.write(c);
      }
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
      final close = command.indexOf('`', i + 1);
      if (close < 0) {
        result.malformed = true;
        break;
      }
      result.substitutions.add(command.substring(i + 1, close));
      wordStarted = true;
      wordExpansion = true;
      i = close + 1;
      continue;
    }
    if (inDouble) {
      if (c == '"') {
        inDouble = false;
      } else if (!windows && c == r'\' && next.isNotEmpty) {
        word.write(next);
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
    if ((!windows && c == r'\') || (windows && c == '^')) {
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
    if ((c == '<' || c == '>') && next == '(') {
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
  if (inSingle || inDouble) result.malformed = true;
  endSegment(nextPiped: false);
  return result;
}
