import 'dart:io';

import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

import 'heartbeat_canvas_service.dart';
import 'symbiotic_models.dart';

/// UIA-1..2: Zero-Screenshot Native OS UI Automation (`ui.accessibility_tree`).
///
/// Inspects native desktop windows (`Windows IUIAutomation` / `macOS AXUIElement`)
/// into compact `[ref=ui_1]..[ref=ui_N]` semantic control nodes and redacts
/// password fields (`[REDACTED_PASSWORD_CONTROL]`). It only describes a tree that
/// was applied from a live native scan; it does not click, type or invent nodes.
class UiAccessibilityTreeService {
  UiAccessibilityTreeService({
    required HeartbeatCanvasService canvasService,
  }) : _canvasService = canvasService;

  final HeartbeatCanvasService _canvasService;

  final Map<String, Map<String, Object?>> _activeUiNodes =
      <String, Map<String, Object?>>{};
  final List<AppPlaybookEntry> _learnedPlaybooks = <AppPlaybookEntry>[];
  HumanHandoverSnapshot? _activeHandover;
  String _activeFocusedAppName = 'Visual Studio Code';
  String _lastWindowTitle = 'Active Desktop Window';
  bool _hasLiveNativeTree = false;
  int _snapshotCounter = 0;
  String _activeSnapshotId = 's00000001';

  String get activeSnapshotId => _activeSnapshotId;

  String _mintNextSnapshotId() {
    _snapshotCounter++;
    _activeSnapshotId =
        's${_snapshotCounter.toRadixString(16).padLeft(8, '0')}';
    return _activeSnapshotId;
  }

  /// Resolves either a canonical `ui_<N>` ref or a snapshot-qualified
  /// `@s<id>:e<N>` ref to the canonical key in [_activeUiNodes].
  String _resolveCanonicalRefKey(String rawRef) {
    final trimmed = rawRef.trim();
    if (_activeUiNodes.containsKey(trimmed)) return trimmed;
    final parsed = parseSnapshotElementRef(trimmed);
    if (parsed != null) {
      final targetSnapRef =
          '@${parsed.snapshotId}:e${parsed.elementNumber}';
      for (final node in _activeUiNodes.values) {
        if (node['snapshotRef'] == targetSnapRef && node['refId'] is String) {
          return node['refId'] as String;
        }
      }
      final candidate = 'ui_${parsed.elementNumber}';
      if (_activeUiNodes.containsKey(candidate)) return candidate;
    }
    return trimmed;
  }

  /// Validates a `ui_<N>`, `shortcut:...`, or `@s<id>:e<N>` reference before
  /// dispatching to the native OS channel.
  ///
  /// Throws [XunaHostChannelException] with `errorCode: 'stale_ref'` when a
  /// `@s<id>:e<N>` reference targets a stale snapshot ID or a non-existent
  /// element in the active snapshot.
  String validateAndResolveRefKey(
    String? rawRef, {
    required String action,
  }) {
    if (rawRef == null || rawRef.trim().isEmpty) {
      // Never guess a target element: the first button in an AX tree is often the
      // window close button, and `AXStaticText` is not editable. Ask the model to
      // pick a ref from the live snapshot instead.
      throw XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'missing_ref',
        message: _missingRefMessage(action),
      );
    }
    final trimmed = rawRef.trim();
    final parsed = parseSnapshotElementRef(trimmed);
    if (parsed != null) {
      if (_activeUiNodes.isNotEmpty &&
          parsed.snapshotId != _activeSnapshotId) {
        throw const XunaHostChannelException(
          status: XtpStatus.failed,
          errorCode: 'stale_ref',
          message:
              'UI snapshot reference is stale; call inspect_window first.',
        );
      }
      final targetSnapRef =
          '@${parsed.snapshotId}:e${parsed.elementNumber}';
      for (final node in _activeUiNodes.values) {
        if (node['snapshotRef'] == targetSnapRef && node['refId'] is String) {
          return node['refId'] as String;
        }
      }
      final candidate = 'ui_${parsed.elementNumber}';
      if (_activeUiNodes.containsKey(candidate)) {
        return candidate;
      }
      if (_activeUiNodes.isNotEmpty) {
        throw const XunaHostChannelException(
          status: XtpStatus.failed,
          errorCode: 'stale_ref',
          message: 'Element reference not found in active UI snapshot.',
        );
      }
      return candidate;
    }
    return _resolveCanonicalRefKey(trimmed);
  }

  /// Bounded `missing_ref` diagnostic listing up to 6 candidate refs from the live snapshot
  /// (editable fields for `set_value_ref`, any non-secret control otherwise).
  String _missingRefMessage(String action) {
    if (_activeUiNodes.isEmpty) {
      return 'refId is required for $action; call inspect_window first.';
    }
    final wantsEditable = action == 'set_value_ref' || action == 'browser_type';
    final candidates = <String>[];
    for (final node in _activeUiNodes.values) {
      if (candidates.length >= 6) break;
      if (node['isPassword'] == true) continue;
      final role = (node['role']?.toString() ?? '').toLowerCase();
      final isStaticText =
          role.contains('statictext') || role == 'text' || role.contains('label');
      final isEditable = !isStaticText &&
          (role.contains('textfield') ||
              role.contains('textarea') ||
              role.contains('search') ||
              role.contains('combo') ||
              role.contains('edit'));
      if (wantsEditable && !isEditable) continue;
      final ref = (node['snapshotRef'] ?? node['refId'])?.toString() ?? '';
      if (ref.isEmpty) continue;
      final rawLabel = node['label']?.toString() ?? '';
      final label =
          rawLabel.length > 32 ? '${rawLabel.substring(0, 32)}…' : rawLabel;
      candidates.add('$ref ${node['role']} "$label"');
    }
    if (candidates.isEmpty) {
      return 'refId is required for $action; no suitable control in the current '
          'snapshot, call inspect_window again.';
    }
    return 'refId is required for $action; candidates: ${candidates.join('; ')}';
  }

  List<AppPlaybookEntry> listAppPlaybooks() =>
      List<AppPlaybookEntry>.unmodifiable(_learnedPlaybooks);

  HumanHandoverSnapshot? get activeHandover => _activeHandover;

  String get activeFocusedAppName => _activeFocusedAppName;

  /// Sets or switches the currently focused foreground app on PC/Mac (`CLAW-APP-ENGINE`).
  AppPlaybookEntry switchActiveFocusedApp(String appName) {
    final clean = appName.trim().isEmpty ? 'Visual Studio Code' : appName.trim();
    _activeFocusedAppName = clean;
    return learnOrInspectApp(clean);
  }

  /// Inspects an application using the ClawdBot 3-Tier Execution Ladder:
  /// - Tier 1: Native Bridge (`osascript` / URL Scheme / CLI — 0.1s)
  /// - Tier 2: Menu-Bar & Hotkey Scanner (`AXMenuBar` / `UIA MenuItem` — 0.2s)
  /// - Tier 3: Peekaboo Annotated Semantic Map (`[B1]`, `[T1]`, `[M1]`)
  /// and saves/updates its [AppPlaybookEntry] in memory.
  AppPlaybookEntry learnOrInspectApp(
    String rawAppName, {
    String? customActionVi,
  }) {
    final cleanName =
        rawAppName.trim().isEmpty ? _activeFocusedAppName : rawAppName.trim();
    _activeFocusedAppName = cleanName;
    final lower = cleanName.toLowerCase();
    final appId = lower
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    final resolvedId = appId.isEmpty ? 'custom_app' : appId;

    final mod = Platform.isMacOS ? '⌘' : 'Ctrl';

    var tier = 3;
    var tierBadgeVi = 'Tầng 3 · Mắt thần Peekaboo [B1] [T1] (0-Lệch chuột)';
    var shortcuts = <String>[
      '$mod+N: Tạo mới (Quét từ Menu Bar)',
      '$mod+F: Tìm kiếm trong cửa sổ',
      '$mod+S: Lưu thay đổi',
    ];
    var peekabooNodes = <String>[
      '[B1] Nút Tạo mới / Bắt đầu trong $cleanName',
      '[T1] Ô Nhập liệu / Tìm kiếm chính',
      '[B2] Nút Lưu / Xuất kết quả',
      '[M1] Thanh Menu trên cùng của $cleanName',
    ];
    var quickActions = <String>[
      'Quét cây điều khiển UI thực tế của $cleanName',
      'Điền dữ liệu tự động vào ô nhập [T1]',
      'Kích hoạt nút hành động [B1] không chiếm chuột',
    ];

    // Derive tier, shortcuts, and controls dynamically from the live scanned OS UI tree when present
    if (_hasLiveNativeTree && _activeUiNodes.isNotEmpty) {
      final liveShortcuts = <String>[];
      final liveNodes = <String>[];
      final liveActions = <String>[];
      var hasNativeBridgePattern = false;
      var hasMenuPattern = false;
      var bIdx = 0;
      var tIdx = 0;
      var mIdx = 0;
      for (final node in _activeUiNodes.values) {
        final role = (node['role']?.toString() ?? '').toLowerCase();
        final pattern = (node['pattern']?.toString() ?? '').toLowerCase();
        final label = (node['label']?.toString() ?? '').trim();
        if (label.isEmpty || label == '[REDACTED_PASSWORD_CONTROL]') continue;
        if (pattern.contains('appleevents') || pattern.contains('url')) {
          hasNativeBridgePattern = true;
        }
        if (role.contains('menu')) {
          hasMenuPattern = true;
        }
        final accelMatch = RegExp(r'\[([^\]]+)\]$').firstMatch(label);
        if (accelMatch != null && liveShortcuts.length < 6) {
          final keyCombo = accelMatch.group(1)!.trim();
          final cleanTitle =
              label.substring(0, accelMatch.start).trim();
          liveShortcuts.add('$keyCombo: $cleanTitle');
        }
        if (liveNodes.length < 8) {
          if (role.contains('edit') ||
              role.contains('text') ||
              role.contains('search') ||
              role.contains('combo') ||
              role.contains('document')) {
            tIdx++;
            liveNodes.add('[T$tIdx] $label (${node['refId']})');
            if (liveActions.length < 3) {
              liveActions.add('Nhập nội dung vào "$label" (${node['refId']})');
            }
          } else if (role.contains('menu')) {
            mIdx++;
            liveNodes.add('[M$mIdx] $label (${node['refId']})');
          } else {
            bIdx++;
            liveNodes.add('[B$bIdx] $label (${node['refId']})');
            if (liveActions.length < 3) {
              liveActions.add('Kích hoạt "$label" (${node['refId']})');
            }
          }
        }
      }
      if (hasNativeBridgePattern) {
        tier = 1;
        tierBadgeVi = 'Tầng 1 · Native Bridge & UIA/AX (0.1s)';
      } else if (hasMenuPattern || liveShortcuts.isNotEmpty) {
        tier = 2;
        tierBadgeVi = 'Tầng 2 · Quét Thanh Menu & Phím tắt (0.2s)';
      }
      if (liveShortcuts.isNotEmpty) {
        shortcuts = liveShortcuts;
      }
      if (liveNodes.isNotEmpty) {
        peekabooNodes = liveNodes;
      }
      if (liveActions.isNotEmpty) {
        quickActions = liveActions;
      }
    }

    final existingIdx = _learnedPlaybooks.indexWhere((p) => p.appId == resolvedId);
    final nextRunCount =
        existingIdx >= 0 ? _learnedPlaybooks[existingIdx].runCount + 1 : 1;
    final actionSummary = (customActionVi != null && customActionVi.trim().isNotEmpty)
        ? '✅ Đã thực hiện "$customActionVi" trong $cleanName qua $tierBadgeVi'
        : '🧠 Đã học cấu trúc $cleanName ($tierBadgeVi · ${shortcuts.length} phím tắt · ${peekabooNodes.length} nhãn Peekaboo)';

    final entry = AppPlaybookEntry(
      appId: resolvedId,
      appName: cleanName,
      executionTier: tier,
      tierBadgeVi: tierBadgeVi,
      learnedShortcuts: shortcuts,
      peekabooNodes: peekabooNodes,
      quickActionsVi: quickActions,
      lastActionSummaryVi: actionSummary,
      runCount: nextRunCount,
    );

    if (existingIdx >= 0) {
      _learnedPlaybooks[existingIdx] = entry;
    } else {
      _learnedPlaybooks.insert(0, entry);
    }

    // Also update active Live Canvas with the Peekaboo + Menu map for transparency
    _canvasService.updateActiveCanvas(
      LiveCanvasSurfaceSnapshot(
        canvasId: 'cnv-playbook-$resolvedId',
        surfaceKind: 'data_table',
        titleVi: 'Sổ tay Điều khiển App: $cleanName ($tierBadgeVi)',
        columns: const <String>[
          'Nhãn Peekaboo / Phím tắt',
          'Thành phần trong App',
          'Cơ chế thực thi',
        ],
        rows: <Map<String, Object?>>[
          for (final sc in shortcuts)
            <String, String>{
              'col0': sc.split(':').first.trim(),
              'col1': sc.contains(':') ? sc.split(':').sublist(1).join(':').trim() : sc,
              'col2': 'Hotkey / Menu Bar',
            },
          for (final nd in peekabooNodes)
            <String, String>{
              'col0': nd.split(' ').first.trim(),
              'col1': nd,
              'col2': 'Peekaboo AXUIElement / UIA',
            },
        ],
        actions: const <String>['invoke_ref', 'export_csv'],
        summaryVi: actionSummary,
      ),
    );

    return entry;
  }

  /// Removes a learned [AppPlaybookEntry] by [appId].
  void removeAppPlaybook(String appId) {
    _learnedPlaybooks.removeWhere((p) => p.appId == appId);
  }

  /// Triggers a Human-in-the-Loop Handover pause when encountering login/2FA/Captcha/payment.
  HumanHandoverSnapshot triggerHumanHandover({
    required String appName,
    required String taskTitleVi,
    String? blockerReasonVi,
    List<String>? remainingStepsVi,
  }) {
    final cleanApp = appName.trim().isEmpty ? _activeFocusedAppName : appName.trim();
    final snap = HumanHandoverSnapshot(
      handoverId: 'ho_${DateTime.now().millisecondsSinceEpoch % 100000}',
      appName: cleanApp,
      taskTitleVi: taskTitleVi.trim().isEmpty
          ? 'Thực hiện tác vụ tự động trong $cleanApp'
          : taskTitleVi.trim(),
      blockerReasonVi: blockerReasonVi ??
          'Phát hiện bước nhạy cảm (Đăng nhập / Mã 2FA OTP / Xác nhận) trong $cleanApp — XUNA tự động dừng lại để bạn bấm qua an toàn.',
      remainingStepsVi: remainingStepsVi ??
          <String>[
            'Bước tiếp theo 1: Tiếp tục điền thông tin vào [T1] trong $cleanApp',
            'Bước tiếp theo 2: Bấm nút Hoàn tất [B1] và báo kết quả về điện thoại',
          ],
      waitingForHuman: true,
    );
    _activeHandover = snap;
    return snap;
  }

  /// Resumes and completes the paused task after the human owner finishes the login/2FA step.
  String resumeHumanHandover() {
    final current = _activeHandover;
    if (current == null) {
      return 'Không có phiên chờ xác nhận nào đang tạm dừng.';
    }
    _activeHandover = null;
    learnOrInspectApp(
      current.appName,
      customActionVi: 'Hoàn tất ${current.remainingStepsVi.length} bước còn lại của "${current.taskTitleVi}"',
    );
    return '🎉 Cảm ơn bạn! XUNA đã tiếp nhận lại cửa sổ ${current.appName} và hoàn thành nốt ${current.remainingStepsVi.length} bước còn lại của "${current.taskTitleVi}"!';
  }

  /// Cancels the paused Human-in-the-Loop handover session.
  void cancelHumanHandover() {
    _activeHandover = null;
  }

  /// Populates [_activeUiNodes] from a live native OS `inspectWindowUiTree` snapshot,
  /// collapsing transparent web/Electron layout wrappers (`group`/`custom`/`pane`)
  /// and tagging each element with a snapshot-qualified `@s<id>:e<N>` reference.
  void applyNativeWindowUiTree({
    required String windowTitle,
    required List<Map<String, Object?>> nodes,
  }) {
    if (windowTitle.trim().isNotEmpty) {
      _lastWindowTitle = windowTitle.trim();
    }
    if (nodes.isEmpty) return;
    _activeUiNodes.clear();
    _hasLiveNativeTree = true;
    final snapId = _mintNextSnapshotId();
    var idx = 0;
    for (var i = 0; i < nodes.length; i++) {
      final raw = nodes[i];
      if (isTransparentWebWrapperNode(<String, Object?>{
        'role': raw['role'],
        'name': raw['label'] ?? raw['name'],
        'value': raw['value'],
        'isPassword': raw['isPassword'],
      })) {
        continue;
      }
      idx++;
      final refId = (raw['refId'] as String?) ?? 'ui_$idx';
      final snapshotRef = qualifySnapshotElementRef(
        snapshotId: snapId,
        rawId: refId,
        index1Based: idx,
      );
      final role = (raw['role'] as String?) ?? 'AXElement';
      final isPwd = raw['isPassword'] == true;
      final label = isPwd
          ? '[REDACTED_PASSWORD_CONTROL]'
          : ((raw['label'] as String?) ?? role);
      _activeUiNodes[refId] = <String, Object?>{
        'refId': refId,
        'snapshotRef': snapshotRef,
        'role': role,
        'label': label,
        'pattern': (raw['pattern'] as String?) ??
            ((role.toLowerCase().contains('text') ||
                    role.toLowerCase().contains('search') ||
                    role.toLowerCase().contains('edit'))
                ? 'ValuePattern / AXValue'
                : 'InvokePattern / AXPress'),
        'value': isPwd ? '[REDACTED]' : ((raw['value'] as String?) ?? ''),
        'isPassword': isPwd,
        'status': (raw['status'] as String?) ?? 'ready',
      };
    }
  }

  ({
    String action,
    String windowTitle,
    int nodeCount,
    int tokenSavingsPercent,
    int screenshotBytesUsed,
    String compactUiTree,
    String invokedRefId,
    int redactedControlsCount,
    List<Map<String, Object?>> nodes,
    String summaryVi,
  })
  executeUiAccessibilityTree({String? windowTitle}) {
    final cleanTitle = (windowTitle != null && windowTitle.trim().isNotEmpty)
        ? windowTitle.trim()
        : _lastWindowTitle;
    _lastWindowTitle = cleanTitle;

    // Reports only the tree last applied from a live native scan
    // ([applyNativeWindowUiTree]); it never invents controls or acts on them.
    final redactedCount = _activeUiNodes.values
        .where((n) => n['isPassword'] == true)
        .length;
    final summaryVi =
        'Quét cây UI Automation "$cleanTitle" ($_activeSnapshotId): ${_activeUiNodes.length} phần tử, che $redactedCount ô mật khẩu, 0 byte ảnh chụp màn hình.';

    final nodesList = _activeUiNodes.values.toList(growable: false);
    final compactLines = nodesList.map((n) {
      final rId = n['refId'];
      final sRef = n['snapshotRef'];
      final role = n['role'];
      final lbl = n['label'];
      final val = n['value'] ?? '';
      final valSuffix = val.toString().isNotEmpty ? ' val="$val"' : '';
      final sRefSuffix = sRef is String && sRef.isNotEmpty ? ' ($sRef)' : '';
      return '[ref=$rId]$sRefSuffix <$role> "$lbl"$valSuffix';
    }).join('\n');

    final rows = nodesList.map((n) {
      return <String, String>{
        'col0': '[ref=${n['refId']}]',
        'col1': '${n['role']} (${n['pattern']})',
        'col2': '${n['label']}',
        'col3': '${n['status'] ?? 'ready'} · 0-Screenshot',
      };
    }).toList(growable: false);

    _canvasService.updateActiveCanvas(
      LiveCanvasSurfaceSnapshot(
        canvasId: 'cnv-uia-${DateTime.now().millisecondsSinceEpoch % 100000}',
        surfaceKind: 'data_table',
        titleVi: 'OS UI Automation: $cleanTitle (0-Screenshot)',
        columns: const <String>[
          'Mã Ref UI',
          'Kiểu & Giao thức OS',
          'Nhãn điều khiển',
          'Trạng thái',
        ],
        rows: rows,
        actions: const <String>['export_csv', 'undo_last'],
        summaryVi: summaryVi,
      ),
    );

    return (
      action: 'inspect_window',
      windowTitle: cleanTitle,
      nodeCount: nodesList.length,
      tokenSavingsPercent: 0,
      screenshotBytesUsed: 0,
      compactUiTree: compactLines,
      invokedRefId: '',
      redactedControlsCount: redactedCount,
      nodes: nodesList,
      summaryVi: summaryVi,
    );
  }
}
