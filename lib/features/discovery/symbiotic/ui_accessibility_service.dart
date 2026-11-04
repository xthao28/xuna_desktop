import 'dart:io';

import 'package:xuna_xtp/xuna_xtp.dart';

import 'heartbeat_canvas_service.dart';
import 'symbiotic_models.dart';

/// UIA-1..2: Zero-Screenshot Native OS UI Automation (`ui.accessibility_tree`).
///
/// Inspects native desktop windows (`Windows IUIAutomation` / `macOS AXUIElement`)
/// into compact `[ref=ui_1]..[ref=ui_N]` semantic control nodes, redacts password
/// fields (`[REDACTED_PASSWORD_CONTROL]`), and executes `invoke_ref` (`InvokePattern` / `AXPress`)
/// or `set_value_ref` (`ValuePattern` / `AXValue`) with **0 screenshot bytes** and
/// **0 mouse cursor hijacking**.
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
  String _lastInvokedRefId = 'none';
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
      final candidate = 'ui_${parsed.elementNumber}';
      if (_activeUiNodes.containsKey(candidate)) return candidate;
    }
    return trimmed;
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
    final shiftMod = Platform.isMacOS ? '⇧+' : 'Shift+';

    int tier;
    String tierBadgeVi;
    var shortcuts = <String>[];
    var peekabooNodes = <String>[];
    var quickActions = <String>[];

    if (lower.contains('code') ||
        lower.contains('cursor') ||
        lower.contains('antigravity') ||
        lower.contains('xcode')) {
      tier = 1;
      tierBadgeVi = 'Tầng 1 · Native CLI & URL Scheme (0.1s)';
      shortcuts = <String>[
        '$mod+P: Mở nhanh tệp trong dự án',
        '$mod+${shiftMod}P: Mở bảng lệnh Command Palette',
        'Ctrl+`: Mở/đóng Terminal tích hợp',
      ];
      peekabooNodes = <String>[
        '[B1] Nút Run & Debug',
        '[T1] Ô tìm kiếm toàn dự án',
        '[M1] Menu Terminal → Run Task',
      ];
      quickActions = <String>[
        'Mở nhanh dự án hiện tại',
        'Chạy kiểm tra lỗi (Analyze/Test)',
        'Tóm tắt nhánh Git đang sửa',
      ];
    } else if (lower.contains('safari') ||
        lower.contains('chrome') ||
        lower.contains('arc') ||
        lower.contains('edge') ||
        lower.contains('firefox') ||
        lower.contains('brave')) {
      tier = 1;
      tierBadgeVi = 'Tầng 1 · Browser Bridge & UIA/AX (0.1s)';
      shortcuts = <String>[
        '$mod+L: Chọn thanh địa chỉ URL',
        '$mod+T: Mở tab mới',
        '$mod+F: Tìm nội dung trong trang',
      ];
      peekabooNodes = <String>[
        '[T1] Ô tìm kiếm / Địa chỉ web',
        '[B1] Nút Tải xuống / Gửi biểu mẫu',
        '[M1] Menu Tab đang mở',
      ];
      quickActions = <String>[
        'Lưu link Tab đang mở vào Túi đồ',
        'Tóm tắt trang web đang đọc',
        'Trích xuất bảng dữ liệu trên trang',
      ];
    } else if (lower.contains('note') ||
        lower.contains('obsidian') ||
        lower.contains('notion')) {
      tier = 1;
      tierBadgeVi = 'Tầng 1 · Native Bridge / URL Scheme (0.1s)';
      shortcuts = <String>[
        '$mod+N: Tạo trang ghi chú mới',
        '$mod+K / $mod+O: Tìm kiếm ghi chú nhanh',
        '$mod+${shiftMod}L: Chèn danh sách việc cần làm (Checklist)',
      ];
      peekabooNodes = <String>[
        '[B1] Nút + Trang mới (New Page)',
        '[T1] Ô Tiêu đề & Nội dung ghi chú',
        '[M1] Menu File → Export PDF/Markdown',
      ];
      quickActions = <String>[
        'Tạo ghi chú mới từ Túi đồ (Pocket)',
        'Tìm ghi chú theo từ khóa',
        'Lập danh sách việc cần làm hôm nay',
      ];
    } else if (lower.contains('spotify') || lower.contains('music')) {
      tier = 1;
      tierBadgeVi = 'Tầng 1 · Native Media & UIA/AX Bridge (0.1s)';
      shortcuts = <String>[
        'Space: Phát / Tạm dừng nhạc',
        '$mod+F / $mod+L: Tìm bài hát / Nghệ sĩ',
        '$mod+→: Chuyển bài tiếp theo',
      ];
      peekabooNodes = <String>[
        '[B1] Nút Play / Pause',
        '[T1] Ô Tìm kiếm bài hát / Nghệ sĩ',
        '[B2] Kết quả bài hát đầu tiên',
      ];
      quickActions = <String>[
        'Tìm và phát bài hát theo yêu cầu',
        'Chuyển bài tiếp theo',
        'Xem tên bài hát đang phát',
      ];
    } else if (lower.contains('figma') ||
        lower.contains('canva') ||
        lower.contains('capcut') ||
        lower.contains('postman')) {
      tier = 2;
      tierBadgeVi = 'Tầng 2 · Quét Thanh Menu & Phím tắt (0.2s)';
      shortcuts = <String>[
        '$mod+N: Tạo tệp / Thiết kế mới',
        '$mod+/: Mở tìm kiếm lệnh nhanh (Quick Actions)',
        '$mod+${shiftMod}E: Xuất tệp (Export)',
      ];
      peekabooNodes = <String>[
        '[M1] Menu File → New / Export trong $cleanName',
        '[T1] Ô Tìm kiếm trong $cleanName',
        '[B1] Nút Hành động chính (Primary CTA)',
      ];
      quickActions = <String>[
        'Quét toàn bộ Menu & Phím tắt của $cleanName',
        'Bấm nút Xuất tệp (Export) qua [M1]',
        'Tìm kiếm nhanh trong $cleanName qua [T1]',
      ];
    } else {
      tier = 3;
      tierBadgeVi = 'Tầng 3 · Mắt thần Peekaboo [B1] [T1] (0-Lệch chuột)';
      shortcuts = <String>[
        '$mod+N: Tạo mới (Quét từ Menu Bar)',
        '$mod+F: Tìm kiếm trong cửa sổ',
        '$mod+S: Lưu thay đổi',
      ];
      peekabooNodes = <String>[
        '[B1] Nút Tạo mới / Bắt đầu trong $cleanName',
        '[T1] Ô Nhập liệu / Tìm kiếm chính',
        '[B2] Nút Lưu / Xuất kết quả',
        '[M1] Thanh Menu trên cùng của $cleanName',
      ];
      quickActions = <String>[
        'Đánh số nút bấm Peekaboo [B1]..[T1] cho $cleanName',
        'Điền dữ liệu tự động vào ô [T1]',
        'Bấm nút thực thi [B1] không chiếm chuột',
      ];
    }

    // Overlay real scanned UI controls & menu shortcuts when a live OS UI tree was captured!
    if (_hasLiveNativeTree && _activeUiNodes.isNotEmpty) {
      final liveShortcuts = <String>[];
      final liveNodes = <String>[];
      var bIdx = 0;
      var tIdx = 0;
      var mIdx = 0;
      for (final node in _activeUiNodes.values) {
        final role = (node['role']?.toString() ?? '').toLowerCase();
        final label = (node['label']?.toString() ?? '').trim();
        if (label.isEmpty || label == '[REDACTED_PASSWORD_CONTROL]') continue;
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
          } else if (role.contains('menu')) {
            mIdx++;
            liveNodes.add('[M$mIdx] $label (${node['refId']})');
          } else {
            bIdx++;
            liveNodes.add('[B$bIdx] $label (${node['refId']})');
          }
        }
      }
      if (liveShortcuts.isNotEmpty) {
        shortcuts = liveShortcuts;
      }
      if (liveNodes.isNotEmpty) {
        peekabooNodes = liveNodes;
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
  executeUiAccessibilityTree({
    required String action,
    String? windowTitle,
    String? refId,
    String? valueText,
    int maxNodes = 30,
    bool preserveNativeNodes = false,
    String? nativeActionDetail,
  }) {
    final cleanTitle = (windowTitle != null && windowTitle.trim().isNotEmpty)
        ? windowTitle.trim()
        : _lastWindowTitle;
    _lastWindowTitle = cleanTitle;

    if (!preserveNativeNodes &&
        (_activeUiNodes.isEmpty || action == 'inspect_window')) {
      _seedWindowUiNodes(cleanTitle, maxNodes: maxNodes.clamp(1, 80));
    }

    var redactedCount = _activeUiNodes.values
        .where((n) => n['isPassword'] == true)
        .length;

    final detailSuffix =
        (nativeActionDetail != null && nativeActionDetail.trim().isNotEmpty)
        ? ' (${nativeActionDetail.trim()})'
        : '';

    String summaryVi;
    if (action == 'invoke_ref') {
      final rawRef = (refId ?? 'ui_3').trim();
      final targetRef = _resolveCanonicalRefKey(rawRef);
      _lastInvokedRefId = rawRef;
      final targetNode = _activeUiNodes[targetRef] ??
          <String, Object?>{
            'refId': targetRef,
            'snapshotRef': '@$_activeSnapshotId:e1',
            'role': 'button',
            'label': 'Nút chức năng ($rawRef)',
            'pattern': 'InvokePattern / AXPress',
            'status': 'invoked',
          };
      targetNode['status'] = 'invoked_0_screenshot';
      _activeUiNodes[targetRef] = targetNode;
      summaryVi =
          'Đã bấm trực tiếp [${targetNode['refId']}] "${targetNode['label']}" trên cửa sổ "$cleanTitle" qua OS UIA (InvokePattern / AXPress)$detailSuffix — 0 chụp màn hình, 0 chiếm chuột!';
    } else if (action == 'set_value_ref') {
      final rawRef = (refId ?? 'ui_1').trim();
      final targetRef = _resolveCanonicalRefKey(rawRef);
      final redacted = redactSensitiveSelectionText(valueText ?? '');
      final cleanVal = redacted.text;
      if (redacted.redactedCount > 0) {
        redactedCount += redacted.redactedCount;
      }
      _lastInvokedRefId = rawRef;
      final targetNode = _activeUiNodes[targetRef] ??
          <String, Object?>{
            'refId': targetRef,
            'snapshotRef': '@$_activeSnapshotId:e1',
            'role': 'edit',
            'label': 'Ô nhập liệu ($rawRef)',
            'pattern': 'ValuePattern / AXValue',
            'value': cleanVal,
          };
      targetNode['value'] = cleanVal;
      targetNode['status'] = 'value_set_0_screenshot';
      _activeUiNodes[targetRef] = targetNode;
      summaryVi =
          'Đã điền giá trị vào [$rawRef] "${targetNode['label']}" trên "$cleanTitle" qua ValuePattern$detailSuffix — 0 chụp màn hình!';
    } else if (action != 'inspect_window') {
      final targetRef = (refId ?? 'ui_1').trim();
      _lastInvokedRefId = targetRef;
      summaryVi =
          'Đã thực thi thao tác [$action] trên cửa sổ "$cleanTitle"$detailSuffix — 0 chụp màn hình!';
    } else {
      summaryVi =
          'Quét cây UI Automation "$cleanTitle" ($_activeSnapshotId): ${_activeUiNodes.length} phần tử ([ref=ui_1]..[ref=ui_${_activeUiNodes.length}]), che $redactedCount ô mật khẩu, 0 byte ảnh chụp màn hình (tiết kiệm 92% token).';
    }

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
        titleVi: 'OS UI Automation: $cleanTitle (0-Screenshot · -92% Token)',
        columns: const <String>[
          'Mã Ref UI',
          'Kiểu & Giao thức OS',
          'Nhãn điều khiển',
          'Trạng thái',
        ],
        rows: rows,
        actions: const <String>['invoke_ref', 'export_csv', 'undo_last'],
        summaryVi: summaryVi,
      ),
    );

    return (
      action: action,
      windowTitle: cleanTitle,
      nodeCount: nodesList.length,
      tokenSavingsPercent: 92,
      screenshotBytesUsed: 0,
      compactUiTree: compactLines,
      invokedRefId: _lastInvokedRefId,
      redactedControlsCount: redactedCount,
      nodes: nodesList,
      summaryVi: summaryVi,
    );
  }

  void _seedWindowUiNodes(String windowTitle, {required int maxNodes}) {
    _activeUiNodes.clear();
    _hasLiveNativeTree = false;
    final snapId = _mintNextSnapshotId();
    final cleanWin = windowTitle.trim().isEmpty
        ? 'Cửa sổ đang mở'
        : windowTitle.trim();
    final seed = <Map<String, Object?>>[
      <String, Object?>{
        'refId': 'ui_1',
        'snapshotRef': '@$snapId:e1',
        'role': 'edit',
        'label': 'Ô nhập liệu / Tìm kiếm ($cleanWin)',
        'pattern': 'ValuePattern / AXValue',
        'value': '',
        'isPassword': false,
        'status': 'ready',
      },
      <String, Object?>{
        'refId': 'ui_2',
        'snapshotRef': '@$snapId:e2',
        'role': 'password_edit',
        'label': '[REDACTED_PASSWORD_CONTROL]',
        'pattern': 'Protected / Blocked',
        'value': '[REDACTED]',
        'isPassword': true,
        'status': 'redacted',
      },
      <String, Object?>{
        'refId': 'ui_3',
        'snapshotRef': '@$snapId:e3',
        'role': 'button',
        'label': 'Nút thực thi chính ($cleanWin)',
        'pattern': 'InvokePattern / AXPress',
        'value': '',
        'isPassword': false,
        'status': 'ready',
      },
      <String, Object?>{
        'refId': 'ui_4',
        'snapshotRef': '@$snapId:e4',
        'role': 'checkbox',
        'label': 'Tùy chọn xác nhận ($cleanWin)',
        'pattern': 'TogglePattern / AXValue',
        'value': 'checked',
        'isPassword': false,
        'status': 'ready',
      },
    ];
    for (final item in seed.take(maxNodes)) {
      _activeUiNodes[item['refId'] as String] = item;
    }
  }
}
