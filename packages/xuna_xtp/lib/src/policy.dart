import 'dart:convert';
import 'dart:typed_data';

import 'canonical_json.dart';
import 'crypto.dart';
import 'policy/exec_fs_validators.dart';
import 'policy/policy_models.dart';
import 'policy/tool_arg_validators.dart';
import 'schemas.dart';

export 'policy/exec_command_classifier.dart';
export 'policy/exec_command_lexer.dart';
export 'policy/exec_environment.dart';
export 'policy/exec_expected_outputs.dart';
export 'policy/exec_fs_validators.dart';
export 'policy/forge_swarm_validators.dart';
export 'policy/fs_path_guard.dart';
export 'policy/input_step_risk.dart';
export 'policy/policy_models.dart';
export 'policy/security_redaction.dart';
export 'policy/shell_control_policy.dart';
export 'policy/tool_arg_validators.dart';
export 'policy/ui_find.dart';
export 'policy/url_domain_validator.dart';

/// Fail-closed evaluator for `host-policy.json` (`UDC-3` §5.6.4–§5.6.5).
///
/// When constructed from a missing, unreadable or invalid policy file,
/// [isHealthy] is `false`, [trayBanner] is `'Cấu hình lỗi'`, and every tool
/// except `host.status` is denied (`policy_invalid`).
class HostPolicyEvaluator {
  const HostPolicyEvaluator.healthy(this.policy)
      : isHealthy = true,
        loadError = null;

  const HostPolicyEvaluator.corrupted([this.loadError = 'invalid_policy_file'])
      : policy = null,
        isHealthy = false;

  /// Parses [jsonText] into a [HostPolicyEvaluator]; any parse or schema
  /// error returns a fail-closed [HostPolicyEvaluator.corrupted] instance.
  factory HostPolicyEvaluator.fromJsonString(String? jsonText) {
    if (jsonText == null || jsonText.trim().isEmpty) {
      return const HostPolicyEvaluator.corrupted('missing_or_empty_policy');
    }
    try {
      final decoded = jsonDecode(jsonText);
      if (decoded is! Map) {
        return const HostPolicyEvaluator.corrupted('policy_not_an_object');
      }
      final map = castPolicyObjectMap(decoded, 'HostPolicy');
      return HostPolicyEvaluator.healthy(HostPolicy.fromJson(map));
    } catch (error) {
      return HostPolicyEvaluator.corrupted(error.toString());
    }
  }

  final HostPolicy? policy;
  final bool isHealthy;
  final String? loadError;

  /// Tray status label when the policy file is corrupted (`UDC-3` §5.6.4).
  String? get trayBanner => isHealthy ? null : 'Cấu hình lỗi';

  /// Evaluates a `tools/call` invocation following the normative order in
  /// `UDC-3` §5.6.5 and `UDC-8` §4.2:
  /// 1. `host.status` is always allowed if arguments are `{}` (even when
  ///    policy is corrupted or e-stop is active).
  /// 2. If suspended by e-stop (`isStopped == true`), deny with `stopped`.
  /// 3. Validate tool arguments against schema/URL rules (`invalid_args`).
  /// 4. Check fail-closed policy health and family/entry allowlist (`denied`).
  /// 5. If effective risk `>= R2` (or `>= R3` inside an active computer-use
  ///    session), verify `approval` is present, unexpired at [nowUtc], and
  ///    `approval.argsSha256 == argsSha256(arguments)`.
  PolicyEvaluationResult evaluateInvocation({
    required String toolName,
    required Map<String, Object?> arguments,
    ApprovalToken? approval,
    bool isStopped = false,
    DateTime? nowUtc,
    String? hostId,
    List<Uint8List> pinnedPhonePublicKeys = const <Uint8List>[],
    bool isInApprovedCuSession = false,
    Set<String>? cuSessionApprovedApps,
    bool allowZeroConfigAppDiscovery = true,
    bool allowPublicHttpsDomains = false,
    ExecFsHostContext? execFsContext,
  }) {
    final now = (nowUtc ?? DateTime.now()).toUtc();
    ToolDescriptor.validateToolName(toolName);

    if (toolName == 'host.status') {
      if (arguments.isNotEmpty) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r0,
          errorCode: 'schema_mismatch',
        );
      }
      return const PolicyEvaluationResult(
        allowed: true,
        status: XtpStatus.ok,
        effectiveRisk: RiskTier.r0,
      );
    }

    if (isStopped) {
      return const PolicyEvaluationResult(
        allowed: false,
        status: XtpStatus.denied,
        effectiveRisk: RiskTier.r1,
        errorCode: 'stopped',
      );
    }

    if (!isHealthy || policy == null) {
      return const PolicyEvaluationResult(
        allowed: false,
        status: XtpStatus.denied,
        effectiveRisk: RiskTier.r1,
        errorCode: 'policy_invalid',
      );
    }

    final activePolicy = policy!;
    final family = resolveToolFamilyForName(toolName)!;
    // `exec` is enabled only by the local-only `shellControl` switch
    // (ADR-0018); the `families` map cannot turn it on.
    if (family == ToolFamily.exec) {
      if (!activePolicy.shellControl.enabled) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.denied,
          effectiveRisk: RiskTier.r2,
          errorCode: 'shell_not_enabled',
          reasonCode: 'policy',
        );
      }
    } else if (!activePolicy.isFamilyAllowed(family)) {
      return const PolicyEvaluationResult(
        allowed: false,
        status: XtpStatus.denied,
        effectiveRisk: RiskTier.r1,
        errorCode: 'policy_blocked',
      );
    }

    final effectiveAllowZeroConfig =
        allowZeroConfigAppDiscovery && policy.allowsZeroConfigAppDiscovery;

    final argResult = validateToolArguments(
      toolName: toolName,
      arguments: arguments,
      activePolicy: activePolicy,
      now: now,
      isStopped: isStopped,
      hostId: hostId,
      pinnedPhonePublicKeys: pinnedPhonePublicKeys,
      isInApprovedCuSession: isInApprovedCuSession,
      allowZeroConfigAppDiscovery: effectiveAllowZeroConfig,
      allowPublicHttpsDomains: allowPublicHttpsDomains,
      evaluateStep: evaluateInvocation,
      execFsContext: execFsContext,
    );
    if (!argResult.allowed) {
      return argResult;
    }

    final effectiveRisk = argResult.effectiveRisk;
    final matchedApp = argResult.app;
    final matchedWorkflow = argResult.workflow;
    final normalizedUrlHost = argResult.normalizedUrlHost;

    // UDC-8 §4.2 & UDC-18: Inside an already-approved computer-use session (or
    // when the owner explicitly enabled the Autopilot trust preset), R2 tools
    // do not require per-call approval; R3 tools ALWAYS require a phone-signed
    // single-use approval regardless of preset or active session.
    final isAutopilot = activePolicy.trustPreset == TrustPreset.autopilot;
    bool isAppInCuSessionScope = false;
    if (family == ToolFamily.app) {
      if (cuSessionApprovedApps != null && toolName == 'app.launch') {
        final rawId = (arguments['id'] as String?)?.trim().toLowerCase();
        isAppInCuSessionScope = rawId != null &&
            rawId.isNotEmpty &&
            cuSessionApprovedApps.contains(rawId);
      } else {
        isAppInCuSessionScope = matchedApp != null;
      }
    }
    final requiresApproval = (isAutopilot ||
            (isInApprovedCuSession &&
                (const <ToolFamily>{
                      ToolFamily.screen,
                      ToolFamily.ui,
                      ToolFamily.input,
                    }.contains(family) ||
                    isAppInCuSessionScope)))
        ? effectiveRisk >= RiskTier.r3
        : effectiveRisk >= RiskTier.r2;

    if (requiresApproval) {
      final approvalError = effectiveRisk >= RiskTier.r3
          ? verifyPhoneSignedApproval(
              approval: approval,
              arguments: arguments,
              nowUtc: now,
              hostId: hostId,
              pinnedPhonePublicKeys: pinnedPhonePublicKeys,
            )
          : _verifyBoundApproval(approval, arguments, now);
      if (approvalError != null) {
        return PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.denied,
          effectiveRisk: effectiveRisk,
          errorCode: approvalError,
          reasonCode: argResult.reasonCode,
        );
      }
    }

    return PolicyEvaluationResult(
      allowed: true,
      status: XtpStatus.ok,
      effectiveRisk: effectiveRisk,
      app: matchedApp,
      workflow: matchedWorkflow,
      normalizedUrlHost: normalizedUrlHost,
      reasonCode: argResult.reasonCode,
    );
  }
}

/// Checks that [approval] is present, unexpired at [nowUtc] and bound to
/// `argsSha256(arguments)`. Returns `null` when it is, otherwise the XTP error
/// code (`approval_required`, `approval_expired`, `approval_mismatch`).
String? _verifyBoundApproval(
  ApprovalToken? approval,
  Map<String, Object?> arguments,
  DateTime nowUtc,
) {
  if (approval == null) return 'approval_required';
  if (approval.isExpiredAt(nowUtc)) return 'approval_expired';
  if (approval.argsSha256 != argsSha256(arguments)) return 'approval_mismatch';
  return null;
}

/// Verifies an R3 approval: bound to [arguments] and unexpired, scope `once`,
/// and signed by one of the owner's enrolled phone keys (UDC-7 S7.5).
///
/// Returns `null` when the approval is valid, otherwise the XTP error code.
/// The Desktop Agent also calls this when the risk comes from the live screen
/// rather than from the arguments (UDC-17 S17.1), so a step the host raised to
/// R3 can run once the owner has signed it.
String? verifyPhoneSignedApproval({
  required ApprovalToken? approval,
  required Map<String, Object?> arguments,
  required DateTime nowUtc,
  String? hostId,
  List<Uint8List> pinnedPhonePublicKeys = const <Uint8List>[],
}) {
  final boundError = _verifyBoundApproval(approval, arguments, nowUtc.toUtc());
  if (boundError != null) return boundError;
  final token = approval!;
  if (token.scope != 'once') return 'r3_requires_once_scope';
  final sig = token.signature;
  if (sig == null ||
      hostId == null ||
      hostId.isEmpty ||
      pinnedPhonePublicKeys.isEmpty) {
    return 'approval_signature_invalid';
  }
  final proofMsg = approvalProofMessage(
    approvalId: token.approvalId,
    argsSha256: token.argsSha256,
    hostId: hostId,
    expiresAt: token.expiresAtWire,
  );
  final candidateKeys = <Uint8List>[];
  final presentedKey = token.publicKey;
  if (presentedKey != null) {
    if (!pinnedPhonePublicKeys.any((k) => _bytesEqual(k, presentedKey))) {
      return 'approval_signature_invalid';
    }
    candidateKeys.add(presentedKey);
  } else {
    candidateKeys.addAll(pinnedPhonePublicKeys);
  }
  final verified = candidateKeys.any(
    (k) => verifyP256Signature(publicKey: k, message: proofMsg, signature: sig),
  );
  return verified ? null : 'approval_signature_invalid';
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// Extension on [HostPolicy] to determine whether zero-config app discovery
/// is permitted by the active trust preset.
extension HostPolicyZeroConfigExtension on HostPolicy? {
  bool get allowsZeroConfigAppDiscovery =>
      (this?.trustPreset ?? TrustPreset.standard) != TrustPreset.strict;
}
