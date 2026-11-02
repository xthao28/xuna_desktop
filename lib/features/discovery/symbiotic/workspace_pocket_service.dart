import 'dart:convert';

import 'package:xuna_xtp/xuna_xtp.dart';

import 'symbiotic_models.dart';

/// Time-Travel Workspace Capsules & Universal Pocket service (`SYM-1` S1.1).
class WorkspacePocketService {
  int _capsuleSeq = 0;
  int _pocketSeq = 0;
  final List<WorkspaceCapsuleEntry> _capsules = <WorkspaceCapsuleEntry>[];
  final List<UniversalPocketItem> _pocketItems = <UniversalPocketItem>[];

  /// Captures a frozen Time-Travel Workspace Capsule (`SYM-1` S1.1).
  WorkspaceCapsuleEntry captureWorkspaceCapsule({
    required String project,
    required String branch,
    required int dirtyCount,
    String? nextStepHint,
    DateTime? nowUtc,
  }) {
    _capsuleSeq++;
    final ts = (nowUtc ?? DateTime.now()).toUtc();
    final safeProject = project.trim().isEmpty ? 'workspace' : project.trim();
    final slug = safeProject
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_-]'), '-')
        .replaceAll(RegExp(r'-+'), '-');
    final capsuleId = 'cap-$slug-$_capsuleSeq';
    final rawHint = (nextStepHint == null || nextStepHint.trim().isEmpty)
        ? 'Tiếp tục kiểm tra nhánh $branch ($dirtyCount tệp đang sửa)'
        : nextStepHint.trim();
    final cleanHint = redactSensitiveSelectionText(rawHint, maxChars: 240).text;
    final entry = WorkspaceCapsuleEntry(
      capsuleId: capsuleId,
      project: safeProject,
      branch: branch.trim().isEmpty ? 'main' : branch.trim(),
      dirtyCount: dirtyCount < 0 ? 0 : dirtyCount,
      nextStepHint: cleanHint,
      createdAt: ts.toIso8601String(),
    );
    _capsules.insert(0, entry);
    if (_capsules.length > 20) {
      _capsules.removeLast();
    }
    return entry;
  }

  /// Lists saved Time-Travel Workspace Capsules (`SYM-1` S1.1).
  List<WorkspaceCapsuleEntry> listWorkspaceCapsules({int limit = 10}) {
    final clamped = limit.clamp(1, 20);
    return _capsules.take(clamped).toList(growable: false);
  }

  /// Finds a saved Time-Travel Workspace Capsule by [capsuleId] or [project] (`SYM-1` S1.1).
  WorkspaceCapsuleEntry? findWorkspaceCapsule({
    String? capsuleId,
    String? project,
  }) {
    if (capsuleId != null && capsuleId.trim().isNotEmpty) {
      final targetId = capsuleId.trim().toLowerCase();
      for (final cap in _capsules) {
        if (cap.capsuleId.toLowerCase() == targetId) {
          return cap;
        }
      }
    }
    if (project != null && project.trim().isNotEmpty) {
      final targetProj = project.trim().toLowerCase();
      for (final cap in _capsules) {
        if (cap.project.toLowerCase().contains(targetProj)) {
          return cap;
        }
      }
    }
    return _capsules.isNotEmpty ? _capsules.first : null;
  }

  /// Pushes a secret-redacted snippet or item into XUNA Universal Pocket (`SYM-1` S1.1).
  UniversalPocketItem pushPocketItem({
    required String rawText,
    String? label,
    String? kind,
    String? sourceDevice,
    DateTime? nowUtc,
  }) {
    if (!isSafeClipboardWriteText(rawText)) {
      throw ArgumentError.value(rawText, 'text', 'Invalid pocket item text');
    }
    _pocketSeq++;
    final ts = (nowUtc ?? DateTime.now()).toUtc();
    final redacted = redactSensitiveSelectionText(rawText, maxChars: 2000);
    final cleanText = redacted.text;
    final resolvedKind = (kind == null || kind == 'auto' || kind.trim().isEmpty)
        ? classifyPocketKind(cleanText)
        : kind.trim();
    final resolvedLabel = (label == null || label.trim().isEmpty)
        ? _defaultPocketLabel(resolvedKind, cleanText)
        : redactSensitiveSelectionText(label.trim(), maxChars: 80).text;
    final preview = cleanText.length <= 160
        ? cleanText.replaceAll('\n', ' ')
        : '${cleanText.substring(0, 157).replaceAll('\n', ' ')}...';
    final item = UniversalPocketItem(
      itemId: 'pkt-$_pocketSeq',
      kind: resolvedKind,
      label: resolvedLabel,
      text: cleanText,
      preview: preview,
      sourceDevice: (sourceDevice == null || sourceDevice.trim().isEmpty)
          ? 'desktop'
          : sourceDevice.trim(),
      createdAt: ts.toIso8601String(),
      redactedCount: redacted.redactedCount,
      suggestedActions: suggestActionsForKind(resolvedKind),
    );
    _pocketItems.insert(0, item);
    if (_pocketItems.length > 20) {
      _pocketItems.removeLast();
    }
    return item;
  }

  /// Lists items in XUNA Universal Pocket with optional [kind] and [query] filter (`SYM-1` S1.1).
  List<UniversalPocketItem> listPocketItems({
    String? kind,
    String? query,
    int limit = 10,
  }) {
    final clamped = limit.clamp(1, 20);
    final filterKind = (kind == null || kind == 'auto' || kind.trim().isEmpty)
        ? null
        : kind.trim().toLowerCase();
    final filterQuery = (query == null || query.trim().isEmpty)
        ? null
        : query.trim().toLowerCase();
    return _pocketItems
        .where((item) {
          if (filterKind != null && item.kind.toLowerCase() != filterKind) {
            return false;
          }
          if (filterQuery != null &&
              !item.label.toLowerCase().contains(filterQuery) &&
              !item.text.toLowerCase().contains(filterQuery)) {
            return false;
          }
          return true;
        })
        .take(clamped)
        .toList(growable: false);
  }

  /// Transforms a pocket item or inline text using deterministic local rules (`SYM-1` S1.1).
  ({String mode, String transformedText, int itemCount}) transformPocketItem({
    String? itemId,
    String? rawText,
    required String mode,
  }) {
    if (!allowedPocketTransformModes.contains(mode)) {
      throw ArgumentError.value(mode, 'mode', 'Unsupported transform mode');
    }
    String source = '';
    if (itemId != null && itemId.trim().isNotEmpty) {
      final found = _pocketItems
          .where((e) => e.itemId.toLowerCase() == itemId.trim().toLowerCase())
          .firstOrNull;
      if (found != null) {
        source = found.text;
      }
    }
    if (source.isEmpty && rawText != null) {
      source = redactSensitiveSelectionText(rawText, maxChars: 2000).text;
    }
    if (source.trim().isEmpty) {
      return (mode: mode, transformedText: '', itemCount: 0);
    }

    switch (mode) {
      case 'format_json':
        try {
          final decoded = jsonDecode(source);
          final pretty = const JsonEncoder.withIndent('  ').convert(decoded);
          final count = decoded is List
              ? decoded.length
              : (decoded is Map ? decoded.length : 1);
          return (mode: mode, transformedText: pretty, itemCount: count);
        } catch (_) {
          return (mode: mode, transformedText: source.trim(), itemCount: 1);
        }
      case 'extract_tasks':
        final lines = source
            .split(RegExp(r'[\r\n;]+'))
            .map((l) => l.trim())
            .where((l) => l.isNotEmpty)
            .toList(growable: false);
        final tasks = <String>[];
        for (var i = 0; i < lines.length && tasks.length < 10; i++) {
          final cleaned = lines[i]
              .replaceFirst(RegExp(r'^[-*•\d.)+\s]+'), '')
              .trim();
          if (cleaned.isNotEmpty) {
            tasks.add('- [ ] $cleaned');
          }
        }
        return (
          mode: mode,
          transformedText: tasks.join('\n'),
          itemCount: tasks.length,
        );
      case 'prepare_knowledge_fact':
        final condensed = source.replaceAll(RegExp(r'\s+'), ' ').trim();
        final fact = condensed.length <= 220
            ? condensed
            : '${condensed.substring(0, 217)}...';
        return (
          mode: mode,
          transformedText: '[Quy ước / Ghi nhớ] $fact',
          itemCount: 1,
        );
      default:
        final condensed = source.replaceAll(RegExp(r'\s+'), ' ').trim();
        final summary = condensed.length <= 180
            ? condensed
            : '${condensed.substring(0, 177)}...';
        return (mode: mode, transformedText: summary, itemCount: 1);
    }
  }

  /// Classifies [text] into one of the canonical Universal Pocket kinds (`SYM-1` S1.1).
  static String classifyPocketKind(String text) {
    final trimmed = text.trim();
    if (trimmed.startsWith('https://') || trimmed.startsWith('http://')) {
      return 'url';
    }
    if ((trimmed.startsWith('{') && trimmed.endsWith('}')) ||
        (trimmed.startsWith('[') && trimmed.endsWith(']'))) {
      try {
        jsonDecode(trimmed);
        return 'json';
      } catch (_) {
        // Fall through if not valid JSON
      }
    }
    if (RegExp(
      r'^(git|docker|npm|pnpm|yarn|pytest|flutter|fvm|pio|cargo|curl|ssh|kubectl)\b',
    ).hasMatch(trimmed)) {
      return 'command';
    }
    if (trimmed.contains('class ') ||
        trimmed.contains('function ') ||
        trimmed.contains('def ') ||
        trimmed.contains('=>') ||
        trimmed.contains('import ')) {
      return 'code';
    }
    if (RegExp(
      r'\b(họp|meeting|deadline|lịch|ngày mai|thứ hai|thứ ba|thứ tư|thứ năm|thứ sáu|\d{1,2}h\d{0,2})\b',
      caseSensitive: false,
    ).hasMatch(trimmed)) {
      return 'schedule_note';
    }
    return 'text';
  }

  /// Suggests 1-tap follow-up actions for a pocket item of [kind].
  static List<String> suggestActionsForKind(String kind) {
    return switch (kind) {
      'json' => const <String>['format_json', 'clipboard.write'],
      'url' => const <String>['url.open', 'clipboard.write'],
      'command' => const <String>['clipboard.write', 'prepare_knowledge_fact'],
      'code' => const <String>[
        'summarize_snippet',
        'prepare_knowledge_fact',
        'clipboard.write',
      ],
      'schedule_note' => const <String>[
        'extract_tasks',
        'prepare_knowledge_fact',
      ],
      _ => const <String>['summarize_snippet', 'extract_tasks'],
    };
  }

  static String _defaultPocketLabel(String kind, String text) {
    final firstLine = text.split('\n').first.trim();
    final snippet = firstLine.length <= 36
        ? firstLine
        : '${firstLine.substring(0, 33)}...';
    return '$kind: $snippet';
  }
}

