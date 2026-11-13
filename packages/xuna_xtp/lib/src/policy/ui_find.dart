import 'security_redaction.dart';

/// Most candidates one `ui.find` call returns (UDC-17 S17.4).
const int maxUiFindResults = 10;

/// Candidates `ui.find` returns when the caller sets no `maxResults`.
const int defaultUiFindResults = 5;

/// Longest `ui.find` query, in characters.
const int maxUiFindQueryLength = 80;

final RegExp _uiFindRoleRe = RegExp(r'^[A-Za-z_]{1,32}$');

/// Whether [role] is an acceptable `ui.find` role filter (letters and `_`).
bool isValidUiFindRole(String role) => _uiFindRoleRe.hasMatch(role.trim());

/// Lower-case role without the macOS `ax` prefix, so `AXButton` and `button`
/// compare equal. A password field is always `password`.
String uiFindRoleKey(Map<String, Object?> node) {
  if (isPasswordUiNode(node)) return 'password';
  return _stripAx(((node['role'] as String?) ?? '').trim().toLowerCase());
}

String _stripAx(String role) =>
    role.startsWith('ax') && role.length > 2 ? role.substring(2) : role;

/// Searches [nodes] for `ui.find` (UDC-17 S17.4) and returns at most
/// [maxResults] raw nodes plus the total number that matched.
///
/// - [query] matches the element's **name** only, as a case-insensitive
///   substring. Values (field contents) are never searched, so the model
///   cannot probe what it is not shown by `ui.inspect`.
/// - A password field's name is never searched; it can only be found by
///   [role] alone, and callers redact it like `ui.inspect` does.
/// - [role] keeps nodes whose role equals it, ignoring case and the `ax`
///   prefix.
/// - Order: exact name, then prefix, then substring; within a rank, controls
///   and overlay surfaces before other nodes, visible and enabled before
///   hidden or disabled, then tree order.
///
/// Nothing is picked: several matches are all returned (H3).
({List<Map<String, Object?>> matches, int total}) findUiNodes(
  List<Map<String, Object?>> nodes, {
  String? query,
  String? role,
  int maxResults = defaultUiFindResults,
}) {
  final needle = (query ?? '').trim().toLowerCase();
  final roleRaw = (role ?? '').trim().toLowerCase();
  final roleWanted = roleRaw.isEmpty ? null : _stripAx(roleRaw);
  if (needle.isEmpty && roleWanted == null) {
    return (matches: const <Map<String, Object?>>[], total: 0);
  }
  final limit = maxResults < 1
      ? 1
      : (maxResults > maxUiFindResults ? maxUiFindResults : maxResults);

  final scored = <({int text, int kind, int availability, int order})>[];
  final byOrder = <int, Map<String, Object?>>{};
  for (var i = 0; i < nodes.length; i++) {
    final node = nodes[i];
    if (roleWanted != null && uiFindRoleKey(node) != roleWanted) continue;
    var textRank = 0;
    if (needle.isNotEmpty) {
      if (isPasswordUiNode(node)) continue;
      final name = ((node['name'] as String?) ?? '').trim().toLowerCase();
      if (name.isEmpty) continue;
      if (name == needle) {
        textRank = 0;
      } else if (name.startsWith(needle)) {
        textRank = 1;
      } else if (name.contains(needle)) {
        textRank = 2;
      } else {
        continue;
      }
    }
    final isControl = isInteractiveUiNode(node) || isOverlaySurfaceNode(node);
    final available = node['visible'] != false &&
        node['offscreen'] != true &&
        node['enabled'] != false;
    scored.add((
      text: textRank,
      kind: isControl ? 0 : 1,
      availability: available ? 0 : 1,
      order: i,
    ));
    byOrder[i] = node;
  }
  scored.sort((a, b) {
    final byText = a.text.compareTo(b.text);
    if (byText != 0) return byText;
    final byKind = a.kind.compareTo(b.kind);
    if (byKind != 0) return byKind;
    final byAvail = a.availability.compareTo(b.availability);
    if (byAvail != 0) return byAvail;
    return a.order.compareTo(b.order);
  });
  return (
    matches: <Map<String, Object?>>[
      for (final s in scored.take(limit)) byOrder[s.order]!,
    ],
    total: scored.length,
  );
}

/// Identity key of a UI node used to tell whether two observations show the
/// same element when no native id is available: lower-case role (password
/// fields as `password`) and the name as `ui.inspect` shows it (60 chars).
String uiNodeSignature(Map<String, Object?> node) {
  final isPwd = isPasswordUiNode(node);
  final role = isPwd
      ? 'password'
      : ((node['role'] as String?) ?? 'unknown').trim().toLowerCase();
  final rawName = (node['name'] as String?) ?? '';
  final name = isPwd
      ? '•••'
      : (rawName.length > 60 ? rawName.substring(0, 60) : rawName);
  return '$role\u0000$name';
}
