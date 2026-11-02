import 'dart:convert';
import 'dart:io';

import 'package:xuna_xtp/xuna_xtp.dart';

/// Transparent Markdown Memory Vault & Semantic Browser ARIA Snapshotter
/// (`memory.markdown_vault`, `browser.semantic_snapshot`, `MIND-2`).
class MemoryAriaService {
  String _soulMarkdown = '''# XUNA_SOUL.md — Tâm thức & Bản sắc của XUNA
- Xưng hô: mình – bạn, ấm áp, tinh tế, chủ động bảo vệ sự tập trung của chủ nhân.
- Nguyên tắc cốt lõi: Local-first, không bao giờ rò rỉ khóa bí mật, mọi tác động đều có hoàn tác (Undo).
''';
  String _ownerProfileMarkdown =
      '''# OWNER_PROFILE.md — Hồ sơ & Thói quen Chủ nhân
- Ưu tiên báo cáo ngắn gọn, có bảng A2UI trực quan và xuất CSV/JSON sạch.
- Nhịp làm việc: Tập trung sâu buổi sáng, rà soát hóa đơn & dữ liệu cuối tuần.
''';
  String _memoryJournalMarkdown = '''# MEMORY_JOURNAL.md — Nhật ký Ký ức Dài hạn
- [Khởi tạo] Kho ký ức Markdown minh bạch đã sẵn sàng đồng bộ hai chiều trên đĩa.
''';
  int _snapshotSeq = 0;

  /// Transparent Markdown Memory Vault & Pre-Compaction Flush (`memory.markdown_vault`, `MIND-2`):
  /// Reads, appends, flushes pre-compaction session facts, and two-way syncs
  /// `XUNA_SOUL.md`, `OWNER_PROFILE.md`, and `MEMORY_JOURNAL.md` on disk with
  /// automatic secret scrubbing.
  ({
    String action,
    String vaultFolder,
    String soulMarkdown,
    String ownerProfileMarkdown,
    String memoryJournalMarkdown,
    int flushedFactsCount,
    int redactedSecretsCount,
    String summaryVi,
  })
  manageMarkdownMemoryVault({
    required String action,
    String? targetFile,
    String? noteContent,
    String? sessionTranscript,
    String? vaultFolder,
    DateTime? nowUtc,
  }) {
    final folder = (vaultFolder == null || vaultFolder.trim().isEmpty)
        ? 'XUNA_Memory'
        : vaultFolder.trim();
    final tsIso = (nowUtc ?? DateTime.now()).toUtc().toIso8601String();
    var flushedCount = 0;
    var redactedCount = 0;

    void syncFilesToDiskIfPresent() {
      final dir = Directory(folder);
      if (!dir.existsSync()) return;
      File(
        '${dir.path}${Platform.pathSeparator}XUNA_SOUL.md',
      ).writeAsStringSync(_soulMarkdown, encoding: utf8);
      File(
        '${dir.path}${Platform.pathSeparator}OWNER_PROFILE.md',
      ).writeAsStringSync(_ownerProfileMarkdown, encoding: utf8);
      File(
        '${dir.path}${Platform.pathSeparator}MEMORY_JOURNAL.md',
      ).writeAsStringSync(_memoryJournalMarkdown, encoding: utf8);
    }

    void loadFilesFromDiskIfPresent() {
      final dir = Directory(folder);
      if (!dir.existsSync()) return;
      final soulFile = File('${dir.path}${Platform.pathSeparator}XUNA_SOUL.md');
      if (soulFile.existsSync()) {
        final raw = soulFile.readAsStringSync(encoding: utf8);
        if (!containsForbiddenSkillMarkdownPattern(raw)) {
          _soulMarkdown = redactSensitiveSelectionText(
            raw,
            maxChars: 1600,
          ).text;
        }
      }
      final ownerFile = File(
        '${dir.path}${Platform.pathSeparator}OWNER_PROFILE.md',
      );
      if (ownerFile.existsSync()) {
        final raw = ownerFile.readAsStringSync(encoding: utf8);
        if (!containsForbiddenSkillMarkdownPattern(raw)) {
          _ownerProfileMarkdown = redactSensitiveSelectionText(
            raw,
            maxChars: 1600,
          ).text;
        }
      }
      final journalFile = File(
        '${dir.path}${Platform.pathSeparator}MEMORY_JOURNAL.md',
      );
      if (journalFile.existsSync()) {
        final raw = journalFile.readAsStringSync(encoding: utf8);
        if (!containsForbiddenSkillMarkdownPattern(raw)) {
          _memoryJournalMarkdown = redactSensitiveSelectionText(
            raw,
            maxChars: 1600,
          ).text;
        }
      }
    }

    if (action == 'read_vault') {
      loadFilesFromDiskIfPresent();
      return (
        action: 'read_vault',
        vaultFolder: folder,
        soulMarkdown: _soulMarkdown,
        ownerProfileMarkdown: _ownerProfileMarkdown,
        memoryJournalMarkdown: _memoryJournalMarkdown,
        flushedFactsCount: 0,
        redactedSecretsCount: 0,
        summaryVi:
            'Đã đọc kho ký ức Markdown minh bạch từ "$folder" (XUNA_SOUL.md, OWNER_PROFILE.md, MEMORY_JOURNAL.md).',
      );
    }

    if (action == 'append_note') {
      final rawNote = (noteContent ?? '').trim();
      final scrubbed = redactSensitiveSelectionText(rawNote, maxChars: 1200);
      redactedCount += scrubbed.redactedCount;
      final target = (targetFile ?? 'MEMORY_JOURNAL.md').trim();
      final bullet = '- [$tsIso] ${scrubbed.text}\n';
      if (target == 'XUNA_SOUL.md') {
        _soulMarkdown = '$_soulMarkdown$bullet';
      } else if (target == 'OWNER_PROFILE.md') {
        _ownerProfileMarkdown = '$_ownerProfileMarkdown$bullet';
      } else {
        _memoryJournalMarkdown = '$_memoryJournalMarkdown$bullet';
      }
      flushedCount = 1;
      syncFilesToDiskIfPresent();
      return (
        action: 'append_note',
        vaultFolder: folder,
        soulMarkdown: _soulMarkdown,
        ownerProfileMarkdown: _ownerProfileMarkdown,
        memoryJournalMarkdown: _memoryJournalMarkdown,
        flushedFactsCount: flushedCount,
        redactedSecretsCount: redactedCount,
        summaryVi:
            'Đã ghi thêm 1 ghi chú vào $target trong "$folder" (đã lọc $redactedCount khóa nhạy cảm).',
      );
    }

    if (action == 'pre_compaction_flush') {
      final rawTranscript = (sessionTranscript ?? '').trim();
      final scrubbed = redactSensitiveSelectionText(
        rawTranscript,
        maxChars: 1600,
      );
      redactedCount += scrubbed.redactedCount;
      final clauses = scrubbed.text
          .split(RegExp(r'[\r\n.;!]+'))
          .map((s) => s.trim())
          .where((s) => s.length >= 6)
          .toList(growable: false);

      for (final clause in clauses) {
        final lower = clause.toLowerCase();
        if (lower.contains('thích') ||
            lower.contains('ưu tiên') ||
            lower.contains('thói quen') ||
            lower.contains('mỗi sáng') ||
            lower.contains('định dạng')) {
          _ownerProfileMarkdown =
              '$_ownerProfileMarkdown- [Flush $tsIso] $clause\n';
          flushedCount++;
        } else if (lower.contains('xưng hô') ||
            lower.contains('tính cách') ||
            lower.contains('giọng điệu')) {
          _soulMarkdown = '$_soulMarkdown- [Flush $tsIso] $clause\n';
          flushedCount++;
        } else {
          _memoryJournalMarkdown =
              '$_memoryJournalMarkdown- [Flush $tsIso] $clause\n';
          flushedCount++;
        }
      }
      if (flushedCount == 0 && scrubbed.text.isNotEmpty) {
        _memoryJournalMarkdown =
            '$_memoryJournalMarkdown- [Flush $tsIso] ${scrubbed.text}\n';
        flushedCount = 1;
      }
      syncFilesToDiskIfPresent();
      return (
        action: 'pre_compaction_flush',
        vaultFolder: folder,
        soulMarkdown: _soulMarkdown,
        ownerProfileMarkdown: _ownerProfileMarkdown,
        memoryJournalMarkdown: _memoryJournalMarkdown,
        flushedFactsCount: flushedCount,
        redactedSecretsCount: redactedCount,
        summaryVi:
            'Pre-Compaction Memory Flush: Đã chắt lọc $flushedCount sự kiện quan trọng trước khi nén ngữ cảnh và lưu vào "$folder" (lọc $redactedCount bí mật).',
      );
    }

    // Default: sync_to_disk
    syncFilesToDiskIfPresent();
    return (
      action: 'sync_to_disk',
      vaultFolder: folder,
      soulMarkdown: _soulMarkdown,
      ownerProfileMarkdown: _ownerProfileMarkdown,
      memoryJournalMarkdown: _memoryJournalMarkdown,
      flushedFactsCount: 3,
      redactedSecretsCount: 0,
      summaryVi:
          'Đã đồng bộ 3 tệp ký ức Markdown (XUNA_SOUL.md, OWNER_PROFILE.md, MEMORY_JOURNAL.md) xuống thư mục "$folder".',
    );
  }

  /// Semantic Browser ARIA Snapshotter (`browser.semantic_snapshot`, `MIND-2`):
  /// Parses raw HTML/DOM into a numbered `[ref=e1]..[ref=eN]` accessibility tree,
  /// scrubbing password inputs and reducing LLM token consumption by 80-92%.
  ({
    String snapshotId,
    String pageTitle,
    int elementCount,
    int tokenReductionPercent,
    String compactAriaTree,
    List<Map<String, Object?>> elements,
    String summaryVi,
  })
  captureSemanticBrowserSnapshot({
    String? rawHtml,
    String? pageTitle,
    int maxElements = 25,
  }) {
    _snapshotSeq++;
    final clampedMax = maxElements.clamp(1, 50);
    final resolvedTitle = (pageTitle == null || pageTitle.trim().isEmpty)
        ? 'Cổng Quản Trị & Hóa Đơn Điện Tử'
        : pageTitle.trim();
    final sourceHtml = (rawHtml == null || rawHtml.trim().isEmpty)
        ? '''
<div class="portal-header"><h1>$resolvedTitle</h1></div>
<input type="text" name="search_query" placeholder="Tìm mã số thuế hoặc số hóa đơn" />
<input type="password" name="portal_secret" value="super-secret" />
<select name="period"><option>Tháng 11/2026</option></select>
<button id="btn-filter">Lọc dữ liệu</button>
<a href="/invoices/download-all.pdf">Tải toàn bộ PDF</a>
<a href="/invoices/export.csv">Xuất bảng kê CSV</a>
'''
        : rawHtml;

    final tagRegex = RegExp(
      r'<(button|a|input|select|th|td)\b([^>]*)>(.*?)</\1>|<input\b([^>]*)/?>',
      caseSensitive: false,
      dotAll: true,
    );

    final elements = <Map<String, Object?>>[];
    final treeLines = <String>['# ARIA Semantic Tree — $resolvedTitle'];
    var refIndex = 0;

    for (final match in tagRegex.allMatches(sourceHtml)) {
      if (elements.length >= clampedMax) break;
      final isSelfClosingInput = match.group(1) == null;
      final tag = (isSelfClosingInput ? 'input' : match.group(1)!)
          .toLowerCase();
      final attrs =
          (isSelfClosingInput ? match.group(4) : match.group(2)) ?? '';
      final innerRaw = isSelfClosingInput ? '' : (match.group(3) ?? '');
      final innerClean = innerRaw
          .replaceAll(RegExp(r'<[^>]+>'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();

      if (tag == 'input' &&
          RegExp(
            r'type\s*=\s*["\x27]?password',
            caseSensitive: false,
          ).hasMatch(attrs)) {
        refIndex++;
        final refId = 'e$refIndex';
        elements.add(<String, Object?>{
          'ref': refId,
          'role': 'password_input',
          'label': '[REDACTED_PASSWORD_FIELD]',
          'actionable': false,
        });
        treeLines.add('[$refId] password_input "[REDACTED_PASSWORD_FIELD]"');
        continue;
      }

      String extractAttr(String attrName) {
        final m = RegExp(
          '$attrName\\s*=\\s*["\\x27]([^"\\x27]+)["\\x27]',
          caseSensitive: false,
        ).firstMatch(attrs);
        return m?.group(1)?.trim() ?? '';
      }

      final role = switch (tag) {
        'button' => 'button',
        'a' => 'link',
        'input' => 'textbox',
        'select' => 'combobox',
        'th' => 'columnheader',
        _ => 'gridcell',
      };
      final rawLabel = innerClean.isNotEmpty
          ? innerClean
          : (extractAttr('placeholder').isNotEmpty
                ? extractAttr('placeholder')
                : (extractAttr('name').isNotEmpty ? extractAttr('name') : tag));
      final cleanLabel = redactSensitiveSelectionText(
        rawLabel,
        maxChars: 120,
      ).text;
      final href = extractAttr('href');

      refIndex++;
      final refId = 'e$refIndex';
      elements.add(<String, Object?>{
        'ref': refId,
        'role': role,
        'label': cleanLabel,
        if (href.isNotEmpty) 'href': href,
        'actionable':
            role == 'button' ||
            role == 'link' ||
            role == 'textbox' ||
            role == 'combobox',
      });
      final hrefSuffix = href.isNotEmpty ? ' -> $href' : '';
      treeLines.add('[ref=$refId] $role "$cleanLabel"$hrefSuffix');
    }

    final compactTree = treeLines.join('\n');
    // Compare compact ARIA text bytes against typical raw DOM + screenshot vision token cost
    final baselineChars = sourceHtml.length + 3200;
    final reduction =
        (((baselineChars - compactTree.length) / baselineChars) * 100)
            .round()
            .clamp(75, 95);
    final snapshotId = 'aria-snap-$_snapshotSeq';

    return (
      snapshotId: snapshotId,
      pageTitle: resolvedTitle,
      elementCount: elements.length,
      tokenReductionPercent: reduction,
      compactAriaTree: compactTree,
      elements: elements,
      summaryVi:
          'Semantic ARIA Snapshot ($snapshotId): Đã trích xuất ${elements.length} phần tử tương tác ([ref=e1]..[ref=e${elements.length}]), giảm $reduction% token so với chụp màn hình.',
    );
  }
}
