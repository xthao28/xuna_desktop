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
  List<Map<String, Object?>>? activeWindowNodes,
  double? windowWidth,
  double? windowHeight,
}) {
  switch (toolName) {
    case 'input.type_text':
      if (liveTarget == null || !isDraftTextTarget(liveTarget)) {
        return const InputStepRisk(RiskTier.r3, 'unclassified_target');
      }
      final text = arguments['text'];
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

      final canonical = canonicalInputKeyCombo(combo);
      final rawLower = combo.trim().toLowerCase();

      // Safe editing shortcuts (Feature F9): Cmd/Ctrl + N/A/C/V
      const safeEditingKeys = <String>{
        'cmd+n',
        'cmd+a',
        'cmd+c',
        'cmd+v',
        'ctrl+n',
        'ctrl+a',
        'ctrl+c',
        'ctrl+v',
      };
      if (safeEditingKeys.contains(canonical) ||
          safeEditingKeys.contains(rawLower)) {
        return const InputStepRisk(RiskTier.r2, 'editing_key');
      }

      // Draft line breaks (Feature F9): Enter/Return/Shift+Enter/Shift+Return in draft text roles
      final isLineBreak = canonical == 'enter' ||
          canonical == 'shift+enter' ||
          rawLower == 'enter' ||
          rawLower == 'return' ||
          rawLower == 'shift+enter' ||
          rawLower == 'shift+return';

      if (isLineBreak && focusedRole == 'searchfield') {
        if (canonical == 'enter' || rawLower == 'enter' || rawLower == 'return') {
          return const InputStepRisk(RiskTier.r2, 'search_submit');
        }
        return const InputStepRisk(RiskTier.r3, 'activation_key');
      }

      if (isLineBreak && draftTextRoles.contains(focusedRole)) {
        return const InputStepRisk(RiskTier.r2, 'draft_line_break');
      }

      if (!isActivationKeyCombo(combo)) {
        return const InputStepRisk(RiskTier.r2, 'navigation_key');
      }
      final parts = combo.split('+').where((p) => p.trim().isNotEmpty).toList();
      if (parts.length != 1) {
        return const InputStepRisk(RiskTier.r3, 'activation_key');
      }
      final key = parts.single.trim().toLowerCase();
      if (key == 'space' && draftTextRoles.contains(focusedRole)) {
        return const InputStepRisk(RiskTier.r2, 'text_space');
      }
      return const InputStepRisk(RiskTier.r3, 'activation_key');
    case 'input.scroll':
      return const InputStepRisk(RiskTier.r2, 'scroll');
    case 'input.click':
      var target = liveTarget;
      final xNorm = (arguments['xNorm'] as num?)?.toDouble();
      final yNorm = (arguments['yNorm'] as num?)?.toDouble();
      final isCoordClick = xNorm != null && yNorm != null;

      if (target == null && isCoordClick && activeWindowNodes != null) {
        target = hitTestNodeAtCoordinates(
          nodes: activeWindowNodes,
          xNorm: xNorm,
          yNorm: yNorm,
          windowWidth: windowWidth,
          windowHeight: windowHeight,
        );
      }

      if (target == null) {
        return const InputStepRisk(RiskTier.r3, 'unclassified_target');
      }

      if (isPasswordUiNode(target)) {
        return const InputStepRisk(RiskTier.r3, 'password_field_forbidden');
      }

      final liveName = target['name'];
      final declaredName = arguments['elementName'];

      // While unsigned draft text sits in the window:
      // If coordinate click cannot be verified as safe editable text -> R3 unclassified_target
      // If element name is missing/empty -> R3 unclassified_target
      if (hasUncommittedDraft) {
        if (isCoordClick && !isDraftTextTarget(target)) {
          return const InputStepRisk(RiskTier.r3, 'unclassified_target');
        }
        if (liveName is! String || liveName.trim().isEmpty) {
          return const InputStepRisk(RiskTier.r3, 'unclassified_target');
        }
      }

      if (isConsequentialElementName(liveName is String ? liveName : null) ||
          isConsequentialElementName(
            declaredName is String ? declaredName : null,
          )) {
        return const InputStepRisk(RiskTier.r3, 'consequential_target');
      }

      return const InputStepRisk(RiskTier.r2, 'navigation_target');
    case 'input.drag':
      var startTarget = liveTarget;
      Map<String, Object?>? endTarget;

      final fromXRaw = arguments['fromXNorm'] ?? arguments['startXNorm'];
      final fromYRaw = arguments['fromYNorm'] ?? arguments['startYNorm'];
      final toXRaw = arguments['toXNorm'] ?? arguments['endXNorm'];
      final toYRaw = arguments['toYNorm'] ?? arguments['endYNorm'];

      final fromXNorm = fromXRaw is num ? fromXRaw.toDouble() : null;
      final fromYNorm = fromYRaw is num ? fromYRaw.toDouble() : null;
      final toXNorm = toXRaw is num ? toXRaw.toDouble() : null;
      final toYNorm = toYRaw is num ? toYRaw.toDouble() : null;

      if (activeWindowNodes != null) {
        if (startTarget == null && fromXNorm != null && fromYNorm != null) {
          startTarget = hitTestNodeAtCoordinates(
            nodes: activeWindowNodes,
            xNorm: fromXNorm,
            yNorm: fromYNorm,
            windowWidth: windowWidth,
            windowHeight: windowHeight,
          );
        }
        if (toXNorm != null && toYNorm != null) {
          endTarget = hitTestNodeAtCoordinates(
            nodes: activeWindowNodes,
            xNorm: toXNorm,
            yNorm: toYNorm,
            windowWidth: windowWidth,
            windowHeight: windowHeight,
          );
        }
      }

      if ((startTarget != null && isPasswordUiNode(startTarget)) ||
          (endTarget != null && isPasswordUiNode(endTarget))) {
        return const InputStepRisk(RiskTier.r3, 'password_field_forbidden');
      }

      if (hasUncommittedDraft) {
        return const InputStepRisk(RiskTier.r3, 'unclassified_target');
      }

      final startName = startTarget?['name'] as String?;
      final endName = endTarget?['name'] as String?;
      if (isConsequentialElementName(startName) ||
          isConsequentialElementName(endName)) {
        return const InputStepRisk(RiskTier.r3, 'consequential_target');
      }

      if (startTarget == null && endTarget == null) {
        return const InputStepRisk(RiskTier.r3, 'unclassified_target');
      }

      return const InputStepRisk(RiskTier.r2, 'navigation_target');
    default:
      return const InputStepRisk(RiskTier.r3, 'unclassified_tool');
  }
}

/// Performs a reverse hit-test on [nodes] using normalized coordinates [xNorm]
/// and [yNorm] in `[0.0, 1.0]`.
///
/// Finds the leaf or smallest-area bounding box containing the point.
Map<String, Object?>? hitTestNodeAtCoordinates({
  required List<Map<String, Object?>> nodes,
  required double xNorm,
  required double yNorm,
  double? windowWidth,
  double? windowHeight,
}) {
  Map<String, Object?>? bestMatch;
  double smallestArea = double.infinity;

  double? inferredWidth = windowWidth;
  double? inferredHeight = windowHeight;
  if (inferredWidth == null || inferredHeight == null) {
    double maxX = 0;
    double maxY = 0;
    for (final node in nodes) {
      final rawBounds = node['bounds'] ?? node['boxNorm'] ?? node['box'];
      if (rawBounds is List && rawBounds.length >= 4) {
        final x2 = (rawBounds[2] as num?)?.toDouble() ?? 0;
        final y2 = (rawBounds[3] as num?)?.toDouble() ?? 0;
        if (x2 > maxX) maxX = x2;
        if (y2 > maxY) maxY = y2;
      } else if (rawBounds is Map) {
        final x = (rawBounds['x'] as num?)?.toDouble() ?? 0;
        final y = (rawBounds['y'] as num?)?.toDouble() ?? 0;
        final w = (rawBounds['width'] as num?)?.toDouble() ?? 0;
        final h = (rawBounds['height'] as num?)?.toDouble() ?? 0;
        if (x + w > maxX) maxX = x + w;
        if (y + h > maxY) maxY = y + h;
      }
    }
    if (maxX > 1.0 && (inferredWidth == null || inferredWidth <= 0)) {
      inferredWidth = maxX;
    }
    if (maxY > 1.0 && (inferredHeight == null || inferredHeight <= 0)) {
      inferredHeight = maxY;
    }
  }

  for (final node in nodes) {
    final rawBounds = node['bounds'] ?? node['boxNorm'] ?? node['box'];
    double? xMin;
    double? yMin;
    double? xMax;
    double? yMax;

    if (rawBounds is List && rawBounds.length >= 4) {
      xMin = (rawBounds[0] as num?)?.toDouble();
      yMin = (rawBounds[1] as num?)?.toDouble();
      xMax = (rawBounds[2] as num?)?.toDouble();
      yMax = (rawBounds[3] as num?)?.toDouble();
    } else if (rawBounds is Map) {
      xMin = (rawBounds['x'] as num?)?.toDouble();
      yMin = (rawBounds['y'] as num?)?.toDouble();
      final w = (rawBounds['width'] as num?)?.toDouble();
      final h = (rawBounds['height'] as num?)?.toDouble();
      if (xMin != null && yMin != null && w != null && h != null) {
        xMax = xMin + w;
        yMax = yMin + h;
      }
    }

    if (xMin == null || yMin == null || xMax == null || yMax == null) continue;

    if (xNorm <= 1.0 && yNorm <= 1.0) {
      if (xMax > 1.0 && inferredWidth != null && inferredWidth > 0) {
        xMin /= inferredWidth;
        xMax /= inferredWidth;
      }
      if (yMax > 1.0 && inferredHeight != null && inferredHeight > 0) {
        yMin /= inferredHeight;
        yMax /= inferredHeight;
      }
    }

    if (xNorm >= xMin && xNorm <= xMax && yNorm >= yMin && yNorm <= yMax) {
      final area = ((xMax - xMin) * (yMax - yMin)).abs();
      if (area <= smallestArea) {
        smallestArea = area;
        bestMatch = node;
      }
    }
  }

  return bestMatch;
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
