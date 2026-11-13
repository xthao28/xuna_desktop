import '../schemas.dart';
import 'security_redaction.dart';

/// Host-decided risk of one `input.*` step (ADR-0015, UDC-17 S17.1).
///
/// [reasonCode] is a short machine code, never screen content, so it can be
/// logged and sent to the backend.
class InputStepRisk {
  const InputStepRisk(this.risk, this.reasonCode);

  final RiskTier risk;
  final String reasonCode;
}

/// Classifies an `input.*` step against the element the host resolved on the
/// live screen.
///
/// This is the single place the Desktop Agent decides the risk of an input
/// step: both `xuna/preflight` and the real execution call it, so the risk the
/// owner is asked to approve is the risk the host enforces.
///
/// Fail closed:
/// - typing is R2 only as a draft (ADR-0015 D1): the live target is in
///   [draftTextRoles], editable, not a password field, the text has no line
///   break, it is set semantically (not `headed` keystrokes), and it fits in
///   [draftCharsRemaining]. Anything else, including an unknown budget, is R3;
/// - while [hasUncommittedDraft] (unsigned text typed since the last signed
///   commit), a click on an element with no name is R3;
/// - Enter/Return is R2 only when [focusedRole] is `searchfield`, and Space only
///   when it is one of [draftTextRoles] (ADR-0015 D2). With a modifier, or with
///   focus unknown, they are R3 whatever the model declares;
/// - a click whose target the host could not find in the live tree is R3;
/// - a click on an element whose live name, or the model-declared name, reads
///   as a commit (send, delete, pay…) is R3. The declared name can only raise
///   the risk, never lower it.
///
/// [focusedRole] must come from the same live read as [liveTarget], and an
/// adapter reports it only when it is exact (role and subrole known, so a
/// secure field can never be reported as `textfield`).
InputStepRisk classifyInputStepRisk({
  required String toolName,
  required Map<String, Object?> arguments,
  Map<String, Object?>? liveTarget,
  String? focusedRole,
  int? draftCharsRemaining,
  bool hasUncommittedDraft = false,
}) {
  switch (toolName) {
    case 'input.type_text':
      if (liveTarget == null || !isDraftTextTarget(liveTarget)) {
        return const InputStepRisk(RiskTier.r3, 'unclassified_target');
      }
      final text = arguments['text'];
      // A line break typed into a composer is an Enter: it can send.
      if (text is String && (text.contains('\n') || text.contains('\r'))) {
        return const InputStepRisk(RiskTier.r3, 'multiline_text');
      }
      // `headed` types real keystrokes instead of setting the value, so any
      // key the app binds (Enter-to-send, shortcuts) can fire.
      if (arguments['headed'] == true) {
        return const InputStepRisk(RiskTier.r3, 'physical_typing');
      }
      if (text is! String ||
          draftCharsRemaining == null ||
          text.length > draftCharsRemaining) {
        return const InputStepRisk(RiskTier.r3, 'draft_budget_exceeded');
      }
      return const InputStepRisk(RiskTier.r2, 'draft_text');
    case 'input.key':
      final combo = arguments['combo'];
      if (combo is! String) {
        return const InputStepRisk(RiskTier.r3, 'activation_key');
      }
      if (!isActivationKeyCombo(combo)) {
        return const InputStepRisk(RiskTier.r2, 'navigation_key');
      }
      final parts = combo.split('+').where((p) => p.trim().isNotEmpty).toList();
      if (parts.length != 1) {
        return const InputStepRisk(RiskTier.r3, 'activation_key');
      }
      final key = parts.single.trim().toLowerCase();
      if ((key == 'enter' || key == 'return') && focusedRole == 'searchfield') {
        return const InputStepRisk(RiskTier.r2, 'search_submit');
      }
      if (key == 'space' && draftTextRoles.contains(focusedRole)) {
        return const InputStepRisk(RiskTier.r2, 'text_space');
      }
      return const InputStepRisk(RiskTier.r3, 'activation_key');
    case 'input.scroll':
      return const InputStepRisk(RiskTier.r2, 'scroll');
    case 'input.click':
      if (liveTarget == null) {
        return const InputStepRisk(RiskTier.r3, 'unclassified_target');
      }
      final liveName = liveTarget['name'];
      // While unsigned draft text sits in the window, an element with no name
      // (an icon-only Send) cannot be told apart from a commit.
      if (hasUncommittedDraft &&
          (liveName is! String || liveName.trim().isEmpty)) {
        return const InputStepRisk(RiskTier.r3, 'unclassified_target');
      }
      final declaredName = arguments['elementName'];
      if (isConsequentialElementName(liveName is String ? liveName : null) ||
          isConsequentialElementName(
            declaredName is String ? declaredName : null,
          )) {
        return const InputStepRisk(RiskTier.r3, 'consequential_target');
      }
      return const InputStepRisk(RiskTier.r2, 'navigation_target');
    default:
      return const InputStepRisk(RiskTier.r3, 'unclassified_tool');
  }
}

/// Normalised roles of ordinary text fields a session may draft into without a
/// per-call signature (ADR-0015 D1). Closed list: adapters must map a role
/// here only when they know it is a real text field. A Windows UIA `Document`
/// (a whole web page or document body) is not one of them.
const Set<String> draftTextRoles = <String>{
  'textfield',
  'searchfield',
  'searchbox',
  'textarea',
};

/// Whether [node] is an ordinary, editable, non-secret text field.
bool isDraftTextTarget(Map<String, Object?> node) {
  final role = (node['role'] as String?)?.trim().toLowerCase();
  return draftTextRoles.contains(role) &&
      node['editable'] != false &&
      node['readOnly'] != true &&
      !isPasswordUiNode(node);
}

/// Maximum length of an element label returned by `xuna/preflight`.
const int maxPreflightLabelLength = 80;

/// Trims a live element label for the approval card: control characters are
/// removed and the result is capped at [maxPreflightLabelLength].
String sanitizePreflightLabel(String raw) {
  final cleaned = raw
      .replaceAll(RegExp(r'[\u0000-\u001F\u007F-\u009F]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (cleaned.length <= maxPreflightLabelLength) return cleaned;
  // Cut on whole characters so an emoji is never split into a lone surrogate.
  final out = StringBuffer();
  for (final rune in cleaned.runes) {
    final char = String.fromCharCode(rune);
    if (out.length + char.length > maxPreflightLabelLength) break;
    out.write(char);
  }
  return out.toString();
}

/// Normalises a live element role to a short machine code (`button`,
/// `textfield`…) or `unknown`.
String sanitizePreflightRole(String? raw) {
  final lower = (raw ?? '').trim().toLowerCase().replaceAll(
        RegExp(r'[^a-z0-9_.-]+'),
        '_',
      );
  if (lower.isEmpty) return 'unknown';
  return lower.length > 32 ? lower.substring(0, 32) : lower;
}
