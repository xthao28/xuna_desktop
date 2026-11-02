import '../schemas.dart';
import 'security_redaction.dart';

/// Allowed safe document/media/archive file extensions for `OMNIFORGE` batch
/// harvesting and file janitor tools (`FORGE-1`).
const Set<String> allowedForgeDocumentExtensions = <String>{
  'pdf',
  'xml',
  'csv',
  'tsv',
  'xlsx',
  'xls',
  'docx',
  'doc',
  'txt',
  'md',
  'html',
  'log',
  'json',
  'zip',
  'png',
  'jpg',
  'jpeg',
  'webp',
  'svg',
  'heic',
  'raw',
};

/// Returns `true` if [ext] (with or without leading `.`) is an allowed safe
/// document/archive extension and is not in [forbiddenBeamExtensions].
bool isAllowedForgeFileExtension(String? ext) {
  if (ext == null) return false;
  final clean = ext.trim().toLowerCase().replaceFirst(RegExp(r'^\.+'), '');
  if (clean.isEmpty || clean.length > 10) return false;
  if (forbiddenBeamExtensions.contains(clean)) return false;
  return allowedForgeDocumentExtensions.contains(clean);
}

final RegExp _sandboxFolderRe = RegExp(
    r'^[a-zA-Z0-9_.\- /àáạảãâầấậẩẫăằắặẳẵèéẹẻẽêềếệểễìíịỉĩòóọỏõôồốộổỗơờớợởỡùúụủũưừứựửữỳýỵỷỹđÀÁẠẢÃÂẦẤẬẨẪĂẰẮẶẲẴÈÉẸẺẼÊỀẾỆỂỄÌÍỊỈĨÒÓỌỎÕÔỒỐỘỔỖƠỜỚỢỞỠÙÚỤỦŨƯỪỨỰỬỮỲÝỴỶỸĐ]{1,120}$');

/// Validates a relative sandbox folder name (`FORGE-1`, e.g., `'XUNA_HoaDon/Thang_11'`):
/// rejects parent traversal (`..`), absolute paths (`/`, `\`, `C:`), and hidden
/// segments starting with `.`.
bool isValidSandboxFolderName(String? folder) {
  if (folder == null) return false;
  final trimmed = folder.trim();
  if (trimmed.isEmpty ||
      trimmed.length > 120 ||
      trimmed.startsWith('/') ||
      trimmed.startsWith(r'\') ||
      trimmed.contains('..') ||
      trimmed.contains(':') ||
      trimmed.contains(r'\') ||
      trimmed.contains('~')) {
    return false;
  }
  final segments = trimmed.split('/');
  for (final seg in segments) {
    final s = seg.trim();
    if (s.isEmpty || s.startsWith('.') || s.endsWith('.')) {
      return false;
    }
  }
  return _sandboxFolderRe.hasMatch(trimmed);
}

final List<RegExp> _forbiddenSkillMarkdownPatterns = <RegExp>[
  RegExp(r'\brm\s+-rf\b', caseSensitive: false),
  RegExp(r'\bcurl\b[^\n]*\|\s*(?:sh|bash|zsh)\b', caseSensitive: false),
  RegExp(r'\bwget\b[^\n]*\|\s*(?:sh|bash|zsh)\b', caseSensitive: false),
  RegExp(r'\binvoke-expression\b', caseSensitive: false),
  RegExp(r'\biex\s+', caseSensitive: false),
  RegExp(r'\bpowershell(?:\.exe)?\s+-(?:enc|encodedcommand)\b',
      caseSensitive: false),
  RegExp(r'\bsudo\s+', caseSensitive: false),
  RegExp(r'(?:id_rsa|\.ssh/|\.env\b)', caseSensitive: false),
];

/// Returns `true` if an imported `SKILL.md` document contains dangerous shell
/// execution or credential-harvesting patterns (`CLAW-1`).
bool containsForbiddenSkillMarkdownPattern(String? markdown) {
  if (markdown == null || markdown.trim().isEmpty) return false;
  for (final pattern in _forbiddenSkillMarkdownPatterns) {
    if (pattern.hasMatch(markdown)) {
      return true;
    }
  }
  return false;
}

/// Infers the ordered list of Universal Atomic Primitives (`UNIV-1`) required
/// to satisfy [goal] across HR, E-Commerce, Content/Marketing, Media/Photo,
/// Operations/Reconciliation, File Organization, and Web/Data pipelines.
List<String> inferUniversalPrimitivesForGoal(String goal) {
  final lower = goal.toLowerCase();
  if (lower.contains('cv') ||
      lower.contains('ứng viên') ||
      lower.contains('tuyển dụng') ||
      lower.contains('resume') ||
      lower.contains('hr')) {
    return const <String>[
      'source.filesystem',
      'parse.universal',
      'transform.pipeline',
      'export.artifact',
      'canvas.dynamic_a2ui',
    ];
  }
  if (lower.contains('giá') ||
      lower.contains('shopee') ||
      lower.contains('lazada') ||
      lower.contains('tiktok') ||
      lower.contains('đối thủ') ||
      lower.contains('radar') ||
      lower.contains('tồn kho')) {
    return const <String>[
      'source.web_http',
      'parse.universal',
      'sensor.hash_delta',
      'transform.pipeline',
      'canvas.dynamic_a2ui',
    ];
  }
  if (lower.contains('tin tức') ||
      lower.contains('tóm tắt') ||
      lower.contains('bài viết') ||
      lower.contains('content') ||
      lower.contains('marketing') ||
      lower.contains('nghiên cứu') ||
      lower.contains('digest')) {
    return const <String>[
      'source.web_http',
      'parse.universal',
      'transform.pipeline',
      'export.artifact',
      'canvas.dynamic_a2ui',
    ];
  }
  if (lower.contains('ảnh') ||
      lower.contains('photo') ||
      lower.contains('đổi tên') ||
      lower.contains('rename') ||
      lower.contains('media') ||
      lower.contains('thiết kế')) {
    return const <String>[
      'source.filesystem',
      'parse.universal',
      'file.batch_ops',
      'canvas.dynamic_a2ui',
    ];
  }
  if (lower.contains('đối soát') ||
      lower.contains('so khớp') ||
      lower.contains('reconcil') ||
      lower.contains('chênh lệch') ||
      lower.contains('sao kê') ||
      lower.contains('công nợ')) {
    return const <String>[
      'source.filesystem',
      'parse.universal',
      'transform.pipeline',
      'export.artifact',
      'canvas.dynamic_a2ui',
    ];
  }
  if (lower.contains('dọn') ||
      lower.contains('sắp xếp') ||
      lower.contains('phân loại') ||
      lower.contains('downloads') ||
      lower.contains('desktop')) {
    return const <String>[
      'source.filesystem',
      'file.batch_ops',
      'canvas.dynamic_a2ui',
    ];
  }
  return const <String>[
    'source.filesystem',
    'parse.universal',
    'transform.pipeline',
    'export.artifact',
    'canvas.dynamic_a2ui',
  ];
}

/// Validates a dynamic `{{key}}` template parameter value for `skill.chain_and_test` (`WORKSHOP-1`):
/// rejects path traversal (`..`), shell pipes/commands, and forbidden markdown patterns.
bool isSafeTemplateParameterValue(String? value) {
  if (value == null) return false;
  final trimmed = value.trim();
  if (trimmed.isEmpty || trimmed.length > 120) return false;
  if (trimmed.contains('..') ||
      trimmed.contains('|') ||
      trimmed.contains(';') ||
      trimmed.contains('`') ||
      trimmed.contains(r'$(')) {
    return false;
  }
  if (containsForbiddenSkillMarkdownPattern(trimmed)) {
    return false;
  }
  return isSafeAgentPrompt(trimmed);
}

final RegExp _templatePlaceholderRe =
    RegExp(r'\{\{\s*([a-zA-Z0-9_.-]+)\s*\}\}');

/// Safely interpolates `{{variable}}` placeholders in [template] using [params] (`WORKSHOP-1`).
String interpolateSkillTemplate(
  String template,
  Map<String, String> params,
) {
  if (template.isEmpty || params.isEmpty) return template;
  return template.replaceAllMapped(_templatePlaceholderRe, (match) {
    final key = match.group(1) ?? '';
    final replacement = params[key];
    if (replacement != null && isSafeTemplateParameterValue(replacement)) {
      return replacement.trim();
    }
    return match.group(0) ?? '';
  });
}

/// Checks whether a Sub-Agent specialist [role] is permitted to invoke a XunaScript [primitive] (`SWARM-1`).
/// `scout_harvester` and `critic_verifier` are strictly read-only.
bool isPrimitiveAllowedForSubagentRole(String role, String primitive) {
  final allowed = roleScopedPrimitiveAllowlist[role.trim()];
  if (allowed == null) return false;
  return allowed.contains(primitive.trim());
}

/// Decomposes a compound natural-language [compoundGoal] into a deterministic
/// Zero-Token Specialist Sub-Agent Swarm plan (`SWARM-1`).
List<Map<String, Object>> decomposeGoalIntoSpecialistSwarm(
  String compoundGoal, {
  List<String>? requestedRoles,
  bool enableCriticVerification = true,
}) {
  final roles = (requestedRoles != null && requestedRoles.isNotEmpty)
      ? requestedRoles
          .where((r) => allowedSubagentSpecialistRoles.contains(r))
          .toList()
      : <String>[
          'scout_harvester',
          'analyst_reconciler',
          'executor_organizer',
          if (enableCriticVerification) 'critic_verifier',
        ];
  final inferredPrimitives = inferUniversalPrimitivesForGoal(compoundGoal);
  final swarmPlan = <Map<String, Object>>[];
  for (final role in roles) {
    final roleAllowlist =
        roleScopedPrimitiveAllowlist[role] ?? const <String>{};
    final scopedPrimitives =
        inferredPrimitives.where((p) => roleAllowlist.contains(p)).toList();
    final effectivePrimitives = scopedPrimitives.isNotEmpty
        ? scopedPrimitives
        : roleAllowlist.take(2).toList();
    String subGoalVi;
    switch (role) {
      case 'scout_harvester':
        subGoalVi =
            'Quét song song dữ liệu thô & trích xuất trường chuẩn hóa lên Shared Blackboard (Read-Only)';
      case 'analyst_reconciler':
        subGoalVi =
            'Đối chiếu chéo, gom nhóm & tính toán số liệu từ Shared Blackboard (0 LLM Token)';
      case 'executor_organizer':
        subGoalVi =
            'Thực thi sắp xếp file / xuất báo cáo thông qua ReversibleActionLedger có Undo';
      case 'critic_verifier':
      default:
        subGoalVi =
            'Kiểm toán chéo tổng số học, schema & phát hiện lệch dữ liệu trước khi chốt';
    }
    swarmPlan.add(<String, Object>{
      'role': role,
      'subGoalVi': subGoalVi,
      'allowedPrimitives': effectivePrimitives,
      'readOnly': role == 'scout_harvester' || role == 'critic_verifier',
      'llmTokensUsed': 0,
    });
  }
  return swarmPlan;
}
