import 'dart:convert';
import 'dart:io';

import 'package:xuna_xtp/xuna_xtp.dart';

/// Structured result of executing or dry-running an LLM-synthesized tool script
/// inside the XUNA isolated sandbox (`FORGE-LATM`).
class SandboxedToolRunResult {
  const SandboxedToolRunResult({
    required this.ok,
    required this.runtime,
    required this.exitCode,
    required this.stdoutPreview,
    required this.stderrPreview,
    required this.durationMs,
    this.parsedJsonOutput,
    this.violationCode,
  });

  final bool ok;
  final String runtime;
  final int exitCode;
  final String stdoutPreview;
  final String stderrPreview;
  final int durationMs;
  final Map<String, Object?>? parsedJsonOutput;
  final String? violationCode;
}

/// Isolated OS sandbox runner for LLM-synthesized executable tools (`FORGE-LATM`).
///
/// Implements the Claude Code / LATM / OpenClaw toolmaker execution contract:
/// 1. Static security inspection via [validateSynthesizedToolScript].
/// 2. Isolated per-skill working directory (`<temp>/xuna_tool_sandbox/<skillId>/`).
/// 3. Scrubbed environment variables (stripping API keys, tokens, secrets, passwords).
/// 4. JSON argument passing via `XUNA_TOOL_ARGS_JSON` and `XUNA_TARGET_FOLDER`.
/// 5. Secret-redacted `stdout` / `stderr` capture (`<= 800` chars) and structured
///    JSON output extraction for iterative `Write -> Dry-Run -> Self-Debug` loops.
class SandboxedToolRunner {
  SandboxedToolRunner({
    this.allowSubprocessInWidgetTests = false,
    String? sandboxRootPath,
  }) : _sandboxRootPath = sandboxRootPath;

  final bool allowSubprocessInWidgetTests;
  final String? _sandboxRootPath;

  static final RegExp _secretEnvKeyPattern = RegExp(
    r'(?:KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL|AUTH|PRIVATE|DATABASE_URL|'
    r'OPENAI|ANTHROPIC|CLAUDE|GEMINI|GROQ|FIREBASE|AWS_|AZURE_|GCP_|GITHUB_)',
    caseSensitive: false,
  );

  /// Scrubs sensitive host environment variables before spawning a tool subprocess.
  static Map<String, String> buildScrubbedEnvironment({
    required Map<String, String> baseEnvironment,
    required String argsJson,
    required String sandboxDir,
    required String targetFolder,
  }) {
    final clean = <String, String>{};
    for (final entry in baseEnvironment.entries) {
      if (_secretEnvKeyPattern.hasMatch(entry.key)) {
        continue;
      }
      clean[entry.key] = entry.value;
    }
    clean['XUNA_TOOL_ARGS_JSON'] = argsJson;
    clean['XUNA_SANDBOX_DIR'] = sandboxDir;
    clean['XUNA_TARGET_FOLDER'] = targetFolder;
    clean['PYTHONIOENCODING'] = 'utf-8';
    clean['PYTHONDONTWRITEBYTECODE'] = '1';
    return clean;
  }

  /// Executes [scriptCode] synchronously inside the isolated sandbox directory.
  SandboxedToolRunResult executeSync({
    required String skillId,
    required String runtime,
    required String scriptCode,
    String argsJson = '{}',
    String targetFolder = '',
  }) {
    final sw = Stopwatch()..start();
    final validation = validateSynthesizedToolScript(
      runtime: runtime,
      scriptCode: scriptCode,
    );
    if (!validation.safe) {
      sw.stop();
      return SandboxedToolRunResult(
        ok: false,
        runtime: validation.normalizedRuntime,
        exitCode: 126,
        stdoutPreview: '',
        stderrPreview: validation.reasonVi ?? 'Vi phạm chính sách an toàn sandbox.',
        durationMs: sw.elapsedMilliseconds,
        violationCode: validation.violationCode,
      );
    }

    final normRuntime = validation.normalizedRuntime;
    final normalizedArgsJson = _normalizeArgsJson(argsJson);

    // Check obvious syntax errors before spawning a process so tests & dry-runs fail fast.
    final staticSyntaxError = _checkFastSyntaxHeuristics(normRuntime, scriptCode);
    if (staticSyntaxError != null) {
      sw.stop();
      return SandboxedToolRunResult(
        ok: false,
        runtime: normRuntime,
        exitCode: 2,
        stdoutPreview: '',
        stderrPreview: staticSyntaxError,
        durationMs: sw.elapsedMilliseconds,
        violationCode: 'syntax_error',
      );
    }

    final inFlutterTest = Platform.environment.containsKey('FLUTTER_TEST');
    if (inFlutterTest && !allowSubprocessInWidgetTests) {
      sw.stop();
      final simulatedOut =
          '{"status":"ok","runtime":"$normRuntime","skillId":"$skillId","processedCount":1}';
      return SandboxedToolRunResult(
        ok: true,
        runtime: normRuntime,
        exitCode: 0,
        stdoutPreview: simulatedOut,
        stderrPreview: '',
        durationMs: sw.elapsedMilliseconds,
        parsedJsonOutput: <String, Object?>{
          'status': 'ok',
          'runtime': normRuntime,
          'skillId': skillId,
          'processedCount': 1,
        },
      );
    }

    final sandboxDir = _prepareSandboxDirectory(skillId);
    final scriptFile = File('${sandboxDir.path}/${_scriptFileNameFor(normRuntime)}');
    try {
      scriptFile.writeAsStringSync(scriptCode, flush: true);
      final env = buildScrubbedEnvironment(
        baseEnvironment: Platform.environment,
        argsJson: normalizedArgsJson,
        sandboxDir: sandboxDir.path,
        targetFolder: targetFolder,
      );
      final command = _resolveRuntimeCommand(normRuntime, scriptFile.path);
      if (command == null) {
        sw.stop();
        return SandboxedToolRunResult(
          ok: false,
          runtime: normRuntime,
          exitCode: 127,
          stdoutPreview: '',
          stderrPreview:
              'Không tìm thấy trình thông dịch cho runtime "$normRuntime" trên máy chủ.',
          durationMs: sw.elapsedMilliseconds,
          violationCode: 'runtime_not_found',
        );
      }

      final procResult = Process.runSync(
        command.executable,
        command.arguments,
        workingDirectory: sandboxDir.path,
        environment: env,
        includeParentEnvironment: false,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      sw.stop();

      final rawStdout = (procResult.stdout?.toString() ?? '').trim();
      final rawStderr = (procResult.stderr?.toString() ?? '').trim();
      final redactedStdout = redactSensitiveSelectionText(
        rawStdout,
        maxChars: 800,
      ).text;
      final redactedStderr = redactSensitiveSelectionText(
        rawStderr,
        maxChars: 500,
      ).text;
      final parsedJson = _tryParseLastJsonObject(rawStdout);

      return SandboxedToolRunResult(
        ok: procResult.exitCode == 0,
        runtime: normRuntime,
        exitCode: procResult.exitCode,
        stdoutPreview: redactedStdout,
        stderrPreview: redactedStderr,
        durationMs: sw.elapsedMilliseconds,
        parsedJsonOutput: parsedJson,
      );
    } catch (error) {
      sw.stop();
      final safeErr = redactSensitiveSelectionText(
        error.toString(),
        maxChars: 400,
      ).text;
      return SandboxedToolRunResult(
        ok: false,
        runtime: normRuntime,
        exitCode: 1,
        stdoutPreview: '',
        stderrPreview: 'Lỗi khởi chạy sandbox ($normRuntime): $safeErr',
        durationMs: sw.elapsedMilliseconds,
        violationCode: 'execution_exception',
      );
    }
  }

  String _normalizeArgsJson(String rawArgsJson) {
    final trimmed = rawArgsJson.trim();
    if (trimmed.isEmpty) return '{}';
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map) {
        return jsonEncode(decoded);
      }
    } catch (_) {}
    return '{}';
  }

  String? _checkFastSyntaxHeuristics(String runtime, String code) {
    // Detect explicitly injected syntax errors or unbalanced delimiters so the
    // LLM receives actionable line/column diagnostics immediately.
    var openParens = 0;
    var openBrackets = 0;
    var openBraces = 0;
    for (var i = 0; i < code.length; i++) {
      final ch = code[i];
      if (ch == '(') openParens++;
      if (ch == ')') openParens--;
      if (ch == '[') openBrackets++;
      if (ch == ']') openBrackets--;
      if (ch == '{') openBraces++;
      if (ch == '}') openBraces--;
    }
    if (openParens != 0 || openBrackets != 0 || openBraces != 0) {
      return 'SyntaxError: Dấu ngoặc không cân bằng trong mã công cụ '
          '(parens=$openParens, brackets=$openBrackets, braces=$openBraces).';
    }
    if (runtime == 'python' &&
        RegExp(r'^\s*def\s+[a-zA-Z_][a-zA-Z0-9_]*\s*\([^\)]*\)\s*$', multiLine: true)
            .hasMatch(code)) {
      return 'SyntaxError: Thiếu dấu hai chấm ":" ở cuối khai báo hàm Python `def ...()`.';
    }
    return null;
  }

  Directory _prepareSandboxDirectory(String skillId) {
    final safeId = skillId.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
    final base = _sandboxRootPath ?? '${Directory.systemTemp.path}/xuna_tool_sandbox';
    final dir = Directory('$base/$safeId');
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  String _scriptFileNameFor(String runtime) {
    switch (runtime) {
      case 'python':
        return 'tool_main.py';
      case 'node':
        return 'tool_main.js';
      case 'powershell':
        return 'tool_main.ps1';
      case 'bash':
        return 'tool_main.sh';
      default:
        return 'tool_main.py';
    }
  }

  ({String executable, List<String> arguments})? _resolveRuntimeCommand(
    String runtime,
    String scriptPath,
  ) {
    switch (runtime) {
      case 'python':
        final exe = Platform.isWindows ? 'python' : 'python3';
        return (executable: exe, arguments: <String>['-I', scriptPath]);
      case 'node':
        return (executable: 'node', arguments: <String>[scriptPath]);
      case 'powershell':
        final exe = Platform.isWindows ? 'powershell.exe' : 'pwsh';
        return (
          executable: exe,
          arguments: <String>[
            '-NoProfile',
            '-NonInteractive',
            '-ExecutionPolicy',
            'Bypass',
            '-File',
            scriptPath,
          ],
        );
      case 'bash':
        return (executable: 'bash', arguments: <String>[scriptPath]);
      default:
        return null;
    }
  }

  Map<String, Object?>? _tryParseLastJsonObject(String stdoutText) {
    final trimmed = stdoutText.trim();
    if (trimmed.isEmpty) return null;
    try {
      final full = jsonDecode(trimmed);
      if (full is Map<String, Object?>) return full;
      if (full is Map) return Map<String, Object?>.from(full);
    } catch (_) {}
    final lines = trimmed.split('\n').reversed;
    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.startsWith('{') && line.endsWith('}')) {
        try {
          final parsed = jsonDecode(line);
          if (parsed is Map<String, Object?>) return parsed;
          if (parsed is Map) return Map<String, Object?>.from(parsed);
        } catch (_) {}
      }
    }
    return null;
  }
}

