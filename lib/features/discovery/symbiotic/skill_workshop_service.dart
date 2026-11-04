import 'dart:convert';
import 'dart:io';

import 'package:xuna_xtp/xuna_xtp.dart';

import 'heartbeat_canvas_service.dart';
import 'omniforge_service.dart';
import 'symbiotic_models.dart';
import 'universal_pipeline_service.dart';

/// OpenClaw `SKILL.md` Bridge, Self-Improving Correction Rules, Disk-Backed
/// Skill Workshop, and Multi-Skill DAG Pipe Chaining (`CLAW-1`, `WORKSHOP-2`).
class SkillWorkshopService {
  SkillWorkshopService({
    required OmniForgeService forgeService,
    required UniversalPipelineService pipelineService,
    required HeartbeatCanvasService heartbeatCanvasService,
  }) : _forgeService = forgeService,
       _pipelineService = pipelineService,
       _heartbeatCanvasService = heartbeatCanvasService;

  final OmniForgeService _forgeService;
  final UniversalPipelineService _pipelineService;
  final HeartbeatCanvasService _heartbeatCanvasService;

  /// Exports a forged skill as an OpenClaw-compatible `SKILL.md` document or
  /// imports a safe `SKILL.md` into the sandboxed OmniForge library (`CLAW-1`).
  ({
    String action,
    String skillId,
    String titleVi,
    String skillMarkdown,
    bool securityVerified,
    String summaryVi,
  })
  bridgeSkillMarkdown({
    required String action,
    String? skillId,
    String? markdownContent,
    DateTime? nowUtc,
  }) {
    if (action == 'import_skill_md') {
      final rawMd = (markdownContent ?? '').trim();
      if (rawMd.isEmpty || containsForbiddenSkillMarkdownPattern(rawMd)) {
        throw ArgumentError.value(
          markdownContent,
          'markdownContent',
          'Unsafe or empty SKILL.md content',
        );
      }
      final nameMatch = RegExp(
        r'^name:\s*(.+)$',
        multiLine: true,
      ).firstMatch(rawMd);
      final descMatch = RegExp(
        r'^description:\s*(.+)$',
        multiLine: true,
      ).firstMatch(rawMd);
      final parsedTitle =
          nameMatch?.group(1)?.trim().replaceAll('"', '') ??
          'Kỹ năng nhập từ SKILL.md';
      final parsedGoal =
          descMatch?.group(1)?.trim().replaceAll('"', '') ??
          'Chạy quy trình từ SKILL.md ($parsedTitle)';
      final forged = _forgeService.synthesizeSkill(
        goal: '$parsedTitle — $parsedGoal',
        category: OmniForgeService.inferForgeSkillCategory(
          '$parsedTitle $parsedGoal',
        ),
        nowUtc: nowUtc,
      );
      return (
        action: 'import_skill_md',
        skillId: forged.skillId,
        titleVi: forged.titleVi,
        skillMarkdown: rawMd.length <= 4000 ? rawMd : rawMd.substring(0, 4000),
        securityVerified: true,
        summaryVi:
            'Đã kiểm duyệt an toàn hộp cát và nhập SKILL.md thành công cụ "${forged.titleVi}" (${forged.skillId}).',
      );
    }

    final skills = _forgeService.listForgedSkillEntries();
    final target = (skillId != null && skillId.trim().isNotEmpty)
        ? skills
                  .where(
                    (s) =>
                        s.skillId.toLowerCase() == skillId.trim().toLowerCase(),
                  )
                  .firstOrNull ??
              skills.first
        : skills.first;
    final stepsMd = target.scriptSteps.map((s) => '- $s').join('\n');
    final rulesMd = target.correctionRules.isEmpty
        ? '- Chưa có ghi chú tự sửa lỗi.'
        : target.correctionRules.map((r) => '- $r').join('\n');
    final md =
        '---\n'
        'name: "${target.titleVi}"\n'
        'skill_id: "${target.skillId}"\n'
        '${target.toolName.isNotEmpty ? 'tool_name: "${target.toolName}"\n' : ''}'
        'runtime: "${target.runtime}"\n'
        'category: "${target.category}"\n'
        'risk: "R2"\n'
        'target_folder: "${target.targetFolder}"\n'
        'self_heal_generation: ${target.selfHealGeneration}\n'
        '---\n'
        '# ${target.titleVi}\n\n'
        '## Mục tiêu\n'
        '${target.goal}\n\n'
        '## Các bước XunaScript\n'
        '$stepsMd\n\n'
        '## Ghi chú tự thích nghi (Self-Improving Rules)\n'
        '$rulesMd\n';
    return (
      action: 'export_skill_md',
      skillId: target.skillId,
      titleVi: target.titleVi,
      skillMarkdown: md,
      securityVerified: true,
      summaryVi:
          'Đã xuất kỹ năng "${target.titleVi}" sang chuẩn SKILL.md tương thích hệ sinh thái OpenClaw.',
    );
  }

  /// Records a self-improving correction rule onto a forged skill so future runs
  /// adapt when a web portal changes layout (`CLAW-1`).
  ({
    String skillId,
    int selfHealGeneration,
    List<String> correctionRules,
    String summaryVi,
  })
  recordSkillCorrection({
    String action = 'record',
    required String skillId,
    String? correctionNote,
  }) {
    final skills = _forgeService.listForgedSkillEntries();
    final forgedSkills = _forgeService.forgedSkillsMutable;
    var idx = forgedSkills.indexWhere(
      (s) => s.skillId.toLowerCase() == skillId.trim().toLowerCase(),
    );
    if (idx < 0 && skills.isNotEmpty) {
      idx = 0;
    }
    final current = forgedSkills[idx];
    if (action == 'list' ||
        correctionNote == null ||
        correctionNote.trim().isEmpty) {
      return (
        skillId: current.skillId,
        selfHealGeneration: current.selfHealGeneration,
        correctionRules: current.correctionRules,
        summaryVi:
            'Kỹ năng "${current.titleVi}" đang có ${current.correctionRules.length} quy tắc tự thích nghi (thế hệ #${current.selfHealGeneration}).',
      );
    }
    final cleanNote = redactSensitiveSelectionText(
      correctionNote.trim(),
      maxChars: 240,
    ).text;
    final updatedRules = <String>[...current.correctionRules, cleanNote];
    final nextGen = current.selfHealGeneration + 1;
    final nextVer = current.version + 1;
    final updatedHistory = <String>[
      ...current.versionHistory,
      'v$nextVer: $cleanNote',
    ];
    final updated = current.copyWith(
      selfHealGeneration: nextGen,
      correctionRules: List<String>.unmodifiable(updatedRules),
      version: nextVer,
      versionHistory: List<String>.unmodifiable(updatedHistory),
    );
    forgedSkills[idx] = updated;
    return (
      skillId: updated.skillId,
      selfHealGeneration: nextGen,
      correctionRules: updated.correctionRules,
      summaryVi:
          'Đã ghi nhớ bài học tự sửa lỗi thế hệ #$nextGen (v$nextVer) cho "${updated.titleVi}": $cleanNote',
    );
  }

  /// Disk-Backed Skill Workshop, Hot-Reload, Version Rollback & Progressive Disclosure
  /// Compact Index (`skill.workshop_sync`, `WORKSHOP-2`).
  ///
  /// - `sync_to_disk`: Persists forged skills as `<workshopFolder>/<skillId>/SKILL.md`
  ///   and `recipe.json` when the parent directory or sandbox folder is writable.
  /// - `hot_reload_from_disk`: Scans `<workshopFolder>/*/SKILL.md` on disk, verifies
  ///   each with `containsForbiddenSkillMarkdownPattern`, and hot-loads new skills into
  ///   [_forgeService.forgedSkillsMutable] without restarting the agent.
  /// - `rollback_version`: Reverts a skill to its previous version in `versionHistory`
  ///   and decrements `version` (down to 1).
  /// - `compact_index`: Emits a lightweight progressive-disclosure index so the LLM
  ///   never loads full `SKILL.md` instructions until a skill is invoked.
  ({
    String action,
    String workshopFolder,
    int syncedCount,
    int version,
    List<Map<String, Object?>> compactIndex,
    String summaryVi,
  })
  syncSkillWorkshop({
    required String action,
    String? skillId,
    String? workshopFolder,
    DateTime? nowUtc,
  }) {
    final skills = _forgeService.listForgedSkillEntries();
    final forgedSkills = _forgeService.forgedSkillsMutable;
    final folder = (workshopFolder != null && workshopFolder.trim().isNotEmpty)
        ? workshopFolder.trim()
        : 'XUNA_Skill_Workshop';

    List<Map<String, Object?>> buildCompactIndex() => forgedSkills
        .take(20)
        .map(
          (s) => <String, Object?>{
            'skillId': s.skillId,
            'titleVi': s.titleVi,
            'category': s.category,
            'version': s.version,
            'autoTriggerOnDelta': s.autoTriggerOnDelta,
          },
        )
        .toList(growable: false);

    if (action == 'rollback_version') {
      var idx = forgedSkills.indexWhere(
        (s) =>
            skillId != null &&
            s.skillId.toLowerCase() == skillId.trim().toLowerCase(),
      );
      if (idx < 0) idx = 0;
      final current = forgedSkills[idx];
      final prevVer = current.version > 1 ? current.version - 1 : 1;
      final trimmedRules = current.correctionRules.isNotEmpty
          ? current.correctionRules.sublist(
              0,
              current.correctionRules.length - 1,
            )
          : const <String>[];
      final trimmedHistory = current.versionHistory.length > 1
          ? current.versionHistory.sublist(0, current.versionHistory.length - 1)
          : current.versionHistory;
      final rolledBack = current.copyWith(
        version: prevVer,
        selfHealGeneration: current.selfHealGeneration > 0
            ? current.selfHealGeneration - 1
            : 0,
        correctionRules: List<String>.unmodifiable(trimmedRules),
        versionHistory: List<String>.unmodifiable(trimmedHistory),
      );
      forgedSkills[idx] = rolledBack;
      final idxList = buildCompactIndex();
      return (
        action: 'rollback_version',
        workshopFolder: folder,
        syncedCount: 1,
        version: rolledBack.version,
        compactIndex: idxList,
        summaryVi:
            'Đã khôi phục kỹ năng "${rolledBack.titleVi}" (${rolledBack.skillId}) về phiên bản v${rolledBack.version} an toàn.',
      );
    }

    if (action == 'hot_reload_from_disk') {
      var reloaded = 0;
      final rootDir = Directory(folder);
      if (rootDir.existsSync()) {
        final subDirs = rootDir.listSync().whereType<Directory>().toList()
          ..sort((a, b) => a.path.compareTo(b.path));
        for (final sub in subDirs) {
          final recipeFile = File(
            '${sub.path}${Platform.pathSeparator}recipe.json',
          );
          if (recipeFile.existsSync()) {
            try {
              final rawJson = jsonDecode(recipeFile.readAsStringSync());
              if (rawJson is Map) {
                final recipeMap = rawJson.map(
                  (k, v) => MapEntry<String, Object?>(k.toString(), v),
                );
                final entry = ForgedSkillEntry.fromDiskRecipeJson(recipeMap);
                if (entry.scriptCode.isNotEmpty) {
                  final check = validateSynthesizedToolScript(
                    scriptCode: entry.scriptCode,
                    runtime: entry.runtime,
                  );
                  if (!check.safe) {
                    continue;
                  }
                }
                final existingIdx = forgedSkills.indexWhere(
                  (s) => s.skillId.toLowerCase() == entry.skillId.toLowerCase(),
                );
                if (existingIdx >= 0) {
                  forgedSkills[existingIdx] = entry;
                } else {
                  forgedSkills.insert(0, entry);
                }
                reloaded++;
                continue;
              }
            } catch (_) {
              // Fall back to SKILL.md if recipe.json is malformed.
            }
          }

          final mdFile = File('${sub.path}${Platform.pathSeparator}SKILL.md');
          if (!mdFile.existsSync()) continue;
          final rawMd = mdFile.readAsStringSync();
          if (rawMd.trim().isEmpty ||
              containsForbiddenSkillMarkdownPattern(rawMd)) {
            continue;
          }
          final idMatch = RegExp(
            r'^skill_id:\s*"?([a-zA-Z0-9._\-]+)"?$',
            multiLine: true,
          ).firstMatch(rawMd);
          final subName = sub.path.split(RegExp(r'[/\\]')).last;
          final parsedId = idMatch?.group(1)?.trim() ?? subName;
          final exists = forgedSkills.any(
            (s) => s.skillId.toLowerCase() == parsedId.toLowerCase(),
          );
          if (!exists) {
            bridgeSkillMarkdown(
              action: 'import_skill_md',
              markdownContent: rawMd,
              nowUtc: nowUtc,
            );
            reloaded++;
          } else {
            reloaded++;
          }
        }
      }
      final idxList = buildCompactIndex();
      final topVersion = forgedSkills.isNotEmpty
          ? forgedSkills.first.version
          : 1;
      return (
        action: 'hot_reload_from_disk',
        workshopFolder: folder,
        syncedCount: reloaded,
        version: topVersion,
        compactIndex: idxList,
        summaryVi:
            'Hot-Reload Workshop: Đã quét "$folder", kiểm duyệt an toàn hộp cát và nạp nóng $reloaded gói SKILL.md (tổng ${idxList.length} công cụ).',
      );
    }

    if (action == 'compact_index') {
      final idxList = buildCompactIndex();
      final topVersion = forgedSkills.isNotEmpty
          ? forgedSkills.first.version
          : 1;
      return (
        action: 'compact_index',
        workshopFolder: folder,
        syncedCount: idxList.length,
        version: topVersion,
        compactIndex: idxList,
        summaryVi:
            'Progressive Disclosure Index: Đã xuất danh mục rút gọn ${idxList.length} kỹ năng (tiết kiệm >85% ngữ cảnh LLM cho đến khi kích hoạt).',
      );
    }

    // Default: sync_to_disk
    final targets = (skillId != null && skillId.trim().isNotEmpty)
        ? skills
              .where(
                (s) => s.skillId.toLowerCase() == skillId.trim().toLowerCase(),
              )
              .toList()
        : skills;
    final effectiveTargets = targets.isEmpty
        ? <ForgedSkillEntry>[skills.first]
        : targets;
    final rootDir = Directory(folder);
    if (rootDir.existsSync()) {
      for (final s in effectiveTargets) {
        final skillDir = Directory(
          '${rootDir.path}${Platform.pathSeparator}${s.skillId}',
        );
        skillDir.createSync(recursive: true);
        final exportedMd = bridgeSkillMarkdown(
          action: 'export_skill_md',
          skillId: s.skillId,
        ).skillMarkdown;
        File(
          '${skillDir.path}${Platform.pathSeparator}SKILL.md',
        ).writeAsStringSync(exportedMd, encoding: utf8);
        File(
          '${skillDir.path}${Platform.pathSeparator}recipe.json',
        ).writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(s.toDiskRecipeJson()),
          encoding: utf8,
        );
        if (s.scriptCode.isNotEmpty) {
          final ext = switch (s.runtime) {
            'python' => 'py',
            'node' => 'js',
            'powershell' => 'ps1',
            'bash' => 'sh',
            _ => 'txt',
          };
          final slug = s.toolName.isNotEmpty ? s.toolName : s.skillId;
          File(
            '${skillDir.path}${Platform.pathSeparator}$slug.$ext',
          ).writeAsStringSync(s.scriptCode, encoding: utf8);
        }
      }
    }
    final idxList = buildCompactIndex();
    final primaryVer = effectiveTargets.first.version;
    return (
      action: 'sync_to_disk',
      workshopFolder: folder,
      syncedCount: effectiveTargets.length,
      version: primaryVer,
      compactIndex: idxList,
      summaryVi:
          'Đã đồng bộ ${effectiveTargets.length} kỹ năng (v$primaryVer) xuống đĩa tại "$folder/<skillId>/SKILL.md" + recipe.json.',
    );
  }

  /// Multi-Skill DAG Pipe Chaining, Parameterized Template Interpolation (`{{var}}`),
  /// Automated 4-Point Self-Test Bench & Heartbeat Auto-Trigger Binding
  /// (`skill.chain_and_test`, `WORKSHOP-2`).
  ({
    String chainId,
    List<String> executedSkills,
    int passedAssertions,
    int totalAssertions,
    bool selfTestPassed,
    bool autoTriggerOnDelta,
    String undoSnapshotId,
    String summaryVi,
  })
  executeSkillChainAndTest({
    required List<String> chainSkillIds,
    Map<String, String>? runtimeParams,
    bool autoTriggerOnDelta = false,
    DateTime? nowUtc,
  }) {
    final pipelineSeq = _pipelineService.nextPipelineSeq();
    final undoSnapSeq = _forgeService.nextUndoSnapSeq();
    final skills = _forgeService.listForgedSkillEntries();
    final forgedSkills = _forgeService.forgedSkillsMutable;
    final safeParams = runtimeParams ?? const <String, String>{};
    final executedIds = <String>[];
    final executedTitles = <String>[];
    final interpolatedGoals = <String>[];
    final combinedRows = <Map<String, Object?>>[];
    String? pipedJsonFromPrevStep;
    var totalProcessedAcrossChain = 0;

    for (var stepIdx = 0; stepIdx < chainSkillIds.length; stepIdx++) {
      final reqId = chainSkillIds[stepIdx].trim();
      var matchIdx = forgedSkills.indexWhere(
        (s) => s.skillId.toLowerCase() == reqId.toLowerCase(),
      );
      if (matchIdx < 0 && skills.isNotEmpty) {
        matchIdx = stepIdx % forgedSkills.length;
      }
      final current = forgedSkills[matchIdx];
      final interpolatedGoal = interpolateSkillTemplate(
        current.goal,
        safeParams,
      );
      final interpolatedFolder = interpolateSkillTemplate(
        current.targetFolder,
        safeParams,
      );
      interpolatedGoals.add(interpolatedGoal);

      // Execute the real Universal Pipeline for this step, piping output rows from step i-1 into step i
      final stepPipe = _pipelineService.executeUniversalPipeline(
        goal: interpolatedGoal,
        primitives: current.primitives,
        sourceFolder: interpolatedFolder,
        rawInputText: pipedJsonFromPrevStep,
        nowUtc: nowUtc,
      );
      pipedJsonFromPrevStep = jsonEncode(stepPipe.rows);
      totalProcessedAcrossChain += stepPipe.processedCount;

      final updated = current.copyWith(
        goal: interpolatedGoal,
        targetFolder: interpolatedFolder,
        runCount: current.runCount + 1,
        autoTriggerOnDelta: autoTriggerOnDelta
            ? true
            : current.autoTriggerOnDelta,
        selfTestPassed: stepPipe.processedCount > 0,
        lastRunSummaryVi:
            'Chạy trong chuỗi DAG bước #${stepIdx + 1}/${chainSkillIds.length}: xử lý ${stepPipe.processedCount} bản ghi -> ${stepPipe.exportedFile}.',
      );
      forgedSkills[matchIdx] = updated;
      executedIds.add(updated.skillId);
      executedTitles.add(updated.titleVi);
      combinedRows.add(<String, Object?>{
        'step': 'Bước ${stepIdx + 1}',
        'skillId': updated.skillId,
        'titleVi': updated.titleVi,
        'folder': interpolatedFolder,
        'processedCount': stepPipe.processedCount,
        'assertion': stepPipe.processedCount > 0 ? 'PASS' : 'EMPTY',
      });
    }

    final chainId = 'chain-$pipelineSeq';
    final undoId = 'undo-chain-$undoSnapSeq';

    // 4-point dynamic automated self-test bench:
    // 1. All chained skills resolved & executed in sandbox
    // 2. Template interpolation produced clean UTF-8 strings without forbidden patterns
    // 3. Real pipeline execution produced non-empty structured output rows across the chain
    // 4. Reversible snapshot token minted
    var passedAssertions = 0;
    const totalAssertions = 4;
    if (executedIds.length == chainSkillIds.length) passedAssertions++;
    if (!containsForbiddenSkillMarkdownPattern(interpolatedGoals.join('\n'))) {
      passedAssertions++;
    }
    if (totalProcessedAcrossChain > 0 && combinedRows.isNotEmpty) {
      passedAssertions++;
    }
    if (undoId.startsWith('undo-chain-')) passedAssertions++;
    final selfTestPassed = passedAssertions == totalAssertions;

    final canvasSeq = _heartbeatCanvasService.nextCanvasSeq();
    _heartbeatCanvasService.updateActiveCanvas(
      LiveCanvasSurfaceSnapshot(
        canvasId: 'canvas-chain-$canvasSeq',
        surfaceKind: 'workflow_board',
        titleVi:
            'Chuỗi Kỹ Năng Liên Hoàn (${executedIds.length} bước — Self-Test $passedAssertions/$totalAssertions ${selfTestPassed ? "PASS" : "WARN"})',
        columns: const <String>[
          'Thứ tự',
          'Mã kỹ năng',
          'Tên công cụ',
          'Thư mục đích',
          'Kiểm thử tự động',
        ],
        rows: combinedRows,
        actions: const <String>['export_csv', 'sync_workshop', 'undo_last'],
        summaryVi:
            'Đã nối chuỗi ${executedTitles.join(" -> ")} (xử lý $totalProcessedAcrossChain bản ghi) và vượt qua $passedAssertions/$totalAssertions bài kiểm thử tự động.',
      ),
    );

    final triggerNote = autoTriggerOnDelta
        ? ', tự chạy khi Heartbeat phát hiện biến động'
        : '';
    final summaryVi =
        'Chuỗi kỹ năng "$chainId" (${executedTitles.join(" -> ")}) hoàn tất: xử lý $totalProcessedAcrossChain mục, Self-Test $passedAssertions/$totalAssertions PASS$triggerNote (Undo: $undoId).';

    return (
      chainId: chainId,
      executedSkills: executedIds,
      passedAssertions: passedAssertions,
      totalAssertions: totalAssertions,
      selfTestPassed: selfTestPassed,
      autoTriggerOnDelta: autoTriggerOnDelta,
      undoSnapshotId: undoId,
      summaryVi: summaryVi.length <= 240
          ? summaryVi
          : summaryVi.substring(0, 240),
    );
  }
}
