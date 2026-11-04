import 'dart:io';

import 'package:xuna_desktop/features/tools/host_tool_dispatcher.dart';

String _resolveWorkspaceSkillDir(String rawFolder) {
  final clean = rawFolder.trim();
  final home =
      Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      Directory.systemTemp.path;
  if (clean.startsWith('~/')) {
    return '$home/${clean.substring(2)}';
  }
  if (clean.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(clean)) {
    return clean;
  }
  final safeSubPath = clean.isEmpty ? 'XUNA_Tools/Output' : clean;
  return '$home/Documents/XUNA_Workspace/$safeSubPath';
}

class ForgeSynthesizeSkillTool extends HostToolHandler {
  const ForgeSynthesizeSkillTool();

  @override
  String get name => 'forge.synthesize_skill';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final goal = context.arguments['goal'] as String;
    final category = context.arguments['category'] as String?;
    final targetFolder = context.arguments['targetFolder'] as String?;
    final rawExts = context.arguments['fileExtensions'];
    final exts = rawExts is List
        ? rawExts.whereType<String>().toList(growable: false)
        : null;
    final res = context.symbioticService.synthesizeSkill(
      goal: goal,
      category: category,
      targetFolder: targetFolder,
      fileExtensions: exts,
      nowUtc: context.nowUtc,
    );
    if (!Platform.environment.containsKey('FLUTTER_TEST')) {
      try {
        final realDir = _resolveWorkspaceSkillDir(res.targetFolder);
        Directory(realDir).createSync(recursive: true);
        final mdRes = context.symbioticService.bridgeSkillMarkdown(
          action: 'export_skill_md',
          skillId: res.skillId,
        );
        if (mdRes.skillMarkdown.isNotEmpty) {
          File('$realDir/SKILL.md').writeAsStringSync(mdRes.skillMarkdown);
        }
      } catch (_) {}
    }
    return ToolHandlerOutput(
      text: res.summaryVi,
      structuredContent: <String, Object?>{
        'skillId': res.skillId,
        'titleVi': res.titleVi,
        'category': res.category,
        'detectedItemsCount': res.detectedItemsCount,
        'dryRunSample': res.dryRunSample,
        'selfDebugIterations': res.selfDebugIterations,
        'parameterFields': res.parameterFields,
        'scriptSteps': res.scriptSteps,
        'summaryVi': res.summaryVi,
      },
      toastBody: 'đã rèn công cụ ${res.titleVi}',
    );
  }
}

class ForgeRunSkillTool extends HostToolHandler {
  const ForgeRunSkillTool();

  @override
  String get name => 'forge.run_skill';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final skillId = context.arguments['skillId'] as String;
    final maxItems = context.arguments['maxItems'] as int?;
    final outputFolder = context.arguments['outputFolder'] as String?;
    final exportCsv = (context.arguments['exportCsv'] as bool?) ?? true;
    final res = context.symbioticService.runForgedSkill(
      skillId: skillId,
      maxItems: maxItems,
      outputFolder: outputFolder,
      exportCsv: exportCsv,
      nowUtc: context.nowUtc,
    );
    context.actionLedger.pushEntry(
      ReversibleActionEntry(
        originalTool: 'forge.run_skill',
        inverseTool: 'forge.list_and_manage',
        inverseArgs: const <String, Object?>{'action': 'list'},
        description:
            'hoàn tác phiên chạy công cụ $skillId (${res.undoSnapshotId})',
        recordedAt: context.nowUtc,
      ),
    );
    if (!Platform.environment.containsKey('FLUTTER_TEST')) {
      try {
        final realDir = _resolveWorkspaceSkillDir(res.outputDirectory);
        Directory(realDir).createSync(recursive: true);
        final list = context.symbioticService.listForgedSkillEntries();
        final idx = list.indexWhere((s) => s.skillId == res.skillId);
        final entry = idx >= 0
            ? list[idx]
            : (list.isNotEmpty ? list.first : null);
        final home =
            Platform.environment['HOME'] ??
            Platform.environment['USERPROFILE'] ??
            Directory.systemTemp.path;
        final scanDirCandidates = <String>[
          realDir,
          '$home/Downloads',
          '$home/Documents',
        ];
        final discoveredFiles = <FileSystemEntity>[];
        for (final cand in scanDirCandidates) {
          final d = Directory(cand);
          if (d.existsSync()) {
            try {
              final items = d
                  .listSync(followLinks: false)
                  .whereType<File>()
                  .take(50)
                  .toList();
              if (items.isNotEmpty) {
                discoveredFiles.addAll(items);
                break;
              }
            } catch (_) {}
          }
        }
        final rows = <Map<String, Object?>>[
          if (discoveredFiles.isNotEmpty)
            for (var i = 0; i < discoveredFiles.length; i++)
              () {
                final f = discoveredFiles[i] as File;
                final name = f.uri.pathSegments.last;
                var preview = '';
                try {
                  final raw = context.symbioticService.pipeline
                      .extractTextFromFileSync(f);
                  if (raw.isNotEmpty) {
                    final parsed = context.symbioticService.pipeline
                        .parseUniversalContent(raw, sourceName: name);
                    if (parsed.isNotEmpty) {
                      preview = parsed.first.entries
                          .take(4)
                          .map((e) => '${e.key}: ${e.value}')
                          .join(' | ');
                    } else {
                      preview = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
                      if (preview.length > 140) {
                        preview = '${preview.substring(0, 140)}...';
                      }
                    }
                  }
                } catch (_) {}
                return <String, Object?>{
                  'STT': i + 1,
                  'TenTep': name,
                  'DuongDan': f.path,
                  'KichThuocBytes': f.lengthSync(),
                  if (preview.isNotEmpty) 'NoiDungTrichXuat': preview,
                  'NgayCapNhat': f.lastModifiedSync().toIso8601String(),
                };
              }()
          else if (entry != null)
            for (var i = 0; i < entry.scriptSteps.length; i++)
              <String, Object?>{
                'Buoc': i + 1,
                'ThaoTac': entry.scriptSteps[i],
                'MucTieu': entry.goal,
              }
          else
            <String, Object?>{
              'SkillId': res.skillId,
              'SoMucXuLy': res.processedCount,
              'ThuMuc': realDir,
            },
        ];
        final csvPath = context.symbioticService.pipeline
            .exportUniversalArtifactToDisk(
              filePath: '$realDir/BangKe_TongHop.csv',
              format: 'csv',
              titleVi: entry?.titleVi ?? res.skillId,
              rows: rows,
            );
        if (Platform.isMacOS && File(csvPath).existsSync()) {
          await Process.run('/usr/bin/open', <String>['-R', csvPath]);
        } else if (Platform.isWindows && File(csvPath).existsSync()) {
          await Process.run('explorer.exe', <String>[
            '/select,${csvPath.replaceAll('/', '\\')}',
          ]);
        }
      } catch (_) {}
    }
    return ToolHandlerOutput(
      text: res.summaryVi,
      structuredContent: <String, Object?>{
        'skillId': res.skillId,
        'processedCount': res.processedCount,
        'outputDirectory': res.outputDirectory,
        'exportedCsvFile': res.exportedCsvFile,
        'selfHealedSelectors': res.selfHealedSelectors,
        'undoSnapshotId': res.undoSnapshotId,
        'summaryVi': res.summaryVi,
      },
      toastBody: 'đã chạy xong công cụ (${res.processedCount} mục)',
    );
  }
}

class ForgeListAndManageTool extends HostToolHandler {
  const ForgeListAndManageTool();

  @override
  String get name => 'forge.list_and_manage';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final action = (context.arguments['action'] as String?) ?? 'list';
    final skillId = context.arguments['skillId'] as String?;
    final res = context.symbioticService.listAndManageForgedSkills(
      action: action,
      skillId: skillId,
    );
    return ToolHandlerOutput(
      text: 'Kho công cụ XUNA hiện có ${res.skills.length} kỹ năng.',
      structuredContent: <String, Object?>{
        'skills': res.skills,
        'exportedRecipeJson': res.exportedRecipeJson,
      },
    );
  }
}

class TeachRecordSessionTool extends HostToolHandler {
  const TeachRecordSessionTool();

  @override
  String get name => 'teach.record_session';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final mode = context.arguments['mode'] as String;
    final skillTitle = context.arguments['skillTitle'] as String?;
    final demonstratedAction =
        context.arguments['demonstratedAction'] as String?;
    final selectorOrPattern = context.arguments['selectorOrPattern'] as String?;
    final res = context.symbioticService.handleTeachSession(
      mode: mode,
      skillTitle: skillTitle,
      demonstratedAction: demonstratedAction,
      selectorOrPattern: selectorOrPattern,
      nowUtc: context.nowUtc,
    );
    return ToolHandlerOutput(
      text: res.generalizedLoopSummaryVi,
      structuredContent: <String, Object?>{
        'recordingActive': res.recordingActive,
        'capturedStepsCount': res.capturedStepsCount,
        'compiledSkillId': res.compiledSkillId,
        'generalizedLoopSummaryVi': res.generalizedLoopSummaryVi,
      },
      toastBody: mode == 'stop_and_compile'
          ? 'đã học xong kỹ năng mới từ thao tác mẫu'
          : null,
    );
  }
}

class ForgeExtractInvoicesToSheetTool extends HostToolHandler {
  const ForgeExtractInvoicesToSheetTool();

  @override
  String get name => 'forge.extract_invoices_to_sheet';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final sourceFolder = context.arguments['sourceFolder'] as String;
    final outputFileName = context.arguments['outputFileName'] as String?;
    final detectDuplicates =
        (context.arguments['detectDuplicates'] as bool?) ?? true;
    final res = context.symbioticService.extractInvoicesToSheet(
      sourceFolder: sourceFolder,
      outputFileName: outputFileName,
      detectDuplicates: detectDuplicates,
    );
    return ToolHandlerOutput(
      text: res.summaryVi,
      structuredContent: <String, Object?>{
        'invoiceCount': res.invoiceCount,
        'totalAmountVnd': res.totalAmountVnd,
        'duplicateCount': res.duplicateCount,
        'outputCsvFile': res.outputCsvFile,
        'rows': res.rows,
        'summaryVi': res.summaryVi,
      },
      toastBody: 'đã xuất bảng kê ${res.invoiceCount} hóa đơn',
    );
  }
}

class SkillMarkdownBridgeTool extends HostToolHandler {
  const SkillMarkdownBridgeTool();

  @override
  String get name => 'skill.markdown_bridge';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final action = context.arguments['action'] as String;
    final skillId = context.arguments['skillId'] as String?;
    final markdownContent = context.arguments['markdownContent'] as String?;
    final res = context.symbioticService.bridgeSkillMarkdown(
      action: action,
      skillId: skillId,
      markdownContent: markdownContent,
      nowUtc: context.nowUtc,
    );
    return ToolHandlerOutput(
      text: res.summaryVi,
      structuredContent: <String, Object?>{
        'action': res.action,
        'skillId': res.skillId,
        'titleVi': res.titleVi,
        'skillMarkdown': res.skillMarkdown,
        'securityVerified': res.securityVerified,
        'summaryVi': res.summaryVi,
      },
      toastBody: action == 'import_skill_md'
          ? 'đã nhập kỹ năng SKILL.md (${res.titleVi})'
          : 'đã xuất SKILL.md (${res.titleVi})',
    );
  }
}

class SkillRecordCorrectionTool extends HostToolHandler {
  const SkillRecordCorrectionTool();

  @override
  String get name => 'skill.record_correction';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final action = (context.arguments['action'] as String?) ?? 'record';
    final skillId = context.arguments['skillId'] as String;
    final correctionNote = context.arguments['correctionNote'] as String?;
    final res = context.symbioticService.recordSkillCorrection(
      action: action,
      skillId: skillId,
      correctionNote: correctionNote,
    );
    return ToolHandlerOutput(
      text: res.summaryVi,
      structuredContent: <String, Object?>{
        'skillId': res.skillId,
        'selfHealGeneration': res.selfHealGeneration,
        'correctionRules': res.correctionRules,
        'summaryVi': res.summaryVi,
      },
      toastBody: action == 'record'
          ? 'đã ghi nhớ quy tắc tự sửa lỗi #${res.selfHealGeneration}'
          : null,
    );
  }
}

class HeartbeatConfigureAndTickTool extends HostToolHandler {
  const HeartbeatConfigureAndTickTool();

  @override
  String get name => 'heartbeat.configure_and_tick';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final action = (context.arguments['action'] as String?) ?? 'tick';
    final checkName = context.arguments['checkName'] as String?;
    final intervalMinutes = context.arguments['intervalMinutes'] as int?;
    final simulateDelta =
        (context.arguments['simulateDelta'] as bool?) ?? false;
    final snap = context.symbioticService.configureAndTickHeartbeat(
      action: action,
      checkName: checkName,
      intervalMinutes: intervalMinutes,
      simulateDelta: simulateDelta,
    );
    return ToolHandlerOutput(
      text: snap.summaryVi,
      structuredContent: snap.toWireJson(),
      toastBody: snap.deltaDetected
          ? 'phát hiện mục mới trong nhịp tuần tra Heartbeat'
          : null,
    );
  }
}

class CanvasPresentTool extends HostToolHandler {
  const CanvasPresentTool();

  @override
  String get name => 'canvas.present';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final action =
        (context.arguments['action'] as String?) ?? 'present_invoice_table';
    final title = context.arguments['title'] as String?;
    final sourceSkillId = context.arguments['sourceSkillId'] as String?;
    final snap = context.symbioticService.presentLiveCanvas(
      action: action,
      title: title,
      sourceSkillId: sourceSkillId,
    );
    return ToolHandlerOutput(
      text: snap.summaryVi,
      structuredContent: snap.toWireJson(),
      toastBody: action == 'clear'
          ? null
          : 'đã mở bảng tương tác Live Canvas (${snap.titleVi})',
    );
  }
}

class PipelineExecuteUniversalTool extends HostToolHandler {
  const PipelineExecuteUniversalTool();

  @override
  String get name => 'pipeline.execute_universal';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final goal = context.arguments['goal'] as String;
    final rawPrimitives = context.arguments['primitives'];
    final primitives = rawPrimitives is List
        ? rawPrimitives.whereType<String>().toList(growable: false)
        : null;
    final sourceFolder = context.arguments['sourceFolder'] as String?;
    final rawInputText = context.arguments['rawInputText'] as String?;
    final secondaryInputText =
        context.arguments['secondaryInputText'] as String?;
    final exportFormat =
        (context.arguments['exportFormat'] as String?) ?? 'csv';
    final outputFileName = context.arguments['outputFileName'] as String?;

    final res = context.symbioticService.executeUniversalPipeline(
      goal: goal,
      primitives: primitives,
      sourceFolder: sourceFolder,
      rawInputText: rawInputText,
      secondaryInputText: secondaryInputText,
      exportFormat: exportFormat,
      outputFileName: outputFileName,
      nowUtc: context.nowUtc,
    );

    context.actionLedger.pushEntry(
      ReversibleActionEntry(
        originalTool: name,
        inverseTool: 'canvas.present',
        inverseArgs: const <String, Object?>{'action': 'clear'},
        description:
            'hoàn tác pipeline ${res.pipelineId} (${res.undoSnapshotId})',
        recordedAt: context.nowUtc,
      ),
    );

    return ToolHandlerOutput(
      text: res.summaryVi,
      structuredContent: <String, Object?>{
        'pipelineId': res.pipelineId,
        'category': res.category,
        'executedPrimitives': res.executedPrimitives,
        'processedCount': res.processedCount,
        'exportedFile': res.exportedFile,
        'canvasSurfaceKind': res.canvasSurfaceKind,
        'rows': res.rows,
        'undoSnapshotId': res.undoSnapshotId,
        'summaryVi': res.summaryVi,
      },
      toastBody:
          'đã chạy pipeline đa năng (${res.processedCount} mục -> ${res.exportedFile})',
    );
  }
}

/// Disk-Backed Skill Workshop, Hot-Reload, Version Rollback & Progressive Disclosure
/// Compact Index (`skill.workshop_sync`, `WORKSHOP-2`).
class SkillWorkshopSyncTool implements HostToolHandler {
  const SkillWorkshopSyncTool();

  @override
  String get name => 'skill.workshop_sync';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final action = context.arguments['action'] as String;
    final skillId = context.arguments['skillId'] as String?;
    final workshopFolder = context.arguments['workshopFolder'] as String?;

    final res = context.symbioticService.syncSkillWorkshop(
      action: action,
      skillId: skillId,
      workshopFolder: workshopFolder,
      nowUtc: context.nowUtc,
    );

    return ToolHandlerOutput(
      text: res.summaryVi,
      structuredContent: <String, Object?>{
        'action': res.action,
        'workshopFolder': res.workshopFolder,
        'syncedCount': res.syncedCount,
        'version': res.version,
        'compactIndex': res.compactIndex,
        'summaryVi': res.summaryVi,
      },
      toastBody:
          'Workshop (${res.action}): ${res.syncedCount} kỹ năng (v${res.version})',
    );
  }
}

/// Multi-Skill DAG Pipe Chaining, Parameterized Template Interpolation (`{{var}}`),
/// Automated Self-Test Bench & Heartbeat Auto-Trigger (`skill.chain_and_test`, `WORKSHOP-2`).
class SkillChainAndTestTool implements HostToolHandler {
  const SkillChainAndTestTool();

  @override
  String get name => 'skill.chain_and_test';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final rawIds = context.arguments['chainSkillIds'] as List;
    final chainSkillIds = rawIds.whereType<String>().toList(growable: false);
    final rawParams = context.arguments['runtimeParams'];
    final runtimeParams = rawParams is Map
        ? rawParams.map(
            (key, value) => MapEntry(key.toString(), value.toString()),
          )
        : null;
    final autoTriggerOnDelta =
        (context.arguments['autoTriggerOnDelta'] as bool?) ?? false;

    final res = context.symbioticService.executeSkillChainAndTest(
      chainSkillIds: chainSkillIds,
      runtimeParams: runtimeParams,
      autoTriggerOnDelta: autoTriggerOnDelta,
      nowUtc: context.nowUtc,
    );

    context.actionLedger.pushEntry(
      ReversibleActionEntry(
        originalTool: name,
        inverseTool: 'canvas.present',
        inverseArgs: const <String, Object?>{'action': 'clear'},
        description:
            'hoàn tác chuỗi kỹ năng ${res.chainId} (${res.undoSnapshotId})',
        recordedAt: context.nowUtc,
      ),
    );

    return ToolHandlerOutput(
      text: res.summaryVi,
      structuredContent: <String, Object?>{
        'chainId': res.chainId,
        'executedSkills': res.executedSkills,
        'passedAssertions': res.passedAssertions,
        'totalAssertions': res.totalAssertions,
        'selfTestPassed': res.selfTestPassed,
        'autoTriggerOnDelta': res.autoTriggerOnDelta,
        'undoSnapshotId': res.undoSnapshotId,
        'summaryVi': res.summaryVi,
      },
      toastBody:
          'đã chạy chuỗi ${res.executedSkills.length} kỹ năng (Self-Test ${res.passedAssertions}/${res.totalAssertions} PASS)',
    );
  }
}

/// Transparent Markdown Memory Vault & Pre-Compaction Flush (`memory.markdown_vault`, `MIND-2`).
class MemoryMarkdownVaultTool implements HostToolHandler {
  const MemoryMarkdownVaultTool();

  @override
  String get name => 'memory.markdown_vault';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final action = context.arguments['action'] as String;
    final targetFile = context.arguments['targetFile'] as String?;
    final noteContent = context.arguments['noteContent'] as String?;
    final sessionTranscript = context.arguments['sessionTranscript'] as String?;
    final vaultFolder = context.arguments['vaultFolder'] as String?;

    final res = context.symbioticService.manageMarkdownMemoryVault(
      action: action,
      targetFile: targetFile,
      noteContent: noteContent,
      sessionTranscript: sessionTranscript,
      vaultFolder: vaultFolder,
      nowUtc: context.nowUtc,
    );

    return ToolHandlerOutput(
      text: res.summaryVi,
      structuredContent: <String, Object?>{
        'action': res.action,
        'vaultFolder': res.vaultFolder,
        'soulMarkdown': res.soulMarkdown,
        'ownerProfileMarkdown': res.ownerProfileMarkdown,
        'memoryJournalMarkdown': res.memoryJournalMarkdown,
        'flushedFactsCount': res.flushedFactsCount,
        'redactedSecretsCount': res.redactedSecretsCount,
        'summaryVi': res.summaryVi,
      },
      toastBody:
          'Memory Vault (${res.action}): lưu ${res.flushedFactsCount} mục vào ${res.vaultFolder}',
    );
  }
}

/// Semantic Browser ARIA Snapshotter (`browser.semantic_snapshot`, `MIND-2`).
class BrowserSemanticSnapshotTool implements HostToolHandler {
  const BrowserSemanticSnapshotTool();

  @override
  String get name => 'browser.semantic_snapshot';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final rawHtml = context.arguments['rawHtml'] as String?;
    final pageTitle = context.arguments['pageTitle'] as String?;
    final maxElements = (context.arguments['maxElements'] as int?) ?? 25;

    final res = context.symbioticService.captureSemanticBrowserSnapshot(
      rawHtml: rawHtml,
      pageTitle: pageTitle,
      maxElements: maxElements,
    );

    return ToolHandlerOutput(
      text: res.summaryVi,
      structuredContent: <String, Object?>{
        'snapshotId': res.snapshotId,
        'pageTitle': res.pageTitle,
        'elementCount': res.elementCount,
        'tokenReductionPercent': res.tokenReductionPercent,
        'compactAriaTree': res.compactAriaTree,
        'elements': res.elements,
        'summaryVi': res.summaryVi,
      },
      toastBody:
          'ARIA Snapshot: ${res.elementCount} phần tử (giảm ${res.tokenReductionPercent}% token)',
    );
  }
}

/// Delegated Background Sub-Agent & Zero-Token Specialist Swarm Spawner (`subagent.spawn_and_poll`, `MIND-2`, `SWARM-2`).
class SubagentSpawnAndPollTool implements HostToolHandler {
  const SubagentSpawnAndPollTool();

  @override
  String get name => 'subagent.spawn_and_poll';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final action = context.arguments['action'] as String;
    final taskGoal = context.arguments['taskGoal'] as String?;
    final workerId = context.arguments['workerId'] as String?;
    final tokenBudget = (context.arguments['tokenBudget'] as int?) ?? 2048;
    final sourceFolder = context.arguments['sourceFolder'] as String?;
    final rawRoles = context.arguments['specialistRoles'] as List<Object?>?;
    final specialistRoles = rawRoles
        ?.whereType<String>()
        .map((r) => r.trim())
        .toList(growable: false);
    final enableCriticVerification =
        (context.arguments['enableCriticVerification'] as bool?) ?? true;

    final res = context.symbioticService.spawnOrPollSubagent(
      action: action,
      taskGoal: taskGoal,
      workerId: workerId,
      tokenBudget: tokenBudget,
      sourceFolder: sourceFolder,
      specialistRoles: specialistRoles,
      enableCriticVerification: enableCriticVerification,
      nowUtc: context.nowUtc,
    );

    return ToolHandlerOutput(
      text: res.summaryVi,
      structuredContent: <String, Object?>{
        'action': res.action,
        'workerId': res.workerId,
        'status': res.status,
        'progressPercent': res.progressPercent,
        'tokenBudget': res.tokenBudget,
        'tokensUsed': res.tokensUsed,
        'llmTokensUsed': res.llmTokensUsed,
        'contextSavedPercent': res.contextSavedPercent,
        'distilledResultVi': res.distilledResultVi,
        'activeWorkers': res.activeWorkers,
        'blackboardEntries': res.blackboardEntries,
        'criticPassed': res.criticPassed,
        'criticConfidenceScore': res.criticConfidenceScore,
        'specialistBreakdown': res.specialistBreakdown,
        'summaryVi': res.summaryVi,
      },
      toastBody:
          'Sub-Agent [${res.workerId}]: ${res.status} (0 LLM Token, Critic ${res.criticConfidenceScore}%)',
    );
  }
}

/// Autonomous Cron & Event-Driven Lifecycle Hooks (`schedule.cron_and_hooks`, `MIND-2`).
class ScheduleCronAndHooksTool implements HostToolHandler {
  const ScheduleCronAndHooksTool();

  @override
  String get name => 'schedule.cron_and_hooks';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final action = context.arguments['action'] as String;
    final hookId = context.arguments['hookId'] as String?;
    final eventOrCron = context.arguments['eventOrCron'] as String?;
    final targetSkillId = context.arguments['targetSkillId'] as String?;
    final labelVi = context.arguments['labelVi'] as String?;

    final res = context.symbioticService.manageCronAndHooks(
      action: action,
      hookId: hookId,
      eventOrCron: eventOrCron,
      targetSkillId: targetSkillId,
      labelVi: labelVi,
      nowUtc: context.nowUtc,
    );

    if (action == 'register' || action == 'trigger_event') {
      context.actionLedger.pushEntry(
        ReversibleActionEntry(
          originalTool: name,
          inverseTool: name,
          inverseArgs: <String, Object?>{
            'action': 'remove',
            'hookId': res.hookId,
          },
          description:
              'hoàn tác Hook tự trị ${res.hookId} (${res.undoSnapshotId})',
          recordedAt: context.nowUtc,
        ),
      );
    }

    return ToolHandlerOutput(
      text: res.summaryVi,
      structuredContent: <String, Object?>{
        'action': res.action,
        'hookId': res.hookId,
        'eventOrCron': res.eventOrCron,
        'targetSkillId': res.targetSkillId,
        'triggeredCount': res.triggeredCount,
        'activeHooks': res.activeHooks,
        'undoSnapshotId': res.undoSnapshotId,
        'summaryVi': res.summaryVi,
      },
      toastBody:
          'Lifecycle Hook (${res.action}): ${res.hookId} -> ${res.targetSkillId}',
    );
  }
}

/// Living Overlay & Drag-and-Drop Feed-to-Process (`companion.overlay_and_drop`, `FRONTIER-1`).
class CompanionOverlayAndDropTool implements HostToolHandler {
  const CompanionOverlayAndDropTool();

  @override
  String get name => 'companion.overlay_and_drop';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final mode = context.arguments['mode'] as String;
    final anchor = context.arguments['anchor'] as String?;
    final droppedItemName = context.arguments['droppedItemName'] as String?;
    final droppedContent = context.arguments['droppedContent'] as String?;
    final targetAction = context.arguments['targetAction'] as String?;

    final res = context.symbioticService.manageOverlayAndDropZone(
      mode: mode,
      anchor: anchor,
      droppedItemName: droppedItemName,
      droppedContent: droppedContent,
      targetAction: targetAction,
      nowUtc: context.nowUtc,
    );

    return ToolHandlerOutput(
      text: res.summaryVi,
      structuredContent: <String, Object?>{
        'mode': res.mode,
        'overlayVisible': res.overlayVisible,
        'anchor': res.anchor,
        'munchAnimation': res.munchAnimation,
        'routedTarget': res.routedTarget,
        'redactedSecretsCount': res.redactedSecretsCount,
        'summaryVi': res.summaryVi,
      },
      toastBody:
          'Overlay (${res.anchor}): ${res.munchAnimation} -> ${res.routedTarget}',
    );
  }
}

/// Bio-Acoustic Procedural Vocalizer & Prosody Sensing (`acoustic.vocalize_and_sense`, `FRONTIER-2`).
class AcousticVocalizeAndSenseTool implements HostToolHandler {
  const AcousticVocalizeAndSenseTool();

  @override
  String get name => 'acoustic.vocalize_and_sense';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final mode = context.arguments['mode'] as String;
    final vocalKind = context.arguments['vocalKind'] as String?;
    final themeId = context.arguments['themeId'] as String?;
    final speechRateWpm = context.arguments['speechRateWpm'] as int?;
    final rmsEnergyDb = context.arguments['rmsEnergyDb'] as int?;
    final pauseRatioPercent = context.arguments['pauseRatioPercent'] as int?;

    final res = context.symbioticService.vocalizeAndSenseProsody(
      mode: mode,
      vocalKind: vocalKind,
      themeId: themeId,
      speechRateWpm: speechRateWpm,
      rmsEnergyDb: rmsEnergyDb,
      pauseRatioPercent: pauseRatioPercent,
    );

    return ToolHandlerOutput(
      text: res.summaryVi,
      structuredContent: <String, Object?>{
        'mode': res.mode,
        'vocalKind': res.vocalKind,
        'sampleRateHz': res.sampleRateHz,
        'pcmByteCount': res.pcmByteCount,
        'wavSha256': res.wavSha256,
        'detectedOwnerTone': res.detectedOwnerTone,
        'empathyAdjustmentVi': res.empathyAdjustmentVi,
        'summaryVi': res.summaryVi,
      },
      toastBody:
          'Bio-Acoustic [${res.vocalKind}]: ${res.pcmByteCount}B PCM · Tone: ${res.detectedOwnerTone}',
    );
  }
}

/// Bi-Temporal Knowledge Graph & Memory Constellation (`memory.temporal_graph`, `FRONTIER-3`).
class MemoryTemporalGraphTool implements HostToolHandler {
  const MemoryTemporalGraphTool();

  @override
  String get name => 'memory.temporal_graph';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final mode = context.arguments['mode'] as String;
    final subject = context.arguments['subject'] as String?;
    final predicate = context.arguments['predicate'] as String?;
    final object = context.arguments['object'] as String?;
    final validFromIso = context.arguments['validFromIso'] as String?;

    final res = context.symbioticService.manageTemporalLifeGraph(
      mode: mode,
      subject: subject,
      predicate: predicate,
      object: object,
      validFromIso: validFromIso,
      nowUtc: context.nowUtc,
    );

    return ToolHandlerOutput(
      text: res.summaryVi,
      structuredContent: <String, Object?>{
        'mode': res.mode,
        'activeEdgesCount': res.activeEdgesCount,
        'historicalEdgesCount': res.historicalEdgesCount,
        'supersededEdgeId': res.supersededEdgeId,
        'temporalNarrativeVi': res.temporalNarrativeVi,
        'constellationNodes': res.constellationNodes,
        'constellationEdges': res.constellationEdges,
        'summaryVi': res.summaryVi,
      },
      toastBody:
          'ChronoGraph: ${res.activeEdgesCount} active / ${res.historicalEdgesCount} historical',
    );
  }
}

/// Embodied Mindful Rituals, StandBy OLED Dock & Neighbor Playdate (`ritual.mindful_and_playdate`, `FRONTIER-4`).
class RitualMindfulAndPlaydateTool implements HostToolHandler {
  const RitualMindfulAndPlaydateTool();

  @override
  String get name => 'ritual.mindful_and_playdate';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final mode = context.arguments['mode'] as String;
    final durationMinutes = context.arguments['durationMinutes'] as int?;
    final focusGoal = context.arguments['focusGoal'] as String?;
    final neighborShortId = context.arguments['neighborShortId'] as String?;
    final giftMessage = context.arguments['giftMessage'] as String?;

    final res = context.symbioticService.executeMindfulRitualAndPlaydate(
      mode: mode,
      durationMinutes: durationMinutes,
      focusGoal: focusGoal,
      neighborShortId: neighborShortId,
      giftMessage: giftMessage,
    );

    return ToolHandlerOutput(
      text: res.summaryVi,
      structuredContent: <String, Object?>{
        'mode': res.mode,
        'activeRitual': res.activeRitual,
        'cadencePattern': res.cadencePattern,
        'standbyDockActive': res.standbyDockActive,
        'unlockedKeepsakeVi': res.unlockedKeepsakeVi,
        'playdateSummaryVi': res.playdateSummaryVi,
        'summaryVi': res.summaryVi,
      },
      toastBody:
          'Ritual [${res.activeRitual}]: ${res.unlockedKeepsakeVi}',
    );
  }
}

/// Zero-Screenshot Native OS UI Automation (`ui.accessibility_tree`, `UIA-2`).
class UiAccessibilityTreeTool implements HostToolHandler {
  const UiAccessibilityTreeTool();

  @override
  String get name => 'ui.accessibility_tree';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final action = context.arguments['action'] as String;
    final windowTitle = context.arguments['windowTitle'] as String?;
    final refId = context.arguments['refId'] as String?;
    final valueText = context.arguments['valueText'] as String?;
    final maxNodes = (context.arguments['maxNodes'] as int?) ?? 30;

    var hasNativeSnapshot = false;
    var effectiveWindowTitle = windowTitle;
    String? nativeDetail;

    try {
      List<Map<String, Object?>> postActionNodes = const <Map<String, Object?>>[];
      if (action != 'inspect_window') {
        final actRes = await context.channel.invokeWindowUiControl(
          action: action,
          refId: refId ?? (action == 'set_value_ref' ? 'ui_1' : 'ui_3'),
          windowTitle: windowTitle,
          valueText: valueText,
          submit: true,
        );
        nativeDetail = actRes.detail;
        postActionNodes = actRes.nodes;
        if (actRes.windowTitle.trim().isNotEmpty &&
            (effectiveWindowTitle == null ||
                effectiveWindowTitle.trim().isEmpty)) {
          effectiveWindowTitle = actRes.windowTitle;
        }
      }
      if (postActionNodes.isNotEmpty) {
        context.symbioticService.uiAccessibility.applyNativeWindowUiTree(
          windowTitle: effectiveWindowTitle ?? 'Active Window',
          nodes: postActionNodes,
        );
        hasNativeSnapshot = true;
      } else {
        final nativeSnap = await context.channel.inspectWindowUiTree(
          windowTitle: effectiveWindowTitle,
          maxNodes: maxNodes,
        );
        if (nativeSnap.nodes.isNotEmpty) {
          context.symbioticService.uiAccessibility.applyNativeWindowUiTree(
            windowTitle: nativeSnap.windowTitle,
            nodes: nativeSnap.nodes,
          );
          effectiveWindowTitle = nativeSnap.windowTitle;
          hasNativeSnapshot = true;
        }
      }
    } catch (_) {
      // Fall back to symbiotic in-memory UI tree if native channel is unavailable
    }

    final res = context.symbioticService.uiAccessibility
        .executeUiAccessibilityTree(
          action: action,
          windowTitle: effectiveWindowTitle,
          refId: refId,
          valueText: valueText,
          maxNodes: maxNodes,
          preserveNativeNodes: hasNativeSnapshot,
          nativeActionDetail: nativeDetail,
        );

    if (action == 'invoke_ref' || action == 'set_value_ref') {
      context.actionLedger.pushEntry(
        ReversibleActionEntry(
          originalTool: name,
          inverseTool: name,
          inverseArgs: <String, Object?>{
            'action': 'inspect_window',
            'windowTitle': res.windowTitle,
          },
          description:
              'hoàn tác thao tác điều khiển [${res.invokedRefId}] trên cửa sổ ${res.windowTitle}',
          recordedAt: context.nowUtc,
        ),
      );
    }

    return ToolHandlerOutput(
      text: res.summaryVi,
      structuredContent: <String, Object?>{
        'action': res.action,
        'windowTitle': res.windowTitle,
        'nodeCount': res.nodeCount,
        'tokenSavingsPercent': res.tokenSavingsPercent,
        'screenshotBytesUsed': res.screenshotBytesUsed,
        'compactUiTree': res.compactUiTree,
        'invokedRefId': res.invokedRefId,
        'redactedControlsCount': res.redactedControlsCount,
        'nodes': res.nodes,
        'summaryVi': res.summaryVi,
      },
      toastBody:
          'OS UIA [${res.windowTitle}]: ${res.nodeCount} controls (0 ảnh · -${res.tokenSavingsPercent}% token)',
    );
  }
}

const List<HostToolHandler> defaultForgeClawToolHandlers = <HostToolHandler>[
  ForgeSynthesizeSkillTool(),
  ForgeRunSkillTool(),
  ForgeListAndManageTool(),
  TeachRecordSessionTool(),
  ForgeExtractInvoicesToSheetTool(),
  SkillMarkdownBridgeTool(),
  SkillRecordCorrectionTool(),
  HeartbeatConfigureAndTickTool(),
  CanvasPresentTool(),
  PipelineExecuteUniversalTool(),
  SkillWorkshopSyncTool(),
  SkillChainAndTestTool(),
  MemoryMarkdownVaultTool(),
  BrowserSemanticSnapshotTool(),
  SubagentSpawnAndPollTool(),
  ScheduleCronAndHooksTool(),
  CompanionOverlayAndDropTool(),
  AcousticVocalizeAndSenseTool(),
  MemoryTemporalGraphTool(),
  RitualMindfulAndPlaydateTool(),
  UiAccessibilityTreeTool(),
];
