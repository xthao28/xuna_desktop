import 'dart:typed_data';

import '../canonical_json.dart';
import '../schemas.dart';
import 'forge_swarm_validators.dart';
import 'policy_models.dart';
import 'security_redaction.dart';
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
});

/// Validates tool arguments and resolves the effective [RiskTier] (plus any
/// matched app/workflow or normalized URL host) before the approval gate.
///
/// If `allowed` is `false` on the returned [PolicyEvaluationResult], the caller
/// must immediately return that failure result. If `allowed` is `true`, the
/// caller proceeds to the approval-token check using the returned
/// `effectiveRisk`, `app`, `workflow`, and `normalizedUrlHost`.
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
      if (arguments.length != 1 || arguments['id'] is! String) {
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
    case 'meeting.status':
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
    case 'meeting.control':
      final action = arguments['action'];
      if (arguments.length != 1 ||
          action is! String ||
          !allowedMeetingActions.contains(action)) {
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
              (dataBase64 is! String || dataBase64.isEmpty))) {
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
                  !isSafeAgentPrompt(payloadJson)))) {
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
          (proj != null &&
              (proj is! String || !isValidWorkspaceQuery(proj))) ||
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
    case 'meeting.desk_whisper_digest':
      final topic = arguments['topic'];
      final contextHint = arguments['contextHint'];
      const allowedWhisperKeys = <String>{'topic', 'contextHint'};
      if (arguments.keys.any((k) => !allowedWhisperKeys.contains(k)) ||
          topic is! String ||
          topic.trim().isEmpty ||
          topic.length > 120 ||
          !isSafeAgentPrompt(topic) ||
          (contextHint != null &&
              (contextHint is! String ||
                  contextHint.length > 240 ||
                  !isSafeAgentPrompt(contextHint)))) {
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
                  !allowedSynthesizedToolRuntimes
                      .contains(runtime.trim().toLowerCase()))) ||
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
      final simulateDelta = arguments['simulateDelta'];
      const allowedHbKeys = <String>{
        'action',
        'checkName',
        'intervalMinutes',
        'simulateDelta',
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
                  intervalMinutes > 720)) ||
          (simulateDelta != null && simulateDelta is! bool)) {
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
    case 'subagent.spawn_and_poll':
      final action = arguments['action'];
      final taskGoal = arguments['taskGoal'];
      final workerId = arguments['workerId'];
      final tokenBudget = arguments['tokenBudget'];
      final sourceFolder = arguments['sourceFolder'];
      final specialistRoles = arguments['specialistRoles'];
      final enableCriticVerification = arguments['enableCriticVerification'];
      const allowedSubKeys = <String>{
        'action',
        'taskGoal',
        'workerId',
        'tokenBudget',
        'sourceFolder',
        'specialistRoles',
        'enableCriticVerification',
      };
      if (arguments.keys.any((k) => !allowedSubKeys.contains(k)) ||
          action is! String ||
          !allowedSubagentActions.contains(action) ||
          (taskGoal != null &&
              (taskGoal is! String ||
                  taskGoal.trim().isEmpty ||
                  taskGoal.length > 400 ||
                  !isSafeAgentPrompt(taskGoal))) ||
          ((action == 'spawn' || action == 'spawn_swarm') &&
              (taskGoal is! String || taskGoal.trim().isEmpty)) ||
          (workerId != null &&
              (workerId is! String || !isValidShortId(workerId))) ||
          (tokenBudget != null &&
              (tokenBudget is! int ||
                  tokenBudget < 256 ||
                  tokenBudget > 8192)) ||
          (sourceFolder != null &&
              (sourceFolder is! String ||
                  !isValidSandboxFolderName(sourceFolder))) ||
          (enableCriticVerification != null &&
              enableCriticVerification is! bool)) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r1,
          errorCode: 'schema_mismatch',
        );
      }
      if (specialistRoles != null) {
        if (specialistRoles is! List ||
            specialistRoles.isEmpty ||
            specialistRoles.length > 4 ||
            specialistRoles.any(
              (r) =>
                  r is! String ||
                  !allowedSubagentSpecialistRoles.contains(r.trim()),
            )) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.denied,
            effectiveRisk: RiskTier.r1,
            errorCode: 'subagent_role_forbidden',
          );
        }
      }
      effectiveRisk = RiskTier.r1;
    case 'schedule.cron_and_hooks':
      final action = arguments['action'];
      final hookId = arguments['hookId'];
      final eventOrCron = arguments['eventOrCron'];
      final targetSkillId = arguments['targetSkillId'];
      final labelVi = arguments['labelVi'];
      const allowedHookKeys = <String>{
        'action',
        'hookId',
        'eventOrCron',
        'targetSkillId',
        'labelVi',
      };
      if (arguments.keys.any((k) => !allowedHookKeys.contains(k)) ||
          action is! String ||
          !allowedScheduleHookActions.contains(action) ||
          (hookId != null &&
              (hookId is! String || !isValidShortId(hookId))) ||
          (eventOrCron != null &&
              (eventOrCron is! String ||
                  !allowedLifecycleEvents.contains(eventOrCron))) ||
          (targetSkillId != null &&
              (targetSkillId is! String || !isValidShortId(targetSkillId))) ||
          (labelVi != null &&
              (labelVi is! String ||
                  labelVi.trim().isEmpty ||
                  labelVi.length > 120 ||
                  !isSafeAgentPrompt(labelVi))) ||
          (action == 'register' &&
              (eventOrCron is! String || targetSkillId is! String)) ||
          (action == 'trigger_event' && eventOrCron is! String) ||
          (action == 'remove' && hookId is! String)) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r1,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r1;
    case 'companion.overlay_and_drop':
      final mode = arguments['mode'];
      final anchor = arguments['anchor'];
      final droppedItemName = arguments['droppedItemName'];
      final droppedContent = arguments['droppedContent'];
      final targetAction = arguments['targetAction'];
      const allowedOverlayKeys = <String>{
        'mode',
        'anchor',
        'droppedItemName',
        'droppedContent',
        'targetAction',
      };
      if (arguments.keys.any((k) => !allowedOverlayKeys.contains(k)) ||
          mode is! String ||
          !allowedCompanionOverlayModes.contains(mode) ||
          (anchor != null &&
              (anchor is! String ||
                  !allowedCompanionOverlayAnchors.contains(anchor))) ||
          (droppedItemName != null &&
              (droppedItemName is! String ||
                  droppedItemName.trim().isEmpty ||
                  droppedItemName.length > 180)) ||
          (droppedContent != null &&
              (droppedContent is! String ||
                  !isSafeClipboardWriteText(droppedContent))) ||
          (targetAction != null &&
              (targetAction is! String ||
                  targetAction.trim().isEmpty ||
                  targetAction.length > 64 ||
                  !isSafeAgentPrompt(targetAction))) ||
          (mode == 'feed_drop_item' &&
              (droppedItemName is! String ||
                  droppedItemName.trim().isEmpty ||
                  droppedItemName.length > 180))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r1,
          errorCode: 'schema_mismatch',
        );
      }
      if (droppedItemName is String &&
          droppedItemName.contains('.') &&
          !isValidBeamFileName(droppedItemName)) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.denied,
          effectiveRisk: RiskTier.r1,
          errorCode: 'drop_item_forbidden_extension',
        );
      }
      effectiveRisk = RiskTier.r1;
    case 'acoustic.vocalize_and_sense':
      final mode = arguments['mode'];
      final vocalKind = arguments['vocalKind'];
      final themeId = arguments['themeId'];
      final speechRateWpm = arguments['speechRateWpm'];
      final rmsEnergyDb = arguments['rmsEnergyDb'];
      final pauseRatioPercent = arguments['pauseRatioPercent'];
      const allowedAcousticKeys = <String>{
        'mode',
        'vocalKind',
        'themeId',
        'speechRateWpm',
        'rmsEnergyDb',
        'pauseRatioPercent',
      };
      if (arguments.keys.any((k) => !allowedAcousticKeys.contains(k)) ||
          mode is! String ||
          !allowedAcousticModes.contains(mode) ||
          (vocalKind != null &&
              (vocalKind is! String ||
                  !allowedAcousticVocalKinds.contains(vocalKind))) ||
          (themeId != null &&
              (themeId is! String || !isValidShortId(themeId))) ||
          (speechRateWpm != null &&
              (speechRateWpm is! int ||
                  speechRateWpm < 20 ||
                  speechRateWpm > 320)) ||
          (rmsEnergyDb != null &&
              (rmsEnergyDb is! int || rmsEnergyDb < -80 || rmsEnergyDb > 0)) ||
          (pauseRatioPercent != null &&
              (pauseRatioPercent is! int ||
                  pauseRatioPercent < 0 ||
                  pauseRatioPercent > 100))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r1,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r1;
    case 'memory.temporal_graph':
      final mode = arguments['mode'];
      final subject = arguments['subject'];
      final predicate = arguments['predicate'];
      final object = arguments['object'];
      final validFromIso = arguments['validFromIso'];
      const allowedTemporalKeys = <String>{
        'mode',
        'subject',
        'predicate',
        'object',
        'validFromIso',
      };
      if (arguments.keys.any((k) => !allowedTemporalKeys.contains(k)) ||
          mode is! String ||
          !allowedTemporalGraphModes.contains(mode) ||
          (subject != null &&
              (subject is! String ||
                  subject.trim().isEmpty ||
                  subject.length > 120)) ||
          (predicate != null &&
              (predicate is! String ||
                  predicate.trim().isEmpty ||
                  predicate.length > 120)) ||
          (object != null &&
              (object is! String ||
                  object.trim().isEmpty ||
                  object.length > 200)) ||
          (validFromIso != null &&
              (validFromIso is! String ||
                  validFromIso.trim().isEmpty ||
                  validFromIso.length > 64)) ||
          (mode == 'upsert_temporal_edge' &&
              (subject is! String ||
                  subject.trim().isEmpty ||
                  predicate is! String ||
                  predicate.trim().isEmpty ||
                  object is! String ||
                  object.trim().isEmpty))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r1,
          errorCode: 'schema_mismatch',
        );
      }
      if (mode == 'upsert_temporal_edge' &&
          containsForbiddenSkillMarkdownPattern(
              '$subject $predicate $object')) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.denied,
          effectiveRisk: RiskTier.r1,
          errorCode: 'temporal_graph_content_unsafe',
        );
      }
      effectiveRisk = RiskTier.r1;
    case 'ritual.mindful_and_playdate':
      final mode = arguments['mode'];
      final durationMinutes = arguments['durationMinutes'];
      final focusGoal = arguments['focusGoal'];
      final neighborShortId = arguments['neighborShortId'];
      final giftMessage = arguments['giftMessage'];
      const allowedRitualKeys = <String>{
        'mode',
        'durationMinutes',
        'focusGoal',
        'neighborShortId',
        'giftMessage',
      };
      if (arguments.keys.any((k) => !allowedRitualKeys.contains(k)) ||
          mode is! String ||
          !allowedRitualModes.contains(mode) ||
          (durationMinutes != null &&
              (durationMinutes is! int ||
                  durationMinutes < 1 ||
                  durationMinutes > 90)) ||
          (focusGoal != null &&
              (focusGoal is! String ||
                  focusGoal.trim().isEmpty ||
                  focusGoal.length > 200 ||
                  !isSafeAgentPrompt(focusGoal))) ||
          (neighborShortId != null &&
              (neighborShortId is! String ||
                  !isValidShortId(neighborShortId.toLowerCase()))) ||
          (giftMessage != null &&
              (giftMessage is! String ||
                  giftMessage.trim().isEmpty ||
                  giftMessage.length > 240 ||
                  !isSafeAgentPrompt(giftMessage))) ||
          (mode == 'send_neighbor_playdate' &&
              (neighborShortId is! String ||
                  !isValidShortId(neighborShortId.toLowerCase())))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r1,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r1;
    case 'ui.accessibility_tree':
      final action = arguments['action'];
      final windowTitle = arguments['windowTitle'];
      final refId = arguments['refId'];
      final valueText = arguments['valueText'];
      final maxNodes = arguments['maxNodes'];
      const allowedUiaKeys = <String>{
        'action',
        'windowTitle',
        'refId',
        'valueText',
        'maxNodes',
      };
      final refPattern = RegExp(r'^ui_[a-z0-9_]{1,24}$');
      if (arguments.keys.any((k) => !allowedUiaKeys.contains(k)) ||
          action is! String ||
          !allowedUiAccessibilityActions.contains(action) ||
          (windowTitle != null &&
              (windowTitle is! String ||
                  windowTitle.trim().isEmpty ||
                  windowTitle.length > 120 ||
                  !isSafeAgentPrompt(windowTitle))) ||
          (refId != null &&
              (refId is! String || !refPattern.hasMatch(refId.trim()))) ||
          (valueText != null &&
              (valueText is! String ||
                  valueText.length > 500 ||
                  !isSafeClipboardWriteText(valueText))) ||
          (maxNodes != null &&
              (maxNodes is! int || maxNodes < 1 || maxNodes > 80)) ||
          ((action == 'invoke_ref' || action == 'set_value_ref') &&
              (refId is! String || !refPattern.hasMatch(refId.trim()))) ||
          (action == 'set_value_ref' &&
              (valueText is! String || valueText.trim().isEmpty))) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r1,
          errorCode: 'schema_mismatch',
        );
      }
      if (windowTitle is String) {
        final lowerWin = windowTitle.toLowerCase();
        if (forbiddenUiWindowPatterns.any((p) => lowerWin.contains(p))) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.denied,
            effectiveRisk: RiskTier.r1,
            errorCode: 'ui_window_forbidden_target',
          );
        }
      }
      if (refId is String) {
        final lowerRef = refId.toLowerCase();
        if (lowerRef.contains('pass') ||
            lowerRef.contains('secret') ||
            lowerRef.contains('pin') ||
            lowerRef.contains('token')) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.denied,
            effectiveRisk: RiskTier.r1,
            errorCode: 'ui_ref_password_or_unsafe_blocked',
          );
        }
      }
      if (valueText is String &&
          containsForbiddenSkillMarkdownPattern(valueText)) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.denied,
          effectiveRisk: RiskTier.r1,
          errorCode: 'ui_ref_password_or_unsafe_blocked',
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
      if (!urlCheck.domainAllowed) {
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
      if (arguments.length > 1 ||
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
        final stepArgs = castPolicyObjectMap(rawStep['arguments'], 'batch_step');
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
          maxSteps > 20 ||
          maxMinutes is! int ||
          maxMinutes < 1 ||
          maxMinutes > 10) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r3,
          errorCode: 'schema_mismatch',
        );
      }
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
        if (activePolicy.findApp(appItem) == null) {
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
        final domainAllowed = activePolicy.urlDomains.any(
          (allowed) =>
              asciiDomain == allowed || asciiDomain.endsWith('.$allowed'),
        );
        if (!domainAllowed) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.denied,
            effectiveRisk: RiskTier.r3,
            errorCode: 'domain_not_allowed',
          );
        }
      }
      effectiveRisk = RiskTier.r3;
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
      if (arguments.length != 2 ||
          scope != 'active_window' ||
          maxNodes is! int ||
          maxNodes < 1 ||
          maxNodes > 300) {
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
      final hasElement = elementId is String && elementId.isNotEmpty;
      final hasCoords = x is int && y is int;
      if ((!hasElement && !hasCoords) ||
          (elementName != null && elementName is! String)) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r2,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = isConsequentialElementName(elementName as String?)
          ? RiskTier.r3
          : RiskTier.r2;
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
      if (elementId is! String ||
          elementId.isEmpty ||
          elementId.length > 64 ||
          text is! String ||
          text.isEmpty ||
          text.length > 200 ||
          (elementName != null && elementName is! String)) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r3,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r3;
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
      if (combo is! String ||
          !allowedInputKeyCombos.contains(combo) ||
          (inForm != null && inForm is! bool)) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r2,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk =
          (combo == 'Enter' && inForm == true) ? RiskTier.r3 : RiskTier.r2;
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
      if (direction is! String ||
          !<String>{'up', 'down', 'left', 'right'}.contains(direction) ||
          amount is! int ||
          amount < 1 ||
          amount > 10 ||
          (elementId != null && elementId is! String)) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r2,
          errorCode: 'schema_mismatch',
        );
      }
      effectiveRisk = RiskTier.r2;
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
