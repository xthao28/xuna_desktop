import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_desktop/core/controller/desktop_app_automation_runner.dart';
import 'package:xuna_desktop/features/discovery/auto_symbiotic_service.dart';

/// Handles OmniForge skill synthesis, real-file scanning/organization, OpenClaw `SKILL.md`
/// and helper script generation, and skill execution side effects for [DesktopAgentController].
class DesktopSkillRunner {
  DesktopSkillRunner({
    required this.channel,
    required this.appAutomationRunner,
    required this.getSymbioticService,
    required this.setFrontierStatusSummaryVi,
    required this.refreshSymbioticState,
  });

  final XunaHostChannel channel;
  final DesktopAppAutomationRunner appAutomationRunner;
  final AutoSymbioticService? Function() getSymbioticService;
  final void Function(String summaryVi) setFrontierStatusSummaryVi;
  final void Function() refreshSymbioticState;

  static String resolveRealSkillDirectoryStatic(String rawFolder) {
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

  String resolveRealSkillDirectory(String rawFolder) =>
      resolveRealSkillDirectoryStatic(rawFolder);

  void loadPersistedForgedSkillsFromDisk() {
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    final svc = getSymbioticService();
    if (svc == null) return;
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home == null || home.isEmpty) return;
    final workspaceDir = Directory('$home/Documents/XUNA_Workspace');
    if (!workspaceDir.existsSync()) return;
    try {
      for (final entity in workspaceDir.listSync(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.isEmpty
            ? ''
            : entity.uri.pathSegments.last;
        if (name != 'SKILL.md') continue;
        try {
          final rawMd = entity.readAsStringSync();
          if (rawMd.trim().isNotEmpty) {
            svc.bridgeSkillMarkdown(
              action: 'import_skill_md',
              markdownContent: rawMd,
            );
          }
        } catch (_) {}
      }
      refreshSymbioticState();
    } catch (_) {}
  }

  List<Map<String, Object?>> scanRealFilesForSkill(ForgedSkillEntry skill) {
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home == null || home.isEmpty) return const <Map<String, Object?>>[];
    final lowerGoal = skill.goal.toLowerCase();
    final candidateDirs = <String>[
      if (lowerGoal.contains('desktop') || lowerGoal.contains('màn hình'))
        '$home/Desktop',
      '$home/Downloads',
      '$home/Documents',
      if (!lowerGoal.contains('desktop') && !lowerGoal.contains('màn hình'))
        '$home/Desktop',
    ];
    final normalizedExts = skill.fileExtensions
        .map((e) => e.trim().toLowerCase().replaceFirst(RegExp(r'^\.'), ''))
        .where((e) => e.isNotEmpty)
        .toSet();
    final matchedFiles = <File>[];
    final fallbackFiles = <File>[];

    for (final dirPath in candidateDirs) {
      final dir = Directory(dirPath);
      if (!dir.existsSync()) continue;
      try {
        for (final entity in dir.listSync(followLinks: false)) {
          if (entity is! File) continue;
          final name = entity.uri.pathSegments.isEmpty
              ? ''
              : entity.uri.pathSegments.last;
          if (name.isEmpty || name.startsWith('.')) continue;
          if (entity.path.contains('XUNA_Workspace')) continue;
          final dotIdx = name.lastIndexOf('.');
          final ext = dotIdx >= 0
              ? name.substring(dotIdx + 1).toLowerCase()
              : '';
          if (normalizedExts.isEmpty || normalizedExts.contains(ext)) {
            matchedFiles.add(entity);
            if (matchedFiles.length >= 50) break;
          } else if (fallbackFiles.length < 25) {
            fallbackFiles.add(entity);
          }
        }
      } catch (_) {}
      if (matchedFiles.length >= 50) break;
    }

    final svc = getSymbioticService();
    final chosen = matchedFiles.isNotEmpty ? matchedFiles : fallbackFiles;
    final rows = <Map<String, Object?>>[];
    for (var i = 0; i < chosen.length; i++) {
      final f = chosen[i];
      try {
        final stat = f.statSync();
        final name = f.uri.pathSegments.last;
        final dotIdx = name.lastIndexOf('.');
        final extLower = dotIdx >= 0
            ? name.substring(dotIdx + 1).toLowerCase()
            : '';
        final ext = extLower.toUpperCase();
        final sizeKb = (stat.size / 1024).toStringAsFixed(1);
        final modIso = stat.modified.toLocal().toIso8601String();
        var contentPreview = '';
        if (stat.size > 0 && stat.size <= 4 * 1024 * 1024) {
          try {
            final raw = svc?.pipeline.extractTextFromFileSync(f) ?? '';
            if (raw.isNotEmpty) {
              final parsed = svc?.pipeline.parseUniversalContent(
                raw,
                sourceName: name,
              );
              if (parsed != null && parsed.isNotEmpty) {
                contentPreview = parsed.first.entries
                    .take(4)
                    .map((e) => '${e.key}: ${e.value}')
                    .join(' | ');
              } else {
                contentPreview = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
                if (contentPreview.length > 140) {
                  contentPreview = '${contentPreview.substring(0, 140)}...';
                }
              }
            }
          } catch (_) {}
        }
        rows.add(<String, Object?>{
          'STT': i + 1,
          'TenTep': name,
          'DinhDang': ext.isEmpty ? 'FILE' : ext,
          'DungLuongKB': sizeKb,
          'CapNhatLuc': modIso.length >= 16 ? modIso.substring(0, 16) : modIso,
          if (contentPreview.isNotEmpty) 'NoiDungTrichXuat': contentPreview,
          'DuongDanGoc': f.path,
        });
      } catch (_) {}
    }
    return rows;
  }

  List<Map<String, Object?>> executeRealFileOperationsForSkill(
    ForgedSkillEntry skill,
    String realDir,
  ) {
    final baseRows = scanRealFilesForSkill(skill);
    if (baseRows.isEmpty) return baseRows;
    if (skill.category == 'smart_file_janitor') {
      final organizedRows = <Map<String, Object?>>[];
      for (final row in baseRows) {
        final srcPath = '${row['DuongDanGoc'] ?? ''}';
        final name = '${row['TenTep'] ?? ''}';
        final ext = '${row['DinhDang'] ?? ''}'.toLowerCase();
        if (srcPath.isEmpty || name.isEmpty) continue;
        final bucket = switch (ext) {
          'pdf' || 'doc' || 'docx' => 'TaiLieu_VanBan',
          'xlsx' || 'xls' || 'csv' || 'tsv' || 'json' || 'xml' =>
            'BangTinh_DuLieu',
          'png' || 'jpg' || 'jpeg' || 'webp' || 'heic' || 'mp4' || 'mov' =>
            'HinhAnh_Media',
          'txt' || 'md' || 'log' => 'GhiChu_Markdown',
          _ => 'TepKhac',
        };
        final bucketDir = Directory('$realDir/$bucket');
        bucketDir.createSync(recursive: true);
        final destPath = '${bucketDir.path}/$name';
        try {
          if (File(srcPath).existsSync() && srcPath != destPath) {
            File(srcPath).copySync(destPath);
          }
        } catch (_) {}
        organizedRows.add(<String, Object?>{
          ...row,
          'NhomPhanLoai': bucket,
          'DuongDanDaPhanLoai': destPath,
        });
      }
      return organizedRows;
    }
    if (skill.category == 'media_batch_renamer') {
      final renamedDir = Directory('$realDir/Media_DaDoiTen');
      renamedDir.createSync(recursive: true);
      final now = DateTime.now().toLocal();
      final ym = '${now.year}-${now.month.toString().padLeft(2, '0')}';
      final renamedRows = <Map<String, Object?>>[];
      for (var i = 0; i < baseRows.length; i++) {
        final row = baseRows[i];
        final srcPath = '${row['DuongDanGoc'] ?? ''}';
        final ext = '${row['DinhDang'] ?? 'FILE'}'.toLowerCase();
        final newName =
            '${ym}_Media_${(i + 1).toString().padLeft(3, '0')}.$ext';
        final destPath = '${renamedDir.path}/$newName';
        try {
          if (File(srcPath).existsSync() && srcPath != destPath) {
            File(srcPath).copySync(destPath);
          }
        } catch (_) {}
        renamedRows.add(<String, Object?>{
          ...row,
          'TenMoiDaChuanHoa': newName,
          'DuongDanMoi': destPath,
        });
      }
      return renamedRows;
    }
    return baseRows;
  }

  void writeOpenClawExecutableSkillScripts(
    ForgedSkillEntry entry,
    String realDir,
  ) {
    try {
      final scriptsDir = Directory('$realDir/scripts');
      scriptsDir.createSync(recursive: true);
      final exts = entry.fileExtensions.isEmpty
          ? '*'
          : entry.fileExtensions.join(',');
      final shScript = '''#!/usr/bin/env bash
set -euo pipefail
# Generated by XUNA OmniForge (OpenClaw AgentSkills compatible)
# Skill: ${entry.skillId} — ${entry.titleVi}
# Goal: ${entry.goal}
SKILL_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")/.." && pwd)"
echo "[XUNA Skill] Running ${entry.skillId} in \$SKILL_DIR (extensions: $exts)"
ls -la "\$SKILL_DIR"
''';
      final psScript = '''# Generated by XUNA OmniForge (OpenClaw AgentSkills compatible)
# Skill: ${entry.skillId} — ${entry.titleVi}
# Goal: ${entry.goal}
\$SkillDir = Split-Path -Parent \$PSScriptRoot
Write-Output "[XUNA Skill] Running ${entry.skillId} in \$SkillDir (extensions: $exts)"
Get-ChildItem -Path \$SkillDir | Select-Object Name, Length, LastWriteTime
''';
      final shFile = File('${scriptsDir.path}/run_skill.sh');
      shFile.writeAsStringSync(shScript);
      if (!Platform.isWindows) {
        try {
          Process.runSync('/bin/chmod', <String>['+x', shFile.path]);
        } catch (_) {}
      }
      File('${scriptsDir.path}/run_skill.ps1').writeAsStringSync(psScript);
    } catch (_) {}
  }

  ForgedSkillEntry? forgeSkill({
    required String goal,
    String? targetFolder,
    List<String>? fileExtensions,
  }) {
    final svc = getSymbioticService();
    final cleanGoal = goal.trim();
    if (svc == null || cleanGoal.isEmpty) {
      setFrontierStatusSummaryVi(
        '⚠️ Hãy nhập mô tả công việc bạn muốn XUNA tạo thành Tool nhé!',
      );
      return null;
    }
    var entry = svc.synthesizeSkill(
      goal: cleanGoal,
      targetFolder: (targetFolder == null || targetFolder.trim().isEmpty)
          ? null
          : targetFolder.trim(),
      fileExtensions: fileExtensions,
    );
    if (!Platform.environment.containsKey('FLUTTER_TEST')) {
      try {
        final realDir = resolveRealSkillDirectory(entry.targetFolder);
        Directory(realDir).createSync(recursive: true);
        final realRows = scanRealFilesForSkill(entry);
        final mdRes = svc.bridgeSkillMarkdown(
          action: 'export_skill_md',
          skillId: entry.skillId,
        );
        if (mdRes.skillMarkdown.isNotEmpty) {
          File('$realDir/SKILL.md').writeAsStringSync(mdRes.skillMarkdown);
        }
        File('$realDir/recipe.json').writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(entry.toWireJson()),
        );
        writeOpenClawExecutableSkillScripts(entry, realDir);
        if (realRows.isNotEmpty) {
          final firstFile = realRows.first['TenTep'] ?? 'file';
          final updated = ForgedSkillEntry(
            skillId: entry.skillId,
            titleVi: entry.titleVi,
            category: entry.category,
            goal: entry.goal,
            targetFolder: entry.targetFolder,
            fileExtensions: entry.fileExtensions,
            detectedItemsCount: realRows.length,
            dryRunSample:
                'Quét thật ${realRows.length} tệp trên máy (mẫu: "$firstFile") → xuất vào "$realDir/BangKe_TongHop.csv"',
            selfDebugIterations: entry.selfDebugIterations,
            parameterFields: entry.parameterFields,
            scriptSteps: entry.scriptSteps,
            summaryVi: entry.summaryVi,
            createdAt: entry.createdAt,
            runCount: entry.runCount,
            lastRunSummaryVi: 'Thư mục thật trên máy: $realDir',
            selfHealGeneration: entry.selfHealGeneration,
            correctionRules: entry.correctionRules,
            primitives: entry.primitives,
            canvasSurfaceKind: entry.canvasSurfaceKind,
            version: entry.version,
            versionHistory: entry.versionHistory,
            autoTriggerOnDelta: entry.autoTriggerOnDelta,
            selfTestPassed: entry.selfTestPassed,
          );
          final list = svc.forge.forgedSkillsMutable;
          final idx = list.indexWhere((s) => s.skillId == entry.skillId);
          if (idx >= 0) {
            list[idx] = updated;
            entry = updated;
          }
        }
        setFrontierStatusSummaryVi(
          '🛠️ Đã viết xong Tool "${entry.titleVi}" (${entry.detectedItemsCount} tệp thật trên máy) → $realDir',
        );
        unawaited(
          channel.showToast(
            title: 'XUNA đã tạo Tool mới',
            body:
                '${entry.titleVi} — Sẵn sàng chạy với ${entry.detectedItemsCount} tệp thật',
          ),
        );
      } catch (_) {
        setFrontierStatusSummaryVi(
          '🛠️ Đã viết xong Tool "${entry.titleVi}" (${entry.skillId}) — thư mục: ${entry.targetFolder}',
        );
      }
    } else {
      setFrontierStatusSummaryVi(
        '🛠️ Đã viết xong Tool "${entry.titleVi}" (${entry.skillId}) — thư mục: ${entry.targetFolder}',
      );
    }
    refreshSymbioticState();
    return entry;
  }

  Map<String, Object?>? runForgedSkill(String skillId) {
    final svc = getSymbioticService();
    if (svc == null) return null;
    final res = svc.runForgedSkill(skillId: skillId);
    var processedCount = res.processedCount;
    var outputDirectory = res.outputDirectory;
    var exportedCsvFile = res.exportedCsvFile;
    var summaryVi = res.summaryVi;

    if (!Platform.environment.containsKey('FLUTTER_TEST')) {
      try {
        final list = svc.forge.forgedSkillsMutable;
        final idx = list.indexWhere((s) => s.skillId == res.skillId);
        final entry = idx >= 0
            ? list[idx]
            : (list.isNotEmpty ? list.first : null);
        if (entry != null) {
          final realDir = resolveRealSkillDirectory(entry.targetFolder);
          Directory(realDir).createSync(recursive: true);
          final realRows = executeRealFileOperationsForSkill(entry, realDir);
          final rowsToWrite = realRows.isNotEmpty
              ? realRows
              : <Map<String, Object?>>[
                  for (var i = 0; i < entry.scriptSteps.length; i++)
                    <String, Object?>{
                      'Buoc': i + 1,
                      'MoTaThaoTac': entry.scriptSteps[i],
                      'MucTieu': entry.goal,
                      'ThoiGianChay': DateTime.now().toLocal().toIso8601String(),
                    },
                ];
          final csvFilePath = svc.pipeline.exportUniversalArtifactToDisk(
            filePath: '$realDir/BangKe_TongHop.csv',
            format: 'csv',
            titleVi: entry.titleVi,
            rows: rowsToWrite,
          );
          final mdFilePath = svc.pipeline.exportUniversalArtifactToDisk(
            filePath: '$realDir/BaoCao_KetQua.md',
            format: 'md',
            titleVi: '${entry.titleVi} — Báo cáo kết quả thực thi',
            rows: rowsToWrite,
          );
          final mdBridge = svc.bridgeSkillMarkdown(
            action: 'export_skill_md',
            skillId: entry.skillId,
          );
          if (mdBridge.skillMarkdown.isNotEmpty) {
            File('$realDir/SKILL.md').writeAsStringSync(mdBridge.skillMarkdown);
          }
          File('$realDir/recipe.json').writeAsStringSync(
            const JsonEncoder.withIndent('  ').convert(entry.toWireJson()),
          );

          processedCount = rowsToWrite.length;
          outputDirectory = realDir;
          exportedCsvFile = csvFilePath;
          summaryVi =
              'Đã chạy thật "${entry.titleVi}": xử lý $processedCount mục và xuất file thật tại "$exportedCsvFile" (+ "$mdFilePath")';

          if (idx >= 0) {
            list[idx] = ForgedSkillEntry(
              skillId: entry.skillId,
              titleVi: entry.titleVi,
              category: entry.category,
              goal: entry.goal,
              targetFolder: entry.targetFolder,
              fileExtensions: entry.fileExtensions,
              detectedItemsCount: processedCount,
              dryRunSample: entry.dryRunSample,
              selfDebugIterations: entry.selfDebugIterations,
              parameterFields: entry.parameterFields,
              scriptSteps: entry.scriptSteps,
              summaryVi: entry.summaryVi,
              createdAt: entry.createdAt,
              runCount: entry.runCount,
              lastRunSummaryVi: summaryVi,
              selfHealGeneration: entry.selfHealGeneration,
              correctionRules: entry.correctionRules,
              primitives: entry.primitives,
              canvasSurfaceKind: entry.canvasSurfaceKind,
              version: entry.version,
              versionHistory: entry.versionHistory,
              autoTriggerOnDelta: entry.autoTriggerOnDelta,
              selfTestPassed: entry.selfTestPassed,
            );
          }
          unawaited(_triggerSideEffectsForSkillRun(entry, exportedCsvFile));
        }
      } catch (_) {}
    }

    setFrontierStatusSummaryVi('▶ $summaryVi');
    refreshSymbioticState();
    return <String, Object?>{
      'skillId': res.skillId,
      'processedCount': processedCount,
      'outputDirectory': outputDirectory,
      'exportedCsvFile': exportedCsvFile,
      'selfHealedSelectors': res.selfHealedSelectors,
      'undoSnapshotId': res.undoSnapshotId,
      'summaryVi': summaryVi,
    };
  }

  Future<void> _triggerSideEffectsForSkillRun(
    ForgedSkillEntry entry,
    String exportedCsvFile,
  ) async {
    try {
      final urlMatch = RegExp(r'https://[^\s"<>]+').firstMatch(entry.goal);
      if (urlMatch != null) {
        await channel.urlOpen(urlMatch.group(0)!);
      }
      final ideFlowSummary =
          await appAutomationRunner.tryExecuteCodingAgentOrIdeProjectFlow(
        entry.goal,
      );
      if (ideFlowSummary != null) {
        setFrontierStatusSummaryVi(ideFlowSummary);
      } else {
        final matchedApp =
            appAutomationRunner.findInstalledAppFromText(entry.goal);
        if (matchedApp != null) {
          await channel.appLaunch(
            target: matchedApp.target,
            kind: matchedApp.kind,
          );
          if (!Platform.environment.containsKey('FLUTTER_TEST')) {
            await Future<void>.delayed(const Duration(milliseconds: 900));
          }
          var nativeSnap = await channel.inspectWindowUiTree(
            windowTitle: matchedApp.name,
            maxNodes: 40,
          );
          if (nativeSnap.nodes.isEmpty &&
              !Platform.environment.containsKey('FLUTTER_TEST')) {
            await Future<void>.delayed(const Duration(milliseconds: 700));
            nativeSnap = await channel.inspectWindowUiTree(
              windowTitle: matchedApp.name,
              maxNodes: 40,
            );
          }
          final richIntent = appAutomationRunner.detectRichOpenClawUiAction(
            entry.goal,
            matchedApp.name,
            nativeSnap.nodes,
          );
          if (richIntent != null) {
            final actRes = await channel.invokeWindowUiControl(
              action: richIntent.action,
              windowTitle: matchedApp.name,
              refId: richIntent.refId,
              valueText: richIntent.valueText,
              submit: richIntent.submit,
            );
            appAutomationRunner.recordTrajectoryStep(
              windowTitle: matchedApp.name,
              action: richIntent.action,
              refId: richIntent.refId,
              valueText: richIntent.valueText,
              detail: actRes.detail,
            );
            if (actRes.nodes.isNotEmpty &&
                richIntent.action == 'set_value_ref' &&
                richIntent.valueText.isNotEmpty) {
              final followUpRef = appAutomationRunner.findBestResultNodeRefId(
                actRes.nodes,
                richIntent.valueText,
                excludeRefId: richIntent.refId,
              );
              if (followUpRef != null) {
                final followRes = await channel.invokeWindowUiControl(
                  action: 'invoke_ref',
                  windowTitle: matchedApp.name,
                  refId: followUpRef,
                );
                appAutomationRunner.recordTrajectoryStep(
                  windowTitle: matchedApp.name,
                  action: 'invoke_ref',
                  refId: followUpRef,
                  valueText: '',
                  detail: followRes.detail,
                );
              }
            }
          }
        }
      }
      if (Platform.isMacOS && File(exportedCsvFile).existsSync()) {
        await Process.run('/usr/bin/open', <String>['-R', exportedCsvFile]);
      } else if (Platform.isWindows && File(exportedCsvFile).existsSync()) {
        await Process.run('explorer.exe', <String>[
          '/select,${exportedCsvFile.replaceAll('/', '\\')}',
        ]);
      }
      await channel.showToast(
        title: 'Đã chạy xong: ${entry.titleVi}',
        body: 'Đã xuất kết quả thật tại $exportedCsvFile',
      );
    } catch (_) {}
  }

  Future<void> openForgedSkillOutputFolder(String skillId) async {
    final svc = getSymbioticService();
    if (svc == null) return;
    final list = svc.listForgedSkillEntries();
    final idx = list.indexWhere((s) => s.skillId == skillId);
    final entry = idx >= 0 ? list[idx] : (list.isNotEmpty ? list.first : null);
    if (entry == null) return;
    final realDir = resolveRealSkillDirectory(entry.targetFolder);
    try {
      Directory(realDir).createSync(recursive: true);
      if (!Platform.environment.containsKey('FLUTTER_TEST')) {
        if (Platform.isMacOS) {
          await Process.run('/usr/bin/open', <String>[realDir]);
        } else if (Platform.isWindows) {
          await Process.run('explorer.exe', <String>[
            realDir.replaceAll('/', '\\'),
          ]);
        }
      }
      setFrontierStatusSummaryVi('📂 Đã mở thư mục kết quả: $realDir');
    } catch (_) {}
  }
}
