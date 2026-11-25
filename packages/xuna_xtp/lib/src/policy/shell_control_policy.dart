/// Local-only `shellControl` section of `host-policy.json` (`ADR-0018`).
///
/// It is never accepted from the wire: `xuna/set_policy` rejects the key and
/// `xuna/get_policy` exposes only `shellEnabled`. [workspaceRoots] are local
/// absolute paths used only to classify whether a write is inside a known
/// workspace (`R2`) or outside it (`R3`); they never leave the host.
class ShellControlPolicy {
  ShellControlPolicy({
    this.enabled = false,
    this.allowPty = true,
    this.defaultTimeoutSeconds = 30,
    this.maxTimeoutSeconds = 300,
    this.maxConcurrentTasks = 4,
    List<String> workspaceRoots = const <String>[],
  }) : workspaceRoots = List<String>.unmodifiable(workspaceRoots) {
    if (defaultTimeoutSeconds < 5 || defaultTimeoutSeconds > 120) {
      throw const FormatException(
        'shellControl.defaultTimeoutSeconds must be 5..120',
      );
    }
    if (maxTimeoutSeconds < 30 || maxTimeoutSeconds > 900) {
      throw const FormatException(
        'shellControl.maxTimeoutSeconds must be 30..900',
      );
    }
    if (maxTimeoutSeconds < defaultTimeoutSeconds) {
      throw const FormatException(
        'shellControl.maxTimeoutSeconds must be >= defaultTimeoutSeconds',
      );
    }
    if (maxConcurrentTasks < 1 || maxConcurrentTasks > 4) {
      throw const FormatException(
        'shellControl.maxConcurrentTasks must be 1..4',
      );
    }
    if (this.workspaceRoots.length > 16) {
      throw const FormatException('shellControl.workspaceRoots max 16 items');
    }
    for (final root in this.workspaceRoots) {
      if (!isValidWorkspaceRoot(root)) {
        throw const FormatException(
          'shellControl.workspaceRoots items must be absolute local paths',
        );
      }
    }
  }

  /// The default every host starts with: execution disabled.
  const ShellControlPolicy.disabled()
      : enabled = false,
        allowPty = true,
        defaultTimeoutSeconds = 30,
        maxTimeoutSeconds = 300,
        maxConcurrentTasks = 4,
        workspaceRoots = const <String>[];

  factory ShellControlPolicy.fromJson(Map<String, Object?> json) {
    const allowed = <String>{
      'enabled',
      'allowPty',
      'defaultTimeoutSeconds',
      'maxTimeoutSeconds',
      'maxConcurrentTasks',
      'workspaceRoots',
    };
    for (final key in json.keys) {
      if (!allowed.contains(key)) {
        throw FormatException('Unexpected key "$key" in shellControl');
      }
    }
    bool readBool(String key, bool fallback) {
      final value = json[key];
      if (value == null) return fallback;
      if (value is! bool) {
        throw FormatException('shellControl.$key must be a boolean');
      }
      return value;
    }

    int readInt(String key, int fallback) {
      final value = json[key];
      if (value == null) return fallback;
      if (value is! int) {
        throw FormatException('shellControl.$key must be an integer');
      }
      return value;
    }

    final rawRoots = json['workspaceRoots'];
    final roots = <String>[];
    if (rawRoots != null) {
      if (rawRoots is! List) {
        throw const FormatException(
            'shellControl.workspaceRoots must be a list');
      }
      for (final item in rawRoots) {
        if (item is! String) {
          throw const FormatException(
            'shellControl.workspaceRoots items must be strings',
          );
        }
        roots.add(item);
      }
    }
    return ShellControlPolicy(
      enabled: readBool('enabled', false),
      allowPty: readBool('allowPty', true),
      defaultTimeoutSeconds: readInt('defaultTimeoutSeconds', 30),
      maxTimeoutSeconds: readInt('maxTimeoutSeconds', 300),
      maxConcurrentTasks: readInt('maxConcurrentTasks', 4),
      workspaceRoots: roots,
    );
  }

  final bool enabled;
  final bool allowPty;
  final int defaultTimeoutSeconds;
  final int maxTimeoutSeconds;
  final int maxConcurrentTasks;
  final List<String> workspaceRoots;

  ShellControlPolicy copyWith({
    bool? enabled,
    bool? allowPty,
    int? defaultTimeoutSeconds,
    int? maxTimeoutSeconds,
    int? maxConcurrentTasks,
    List<String>? workspaceRoots,
  }) =>
      ShellControlPolicy(
        enabled: enabled ?? this.enabled,
        allowPty: allowPty ?? this.allowPty,
        defaultTimeoutSeconds:
            defaultTimeoutSeconds ?? this.defaultTimeoutSeconds,
        maxTimeoutSeconds: maxTimeoutSeconds ?? this.maxTimeoutSeconds,
        maxConcurrentTasks: maxConcurrentTasks ?? this.maxConcurrentTasks,
        workspaceRoots: workspaceRoots ?? this.workspaceRoots,
      );

  /// Local file form (written only to `host-policy.json`).
  Map<String, Object?> toJson() => <String, Object?>{
        'enabled': enabled,
        'allowPty': allowPty,
        'defaultTimeoutSeconds': defaultTimeoutSeconds,
        'maxTimeoutSeconds': maxTimeoutSeconds,
        'maxConcurrentTasks': maxConcurrentTasks,
        'workspaceRoots': workspaceRoots,
      };

  @override
  bool operator ==(Object other) =>
      other is ShellControlPolicy &&
      other.enabled == enabled &&
      other.allowPty == allowPty &&
      other.defaultTimeoutSeconds == defaultTimeoutSeconds &&
      other.maxTimeoutSeconds == maxTimeoutSeconds &&
      other.maxConcurrentTasks == maxConcurrentTasks &&
      other.workspaceRoots.length == workspaceRoots.length &&
      Iterable<int>.generate(workspaceRoots.length)
          .every((i) => other.workspaceRoots[i] == workspaceRoots[i]);

  @override
  int get hashCode => Object.hash(
        enabled,
        allowPty,
        defaultTimeoutSeconds,
        maxTimeoutSeconds,
        maxConcurrentTasks,
        Object.hashAll(workspaceRoots),
      );
}

final RegExp _windowsAbsolute = RegExp(r'^[A-Za-z]:[\\/]');

/// Whether [root] is an absolute local path (`/…`, `~/…` or `X:\…`) of
/// 1..512 characters without control characters.
bool isValidWorkspaceRoot(String root) {
  if (root.isEmpty || root.length > 512) return false;
  if (RegExp(r'[\x00-\x1f\x7f]').hasMatch(root)) return false;
  return root.startsWith('/') ||
      root == '~' ||
      root.startsWith('~/') ||
      _windowsAbsolute.hasMatch(root);
}
