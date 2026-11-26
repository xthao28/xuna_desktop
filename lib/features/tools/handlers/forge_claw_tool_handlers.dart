import 'dart:convert';
import 'dart:io';

import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_desktop/features/discovery/symbiotic/skill_workshop_service.dart';
import 'package:xuna_desktop/features/tools/host_tool_dispatcher.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

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
    final toolName = context.arguments['toolName'] as String?;
    final runtime = context.arguments['runtime'] as String?;
    final scriptCode = context.arguments['scriptCode'] as String?;
    final testArgsJson = context.arguments['testArgsJson'] as String?;
    final skillIdToUpdate = context.arguments['skillIdToUpdate'] as String?;
    final rawExts = context.arguments['fileExtensions'];
    final exts = rawExts is List
        ? rawExts.whereType<String>().toList(growable: false)
        : null;
    final res = context.symbioticService.synthesizeSkill(
      goal: goal,
      category: category,
      targetFolder: targetFolder,
      fileExtensions: exts,
      toolName: toolName,
      runtime: runtime,
      scriptCode: scriptCode,
      testArgsJson: testArgsJson,
      skillIdToUpdate: skillIdToUpdate,
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
        if (res.scriptCode.isNotEmpty) {
          final ext = switch (res.runtime) {
            'python' => 'py',
            'node' => 'js',
            'powershell' => 'ps1',
            'bash' => 'sh',
            _ => 'txt',
          };
          final slug = res.toolName.isNotEmpty ? res.toolName : res.skillId;
          File('$realDir/$slug.$ext').writeAsStringSync(res.scriptCode);
        }
        final workshopRoot = _resolveWorkspaceSkillDir('XUNA_Skill_Workshop');
        Directory(workshopRoot).createSync(recursive: true);
        context.symbioticService.syncSkillWorkshop(
          action: 'sync_to_disk',
          skillId: res.skillId,
          workshopFolder: workshopRoot,
          nowUtc: context.nowUtc,
        );
      } catch (_) {}
    }
    return ToolHandlerOutput(
      text: res.summaryVi,
      structuredContent: <String, Object?>{
        'skillId': res.skillId,
        'toolName': res.toolName,
        'runtime': res.runtime,
        'titleVi': res.titleVi,
        'category': res.category,
        'detectedItemsCount': res.detectedItemsCount,
        'dryRunOk': res.selfTestPassed,
        'dryRunSample': res.dryRunSample,
        'stdoutPreview': res.lastStdoutPreview,
        'stderrPreview': res.lastStderrPreview,
        'selfDebugIterations': res.selfDebugIterations,
        'parameterFields': res.parameterFields,
        'scriptSteps': res.scriptSteps,
        'summaryVi': res.summaryVi,
      },
      toastBody: 'đã rèn công cụ ${res.titleVi}',
    );
  }
}

Map<String, Object?> _interpolateStepArgs(
  Map<String, Object?> args,
  Map<String, String> params,
) {
  if (params.isEmpty) return args;
  final result = <String, Object?>{};
  for (final entry in args.entries) {
    final val = entry.value;
    if (val is String) {
      result[entry.key] = interpolateSkillTemplate(val, params);
    } else if (val is Map) {
      result[entry.key] = _interpolateStepArgs(
        val.map((k, v) => MapEntry(k.toString(), v)),
        params,
      );
    } else if (val is List) {
      result[entry.key] = val.map((item) {
        if (item is String) return interpolateSkillTemplate(item, params);
        if (item is Map) {
          return _interpolateStepArgs(
            item.map((k, v) => MapEntry(k.toString(), v)),
            params,
          );
        }
        return item;
      }).toList();
    } else {
      result[entry.key] = val;
    }
  }
  return result;
}

class ForgeRunSkillTool extends HostToolHandler {
  const ForgeRunSkillTool();

  @override
  String get name => 'forge.run_skill';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final rawSkillId = context.arguments['skillId'];
    if (rawSkillId == null || rawSkillId.toString().trim().isEmpty) {
      throw const XunaHostChannelException(
        status: XtpStatus.invalidArgs,
        errorCode: 'missing_param',
      );
    }
    final skillId = rawSkillId.toString().trim();
    final maxItems = context.arguments['maxItems'] as int?;
    final outputFolder = context.arguments['outputFolder'] as String?;
    final exportCsv = (context.arguments['exportCsv'] as bool?) ?? true;
    final argsJson = context.arguments['argsJson'] as String?;
    final stringParams = <String, String>{};
    if (argsJson != null && argsJson.trim().isNotEmpty) {
      final Object? decoded;
      try {
        decoded = jsonDecode(argsJson);
      } on FormatException {
        throw const XunaHostChannelException(
          status: XtpStatus.invalidArgs,
          errorCode: 'schema_mismatch',
        );
      }
      if (decoded is! Map) {
        throw const XunaHostChannelException(
          status: XtpStatus.invalidArgs,
          errorCode: 'schema_mismatch',
        );
      }
      for (final entry in decoded.entries) {
        final val = entry.value?.toString() ?? '';
        if (!isSafeTemplateParameterValue(val)) {
          throw const XunaHostChannelException(
            status: XtpStatus.invalidArgs,
            errorCode: 'schema_mismatch',
          );
        }
        stringParams[entry.key.toString()] = val;
      }
    }

    final skill = context.symbioticService.findForgedSkill(skillId);
    if (skill == null) {
      throw const XunaHostChannelException(
        status: XtpStatus.invalidArgs,
        errorCode: 'skill_not_found',
      );
    }

    final steps = skill.executableSteps;

    // If the skill defines structured tool steps, execute them sequentially via subStepExecutor
    if (steps.isNotEmpty) {
      final executor = context.subStepExecutor;
      if (executor == null) {
        throw const XunaHostChannelException(
          status: XtpStatus.unsupported,
          errorCode: 'platform_unsupported',
        );
      }
      final executedSteps = <Map<String, Object?>>[];
      for (var i = 0; i < steps.length; i++) {
        if (context.cancellationToken.isCancelled) {
          throw const XunaHostChannelException(
            status: XtpStatus.failed,
            errorCode: 'cancelled',
          );
        }
        final step = steps[i];
        final stepTool = step['tool'] as String? ?? '';
        if (stepTool.isEmpty) {
          throw const XunaHostChannelException(
            status: XtpStatus.invalidArgs,
            errorCode: 'schema_mismatch',
          );
        }
        if (isHardDeniedAppOrProcess(stepTool)) {
          throw const XunaHostChannelException(
            status: XtpStatus.denied,
            errorCode: 'policy_blocked',
          );
        }
        final rawArgs =
            (step['arguments'] as Map?)?.map(
              (k, v) => MapEntry(k.toString(), v),
            ) ??
            <String, Object?>{};
        final interpolatedArgs = _interpolateStepArgs(rawArgs, stringParams);

        final checkApp =
            interpolatedArgs['appId']?.toString() ??
            interpolatedArgs['app']?.toString() ??
            interpolatedArgs['process']?.toString();
        if (checkApp != null && isHardDeniedAppOrProcess(checkApp)) {
          throw const XunaHostChannelException(
            status: XtpStatus.denied,
            errorCode: 'policy_blocked',
          );
        }

        // Sub-step execution: ANY error (R3 phone signature invalid, policy blocked, etc.)
        // propagates end-to-end to caller without swallowing (Rule H4).
        final stepOutput = await executor(stepTool, interpolatedArgs);
        executedSteps.add(<String, Object?>{
          'step': i + 1,
          'tool': stepTool,
          'output': stepOutput.structuredContent,
        });
      }

      final snapSeq = context.symbioticService.forge.nextUndoSnapSeq();
      final undoId = 'undo-forge-$snapSeq';
      final summary =
          'Đã thực thi thành công kỹ năng "${skill.titleVi}" (${executedSteps.length} bước).';
      context.actionLedger.pushEntry(
        ReversibleActionEntry(
          originalTool: 'forge.run_skill',
          inverseTool: 'forge.list_and_manage',
          inverseArgs: const <String, Object?>{'action': 'list'},
          description: 'hoàn tác phiên chạy công cụ $skillId ($undoId)',
          recordedAt: context.nowUtc,
        ),
      );

      return ToolHandlerOutput(
        text: summary,
        structuredContent: <String, Object?>{
          'skillId': skill.skillId,
          'titleVi': skill.titleVi,
          'exitCode': 0,
          'processedCount': executedSteps.length,
          'completedSteps': executedSteps.length,
          'steps': executedSteps,
          'undoSnapshotId': undoId,
          'summaryVi': summary,
        },
        toastBody: 'đã chạy xong kỹ năng ${skill.titleVi}',
      );
    }

    // Otherwise (sandbox script or native pipeline), run via symbioticService.runForgedSkill
    final res = context.symbioticService.runForgedSkill(
      skillId: skillId,
      maxItems: maxItems,
      outputFolder: outputFolder,
      exportCsv: exportCsv,
      argsJson: argsJson,
      nowUtc: context.nowUtc,
    );
    if (res.exitCode != 0) {
      throw const XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'script_execution_failed',
      );
    }

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

    return ToolHandlerOutput(
      text: res.summaryVi,
      structuredContent: <String, Object?>{
        'skillId': res.skillId,
        'runtime': res.runtime,
        'exitCode': res.exitCode,
        'processedCount': res.processedCount,
        'outputDirectory': res.outputDirectory,
        'exportedCsvFile': res.exportedCsvFile,
        'stdoutPreview': res.stdoutPreview,
        'stderrPreview': res.stderrPreview,
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
    final ({
      String action,
      String skillId,
      String titleVi,
      String skillMarkdown,
      bool securityVerified,
      String summaryVi,
    })
    res;
    try {
      res = context.symbioticService.bridgeSkillMarkdown(
        action: action,
        skillId: skillId,
        markdownContent: markdownContent,
        nowUtc: context.nowUtc,
      );
    } on SkillNotFoundError catch (e) {
      throw XunaHostChannelException(
        status: XtpStatus.invalidArgs,
        errorCode: 'skill_not_found',
        message: e.candidateIds.isEmpty
            ? 'No forged skills exist yet.'
            : 'Valid skillId values: ${e.candidateIds.join(', ')}',
      );
    }
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
    final snap = context.symbioticService.configureAndTickHeartbeat(
      action: action,
      checkName: checkName,
      intervalMinutes: intervalMinutes,
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
    if (rawHtml == null || rawHtml.trim().isEmpty) {
      // The service would otherwise parse a built-in sample portal page and report it
      // as if it were the owner's browser. This tool does not read the browser itself.
      throw const XunaHostChannelException(
        status: XtpStatus.invalidArgs,
        errorCode: 'raw_html_required',
        message:
            'browser.semantic_snapshot only parses supplied rawHtml; use '
            'browser.read_page to read the active browser tab.',
      );
    }

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
];
