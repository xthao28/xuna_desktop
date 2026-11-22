import 'dart:typed_data';

import '../canonical_json.dart';
import '../schemas.dart';
import 'forge_swarm_validators.dart';
import 'policy_models.dart';
import 'security_redaction.dart';
import 'ui_find.dart';
import 'url_domain_validator.dart';

/// Callback signature for recursive step evaluation in `workflow.batch_steps`.
typedef EvaluateStepCallback = PolicyEvaluationResult Function({
  required String toolName,
  required Map<String, Object?> arguments,
  ApprovalToken? approval,
  required bool isStopped,
  required DateTime nowUtc,
  String? hostId,
  required List<Uint8List> pinnedPhonePublicKeys,
  required bool isInApprovedCuSession,
  required bool allowZeroConfigAppDiscovery,
  bool allowPublicHttpsDomains,
});

/// Validates tool arguments and resolves the effective [RiskTier] (plus any
/// matched app/workflow or normalized URL host) before the approval gate.
///
/// If `allowed` is `false` on the returned [PolicyEvaluationResult], the caller
/// must immediately return that failure result. If `allowed` is `true`, the
/// caller proceeds to the approval-token check using the returned
/// `effectiveRisk`, `app`, `workflow`, and `normalizedUrlHost`.
/// Checks the apps and domains of `cu.session_start` and `cu.session_extend`
/// (one implementation, so the two cannot drift). Returns `null` when every
/// item is allowed, otherwise the refusal.
PolicyEvaluationResult? validateCuSessionScope({
  required List<Object?> apps,
  required List<Object?> domains,
  required HostPolicy activePolicy,
  required bool allowZeroConfigAppDiscovery,
  required bool allowPublicHttpsDomains,
}) {
  for (final appItem in apps) {
    if (appItem is! String || !isValidShortId(appItem)) {
      return const PolicyEvaluationResult(
        allowed: false,
        status: XtpStatus.invalidArgs,
        effectiveRisk: RiskTier.r3,
        errorCode: 'schema_mismatch',
      );
    }
    if (isHardDeniedAppOrProcess(appItem)) {
      return const PolicyEvaluationResult(
        allowed: false,
        status: XtpStatus.denied,
        effectiveRisk: RiskTier.r3,
        errorCode: 'denylisted_target_forbidden',
      );
    }
    if (activePolicy.isAppDenied(appItem)) {
      return const PolicyEvaluationResult(
        allowed: false,
        status: XtpStatus.denied,
        effectiveRisk: RiskTier.r3,
        errorCode: 'policy_blocked',
      );
    }
    if (activePolicy.findApp(appItem) == null && !allowZeroConfigAppDiscovery) {
      return const PolicyEvaluationResult(
        allowed: false,
        status: XtpStatus.denied,
        effectiveRisk: RiskTier.r3,
        errorCode: 'policy_blocked',
      );
    }
  }
  for (final domainItem in domains) {
    if (domainItem is! String) {
      return const PolicyEvaluationResult(
        allowed: false,
        status: XtpStatus.invalidArgs,
        effectiveRisk: RiskTier.r3,
        errorCode: 'schema_mismatch',
      );
    }
    final String asciiDomain;
    try {
      asciiDomain = normalizeDomainAllowlistEntry(domainItem);
    } on FormatException {
      return const PolicyEvaluationResult(
        allowed: false,
        status: XtpStatus.invalidArgs,
        effectiveRisk: RiskTier.r3,
        errorCode: 'url_invalid',
      );
    }
    if (activePolicy.isDomainDenied(asciiDomain)) {
      return const PolicyEvaluationResult(
        allowed: false,
        status: XtpStatus.denied,
        effectiveRisk: RiskTier.r3,
        errorCode: 'domain_not_allowed',
      );
    }
    final domainAllowed = activePolicy.urlDomains.any(
      (allowed) => asciiDomain == allowed || asciiDomain.endsWith('.$allowed'),
    );
    if (!domainAllowed && !allowPublicHttpsDomains) {
      return const PolicyEvaluationResult(
        allowed: false,
        status: XtpStatus.denied,
        effectiveRisk: RiskTier.r3,
        errorCode: 'domain_not_allowed',
      );
    }
  }
  return null;
}

final _shortcutNamePattern = RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9 _.-]{0,119}$');

bool _isValidIsoDate(String dateStr) {
  if (dateStr.length > 50) return false;
  final trimmed = dateStr.trim();
  if (trimmed.isEmpty) return false;
  try {
    DateTime.parse(trimmed);
    return true;
  } on FormatException {
    return false;
  }
}

bool _isValidEmailAddress(String email) {
  if (email.length > 320) return false;
  final trimmed = email.trim();
  if (trimmed.isEmpty) return false;
  if (trimmed.contains('\r') ||
      trimmed.contains('\n') ||
      trimmed.contains('\x00')) {
    return false;
  }
  final atIndex = trimmed.indexOf('@');
  if (atIndex <= 0 ||
      atIndex != trimmed.lastIndexOf('@') ||
      atIndex == trimmed.length - 1) {
    return false;
  }
  final localPart = trimmed.substring(0, atIndex);
  final domainPart = trimmed.substring(atIndex + 1);
  if (domainPart.contains(' ') ||
      domainPart.contains(',') ||
      domainPart.contains('"')) {
    return false;
  }
  // Disallow unquoted spaces or commas in local-part
  bool inQuotes = false;
  for (int i = 0; i < localPart.length; i++) {
    final ch = localPart[i];
    if (ch == '"' && (i == 0 || localPart[i - 1] != r'\')) {
      inQuotes = !inQuotes;
    } else if (!inQuotes && (ch == ' ' || ch == ',')) {
      return false;
    }
  }
  if (inQuotes) return false;
  return true;
}

PolicyEvaluationResult validateToolArguments({
  required String toolName,
  required Map<String, Object?> arguments,
  required HostPolicy activePolicy,
  required DateTime now,
  required bool isStopped,
  required String? hostId,
  required List<Uint8List> pinnedPhonePublicKeys,
  required bool isInApprovedCuSession,
  required bool allowZeroConfigAppDiscovery,
  bool allowPublicHttpsDomains = false,
  required EvaluateStepCallback evaluateStep,
}) {
  late final RiskTier effectiveRisk;
  AllowedAppConfig? matchedApp;
  WorkflowConfig? matchedWorkflow;
  String? normalizedUrlHost;

  switch (toolName) {
    case 'media.play_pause':
    case 'media.next':
    case 'media.previous':
      if (arguments.isNotEmpty) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r1,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r1;
    case 'media.now_playing':
      if (arguments.isNotEmpty) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r0,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r0;
    case 'media.volume_set':
      if (arguments.length != 1 || arguments['level'] is! int) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r1,
          errorCode: 'schema_mismatch',
        );
      }
      final level = arguments['level'] as int;
      if (level < 0 || level > 100) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r1,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r1;
    case 'app.list_allowed':
    case 'workflow.list':
    case 'host.status':
      if (arguments.isNotEmpty) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r0,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r0;
    case 'app.launch':
      const allowedLaunchKeys = <String>{'id', 'openTarget'};
      final rawOpenTarget = arguments['openTarget'];
      final openTargetInvalid = rawOpenTarget != null &&
          (rawOpenTarget is! String ||
              rawOpenTarget.trim().isEmpty ||
              rawOpenTarget.length > 256 ||
              rawOpenTarget.contains('\u0000') ||
              !isSafeAgentPrompt(rawOpenTarget));
      if (arguments.isEmpty ||
          arguments.keys.any((k) => !allowedLaunchKeys.contains(k)) ||
          arguments['id'] is! String ||
          openTargetInvalid) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r2,
          errorCode: 'schema_mismatch',
        );
      }
      final appId = arguments['id'] as String;
      if (!isValidShortId(appId)) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r2,
          errorCode: 'schema_mismatch',
        );
      }
      if (isHardDeniedAppOrProcess(appId)) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.denied,
          effectiveRisk: RiskTier.r2,
          errorCode: 'denylisted_target_forbidden',
        );
      }
      if (activePolicy.isAppDenied(appId)) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.denied,
          effectiveRisk: RiskTier.r2,
          errorCode: 'policy_blocked',
        );
      }
      matchedApp = activePolicy.findApp(appId);
      if (matchedApp == null) {
        if (!allowZeroConfigAppDiscovery) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.denied,
            effectiveRisk: RiskTier.r2,
            errorCode: 'policy_blocked',
          );
        }
        effectiveRisk = RiskTier.r2;
      } else {
        effectiveRisk =
            matchedApp.risk >= RiskTier.r2 ? matchedApp.risk : RiskTier.r2;
      }
    case 'display.wake':
      if (arguments.isNotEmpty) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r1,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r1;
    case 'workspace.git_summary':
    case 'workspace.watch_task':
      final proj = arguments['project'];
      if (arguments.length != 1 ||
          proj is! String ||
          !isValidWorkspaceQuery(proj)) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r1,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r1;
    case 'selection.read':
    case 'window.active_context':
      final maxChars = arguments['maxChars'];
      if (arguments.keys.any((k) => k != 'maxChars') ||
          (maxChars != null &&
              (maxChars is! int || maxChars < 80 || maxChars > 1200))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r1,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r1;
    case 'host.lock_screen':
    case 'mcp.list_servers':
    case 'action.undo':
    case 'tv.list_devices':
      if (arguments.isNotEmpty) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r1,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r1;
    case 'tv.control':
      final device = arguments['device'];
      final action = arguments['action'];
      final level = arguments['level'];
      const allowedTvCtrlKeys = <String>{'device', 'action', 'level'};
      if (arguments.keys.any((k) => !allowedTvCtrlKeys.contains(k)) ||
          action is! String ||
          !allowedTvActions.contains(action) ||
          (device != null &&
              (device is! String || !isValidTvDeviceQuery(device))) ||
          (level != null && (level is! int || level < 0 || level > 100)) ||
          (action == 'volume_set' && level == null)) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r1,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r1;
    case 'tv.launch_app':
      final device = arguments['device'];
      final appId = arguments['appId'];
      const allowedTvLaunchKeys = <String>{'device', 'appId'};
      if (arguments.keys.any((k) => !allowedTvLaunchKeys.contains(k)) ||
          appId is! String ||
          !allowedTvAppIds.contains(appId) ||
          (device != null &&
              (device is! String || !isValidTvDeviceQuery(device)))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r2,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r2;
    case 'tv.cast_media':
      final device = arguments['device'];
      final rawUrl = arguments['url'];
      final title = arguments['title'];
      const allowedCastKeys = <String>{'device', 'url', 'title'};
      if (arguments.keys.any((k) => !allowedCastKeys.contains(k)) ||
          rawUrl is! String ||
          (device != null &&
              (device is! String || !isValidTvDeviceQuery(device))) ||
          (title != null &&
              (title is! String ||
                  title.length > 120 ||
                  !isSafeAgentPrompt(title)))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r2,
          errorCode: 'schema_mismatch',
        );
      }
      if (!isAllowedHttpsCurrentUrl(rawUrl)) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r2,
          errorCode: 'url_invalid',
        );
      }
      normalizedUrlHost = Uri.parse(rawUrl.trim()).host.toLowerCase();
      effectiveRisk = RiskTier.r2;
    case 'smarthome.list_entities':
      final domain = arguments['domain'];
      if (arguments.keys.any((k) => k != 'domain')) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r1,
          errorCode: 'schema_mismatch',
        );
      }
      if (domain != null) {
        if (domain is! String) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.invalidArgs,
            effectiveRisk: RiskTier.r1,
            errorCode: 'schema_mismatch',
          );
        }
        if (hardDeniedSmartHomeDomains.contains(domain.toLowerCase())) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.denied,
            effectiveRisk: RiskTier.r1,
            errorCode: 'smarthome_domain_forbidden',
          );
        }
        if (!allowedSmartHomeDomains.contains(domain)) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.invalidArgs,
            effectiveRisk: RiskTier.r1,
            errorCode: 'schema_mismatch',
          );
        }
      }
      effectiveRisk = RiskTier.r1;
    case 'smarthome.control':
      final entityId = arguments['entityId'];
      final action = arguments['action'];
      final value = arguments['value'];
      const allowedShKeys = <String>{'entityId', 'action', 'value'};
      if (arguments.keys.any((k) => !allowedShKeys.contains(k)) ||
          entityId is! String ||
          action is! String ||
          !allowedSmartHomeActions.contains(action) ||
          (value != null && (value is! int || value < 0 || value > 100))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r2,
          errorCode: 'schema_mismatch',
        );
      }
      if (isHardDeniedSmartHomeEntity(entityId)) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.denied,
          effectiveRisk: RiskTier.r2,
          errorCode: 'smarthome_domain_forbidden',
        );
      }
      if (!isValidSmartHomeEntityId(entityId)) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r2,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r2;
    case 'clipboard.write':
      final text = arguments['text'];
      final label = arguments['label'];
      const allowedClipKeys = <String>{'text', 'label'};
      if (arguments.keys.any((k) => !allowedClipKeys.contains(k)) ||
          text is! String ||
          !isSafeClipboardWriteText(text) ||
          (label != null &&
              (label is! String ||
                  label.length > 80 ||
                  !isSafeAgentPrompt(label)))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r2,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r2;
    case 'system.vitals':
      if (arguments.isNotEmpty) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r1,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r1;
    case 'dev.ports':
      final ports = arguments['ports'];
      if (arguments.keys.any((k) => k != 'ports')) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r1,
          errorCode: 'schema_mismatch',
        );
      }
      if (ports != null) {
        if (ports is! List || ports.length > 16) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.invalidArgs,
            effectiveRisk: RiskTier.r1,
            errorCode: 'schema_mismatch',
          );
        }
        for (final p in ports) {
          if (p is! int || p < 1024 || p > 65535) {
            return const PolicyEvaluationResult(
              allowed: false,
              status: XtpStatus.invalidArgs,
              effectiveRisk: RiskTier.r1,
              errorCode: 'schema_mismatch',
            );
          }
        }
      }
      effectiveRisk = RiskTier.r1;
    case 'beam.transfer':
      final direction = arguments['direction'];
      final kind = arguments['kind'];
      final fileName = arguments['fileName'];
      final sizeBytes = arguments['sizeBytes'];
      final sha256 = arguments['sha256'];
      final dataBase64 = arguments['dataBase64'];
      const allowedBeamKeys = <String>{
        'direction',
        'kind',
        'fileName',
        'sizeBytes',
        'sha256',
        'dataBase64',
      };
      if (arguments.keys.any((k) => !allowedBeamKeys.contains(k)) ||
          direction is! String ||
          !<String>{'phone_to_desktop', 'desktop_to_phone'}
              .contains(direction) ||
          kind is! String ||
          !<String>{'clipboard_text', 'screenshot', 'file'}.contains(kind) ||
          fileName is! String ||
          !isValidBeamFileName(fileName) ||
          sizeBytes is! int ||
          sizeBytes < 1 ||
          sizeBytes > 26214400 ||
          sha256 is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256) ||
          (dataBase64 != null &&
              (dataBase64 is! String ||
                  dataBase64.isEmpty ||
                  dataBase64.length > 16384))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r2,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r2;
    case 'mcp.call':
      final server = arguments['server'];
      final tool = arguments['tool'];
      final payloadJson = arguments['payloadJson'];
      const allowedMcpKeys = <String>{'server', 'tool', 'payloadJson'};
      if (server is! String ||
          !isValidShortId(server) ||
          tool is! String ||
          !RegExp(r'^[a-zA-Z0-9_.-]{1,64}$').hasMatch(tool) ||
          arguments.keys.any((k) => !allowedMcpKeys.contains(k)) ||
          (payloadJson != null &&
              (payloadJson is! String ||
                  payloadJson.length > 1000 ||
                  !isSafeClipboardWriteText(payloadJson)))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r2,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r2;
    case 'workspace.open':
      final proj = arguments['project'];
      final ide = arguments['ide'];
      if (proj is! String ||
          !isValidWorkspaceQuery(proj) ||
          arguments.keys.any((k) => k != 'project' && k != 'ide') ||
          (ide != null &&
              (ide is! String || !supportedWorkspaceIdes.contains(ide)))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r2,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r2;
    case 'workspace.capture_capsule':
      final proj = arguments['project'];
      final nextStepHint = arguments['nextStepHint'];
      const allowedCaptureKeys = <String>{'project', 'nextStepHint'};
      if (arguments.keys.any((k) => !allowedCaptureKeys.contains(k)) ||
          (proj != null && (proj is! String || !isValidWorkspaceQuery(proj))) ||
          (nextStepHint != null &&
              (nextStepHint is! String ||
                  nextStepHint.length > 240 ||
                  !isSafeAgentPrompt(nextStepHint)))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r1,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r1;
    case 'workspace.restore_capsule':
      final capsuleId = arguments['capsuleId'];
      final proj = arguments['project'];
      final ide = arguments['ide'];
      const allowedRestoreKeys = <String>{'capsuleId', 'project', 'ide'};
      final hasCapsuleId = capsuleId is String && isValidShortId(capsuleId);
      final hasProj = proj is String && isValidWorkspaceQuery(proj);
      if (arguments.keys.any((k) => !allowedRestoreKeys.contains(k)) ||
          (!hasCapsuleId && !hasProj) ||
          (capsuleId != null && !hasCapsuleId) ||
          (proj != null && !hasProj) ||
          (ide != null &&
              (ide is! String || !supportedWorkspaceIdes.contains(ide)))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r2,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r2;
    case 'workspace.list_capsules':
      final limit = arguments['limit'];
      if (arguments.keys.any((k) => k != 'limit') ||
          (limit != null && (limit is! int || limit < 1 || limit > 20))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r1,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r1;
    case 'pocket.push_item':
      final text = arguments['text'];
      final label = arguments['label'];
      final kind = arguments['kind'];
      final sourceDevice = arguments['sourceDevice'];
      const allowedPocketPushKeys = <String>{
        'text',
        'label',
        'kind',
        'sourceDevice',
      };
      if (arguments.keys.any((k) => !allowedPocketPushKeys.contains(k)) ||
          text is! String ||
          !isSafeClipboardWriteText(text) ||
          (label != null &&
              (label is! String ||
                  label.length > 80 ||
                  !isSafeAgentPrompt(label))) ||
          (kind != null &&
              (kind is! String || !allowedPocketItemKinds.contains(kind))) ||
          (sourceDevice != null &&
              (sourceDevice is! String ||
                  sourceDevice.length > 40 ||
                  !isSafeAgentPrompt(sourceDevice)))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r1,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r1;
    case 'pocket.list_items':
      final kind = arguments['kind'];
      final query = arguments['query'];
      final limit = arguments['limit'];
      const allowedPocketListKeys = <String>{'kind', 'query', 'limit'};
      if (arguments.keys.any((k) => !allowedPocketListKeys.contains(k)) ||
          (kind != null &&
              (kind is! String || !allowedPocketItemKinds.contains(kind))) ||
          (query != null &&
              (query is! String ||
                  query.length > 80 ||
                  !isSafeAgentPrompt(query))) ||
          (limit != null && (limit is! int || limit < 1 || limit > 20))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r1,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r1;
    case 'pocket.transform_item':
      final itemId = arguments['itemId'];
      final text = arguments['text'];
      final mode = arguments['mode'];
      const allowedTransformKeys = <String>{'itemId', 'text', 'mode'};
      final hasItemId = itemId is String && isValidShortId(itemId);
      final hasText = text is String && isSafeClipboardWriteText(text);
      if (arguments.keys.any((k) => !allowedTransformKeys.contains(k)) ||
          mode is! String ||
          !allowedPocketTransformModes.contains(mode) ||
          (!hasItemId && !hasText) ||
          (itemId != null && !hasItemId) ||
          (text != null && !hasText)) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r1,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r1;
    case 'watchdog.watch_process_or_port':
      final targetKind = arguments['targetKind'];
      final processName = arguments['processName'];
      final port = arguments['port'];
      final label = arguments['label'];
      const allowedWdKeys = <String>{
        'targetKind',
        'processName',
        'port',
        'label',
      };
      final validProcess = processName is String &&
          processName.trim().isNotEmpty &&
          processName.length <= 64 &&
          isSafeAgentPrompt(processName);
      final validPort = port is int && port >= 1024 && port <= 65535;
      if (arguments.keys.any((k) => !allowedWdKeys.contains(k)) ||
          targetKind is! String ||
          !allowedWatchdogTargetKinds.contains(targetKind) ||
          (targetKind == 'process' && !validProcess) ||
          (targetKind == 'port' && !validPort) ||
          (processName != null && !validProcess) ||
          (port != null && !validPort) ||
          (label != null &&
              (label is! String ||
                  label.length > 80 ||
                  !isSafeAgentPrompt(label)))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r1,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r1;
    case 'watchdog.watch_resource_threshold':
      final metric = arguments['metric'];
      final threshold = arguments['threshold'];
      const allowedResKeys = <String>{'metric', 'threshold'};
      if (arguments.keys.any((k) => !allowedResKeys.contains(k)) ||
          metric is! String ||
          !allowedWatchdogResourceMetrics.contains(metric) ||
          threshold is! int ||
          threshold < 1 ||
          threshold > 99) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r1,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r1;
    case 'watchdog.list_and_clear':
      final action = arguments['action'];
      if (arguments.keys.any((k) => k != 'action') ||
          (action != null &&
              (action is! String ||
                  !allowedWatchdogListActions.contains(action)))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r1,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r1;
    case 'coach.decompose_overwhelm':
      final goal = arguments['goal'];
      final project = arguments['project'];
      const allowedCoachKeys = <String>{'goal', 'project'};
      if (arguments.keys.any((k) => !allowedCoachKeys.contains(k)) ||
          goal is! String ||
          goal.trim().isEmpty ||
          goal.length > 240 ||
          !isSafeAgentPrompt(goal) ||
          (project != null &&
              (project is! String || !isValidWorkspaceQuery(project)))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r1,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r1;
    case 'habit.propose_workflow':
      final minOccurrences = arguments['minOccurrences'];
      if (arguments.keys.any((k) => k != 'minOccurrences') ||
          (minOccurrences != null &&
              (minOccurrences is! int ||
                  minOccurrences < 2 ||
                  minOccurrences > 10))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r1,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r1;
    case 'forge.synthesize_skill':
      final goal = arguments['goal'];
      final category = arguments['category'];
      final targetFolder = arguments['targetFolder'];
      final fileExtensions = arguments['fileExtensions'];
      final toolName = arguments['toolName'];
      final runtime = arguments['runtime'];
      final scriptCode = arguments['scriptCode'];
      final testArgsJson = arguments['testArgsJson'];
      final skillIdToUpdate = arguments['skillIdToUpdate'];
      const allowedSynthKeys = <String>{
        'goal',
        'category',
        'targetFolder',
        'fileExtensions',
        'toolName',
        'runtime',
        'scriptCode',
        'testArgsJson',
        'skillIdToUpdate',
      };
      if (arguments.keys.any((k) => !allowedSynthKeys.contains(k)) ||
          goal is! String ||
          goal.trim().isEmpty ||
          goal.length > 400 ||
          !isSafeAgentPrompt(goal) ||
          (category != null &&
              (category is! String ||
                  !allowedForgeSkillCategories.contains(category))) ||
          (targetFolder != null &&
              (targetFolder is! String ||
                  !isValidSandboxFolderName(targetFolder))) ||
          (toolName != null &&
              (toolName is! String ||
                  toolName.trim().isEmpty ||
                  toolName.length > 48)) ||
          (runtime != null &&
              (runtime is! String ||
                  !allowedSynthesizedToolRuntimes.contains(runtime))) ||
          (testArgsJson != null &&
              (testArgsJson is! String ||
                  testArgsJson.length > 1000 ||
                  !isSafeClipboardWriteText(testArgsJson))) ||
          (skillIdToUpdate != null &&
              (skillIdToUpdate is! String ||
                  !isValidShortId(skillIdToUpdate)))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r1,
          errorCode: 'schema_mismatch',
        );
      }
      if (scriptCode != null) {
        if (scriptCode is! String ||
            scriptCode.trim().isEmpty ||
            scriptCode.length > 4000) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.invalidArgs,
            effectiveRisk: RiskTier.r1,
            errorCode: 'schema_mismatch',
          );
        }
        final scriptCheck = validateSynthesizedToolScript(
          runtime: (runtime as String?) ?? 'python',
          scriptCode: scriptCode,
        );
        if (!scriptCheck.safe) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.denied,
            effectiveRisk: RiskTier.r1,
            errorCode: 'forge_script_security_violation',
          );
        }
      }
      if (fileExtensions != null) {
        if (fileExtensions is! List ||
            fileExtensions.isEmpty ||
            fileExtensions.length > 10) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.invalidArgs,
            effectiveRisk: RiskTier.r1,
            errorCode: 'schema_mismatch',
          );
        }
        for (final ext in fileExtensions) {
          if (ext is! String || !isAllowedForgeFileExtension(ext)) {
            return const PolicyEvaluationResult(
              allowed: false,
              status: XtpStatus.denied,
              effectiveRisk: RiskTier.r1,
              errorCode: 'forge_extension_forbidden',
            );
          }
        }
      }
      effectiveRisk = RiskTier.r1;
    case 'forge.run_skill':
      final skillId = arguments['skillId'];
      final maxItems = arguments['maxItems'];
      final outputFolder = arguments['outputFolder'];
      final exportCsv = arguments['exportCsv'];
      final argsJson = arguments['argsJson'];
      const allowedRunKeys = <String>{
        'skillId',
        'maxItems',
        'outputFolder',
        'exportCsv',
        'argsJson',
      };
      if (arguments.keys.any((k) => !allowedRunKeys.contains(k)) ||
          skillId is! String ||
          !isValidShortId(skillId) ||
          (maxItems != null &&
              (maxItems is! int || maxItems < 1 || maxItems > 500)) ||
          (outputFolder != null &&
              (outputFolder is! String ||
                  !isValidSandboxFolderName(outputFolder))) ||
          (exportCsv != null && exportCsv is! bool) ||
          (argsJson != null &&
              (argsJson is! String ||
                  argsJson.length > 2000 ||
                  !isSafeClipboardWriteText(argsJson)))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r2,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r2;
    case 'forge.list_and_manage':
      final action = arguments['action'];
      final skillId = arguments['skillId'];
      const allowedManageKeys = <String>{'action', 'skillId'};
      if (arguments.keys.any((k) => !allowedManageKeys.contains(k)) ||
          (action != null &&
              (action is! String ||
                  !allowedForgeManageActions.contains(action))) ||
          (skillId != null &&
              (skillId is! String || !isValidShortId(skillId))) ||
          ((action == 'delete_one' || action == 'export_recipe') &&
              (skillId is! String || !isValidShortId(skillId)))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r1,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r1;
    case 'teach.record_session':
      final mode = arguments['mode'];
      final skillTitle = arguments['skillTitle'];
      final demonstratedAction = arguments['demonstratedAction'];
      final selectorOrPattern = arguments['selectorOrPattern'];
      const allowedTeachKeys = <String>{
        'mode',
        'skillTitle',
        'demonstratedAction',
        'selectorOrPattern',
      };
      if (arguments.keys.any((k) => !allowedTeachKeys.contains(k)) ||
          mode is! String ||
          !allowedTeachRecordModes.contains(mode) ||
          (skillTitle != null &&
              (skillTitle is! String ||
                  skillTitle.trim().isEmpty ||
                  skillTitle.length > 80 ||
                  !isSafeAgentPrompt(skillTitle))) ||
          (demonstratedAction != null &&
              (demonstratedAction is! String ||
                  demonstratedAction.trim().isEmpty ||
                  demonstratedAction.length > 240 ||
                  !isSafeAgentPrompt(demonstratedAction))) ||
          (selectorOrPattern != null &&
              (selectorOrPattern is! String ||
                  selectorOrPattern.trim().isEmpty ||
                  selectorOrPattern.length > 160 ||
                  !isSafeAgentPrompt(selectorOrPattern)))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r1,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r1;
    case 'forge.extract_invoices_to_sheet':
      final sourceFolder = arguments['sourceFolder'];
      final outputFileName = arguments['outputFileName'];
      final detectDuplicates = arguments['detectDuplicates'];
      const allowedExtractKeys = <String>{
        'sourceFolder',
        'outputFileName',
        'detectDuplicates',
      };
      if (arguments.keys.any((k) => !allowedExtractKeys.contains(k)) ||
          sourceFolder is! String ||
          !isValidSandboxFolderName(sourceFolder) ||
          (outputFileName != null &&
              (outputFileName is! String ||
                  outputFileName.length > 80 ||
                  !isValidBeamFileName(outputFileName))) ||
          (detectDuplicates != null && detectDuplicates is! bool)) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r1,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r1;
    case 'skill.markdown_bridge':
      final action = arguments['action'];
      final skillId = arguments['skillId'];
      final markdownContent = arguments['markdownContent'];
      const allowedMdKeys = <String>{
        'action',
        'skillId',
        'markdownContent',
      };
      if (arguments.keys.any((k) => !allowedMdKeys.contains(k)) ||
          action is! String ||
          !allowedSkillMarkdownActions.contains(action) ||
          (skillId != null &&
              (skillId is! String || !isValidShortId(skillId))) ||
          (markdownContent != null &&
              (markdownContent is! String || markdownContent.length > 4000)) ||
          (action == 'export_skill_md' &&
              (skillId is! String || !isValidShortId(skillId))) ||
          (action == 'import_skill_md' &&
              (markdownContent is! String ||
                  markdownContent.trim().isEmpty ||
                  markdownContent.length > 4000))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r1,
          errorCode: 'schema_mismatch',
        );
      }
      if (markdownContent is String &&
          containsForbiddenSkillMarkdownPattern(markdownContent)) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.denied,
          effectiveRisk: RiskTier.r1,
          errorCode: 'skill_markdown_forbidden_command',
        );
      }
      effectiveRisk = RiskTier.r1;
    case 'skill.record_correction':
      final action = arguments['action'];
      final skillId = arguments['skillId'];
      final correctionNote = arguments['correctionNote'];
      const allowedCorrKeys = <String>{
        'action',
        'skillId',
        'correctionNote',
      };
      if (arguments.keys.any((k) => !allowedCorrKeys.contains(k)) ||
          skillId is! String ||
          !isValidShortId(skillId) ||
          (action != null &&
              (action is! String ||
                  !allowedSkillCorrectionActions.contains(action))) ||
          (correctionNote != null &&
              (correctionNote is! String ||
                  correctionNote.trim().isEmpty ||
                  correctionNote.length > 240 ||
                  !isSafeAgentPrompt(correctionNote))) ||
          ((action == null || action == 'record') &&
              (correctionNote is! String || correctionNote.trim().isEmpty))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r1,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r1;
    case 'heartbeat.configure_and_tick':
      final action = arguments['action'];
      final checkName = arguments['checkName'];
      final intervalMinutes = arguments['intervalMinutes'];
      const allowedHbKeys = <String>{
        'action',
        'checkName',
        'intervalMinutes',
      };
      if (arguments.keys.any((k) => !allowedHbKeys.contains(k)) ||
          (action != null &&
              (action is! String ||
                  !allowedHeartbeatActions.contains(action))) ||
          (checkName != null &&
              (checkName is! String ||
                  checkName.trim().isEmpty ||
                  checkName.length > 80 ||
                  !isSafeAgentPrompt(checkName))) ||
          (intervalMinutes != null &&
              (intervalMinutes is! int ||
                  intervalMinutes < 5 ||
                  intervalMinutes > 720))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r1,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r1;
    case 'canvas.present':
      final action = arguments['action'];
      final title = arguments['title'];
      final sourceSkillId = arguments['sourceSkillId'];
      const allowedCanvasKeys = <String>{
        'action',
        'title',
        'sourceSkillId',
      };
      if (arguments.keys.any((k) => !allowedCanvasKeys.contains(k)) ||
          (action != null &&
              (action is! String || !allowedCanvasActions.contains(action))) ||
          (title != null &&
              (title is! String ||
                  title.trim().isEmpty ||
                  title.length > 120 ||
                  !isSafeAgentPrompt(title))) ||
          (sourceSkillId != null &&
              (sourceSkillId is! String || !isValidShortId(sourceSkillId)))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r1,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r1;
    case 'pipeline.execute_universal':
      final goal = arguments['goal'];
      final primitives = arguments['primitives'];
      final sourceFolder = arguments['sourceFolder'];
      final rawInputText = arguments['rawInputText'];
      final secondaryInputText = arguments['secondaryInputText'];
      final exportFormat = arguments['exportFormat'];
      final outputFileName = arguments['outputFileName'];
      const allowedPipelineKeys = <String>{
        'goal',
        'primitives',
        'sourceFolder',
        'rawInputText',
        'secondaryInputText',
        'exportFormat',
        'outputFileName',
      };
      if (arguments.keys.any((k) => !allowedPipelineKeys.contains(k)) ||
          goal is! String ||
          goal.trim().isEmpty ||
          goal.length > 400 ||
          !isSafeAgentPrompt(goal) ||
          (sourceFolder != null &&
              (sourceFolder is! String ||
                  !isValidSandboxFolderName(sourceFolder))) ||
          (rawInputText != null &&
              (rawInputText is! String ||
                  !isSafeClipboardWriteText(rawInputText))) ||
          (secondaryInputText != null &&
              (secondaryInputText is! String ||
                  !isSafeClipboardWriteText(secondaryInputText))) ||
          (exportFormat != null &&
              (exportFormat is! String ||
                  !allowedUniversalExportFormats.contains(exportFormat))) ||
          (outputFileName != null &&
              (outputFileName is! String ||
                  outputFileName.length > 80 ||
                  !isValidBeamFileName(outputFileName)))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r2,
          errorCode: 'schema_mismatch',
        );
      }
      if (primitives != null) {
        if (primitives is! List ||
            primitives.isEmpty ||
            primitives.length > 8) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.invalidArgs,
            effectiveRisk: RiskTier.r2,
            errorCode: 'schema_mismatch',
          );
        }
        for (final p in primitives) {
          if (p is! String || !allowedUniversalPrimitives.contains(p)) {
            return const PolicyEvaluationResult(
              allowed: false,
              status: XtpStatus.denied,
              effectiveRisk: RiskTier.r2,
              errorCode: 'pipeline_primitive_forbidden',
            );
          }
        }
      }
      effectiveRisk = RiskTier.r2;
    case 'skill.workshop_sync':
      final action = arguments['action'];
      final skillId = arguments['skillId'];
      final workshopFolder = arguments['workshopFolder'];
      const allowedWorkshopKeys = <String>{
        'action',
        'skillId',
        'workshopFolder',
      };
      if (arguments.keys.any((k) => !allowedWorkshopKeys.contains(k)) ||
          action is! String ||
          !allowedSkillWorkshopActions.contains(action) ||
          (skillId != null &&
              (skillId is! String || !isValidShortId(skillId))) ||
          (action == 'rollback_version' &&
              (skillId is! String || !isValidShortId(skillId))) ||
          (workshopFolder != null &&
              (workshopFolder is! String ||
                  !isValidSandboxFolderName(workshopFolder)))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r1,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r1;
    case 'skill.chain_and_test':
      final chainSkillIds = arguments['chainSkillIds'];
      final runtimeParams = arguments['runtimeParams'];
      final autoTriggerOnDelta = arguments['autoTriggerOnDelta'];
      const allowedChainKeys = <String>{
        'chainSkillIds',
        'runtimeParams',
        'autoTriggerOnDelta',
      };
      if (arguments.keys.any((k) => !allowedChainKeys.contains(k)) ||
          chainSkillIds is! List ||
          chainSkillIds.isEmpty ||
          chainSkillIds.length > 5 ||
          (autoTriggerOnDelta != null && autoTriggerOnDelta is! bool)) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r2,
          errorCode: 'schema_mismatch',
        );
      }
      for (final id in chainSkillIds) {
        if (id is! String || !isValidShortId(id)) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.invalidArgs,
            effectiveRisk: RiskTier.r2,
            errorCode: 'schema_mismatch',
          );
        }
      }
      if (runtimeParams != null) {
        if (runtimeParams is! Map || runtimeParams.length > 10) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.invalidArgs,
            effectiveRisk: RiskTier.r2,
            errorCode: 'schema_mismatch',
          );
        }
        for (final entry in runtimeParams.entries) {
          final k = entry.key;
          final v = entry.value;
          if (k is! String ||
              !isValidShortId(k) ||
              v is! String ||
              !isSafeTemplateParameterValue(v)) {
            return const PolicyEvaluationResult(
              allowed: false,
              status: XtpStatus.denied,
              effectiveRisk: RiskTier.r2,
              errorCode: 'skill_template_param_unsafe',
            );
          }
        }
      }
      effectiveRisk = RiskTier.r2;
    case 'memory.markdown_vault':
      final action = arguments['action'];
      final targetFile = arguments['targetFile'];
      final noteContent = arguments['noteContent'];
      final sessionTranscript = arguments['sessionTranscript'];
      final vaultFolder = arguments['vaultFolder'];
      const allowedMemoryKeys = <String>{
        'action',
        'targetFile',
        'noteContent',
        'sessionTranscript',
        'vaultFolder',
      };
      if (arguments.keys.any((k) => !allowedMemoryKeys.contains(k)) ||
          action is! String ||
          !allowedMemoryVaultActions.contains(action) ||
          (targetFile != null &&
              (targetFile is! String ||
                  !allowedMemoryVaultTargetFiles.contains(targetFile))) ||
          (noteContent != null &&
              (noteContent is! String ||
                  noteContent.length > 2000 ||
                  !isSafeClipboardWriteText(noteContent))) ||
          (sessionTranscript != null &&
              (sessionTranscript is! String ||
                  !isSafeClipboardWriteText(sessionTranscript))) ||
          (vaultFolder != null &&
              (vaultFolder is! String ||
                  !isValidSandboxFolderName(vaultFolder))) ||
          (action == 'append_note' &&
              (noteContent is! String || noteContent.trim().isEmpty)) ||
          (action == 'pre_compaction_flush' &&
              (sessionTranscript is! String ||
                  sessionTranscript.trim().isEmpty))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r1,
          errorCode: 'schema_mismatch',
        );
      }
      if (noteContent is String &&
          containsForbiddenSkillMarkdownPattern(noteContent)) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.denied,
          effectiveRisk: RiskTier.r1,
          errorCode: 'memory_vault_content_unsafe',
        );
      }
      effectiveRisk = RiskTier.r1;
    case 'browser.semantic_snapshot':
      final rawHtml = arguments['rawHtml'];
      final pageTitle = arguments['pageTitle'];
      final maxElements = arguments['maxElements'];
      const allowedSnapKeys = <String>{
        'rawHtml',
        'pageTitle',
        'maxElements',
      };
      if (arguments.keys.any((k) => !allowedSnapKeys.contains(k)) ||
          (rawHtml != null &&
              (rawHtml is! String || !isSafeClipboardWriteText(rawHtml))) ||
          (pageTitle != null &&
              (pageTitle is! String ||
                  pageTitle.trim().isEmpty ||
                  pageTitle.length > 120 ||
                  !isSafeAgentPrompt(pageTitle))) ||
          (maxElements != null &&
              (maxElements is! int || maxElements < 1 || maxElements > 50))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r1,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r1;
    case 'workspace.coding_agent':
      final proj = arguments['project'];
      final agent = arguments['agent'];
      final resumeLast = arguments['resumeLast'];
      final prompt = arguments['prompt'];
      const allowedKeys = <String>{
        'project',
        'agent',
        'resumeLast',
        'prompt',
      };
      if (proj is! String ||
          !isValidWorkspaceQuery(proj) ||
          arguments.keys.any((k) => !allowedKeys.contains(k)) ||
          (agent != null &&
              (agent is! String || !supportedCodingAgents.contains(agent))) ||
          (resumeLast != null && resumeLast is! bool) ||
          (prompt != null &&
              (prompt is! String || !isSafeAgentPrompt(prompt)))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r2,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r2;
    case 'url.open':
      if (arguments.length != 1 || arguments['url'] is! String) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r2,
          errorCode: 'schema_mismatch',
        );
      }
      final rawUrl = arguments['url'] as String;
      final urlCheck = validateHttpsUrlAgainstAllowlist(
        rawUrl,
        activePolicy.urlDomains,
      );
      if (!urlCheck.validUrl) {
        return PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r2,
          errorCode: urlCheck.errorCode ?? 'url_invalid',
        );
      }
      if (activePolicy.isDomainDenied(urlCheck.asciiHost)) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.denied,
          effectiveRisk: RiskTier.r2,
          errorCode: 'domain_not_allowed',
        );
      }
      if (!urlCheck.domainAllowed && !allowPublicHttpsDomains) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.denied,
          effectiveRisk: RiskTier.r2,
          errorCode: 'domain_not_allowed',
        );
      }
      normalizedUrlHost = urlCheck.asciiHost;
      effectiveRisk = RiskTier.r2;
    case 'browser.current_url':
      if (arguments.keys.any((k) => k != 'browser') ||
          (arguments.containsKey('browser') &&
              (arguments['browser'] is! String ||
                  !<String>{'auto', 'edge', 'chrome', 'safari'}
                      .contains(arguments['browser'] as String)))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r2,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r2;
    case 'browser.read_page':
      final browser = arguments['browser'];
      final maxChars = arguments['maxChars'];
      const allowedReadPageKeys = <String>{'browser', 'maxChars'};
      if (arguments.keys.any((k) => !allowedReadPageKeys.contains(k)) ||
          (browser != null &&
              (browser is! String ||
                  !<String>{'auto', 'edge', 'chrome', 'safari'}
                      .contains(browser))) ||
          (maxChars != null &&
              (maxChars is! int || maxChars < 80 || maxChars > 1600))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r1,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r1;
    case 'workflow.run':
      if (arguments.length != 1 || arguments['id'] is! String) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r1,
          errorCode: 'schema_mismatch',
        );
      }
      final wfId = arguments['id'] as String;
      if (!isValidShortId(wfId)) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r1,
          errorCode: 'schema_mismatch',
        );
      }
      matchedWorkflow = activePolicy.findWorkflow(wfId);
      if (matchedWorkflow == null) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.denied,
          effectiveRisk: RiskTier.r1,
          errorCode: 'policy_blocked',
        );
      }
      effectiveRisk = matchedWorkflow.risk;
    case 'workflow.batch_steps':
      final steps = arguments['steps'];
      if (arguments.length != 1 ||
          steps is! List ||
          steps.isEmpty ||
          steps.length > 5) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r2,
          errorCode: 'schema_mismatch',
        );
      }
      for (final rawStep in steps) {
        if (rawStep is! Map) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.invalidArgs,
            effectiveRisk: RiskTier.r2,
            errorCode: 'schema_mismatch',
          );
        }
        if (rawStep.length != 2 ||
            !rawStep.containsKey('tool') ||
            !rawStep.containsKey('arguments') ||
            rawStep['tool'] is! String ||
            rawStep['arguments'] is! Map) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.invalidArgs,
            effectiveRisk: RiskTier.r2,
            errorCode: 'schema_mismatch',
          );
        }
        final stepTool = rawStep['tool'] as String;
        if (stepTool.length > 64) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.invalidArgs,
            effectiveRisk: RiskTier.r2,
            errorCode: 'schema_mismatch',
          );
        }
        if (stepTool == 'workflow.batch_steps' ||
            stepTool.startsWith('cu.') ||
            stepTool.startsWith('screen.') ||
            stepTool.startsWith('ui.') ||
            stepTool.startsWith('input.')) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.denied,
            effectiveRisk: RiskTier.r3,
            errorCode: 'batch_r3_forbidden',
          );
        }
        try {
          ToolDescriptor.validateToolName(stepTool);
        } on FormatException {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.invalidArgs,
            effectiveRisk: RiskTier.r2,
            errorCode: 'schema_mismatch',
          );
        }
        final stepArgs =
            castPolicyObjectMap(rawStep['arguments'], 'batch_step');
        final syntheticApproval = ApprovalToken(
          approvalId: 'a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c99',
          scope: 'once',
          expiresAt: now.add(const Duration(minutes: 5)),
          argsSha256: argsSha256(stepArgs),
        );
        final stepEval = evaluateStep(
          toolName: stepTool,
          arguments: stepArgs,
          approval: syntheticApproval,
          isStopped: isStopped,
          nowUtc: now,
          hostId: hostId,
          pinnedPhonePublicKeys: pinnedPhonePublicKeys,
          isInApprovedCuSession: false,
          allowZeroConfigAppDiscovery: allowZeroConfigAppDiscovery,
        );
        if (stepEval.effectiveRisk >= RiskTier.r3) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.denied,
            effectiveRisk: RiskTier.r3,
            errorCode: 'batch_r3_forbidden',
          );
        }
        if (!stepEval.allowed) {
          return PolicyEvaluationResult(
            allowed: false,
            status: stepEval.status,
            effectiveRisk: RiskTier.r2,
            errorCode: stepEval.errorCode ?? 'batch_step_rejected',
          );
        }
      }
      effectiveRisk = RiskTier.r2;
    case 'host.notify':
      if (arguments.length != 2 ||
          arguments['title'] is! String ||
          arguments['body'] is! String) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r1,
          errorCode: 'schema_mismatch',
        );
      }
      final title = arguments['title'] as String;
      final body = arguments['body'] as String;
      if (title.isEmpty ||
          title.length > 40 ||
          body.isEmpty ||
          body.length > 120) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r1,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r1;
    case 'cu.session_start':
      final goal = arguments['goal'];
      final apps = arguments['apps'];
      final domains = arguments['domains'];
      final maxSteps = arguments['maxSteps'];
      final maxMinutes = arguments['maxMinutes'];
      if (arguments.length != 5 ||
          goal is! String ||
          goal.trim().isEmpty ||
          goal.length > 200 ||
          apps is! List ||
          domains is! List ||
          maxSteps is! int ||
          maxSteps < 1 ||
          maxSteps > maxCuSessionSteps ||
          maxMinutes is! int ||
          maxMinutes < 1 ||
          maxMinutes > maxCuSessionMinutes) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r3,
          errorCode: 'schema_mismatch',
        );
      }
      final startScopeError = validateCuSessionScope(
        apps: apps,
        domains: domains,
        activePolicy: activePolicy,
        allowZeroConfigAppDiscovery: allowZeroConfigAppDiscovery,
        allowPublicHttpsDomains: allowPublicHttpsDomains,
      );
      if (startScopeError != null) return startScopeError;
      effectiveRisk = activePolicy.trustPreset == TrustPreset.autopilot
          ? RiskTier.r2
          : RiskTier.r3;
    case 'cu.session_extend':
      // UDC-17 S17.3: add apps/domains to the running session without
      // restarting it. Same checks as `cu.session_start`; R3, phone-signed.
      if (!isInApprovedCuSession) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.denied,
          effectiveRisk: RiskTier.r3,
          errorCode: 'cu_session_required',
        );
      }
      final extSessionId = arguments['sessionId'];
      final extApps = arguments['apps'];
      final extDomains = arguments['domains'];
      if (arguments.length != 3 ||
          extSessionId is! String ||
          extSessionId.isEmpty ||
          extSessionId.length > 64 ||
          extApps is! List ||
          extDomains is! List ||
          (extApps.isEmpty && extDomains.isEmpty) ||
          extApps.length > maxCuSessionExtendItems ||
          extDomains.length > maxCuSessionExtendItems) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r3,
          errorCode: 'schema_mismatch',
        );
      }
      final extendScopeError = validateCuSessionScope(
        apps: extApps,
        domains: extDomains,
        activePolicy: activePolicy,
        allowZeroConfigAppDiscovery: allowZeroConfigAppDiscovery,
        allowPublicHttpsDomains: allowPublicHttpsDomains,
      );
      if (extendScopeError != null) return extendScopeError;
      effectiveRisk = activePolicy.trustPreset == TrustPreset.autopilot
          ? RiskTier.r2
          : RiskTier.r3;
    case 'cu.session_end':
      final sessionId = arguments['sessionId'];
      final outcome = arguments['outcome'];
      if (arguments.length != 2 ||
          sessionId is! String ||
          sessionId.isEmpty ||
          sessionId.length > 64 ||
          outcome is! String ||
          !<String>{'completed', 'stopped', 'budget_exceeded', 'failed'}
              .contains(outcome)) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r0,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r0;
    case 'screen.capture':
      if (!isInApprovedCuSession) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.denied,
          effectiveRisk: RiskTier.r2,
          errorCode: 'cu_session_required',
        );
      }
      final scope = arguments['scope'];
      final maxEdge = arguments['maxEdge'];
      if (arguments.length != 2 ||
          scope is! String ||
          !<String>{'active_window', 'screen'}.contains(scope) ||
          maxEdge is! int ||
          maxEdge < 320 ||
          maxEdge > 1280) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r2,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r2;
    case 'ui.inspect':
      if (!isInApprovedCuSession) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.denied,
          effectiveRisk: RiskTier.r2,
          errorCode: 'cu_session_required',
        );
      }
      final scope = arguments['scope'];
      final maxNodes = arguments['maxNodes'];
      final skeleton = arguments['skeleton'];
      final interactiveOnly = arguments['interactiveOnly'];
      final rootElementId = arguments['rootElementId'];
      final collapseWebWrappers = arguments['collapseWebWrappers'];
      const allowedInspectKeys = <String>{
        'scope',
        'maxNodes',
        'skeleton',
        'interactiveOnly',
        'rootElementId',
        'collapseWebWrappers',
      };
      if (arguments.keys.any((k) => !allowedInspectKeys.contains(k)) ||
          scope != 'active_window' ||
          maxNodes is! int ||
          maxNodes < 1 ||
          maxNodes > 300 ||
          (skeleton != null && skeleton is! bool) ||
          (interactiveOnly != null && interactiveOnly is! bool) ||
          (collapseWebWrappers != null && collapseWebWrappers is! bool) ||
          (rootElementId != null &&
              (rootElementId is! String ||
                  rootElementId.trim().isEmpty ||
                  rootElementId.length > 64 ||
                  !isSafeAgentPrompt(rootElementId)))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r2,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r2;
    case 'ui.observe_hybrid':
      if (!isInApprovedCuSession) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.denied,
          effectiveRisk: RiskTier.r2,
          errorCode: 'cu_session_required',
        );
      }
      final scope = arguments['scope'];
      final maxNodes = arguments['maxNodes'];
      final maxEdge = arguments['maxEdge'];
      final skeleton = arguments['skeleton'];
      final interactiveOnly = arguments['interactiveOnly'];
      final rootElementId = arguments['rootElementId'];
      final collapseWebWrappers = arguments['collapseWebWrappers'];
      const allowedObserveHybridKeys = <String>{
        'scope',
        'maxNodes',
        'maxEdge',
        'skeleton',
        'interactiveOnly',
        'rootElementId',
        'collapseWebWrappers',
      };
      if (arguments.keys.any((k) => !allowedObserveHybridKeys.contains(k)) ||
          scope != 'active_window' ||
          (maxNodes != null &&
              (maxNodes is! int || maxNodes < 1 || maxNodes > 300)) ||
          (maxEdge != null &&
              (maxEdge is! int || maxEdge < 320 || maxEdge > 1280)) ||
          (skeleton != null && skeleton is! bool) ||
          (interactiveOnly != null && interactiveOnly is! bool) ||
          (collapseWebWrappers != null && collapseWebWrappers is! bool) ||
          (rootElementId != null &&
              (rootElementId is! String ||
                  rootElementId.trim().isEmpty ||
                  rootElementId.length > 64 ||
                  !isSafeAgentPrompt(rootElementId)))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r2,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r2;
    case 'ui.find':
      if (!isInApprovedCuSession) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.denied,
          effectiveRisk: RiskTier.r2,
          errorCode: 'cu_session_required',
        );
      }
      final query = arguments['query'];
      final role = arguments['role'];
      final maxResults = arguments['maxResults'];
      const allowedFindKeys = <String>{'query', 'role', 'maxResults'};
      final queryOk = query == null ||
          (query is String &&
              query.trim().isNotEmpty &&
              query.length <= maxUiFindQueryLength &&
              isSafeAgentPrompt(query));
      final roleOk =
          role == null || (role is String && isValidUiFindRole(role));
      if (arguments.keys.any((k) => !allowedFindKeys.contains(k)) ||
          !queryOk ||
          !roleOk ||
          (query == null && role == null) ||
          (maxResults != null &&
              (maxResults is! int ||
                  maxResults < 1 ||
                  maxResults > maxUiFindResults))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r2,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r2;
    case 'input.click':
      if (!isInApprovedCuSession) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.denied,
          effectiveRisk: RiskTier.r2,
          errorCode: 'cu_session_required',
        );
      }
      final elementId = arguments['elementId'];
      final elementName = arguments['elementName'];
      final x = arguments['x'];
      final y = arguments['y'];
      final xNorm = arguments['xNorm'];
      final yNorm = arguments['yNorm'];
      final headed = arguments['headed'];
      final waitFor = arguments['waitFor'];
      final waitForGone = arguments['waitForGone'];
      final clickCount = arguments['clickCount'];
      final button = arguments['button'];
      final hover = arguments['hover'];
      final menuPath = arguments['menuPath'];
      const allowedClickKeys = <String>{
        'elementId',
        'elementName',
        'x',
        'y',
        'xNorm',
        'yNorm',
        'clickCount',
        'button',
        'hover',
        'menuPath',
        'headed',
        'waitFor',
        'waitForGone',
      };
      const allowedMouseButtons = <String>{'left', 'right', 'middle'};
      final elementIdInvalid = elementId != null &&
          (elementId is! String || elementId.isEmpty || elementId.length > 64);
      final hasElement =
          elementId is String && elementId.isNotEmpty && elementId.length <= 64;
      final intCoordsInvalid =
          (x != null && x is! int) || (y != null && y is! int);
      final hasIntCoords = x is int && y is int;
      final hasNormCoords = xNorm is num &&
          yNorm is num &&
          xNorm.isFinite &&
          yNorm.isFinite &&
          xNorm >= 0.0 &&
          xNorm <= 1.0 &&
          yNorm >= 0.0 &&
          yNorm <= 1.0;
      final hasCoords = hasIntCoords || hasNormCoords;
      final hasMenu = menuPath is String && menuPath.trim().isNotEmpty;
      final menuPathInvalid = menuPath != null &&
          (menuPath is! String ||
              menuPath.trim().isEmpty ||
              menuPath.length > 160 ||
              !isSafeAgentPrompt(menuPath));
      final clickCountInvalid = clickCount != null &&
          (clickCount is! int || clickCount < 1 || clickCount > 3);
      final buttonInvalid = button != null &&
          (button is! String || !allowedMouseButtons.contains(button));
      final normCoordsInvalid = (xNorm != null &&
              (xNorm is! num ||
                  !xNorm.isFinite ||
                  xNorm < 0.0 ||
                  xNorm > 1.0)) ||
          (yNorm != null &&
              (yNorm is! num ||
                  !yNorm.isFinite ||
                  yNorm < 0.0 ||
                  yNorm > 1.0)) ||
          (xNorm != null && yNorm == null) ||
          (xNorm == null && yNorm != null);

      if (arguments.keys.any((k) => !allowedClickKeys.contains(k)) ||
          elementIdInvalid ||
          intCoordsInvalid ||
          normCoordsInvalid ||
          menuPathInvalid ||
          clickCountInvalid ||
          buttonInvalid ||
          (hover != null && hover is! bool) ||
          (!hasElement && !hasCoords && !hasMenu) ||
          (elementName != null &&
              (elementName is! String || elementName.length > 120)) ||
          (headed != null && headed is! bool) ||
          (waitFor != null && waitForGone != null) ||
          (waitFor != null &&
              (waitFor is! String ||
                  waitFor.trim().isEmpty ||
                  waitFor.length > 120 ||
                  !isSafeAgentPrompt(waitFor))) ||
          (waitForGone != null &&
              (waitForGone is! String ||
                  waitForGone.trim().isEmpty ||
                  waitForGone.length > 120 ||
                  !isSafeAgentPrompt(waitForGone)))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r2,
          errorCode: 'schema_mismatch',
        );
      }
      const destructiveMenuTokens = <String>[
        'quit',
        'exit',
        'empty trash',
        'sign out',
        'log out',
        'logout',
        'uninstall',
        'format',
        'thoát',
        'đăng xuất',
        'dọn sạch thùng rác',
      ];
      final lowerMenu = hasMenu ? menuPath.trim().toLowerCase() : '';
      final menuIsConsequential = hasMenu &&
          (isConsequentialElementName(menuPath) ||
              destructiveMenuTokens.any(lowerMenu.contains));
      effectiveRisk = (isConsequentialElementName(elementName as String?) ||
              menuIsConsequential)
          ? RiskTier.r3
          : RiskTier.r2;
    case 'input.drag':
      if (!isInApprovedCuSession) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.denied,
          effectiveRisk: RiskTier.r2,
          errorCode: 'cu_session_required',
        );
      }
      const allowedDragKeys = <String>{
        'fromXNorm',
        'fromYNorm',
        'toXNorm',
        'toYNorm',
        'startXNorm',
        'startYNorm',
        'endXNorm',
        'endYNorm',
        'fromX',
        'fromY',
        'toX',
        'toY',
        'startX',
        'startY',
        'endX',
        'endY',
        'fromElementId',
        'toElementId',
        'durationMs',
        'headed',
        'waitFor',
        'waitForGone',
      };
      if (arguments.keys.any((k) => !allowedDragKeys.contains(k))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r2,
          errorCode: 'schema_mismatch',
        );
      }
      final fromXNorm = arguments['fromXNorm'] ?? arguments['startXNorm'];
      final fromYNorm = arguments['fromYNorm'] ?? arguments['startYNorm'];
      final toXNorm = arguments['toXNorm'] ?? arguments['endXNorm'];
      final toYNorm = arguments['toYNorm'] ?? arguments['endYNorm'];

      final fromX = arguments['fromX'] ?? arguments['startX'];
      final fromY = arguments['fromY'] ?? arguments['startY'];
      final toX = arguments['toX'] ?? arguments['endX'];
      final toY = arguments['toY'] ?? arguments['endY'];

      final fromElementId = arguments['fromElementId'];
      final toElementId = arguments['toElementId'];

      const dragNormCoordKeys = <String>[
        'fromXNorm',
        'fromYNorm',
        'toXNorm',
        'toYNorm',
        'startXNorm',
        'startYNorm',
        'endXNorm',
        'endYNorm',
      ];
      const dragIntCoordKeys = <String>[
        'fromX',
        'fromY',
        'toX',
        'toY',
        'startX',
        'startY',
        'endX',
        'endY',
      ];
      final dragNormCoordsInvalid = dragNormCoordKeys.any((k) {
        final v = arguments[k];
        return v != null && (v is! num || !v.isFinite || v < 0.0 || v > 1.0);
      });
      final dragIntCoordsInvalid = dragIntCoordKeys.any((k) {
        final v = arguments[k];
        return v != null && v is! int;
      });
      final dragElementIdsInvalid = (fromElementId != null &&
              (fromElementId is! String ||
                  fromElementId.isEmpty ||
                  fromElementId.length > 64)) ||
          (toElementId != null &&
              (toElementId is! String ||
                  toElementId.isEmpty ||
                  toElementId.length > 64));

      final hasNormCoords = fromXNorm is num &&
          fromYNorm is num &&
          toXNorm is num &&
          toYNorm is num &&
          fromXNorm.isFinite &&
          fromYNorm.isFinite &&
          toXNorm.isFinite &&
          toYNorm.isFinite &&
          fromXNorm >= 0.0 &&
          fromXNorm <= 1.0 &&
          fromYNorm >= 0.0 &&
          fromYNorm <= 1.0 &&
          toXNorm >= 0.0 &&
          toXNorm <= 1.0 &&
          toYNorm >= 0.0 &&
          toYNorm <= 1.0;

      final hasIntCoords =
          fromX is int && fromY is int && toX is int && toY is int;

      final hasElements = fromElementId is String &&
          fromElementId.isNotEmpty &&
          fromElementId.length <= 64 &&
          toElementId is String &&
          toElementId.isNotEmpty &&
          toElementId.length <= 64;

      if (dragNormCoordsInvalid ||
          dragIntCoordsInvalid ||
          dragElementIdsInvalid ||
          (!hasNormCoords && !hasIntCoords && !hasElements)) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r2,
          errorCode: 'schema_mismatch',
        );
      }

      final durationMs = arguments['durationMs'];
      if (durationMs != null &&
          (durationMs is! int || durationMs < 50 || durationMs > 5000)) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r2,
          errorCode: 'schema_mismatch',
        );
      }
      final headed = arguments['headed'];
      if (headed != null && headed is! bool) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r2,
          errorCode: 'schema_mismatch',
        );
      }
      final waitFor = arguments['waitFor'];
      final waitForGone = arguments['waitForGone'];
      if ((waitFor != null && waitForGone != null) ||
          (waitFor != null &&
              (waitFor is! String ||
                  waitFor.trim().isEmpty ||
                  waitFor.length > 120 ||
                  !isSafeAgentPrompt(waitFor))) ||
          (waitForGone != null &&
              (waitForGone is! String ||
                  waitForGone.trim().isEmpty ||
                  waitForGone.length > 120 ||
                  !isSafeAgentPrompt(waitForGone)))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r2,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r2;
    case 'input.type_text':
      if (!isInApprovedCuSession) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.denied,
          effectiveRisk: RiskTier.r3,
          errorCode: 'cu_session_required',
        );
      }
      final elementId = arguments['elementId'];
      final text = arguments['text'];
      final elementName = arguments['elementName'];
      final headed = arguments['headed'];
      final waitFor = arguments['waitFor'];
      final waitForGone = arguments['waitForGone'];
      const allowedTypeKeys = <String>{
        'elementId',
        'elementName',
        'text',
        'headed',
        'waitFor',
        'waitForGone',
      };
      if (arguments.keys.any((k) => !allowedTypeKeys.contains(k)) ||
          elementId is! String ||
          elementId.isEmpty ||
          elementId.length > 64 ||
          text is! String ||
          text.isEmpty ||
          text.length > maxInputTypeTextLength ||
          (elementName != null &&
              (elementName is! String || elementName.length > 120)) ||
          (headed != null && headed is! bool) ||
          (waitFor != null && waitForGone != null) ||
          (waitFor != null &&
              (waitFor is! String ||
                  waitFor.trim().isEmpty ||
                  waitFor.length > 120 ||
                  !isSafeAgentPrompt(waitFor))) ||
          (waitForGone != null &&
              (waitForGone is! String ||
                  waitForGone.trim().isEmpty ||
                  waitForGone.length > 120 ||
                  !isSafeAgentPrompt(waitForGone)))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r3,
          errorCode: 'schema_mismatch',
        );
      }
      // Floor only: the live classifier decides whether this is a draft into
      // an ordinary text field (R2, ADR-0015 D1) or needs a signature (R3).
      effectiveRisk = RiskTier.r2;
    case 'input.key':
      if (!isInApprovedCuSession) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.denied,
          effectiveRisk: RiskTier.r2,
          errorCode: 'cu_session_required',
        );
      }
      final combo = arguments['combo'];
      final inForm = arguments['inForm'];
      final headed = arguments['headed'];
      final waitFor = arguments['waitFor'];
      final waitForGone = arguments['waitForGone'];
      const allowedKeyKeys = <String>{
        'combo',
        'inForm',
        'headed',
        'waitFor',
        'waitForGone',
      };
      if (arguments.keys.any((k) => !allowedKeyKeys.contains(k)) ||
          combo is! String ||
          combo.length > 40 ||
          !isAllowedInputKeyCombo(combo) ||
          (inForm != null && inForm is! bool) ||
          (headed != null && headed is! bool) ||
          (waitFor != null && waitForGone != null) ||
          (waitFor != null &&
              (waitFor is! String ||
                  waitFor.trim().isEmpty ||
                  waitFor.length > 120 ||
                  !isSafeAgentPrompt(waitFor))) ||
          (waitForGone != null &&
              (waitForGone is! String ||
                  waitForGone.trim().isEmpty ||
                  waitForGone.length > 120 ||
                  !isSafeAgentPrompt(waitForGone)))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r2,
          errorCode: 'schema_mismatch',
        );
      }
      // Arguments alone cannot tell what Enter/Return/Space will activate, so
      // this is only a floor: inside a session the live classifier
      // (`classifyInputStepRisk`, ADR-0015 D2) decides and enforces R3 unless
      // the focused element is known to be safe. The model-declared `inForm`
      // flag is untrusted and never consulted.
      effectiveRisk = RiskTier.r2;
    case 'input.scroll':
      if (!isInApprovedCuSession) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.denied,
          effectiveRisk: RiskTier.r2,
          errorCode: 'cu_session_required',
        );
      }
      final direction = arguments['direction'];
      final amount = arguments['amount'];
      final elementId = arguments['elementId'];
      final headed = arguments['headed'];
      final waitFor = arguments['waitFor'];
      final waitForGone = arguments['waitForGone'];
      const allowedScrollKeys = <String>{
        'elementId',
        'direction',
        'amount',
        'headed',
        'waitFor',
        'waitForGone',
      };
      if (arguments.keys.any((k) => !allowedScrollKeys.contains(k)) ||
          direction is! String ||
          !<String>{'up', 'down', 'left', 'right'}.contains(direction) ||
          amount is! int ||
          amount < 1 ||
          amount > 10 ||
          (elementId != null &&
              (elementId is! String ||
                  elementId.isEmpty ||
                  elementId.length > 64)) ||
          (headed != null && headed is! bool) ||
          (waitFor != null && waitForGone != null) ||
          (waitFor != null &&
              (waitFor is! String ||
                  waitFor.trim().isEmpty ||
                  waitFor.length > 120 ||
                  !isSafeAgentPrompt(waitFor))) ||
          (waitForGone != null &&
              (waitForGone is! String ||
                  waitForGone.trim().isEmpty ||
                  waitForGone.length > 120 ||
                  !isSafeAgentPrompt(waitForGone)))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r2,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r2;
    case 'notes.create':
      final title = arguments['title'];
      final body = arguments['body'];
      final folder = arguments['folder'];
      const allowedNotesCreateKeys = <String>{'title', 'body', 'folder'};
      if (arguments.keys.any((k) => !allowedNotesCreateKeys.contains(k)) ||
          title is! String ||
          title.trim().isEmpty ||
          title.length > 500 ||
          title.contains('\x00') ||
          body is! String ||
          body.length > 50000 ||
          body.contains('\x00') ||
          (folder != null &&
              (folder is! String ||
                  folder.trim().isEmpty ||
                  folder.length > 200 ||
                  folder.contains('\x00')))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r2,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r2;
    case 'notes.append':
      final id = arguments['id'];
      final title = arguments['title'];
      final text = arguments['text'];
      const allowedNotesAppendKeys = <String>{'id', 'title', 'text'};
      if (arguments.keys.any((k) => !allowedNotesAppendKeys.contains(k)) ||
          text is! String ||
          text.trim().isEmpty ||
          text.length > 50000 ||
          text.contains('\x00') ||
          (id != null &&
              (id is! String ||
                  id.trim().isEmpty ||
                  id.length > 200 ||
                  id.contains('\x00'))) ||
          (title != null &&
              (title is! String ||
                  title.trim().isEmpty ||
                  title.length > 500 ||
                  title.contains('\x00')))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r2,
          errorCode: 'schema_mismatch',
        );
      }
      if (id == null && title == null) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r2,
          errorCode: 'missing_target',
        );
      }
      effectiveRisk = RiskTier.r2;
    case 'notes.search':
      final query = arguments['query'];
      final maxResults = arguments['maxResults'];
      const allowedNotesSearchKeys = <String>{'query', 'maxResults'};
      if (arguments.keys.any((k) => !allowedNotesSearchKeys.contains(k)) ||
          query is! String ||
          query.trim().isEmpty ||
          query.length > 200 ||
          (maxResults != null &&
              (maxResults is! int || maxResults < 1 || maxResults > 20))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r1,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r1;
    case 'reminders.create':
      final title = arguments['title'];
      final list = arguments['list'];
      final dueDate = arguments['dueDate'];
      final notes = arguments['notes'];
      final priority = arguments['priority'];
      const allowedRemindersCreateKeys = <String>{
        'title',
        'list',
        'dueDate',
        'notes',
        'priority',
      };
      if (arguments.keys.any((k) => !allowedRemindersCreateKeys.contains(k)) ||
          title is! String ||
          title.trim().isEmpty ||
          title.length > 500 ||
          (list != null &&
              (list is! String || list.trim().isEmpty || list.length > 200)) ||
          (dueDate != null &&
              (dueDate is! String || !_isValidIsoDate(dueDate))) ||
          (notes != null && (notes is! String || notes.length > 5000)) ||
          (priority != null &&
              (priority is! int || priority < 0 || priority > 9))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r2,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r2;
    case 'calendar.list_events':
      final timeMin = arguments['timeMin'];
      final timeMax = arguments['timeMax'];
      final calendarName = arguments['calendarName'];
      final maxResults = arguments['maxResults'];
      const allowedCalendarListKeys = <String>{
        'timeMin',
        'timeMax',
        'calendarName',
        'maxResults',
      };
      if (arguments.keys.any((k) => !allowedCalendarListKeys.contains(k)) ||
          timeMin is! String ||
          !_isValidIsoDate(timeMin) ||
          timeMax is! String ||
          !_isValidIsoDate(timeMax) ||
          (calendarName != null &&
              (calendarName is! String ||
                  calendarName.trim().isEmpty ||
                  calendarName.length > 200)) ||
          (maxResults != null &&
              (maxResults is! int || maxResults < 1 || maxResults > 50))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r1,
          errorCode: 'schema_mismatch',
        );
      }
      final parsedMin = DateTime.parse(timeMin.trim());
      final parsedMax = DateTime.parse(timeMax.trim());
      if (parsedMin.isAfter(parsedMax)) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r1,
          errorCode: 'invalid_date_range',
        );
      }
      effectiveRisk = RiskTier.r1;
    case 'calendar.create_event':
      final title = arguments['title'];
      final startTime = arguments['startTime'];
      final endTime = arguments['endTime'];
      final location = arguments['location'];
      final notes = arguments['notes'];
      final calendarName = arguments['calendarName'];
      const allowedCalendarCreateKeys = <String>{
        'title',
        'startTime',
        'endTime',
        'location',
        'notes',
        'calendarName',
      };
      if (arguments.keys.any((k) => !allowedCalendarCreateKeys.contains(k)) ||
          title is! String ||
          title.trim().isEmpty ||
          title.length > 500 ||
          startTime is! String ||
          !_isValidIsoDate(startTime) ||
          endTime is! String ||
          !_isValidIsoDate(endTime) ||
          (location != null &&
              (location is! String || location.length > 500)) ||
          (notes != null && (notes is! String || notes.length > 5000)) ||
          (calendarName != null &&
              (calendarName is! String ||
                  calendarName.trim().isEmpty ||
                  calendarName.length > 200))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r2,
          errorCode: 'schema_mismatch',
        );
      }
      final parsedStart = DateTime.parse(startTime.trim());
      final parsedEnd = DateTime.parse(endTime.trim());
      if (parsedStart.isAfter(parsedEnd)) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r2,
          errorCode: 'invalid_date_range',
        );
      }
      effectiveRisk = RiskTier.r2;
    case 'finder.reveal':
      final path = arguments['path'];
      const allowedFinderKeys = <String>{'path'};
      if (arguments.keys.any((k) => !allowedFinderKeys.contains(k)) ||
          path is! String ||
          path.trim().isEmpty ||
          path.length > 1024 ||
          path.contains('\x00')) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r1,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r1;
    case 'shortcuts.run':
      final shortcutName = arguments['shortcutName'];
      final input = arguments['input'];
      const allowedShortcutsKeys = <String>{'shortcutName', 'input'};
      if (arguments.keys.any((k) => !allowedShortcutsKeys.contains(k)) ||
          shortcutName is! String ||
          shortcutName.startsWith('-') ||
          !_shortcutNamePattern.hasMatch(shortcutName) ||
          (input != null && input is String && input.length > 50000)) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r2,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r2;
    case 'mail.create_draft':
      final to = arguments['to'];
      final cc = arguments['cc'];
      final bcc = arguments['bcc'];
      final subject = arguments['subject'];
      final body = arguments['body'];
      const allowedMailKeys = <String>{'to', 'cc', 'bcc', 'subject', 'body'};
      if (arguments.keys.any((k) => !allowedMailKeys.contains(k)) ||
          to is! List ||
          to.isEmpty ||
          !to.every((item) => item is String && _isValidEmailAddress(item)) ||
          (cc != null &&
              (cc is! List ||
                  !cc.every((item) =>
                      item is String && _isValidEmailAddress(item)))) ||
          (bcc != null &&
              (bcc is! List ||
                  !bcc.every((item) =>
                      item is String && _isValidEmailAddress(item)))) ||
          subject is! String ||
          subject.length > 500 ||
          subject.contains('\r') ||
          subject.contains('\n') ||
          body is! String ||
          body.length > 50000) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r2,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r2;

    case 'web.navigate':
      final url = arguments['url'];
      final timeoutMs = arguments['timeoutMs'];
      const allowedNavigateKeys = <String>{'url', 'timeoutMs'};
      if (arguments.keys.any((k) => !allowedNavigateKeys.contains(k)) ||
          url is! String ||
          url.trim().isEmpty ||
          url.length > 2048 ||
          url.contains('\x00') ||
          (timeoutMs != null &&
              (timeoutMs is! int || timeoutMs < 1000 || timeoutMs > 60000))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r2,
          errorCode: 'schema_mismatch',
        );
      }
      final urlCheck = validateHttpsUrlAgainstAllowlist(
        url,
        activePolicy.urlDomains,
      );
      if (!urlCheck.validUrl) {
        return PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r2,
          errorCode: urlCheck.errorCode ?? 'url_invalid',
        );
      }
      if (activePolicy.isDomainDenied(urlCheck.asciiHost)) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.denied,
          effectiveRisk: RiskTier.r2,
          errorCode: 'domain_not_allowed',
        );
      }
      if (!urlCheck.domainAllowed && !allowPublicHttpsDomains) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.denied,
          effectiveRisk: RiskTier.r2,
          errorCode: 'domain_not_allowed',
        );
      }
      normalizedUrlHost = urlCheck.asciiHost;
      effectiveRisk = RiskTier.r2;

    case 'web.snapshot':
      final compact = arguments['compact'];
      final maxBytes = arguments['maxBytes'];
      const allowedSnapshotKeys = <String>{'compact', 'maxBytes'};
      if (arguments.keys.any((k) => !allowedSnapshotKeys.contains(k)) ||
          (compact != null && compact is! bool) ||
          (maxBytes != null &&
              (maxBytes is! int || maxBytes < 100 || maxBytes > 6144))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r1,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r1;

    case 'web.click':
      final ref = arguments['ref'];
      final selector = arguments['selector'];
      final targetText = arguments['targetText'];
      const allowedClickKeys = <String>{'ref', 'selector', 'targetText'};
      if (arguments.keys.any((k) => !allowedClickKeys.contains(k)) ||
          ref is! String ||
          ref.trim().isEmpty ||
          ref.length > 200 ||
          ref.contains('\x00') ||
          (selector != null &&
              (selector is! String ||
                  selector.trim().isEmpty ||
                  selector.length > 500 ||
                  selector.contains('\x00'))) ||
          (targetText != null &&
              (targetText is! String || targetText.length > 200))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r2,
          errorCode: 'schema_mismatch',
        );
      }
      final isConsequential = activePolicy.trustPreset == TrustPreset.autopilot
          ? isHighImpactBrowserTarget(
              ref: ref,
              selector: selector as String?,
              targetText: targetText as String?,
            )
          : isConsequentialBrowserTarget(
              ref: ref,
              selector: selector as String?,
              targetText: targetText as String?,
            );
      effectiveRisk = isConsequential ? RiskTier.r3 : RiskTier.r2;

    case 'web.fill':
      final ref = arguments['ref'];
      final value = arguments['value'];
      final selector = arguments['selector'];
      final targetText = arguments['targetText'];
      const allowedFillKeys = <String>{
        'ref',
        'value',
        'selector',
        'targetText'
      };
      if (arguments.keys.any((k) => !allowedFillKeys.contains(k)) ||
          ref is! String ||
          ref.trim().isEmpty ||
          ref.length > 200 ||
          ref.contains('\x00') ||
          value is! String ||
          value.length > 10000 ||
          value.contains('\x00') ||
          (selector != null &&
              (selector is! String ||
                  selector.trim().isEmpty ||
                  selector.length > 500 ||
                  selector.contains('\x00'))) ||
          (targetText != null &&
              (targetText is! String || targetText.length > 200))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r2,
          errorCode: 'schema_mismatch',
        );
      }
      final isConsequential = activePolicy.trustPreset == TrustPreset.autopilot
          ? isHighImpactBrowserTarget(
              ref: ref,
              selector: selector as String?,
              targetText: targetText as String?,
              value: value,
            )
          : isConsequentialBrowserTarget(
              ref: ref,
              selector: selector as String?,
              targetText: targetText as String?,
              value: value,
            );
      effectiveRisk = isConsequential ? RiskTier.r3 : RiskTier.r2;

    case 'web.select':
      final ref = arguments['ref'];
      final value = arguments['value'];
      final selector = arguments['selector'];
      const allowedSelectKeys = <String>{'ref', 'value', 'selector'};
      if (arguments.keys.any((k) => !allowedSelectKeys.contains(k)) ||
          ref is! String ||
          ref.trim().isEmpty ||
          ref.length > 200 ||
          ref.contains('\x00') ||
          value is! String ||
          value.trim().isEmpty ||
          value.length > 500 ||
          value.contains('\x00') ||
          (selector != null &&
              (selector is! String ||
                  selector.trim().isEmpty ||
                  selector.length > 500 ||
                  selector.contains('\x00')))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r2,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r2;

    case 'web.extract':
      final ref = arguments['ref'];
      final selector = arguments['selector'];
      final attribute = arguments['attribute'];
      const allowedExtractKeys = <String>{'ref', 'selector', 'attribute'};
      if (arguments.keys.any((k) => !allowedExtractKeys.contains(k)) ||
          (ref != null &&
              (ref is! String ||
                  ref.trim().isEmpty ||
                  ref.length > 200 ||
                  ref.contains('\x00'))) ||
          (selector != null &&
              (selector is! String ||
                  selector.trim().isEmpty ||
                  selector.length > 500 ||
                  selector.contains('\x00'))) ||
          (attribute != null &&
              (attribute is! String ||
                  attribute.trim().isEmpty ||
                  attribute.length > 100 ||
                  attribute.contains('\x00')))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r1,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r1;

    case 'web.wait_for':
      final selector = arguments['selector'];
      final state = arguments['state'];
      final timeoutMs = arguments['timeoutMs'];
      const allowedWaitForKeys = <String>{'selector', 'state', 'timeoutMs'};
      const allowedStates = <String>{
        'visible',
        'hidden',
        'attached',
        'detached'
      };
      if (arguments.keys.any((k) => !allowedWaitForKeys.contains(k)) ||
          (selector != null &&
              (selector is! String ||
                  selector.trim().isEmpty ||
                  selector.length > 500 ||
                  selector.contains('\x00'))) ||
          (state != null &&
              (state is! String || !allowedStates.contains(state))) ||
          (timeoutMs != null &&
              (timeoutMs is! int || timeoutMs < 100 || timeoutMs > 30000))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r1,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r1;

    default:
      if (toolName.startsWith('forge.custom_')) {
        final argsJson = arguments['argsJson'];
        final outputFolder = arguments['outputFolder'];
        const allowedCustomKeys = <String>{'argsJson', 'outputFolder'};
        if (arguments.keys.any((k) => !allowedCustomKeys.contains(k)) ||
            (argsJson != null &&
                (argsJson is! String ||
                    argsJson.length > 2000 ||
                    !isSafeClipboardWriteText(argsJson))) ||
            (outputFolder != null &&
                (outputFolder is! String ||
                    !isValidSandboxFolderName(outputFolder)))) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.invalidArgs,
            effectiveRisk: RiskTier.r2,
            errorCode: 'schema_mismatch',
          );
        }
        effectiveRisk = RiskTier.r2;
        break;
      }
      return const PolicyEvaluationResult(
        allowed: false,
        status: XtpStatus.unsupported,
        effectiveRisk: RiskTier.r1,
        errorCode: 'platform_unsupported',
      );
  }

  return PolicyEvaluationResult(
    allowed: true,
    status: XtpStatus.ok,
    effectiveRisk: effectiveRisk,
    app: matchedApp,
    workflow: matchedWorkflow,
    normalizedUrlHost: normalizedUrlHost,
  );
}
