import 'dart:convert';
import 'dart:typed_data';

import 'canonical_json.dart';
import 'crypto.dart';
import 'policy/policy_models.dart';
import 'policy/tool_arg_validators.dart';
import 'schemas.dart';

export 'policy/forge_swarm_validators.dart';
export 'policy/policy_models.dart';
export 'policy/security_redaction.dart';
export 'policy/tool_arg_validators.dart';
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
    bool allowZeroConfigAppDiscovery = false,
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
    if (!activePolicy.isFamilyAllowed(family)) {
      return const PolicyEvaluationResult(
        allowed: false,
        status: XtpStatus.denied,
        effectiveRisk: RiskTier.r1,
        errorCode: 'policy_blocked',
      );
    }

    final argResult = validateToolArguments(
      toolName: toolName,
      arguments: arguments,
      activePolicy: activePolicy,
      now: now,
      isStopped: isStopped,
      hostId: hostId,
      pinnedPhonePublicKeys: pinnedPhonePublicKeys,
      isInApprovedCuSession: isInApprovedCuSession,
      allowZeroConfigAppDiscovery: allowZeroConfigAppDiscovery,
      evaluateStep: evaluateInvocation,
    );
    if (!argResult.allowed) {
      return argResult;
    }

    final effectiveRisk = argResult.effectiveRisk;
    final matchedApp = argResult.app;
    final matchedWorkflow = argResult.workflow;
    final normalizedUrlHost = argResult.normalizedUrlHost;

    // UDC-8 §4.2: Inside an already-approved computer-use session, R2
    // observation/input tools do not require per-call approval; R3 tools
    // ALWAYS require a phone-signed single-use approval.
    final requiresApproval = isInApprovedCuSession &&
            const <ToolFamily>{
              ToolFamily.screen,
              ToolFamily.ui,
              ToolFamily.input,
            }.contains(family)
        ? effectiveRisk >= RiskTier.r3
        : effectiveRisk >= RiskTier.r2;

    if (requiresApproval) {
      if (approval == null) {
        return PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.denied,
          effectiveRisk: effectiveRisk,
          errorCode: 'approval_required',
        );
      }
      if (approval.isExpiredAt(now)) {
        return PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.denied,
          effectiveRisk: effectiveRisk,
          errorCode: 'approval_expired',
        );
      }
      final computedHash = argsSha256(arguments);
      if (approval.argsSha256 != computedHash) {
        return PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.denied,
          effectiveRisk: effectiveRisk,
          errorCode: 'approval_mismatch',
        );
      }
      if (effectiveRisk >= RiskTier.r3) {
        if (approval.scope != 'once') {
          return PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.denied,
            effectiveRisk: effectiveRisk,
            errorCode: 'r3_requires_once_scope',
          );
        }
        // UDC-7 S7.5: Verify phone-signed approval for R3 tools against
        // enrolled owner phone keys; reject missing or invalid signatures.
        final sig = approval.signature;
        if (sig == null ||
            hostId == null ||
            hostId.isEmpty ||
            pinnedPhonePublicKeys.isEmpty) {
          return PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.denied,
            effectiveRisk: effectiveRisk,
            errorCode: 'approval_signature_invalid',
          );
        }
        final proofMsg = approvalProofMessage(
          approvalId: approval.approvalId,
          argsSha256: approval.argsSha256,
          hostId: hostId,
          expiresAt: approval.expiresAtWire,
        );
        final candidateKeys = <Uint8List>[];
        if (approval.publicKey != null) {
          final hasMatch = pinnedPhonePublicKeys.any(
            (k) => _bytesEqual(k, approval.publicKey!),
          );
          if (!hasMatch) {
            return PolicyEvaluationResult(
              allowed: false,
              status: XtpStatus.denied,
              effectiveRisk: effectiveRisk,
              errorCode: 'approval_signature_invalid',
            );
          }
          candidateKeys.add(approval.publicKey!);
        } else {
          candidateKeys.addAll(pinnedPhonePublicKeys);
        }
        if (candidateKeys.isEmpty ||
            !candidateKeys.any(
              (k) => verifyP256Signature(
                publicKey: k,
                message: proofMsg,
                signature: sig,
              ),
            )) {
          return PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.denied,
            effectiveRisk: effectiveRisk,
            errorCode: 'approval_signature_invalid',
          );
        }
      }
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
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
