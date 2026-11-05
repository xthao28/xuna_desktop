import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_desktop/features/discovery/auto_app_scanner.dart';
import 'package:xuna_desktop/features/discovery/auto_symbiotic_service.dart';
import 'package:xuna_desktop/features/discovery/auto_workspace_indexer.dart';

/// Handles 3-tier app playbook inspection, OpenClaw coding-agent / IDE workspace flows,
/// natural-language UI intent parsing, and trajectory recording/replay for [DesktopAgentController].
class DesktopAppAutomationRunner {
  DesktopAppAutomationRunner({
    required this.channel,
    required this.appScanner,
    required this.workspaceIndexer,
    required this.getSymbioticService,
    required this.getDiscoveredApps,
    required this.scanInstalledApps,
    required this.getDiscoveredWorkspaces,
    required this.scanWorkspaces,
    required this.recordedTrajectorySteps,
    required this.resolveRealSkillDirectory,
    required this.setFrontierStatusSummaryVi,
    required this.refreshSymbioticState,
  });

  final XunaHostChannel channel;
  final AutoAppScanner appScanner;
  final AutoWorkspaceIndexer workspaceIndexer;
  final AutoSymbioticService? Function() getSymbioticService;
  final List<DiscoveredApp> Function() getDiscoveredApps;
  final List<DiscoveredApp> Function() scanInstalledApps;
  final List<DiscoveredWorkspace> Function() getDiscoveredWorkspaces;
  final List<DiscoveredWorkspace> Function() scanWorkspaces;
  final List<Map<String, Object?>> recordedTrajectorySteps;
  final String Function(String rawFolder) resolveRealSkillDirectory;
  final void Function(String summaryVi) setFrontierStatusSummaryVi;
  final void Function() refreshSymbioticState;

  Future<void> launchAppForPlaybookInspection(
    String rawAppName,
    AppPlaybookEntry entry, {
    String? customActionVi,
  }) async {
    try {
      final combinedText =
          customActionVi != null && customActionVi.trim().isNotEmpty
          ? '$rawAppName ${customActionVi.trim()}'
          : rawAppName;
      final ideFlowSummary = await tryExecuteCodingAgentOrIdeProjectFlow(
        combinedText,
        fallbackAppName: rawAppName,
      );
      if (ideFlowSummary != null) {
        setFrontierStatusSummaryVi(ideFlowSummary);
        refreshSymbioticState();
        await channel.showToast(
          title: 'XUNA Coding Agent & IDE (${entry.appName})',
          body: ideFlowSummary,
        );
        return;
      }

      final matched = findInstalledAppFromText(rawAppName);
      final targetAppName = matched?.name ?? entry.appName;
      if (matched != null) {
        await channel.appLaunch(target: matched.target, kind: matched.kind);
        if (!Platform.environment.containsKey('FLUTTER_TEST')) {
          await Future<void>.delayed(const Duration(milliseconds: 900));
        }
      }
      var nativeSnap = await channel.inspectWindowUiTree(
        windowTitle: targetAppName,
        maxNodes: 40,
      );
      if (nativeSnap.nodes.isEmpty &&
          matched != null &&
          !Platform.environment.containsKey('FLUTTER_TEST')) {
        await Future<void>.delayed(const Duration(milliseconds: 700));
        nativeSnap = await channel.inspectWindowUiTree(
          windowTitle: targetAppName,
          maxNodes: 40,
        );
      }
      final svc = getSymbioticService();
      if (nativeSnap.nodes.isNotEmpty) {
        svc?.uiAccessibility.applyNativeWindowUiTree(
          windowTitle: nativeSnap.windowTitle.isNotEmpty
              ? nativeSnap.windowTitle
              : targetAppName,
          nodes: nativeSnap.nodes,
        );
        svc?.learnOrInspectApp(
          targetAppName,
          customActionVi: customActionVi,
        );
      }

      final richIntent = detectRichOpenClawUiAction(
        customActionVi ?? rawAppName,
        targetAppName,
        nativeSnap.nodes,
      );
      var statusMsg = '';
      if (richIntent != null) {
        var actRes = await channel.invokeWindowUiControl(
          action: richIntent.action,
          windowTitle: targetAppName,
          refId: richIntent.refId,
          valueText: richIntent.valueText,
          submit: richIntent.submit,
        );
        recordTrajectoryStep(
          windowTitle: targetAppName,
          action: richIntent.action,
          refId: richIntent.refId,
          valueText: richIntent.valueText,
          detail: actRes.detail,
        );
        if (actRes.nodes.isNotEmpty) {
          svc?.uiAccessibility.applyNativeWindowUiTree(
            windowTitle: actRes.windowTitle.isNotEmpty
                ? actRes.windowTitle
                : targetAppName,
            nodes: actRes.nodes,
          );
          if (richIntent.action == 'set_value_ref' &&
              richIntent.valueText.isNotEmpty) {
            final followUpRef = findBestResultNodeRefId(
              actRes.nodes,
              richIntent.valueText,
              excludeRefId: richIntent.refId,
            );
            if (followUpRef != null) {
              actRes = await channel.invokeWindowUiControl(
                action: 'invoke_ref',
                windowTitle: targetAppName,
                refId: followUpRef,
              );
              recordTrajectoryStep(
                windowTitle: targetAppName,
                action: 'invoke_ref',
                refId: followUpRef,
                valueText: '',
                detail: actRes.detail,
              );
              if (actRes.nodes.isNotEmpty) {
                svc?.uiAccessibility.applyNativeWindowUiTree(
                  windowTitle: actRes.windowTitle.isNotEmpty
                      ? actRes.windowTitle
                      : targetAppName,
                  nodes: actRes.nodes,
                );
              }
            }
          }
          svc?.learnOrInspectApp(
            targetAppName,
            customActionVi: customActionVi,
          );
        }
        if (actRes.detail.isNotEmpty) {
          statusMsg = '🚀 ${actRes.detail}';
          setFrontierStatusSummaryVi(statusMsg);
        } else if (matched != null) {
          statusMsg =
              '🚀 Đã mở "${matched.name}" & thực thi thao tác (${richIntent.action}): ${richIntent.valueText}';
          setFrontierStatusSummaryVi(statusMsg);
        }
      } else if (matched != null) {
        final count = nativeSnap.nodes.isNotEmpty
            ? nativeSnap.nodes.length
            : entry.peekabooNodes.length;
        statusMsg =
            '🚀 Đã mở "${matched.name}" & quét $count phần tử UI (${entry.tierBadgeVi})';
        setFrontierStatusSummaryVi(statusMsg);
      }
      refreshSymbioticState();
      await channel.showToast(
        title: 'XUNA Điều Khiển App (${entry.appName})',
        body: statusMsg.isNotEmpty ? statusMsg : entry.lastActionSummaryVi,
      );
    } catch (_) {}
  }

  Future<String?> tryExecuteCodingAgentOrIdeProjectFlow(
    String rawText, {
    String? fallbackAppName,
  }) async {
    final lower = rawText.toLowerCase();
    String? requestedAgent;
    if (lower.contains('claude code') ||
        lower.contains('claude-code') ||
        RegExp(r'\bclaude\b').hasMatch(lower)) {
      requestedAgent = 'claude_code';
    } else if (lower.contains('antigravity') ||
        RegExp(r'\bagy\b').hasMatch(lower)) {
      requestedAgent = 'antigravity';
    } else if (RegExp(r'\bcursor\b').hasMatch(lower)) {
      requestedAgent = 'cursor';
    } else if (lower.contains('vs code') ||
        lower.contains('vscode') ||
        lower.contains('visual studio code')) {
      requestedAgent = 'vscode';
    } else if (RegExp(r'\bcodex\b').hasMatch(lower)) {
      requestedAgent = 'codex';
    }
    if (requestedAgent == null) return null;

    var workspaces = getDiscoveredWorkspaces();
    if (workspaces.isEmpty) {
      workspaces = scanWorkspaces();
    }
    DiscoveredWorkspace? matchedWs;
    for (final ws in workspaces) {
      final aliasLower = ws.alias.toLowerCase();
      if (aliasLower.length >= 2 && lower.contains(aliasLower)) {
        matchedWs = ws;
        break;
      }
    }
    if (matchedWs == null) {
      final projMatch = RegExp(
        r'(?:project|dự án|workspace|repo|thư mục)\s+([a-zA-Z0-9_.\-]+)',
        caseSensitive: false,
      ).firstMatch(rawText);
      if (projMatch != null) {
        matchedWs = workspaceIndexer.resolveWorkspace(projMatch.group(1)!);
      }
    }
    final mentionsProjectOrPrompt =
        matchedWs != null ||
        requestedAgent == 'claude_code' ||
        requestedAgent == 'codex' ||
        lower.contains('project') ||
        lower.contains('dự án') ||
        lower.contains('prompt');
    if (!mentionsProjectOrPrompt) return null;

    matchedWs ??= workspaceIndexer.resolveWorkspace('recent');
    if (matchedWs == null) return null;

    final resolvedAgent =
        appScanner.resolveCodingAgent(requestedAgent) ??
        appScanner.resolveCodingAgent('auto');
    if (resolvedAgent == null) return null;

    final prompt = extractInAppQueryFromGoal(
      rawText,
      fallbackAppName ?? resolvedAgent.agent,
    );
    final plan = await workspaceIndexer.launchCodingAgent(
      workspace: matchedWs,
      agent: resolvedAgent.agent,
      executable: resolvedAgent.executable,
      resumeLast: true,
      prompt: prompt,
    );

    if (prompt != null &&
        prompt.isNotEmpty &&
        plan.agent != 'claude_code' &&
        plan.agent != 'codex' &&
        !Platform.environment.containsKey('FLUTTER_TEST')) {
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      final ideWinTitle = switch (plan.agent) {
        'antigravity' => 'Antigravity',
        'cursor' => 'Cursor',
        'vscode' => 'Visual Studio Code',
        _ => plan.agent,
      };
      await channel.invokeWindowUiControl(
        action: 'shortcut',
        windowTitle: ideWinTitle,
        refId: Platform.isMacOS ? 'shortcut:cmd+l' : 'shortcut:ctrl+l',
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await channel.invokeWindowUiControl(
        action: 'set_value_ref',
        windowTitle: ideWinTitle,
        refId: 'auto_search',
        valueText: prompt,
        submit: true,
      );
      recordTrajectoryStep(
        windowTitle: ideWinTitle,
        action: 'set_value_ref',
        refId: 'ai_agent_prompt',
        valueText: prompt,
        detail: 'IDE_PROJECT_PROMPT_SUBMITTED:${matchedWs.alias}',
      );
    }

    return prompt != null && prompt.isNotEmpty
        ? '🚀 Đã mở dự án "${matchedWs.alias}" trên ${plan.agent} & gửi prompt: "$prompt"'
        : '🚀 Đã mở dự án "${matchedWs.alias}" trên ${plan.agent} (${matchedWs.path})';
  }

  ({String action, String refId, String valueText, bool submit})?
  detectRichOpenClawUiAction(
    String rawText,
    String targetAppName,
    List<Map<String, Object?>> nodes,
  ) {
    final text = rawText.trim();
    if (text.isEmpty) return null;
    final lower = text.toLowerCase();

    final menuMatch = RegExp(
      r'(?:menu|thanh menu)\s+(.+)$',
      caseSensitive: false,
    ).firstMatch(text);
    if (menuMatch != null || text.contains(' > ')) {
      final menuSpec = (menuMatch?.group(1) ?? text).trim();
      return (
        action: 'invoke_menu',
        refId: menuSpec,
        valueText: menuSpec,
        submit: false,
      );
    }

    if (RegExp(r'\b(?:cuộn|scroll|lăn chuột)\b', caseSensitive: false)
        .hasMatch(lower)) {
      final dir = (lower.contains('lên') || lower.contains('up'))
          ? 'scroll_up'
          : (lower.contains('trái') || lower.contains('left'))
          ? 'scroll_left'
          : (lower.contains('phải') || lower.contains('right'))
          ? 'scroll_right'
          : 'scroll_down';
      return (
        action: dir,
        refId: 'window',
        valueText: dir.replaceFirst('scroll_', ''),
        submit: false,
      );
    }

    final firstNodeRef = nodes.isNotEmpty
        ? (nodes.first['refId']?.toString() ?? 'ui_1')
        : 'ui_1';

    // Clicks need a named target that matches a live node; never fall back to an
    // arbitrary first element (it can be the window close button).
    if (lower.contains('click đúp') ||
        lower.contains('nháy đúp') ||
        lower.contains('double click')) {
      final q = extractInAppQueryFromGoal(text, targetAppName);
      final ref = q == null
          ? null
          : findBestResultNodeRefId(nodes, q, excludeRefId: '');
      if (q == null || ref == null) return null;
      return (
        action: 'double_click',
        refId: ref,
        valueText: q,
        submit: false,
      );
    }
    if (lower.contains('chuột phải') || lower.contains('right click')) {
      final q = extractInAppQueryFromGoal(text, targetAppName);
      final ref = q == null
          ? null
          : findBestResultNodeRefId(nodes, q, excludeRefId: '');
      if (q == null || ref == null) return null;
      return (
        action: 'right_click',
        refId: ref,
        valueText: q,
        submit: false,
      );
    }
    if (lower.contains('kéo thả') || RegExp(r'\bdrag\b').hasMatch(lower)) {
      final coordMatch = RegExp(
        r'(\d+\s*,\s*\d+\s*->\s*\d+\s*,\s*\d+)',
      ).firstMatch(text);
      final spec = coordMatch?.group(1) ?? '400,400->580,400';
      return (
        action: 'drag',
        refId: firstNodeRef,
        valueText: spec,
        submit: false,
      );
    }

    final clickMatch = RegExp(
      r'(?:bấm nút|nhấn nút|bấm vào|nhấn vào|click vào|click)\s+(.+)$',
      caseSensitive: false,
    ).firstMatch(text);
    if (clickMatch != null) {
      final targetLabel = (clickMatch.group(1) ?? '')
          .trim()
          .replaceAll(RegExp(r'^["“]|["”]$'), '');
      if (targetLabel.isNotEmpty) {
        final matchedRef =
            findBestResultNodeRefId(nodes, targetLabel, excludeRefId: '') ??
            targetLabel;
        return (
          action: 'invoke_ref',
          refId: matchedRef,
          valueText: targetLabel,
          submit: false,
        );
      }
    }

    final inAppAction = extractInAppQueryFromGoal(text, targetAppName);
    if (inAppAction != null && inAppAction.isNotEmpty) {
      final editableRefId = findFirstEditableRefId(nodes) ?? 'auto_search';
      return (
        action: 'set_value_ref',
        refId: editableRefId,
        valueText: inAppAction,
        submit: true,
      );
    }
    return null;
  }

  void recordTrajectoryStep({
    required String windowTitle,
    required String action,
    required String refId,
    required String valueText,
    required String detail,
  }) {
    final step = <String, Object?>{
      'stepIndex': recordedTrajectorySteps.length + 1,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'windowTitle': windowTitle,
      'action': action,
      'refId': refId,
      'valueText': valueText,
      'detail': detail,
    };
    recordedTrajectorySteps.add(step);
    if (recordedTrajectorySteps.length > 50) {
      recordedTrajectorySteps.removeAt(0);
    }
    if (!Platform.environment.containsKey('FLUTTER_TEST')) {
      try {
        final trajDir = Directory(resolveRealSkillDirectory('Trajectories'));
        trajDir.createSync(recursive: true);
        File('${trajDir.path}/latest_trajectory.json').writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(<String, Object?>{
            'updatedAt': DateTime.now().toUtc().toIso8601String(),
            'stepCount': recordedTrajectorySteps.length,
            'steps': recordedTrajectorySteps.toList(),
          }),
        );
      } catch (_) {}
    }
  }

  Future<Map<String, Object?>> replayRecordedTrajectory({
    int delayMs = 450,
    bool stopOnError = false,
  }) async {
    final steps = List<Map<String, Object?>>.from(recordedTrajectorySteps);
    if (steps.isEmpty) {
      setFrontierStatusSummaryVi(
        '⚠️ Chưa có bước thao tác nào trong Trajectory để phát lại!',
      );
      return const <String, Object?>{
        'replayedSteps': 0,
        'totalSteps': 0,
        'completed': false,
      };
    }
    var replayed = 0;
    for (final step in steps) {
      final winTitle = '${step['windowTitle'] ?? ''}';
      final action = '${step['action'] ?? 'invoke_ref'}';
      final refId = '${step['refId'] ?? 'ui_1'}';
      final valueText = '${step['valueText'] ?? ''}';
      try {
        final res = await channel.invokeWindowUiControl(
          action: action,
          windowTitle: winTitle.isEmpty ? null : winTitle,
          refId: refId,
          valueText: valueText.isEmpty ? null : valueText,
          submit: action == 'set_value_ref',
        );
        replayed++;
        if (!res.ok && stopOnError) break;
        if (delayMs > 0 && !Platform.environment.containsKey('FLUTTER_TEST')) {
          await Future<void>.delayed(Duration(milliseconds: delayMs));
        }
      } catch (_) {
        if (stopOnError) break;
      }
    }
    setFrontierStatusSummaryVi(
      '🔁 Đã phát lại Trajectory: $replayed/${steps.length} bước thao tác thành công!',
    );
    refreshSymbioticState();
    return <String, Object?>{
      'replayedSteps': replayed,
      'totalSteps': steps.length,
      'completed': replayed == steps.length,
    };
  }

  String? findFirstEditableRefId(List<Map<String, Object?>> nodes) {
    for (final node in nodes) {
      final role = (node['role']?.toString() ?? '').toLowerCase();
      final refId = node['refId']?.toString() ?? '';
      if (refId.isEmpty) continue;
      if (role.contains('search') ||
          role.contains('text') ||
          role.contains('edit') ||
          role.contains('combo')) {
        return refId;
      }
    }
    return null;
  }

  String? findBestResultNodeRefId(
    List<Map<String, Object?>> nodes,
    String query, {
    required String excludeRefId,
  }) {
    final tokens = query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((t) => t.length >= 2)
        .toList();
    if (tokens.isEmpty) return null;
    for (final node in nodes) {
      final refId = node['refId']?.toString() ?? '';
      if (refId.isEmpty || refId == excludeRefId) continue;
      final role = (node['role']?.toString() ?? '').toLowerCase();
      if (role.contains('search') ||
          role.contains('textfield') ||
          role.contains('edit')) {
        continue;
      }
      final label = (node['label']?.toString() ?? '').toLowerCase();
      if (tokens.every((t) => label.contains(t))) {
        return refId;
      }
    }
    return null;
  }

  String? extractInAppQueryFromGoal(String rawText, String appName) {
    final text = rawText.trim();
    if (text.isEmpty) return null;

    final quotedMatch = RegExp(r'["“]([^"”\n]+)["”]').firstMatch(text);
    if (quotedMatch != null) {
      final q = (quotedMatch.group(1) ?? '').trim();
      if (q.isNotEmpty && q.toLowerCase() != appName.toLowerCase()) {
        return q;
      }
    }

    final actionMatch = RegExp(
      r'(?:tìm kiếm|tìm|search|nhập|gõ|gửi|prompt|hỏi|chạy lệnh|mở bài|phát|bật|nghe|chọn|open|play|run)\s+(.+)$',
      caseSensitive: false,
    ).firstMatch(text);
    if (actionMatch != null) {
      final query = (actionMatch.group(1) ?? '').trim();
      if (query.isNotEmpty &&
          query.toLowerCase() != appName.toLowerCase() &&
          !appName.toLowerCase().contains(query.toLowerCase())) {
        return query;
      }
    }
    return null;
  }

  DiscoveredApp? findInstalledAppFromText(String rawText) {
    final text = rawText.trim();
    if (text.isEmpty) return null;
    var apps = getDiscoveredApps();
    if (apps.isEmpty) {
      apps = scanInstalledApps();
    }
    for (final part in text.split(RegExp(r'[/,|]'))) {
      final q = part.trim();
      if (q.isEmpty) continue;
      final direct = appScanner.findApp(q);
      if (direct != null) return direct;
    }
    final lower = text.toLowerCase();
    DiscoveredApp? bestMatch;
    var bestScore = 0;
    for (final app in apps) {
      final appLower = app.name.toLowerCase();
      final targetStem = app.target
          .split(RegExp(r'[/\\]'))
          .last
          .replaceAll(RegExp(r'\.(app|exe|lnk)$', caseSensitive: false), '')
          .toLowerCase();
      if (appLower.length >= 2 && lower.contains(appLower)) {
        final score = 100 + appLower.length;
        if (score > bestScore) {
          bestScore = score;
          bestMatch = app;
        }
      } else if (targetStem.length >= 2 && lower.contains(targetStem)) {
        final score = 80 + targetStem.length;
        if (score > bestScore) {
          bestScore = score;
          bestMatch = app;
        }
      }
    }
    return bestMatch;
  }
}
