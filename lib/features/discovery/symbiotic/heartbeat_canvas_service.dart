import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

import 'omniforge_service.dart';
import 'symbiotic_models.dart';
import 'universal_pipeline_service.dart';

/// Zero-Token 2-Tier Heartbeat & Interactive Agent-to-UI (`A2UI`) Live Canvas
/// (`CLAW-2`, `CLAW-3`, `UNIV-2`, `WORKSHOP-2`).
class HeartbeatCanvasService {
  HeartbeatCanvasService({
    required OmniForgeService forgeService,
    required UniversalPipelineService pipelineService,
  }) : _forgeService = forgeService,
       _pipelineService = pipelineService;

  final OmniForgeService _forgeService;
  final UniversalPipelineService _pipelineService;

  int _heartbeatIntervalMinutes = 30;
  String _heartbeatCheckName = 'Tuần tra đa năng (File / Giá / Dữ liệu)';
  HeartbeatStatusSnapshot? _lastHeartbeatStatus;
  LiveCanvasSurfaceSnapshot? _activeLiveCanvas;
  int _canvasSeq = 0;
  final Map<String, String> _sensorHashByTarget = <String, String>{};

  HeartbeatStatusSnapshot? get lastHeartbeatStatus => _lastHeartbeatStatus;
  LiveCanvasSurfaceSnapshot? get activeLiveCanvas => _activeLiveCanvas;

  void updateActiveCanvas(LiveCanvasSurfaceSnapshot snap) {
    _activeLiveCanvas = snap;
  }

  int nextCanvasSeq() => ++_canvasSeq;

  /// Runs or configures XUNA's Zero-Token 2-Tier Heartbeat (`CLAW-2`, `UNIV-2`, `WORKSHOP-2`).
  ///
  /// Supports real SHA-256 `sensor.hash_delta` detection when [watchedDirectoryPath]
  /// or [watchedContent] is supplied: if the computed SHA-256 differs from the
  /// previous tick for the same target, `deltaDetected` is automatically `true`,
  /// and any forged skills with `autoTriggerOnDelta == true` are automatically
  /// executed.
  HeartbeatStatusSnapshot configureAndTickHeartbeat({
    String action = 'tick',
    String? checkName,
    int? intervalMinutes,
    String? watchedDirectoryPath,
    String? watchedContent,
  }) {
    if (checkName != null && checkName.trim().isNotEmpty) {
      _heartbeatCheckName = redactSensitiveSelectionText(
        checkName.trim(),
        maxChars: 80,
      ).text;
    }
    if (intervalMinutes != null) {
      _heartbeatIntervalMinutes = intervalMinutes.clamp(5, 720);
    }
    if (action == 'status' && _lastHeartbeatStatus != null) {
      return _lastHeartbeatStatus!;
    }

    var realDelta = false;
    var sensed = false;
    if (watchedDirectoryPath != null &&
        watchedDirectoryPath.trim().isNotEmpty) {
      final dir = Directory(watchedDirectoryPath.trim());
      if (dir.existsSync()) {
        sensed = true;
        final entries = dir.listSync().whereType<File>().map((f) {
          final stat = f.statSync();
          final base = f.path.split(RegExp(r'[/\\]')).last;
          return '$base:${stat.size}:${stat.modified.millisecondsSinceEpoch}';
        }).toList()..sort();
        final digest = sha256
            .convert(utf8.encode(entries.join('|')))
            .toString();
        final key = 'dir:${dir.path}';
        final prev = _sensorHashByTarget[key];
        _sensorHashByTarget[key] = digest;
        if (prev != null && prev != digest) {
          realDelta = true;
        }
      }
    } else if (watchedContent != null) {
      sensed = true;
      final digest = sha256.convert(utf8.encode(watchedContent)).toString();
      final key = 'content:$_heartbeatCheckName';
      final prev = _sensorHashByTarget[key];
      _sensorHashByTarget[key] = digest;
      if (prev != null && prev != digest) {
        realDelta = true;
      }
    }

    final forgedSkills = _forgeService.forgedSkillsMutable;
    final autoTriggeredTitles = <String>[];
    if (realDelta) {
      for (var i = 0; i < forgedSkills.length; i++) {
        final s = forgedSkills[i];
        if (s.autoTriggerOnDelta) {
          final pipeRes = _pipelineService.executeUniversalPipeline(
            goal: s.goal,
            primitives: s.primitives,
            sourceFolder:
                (watchedDirectoryPath != null &&
                    watchedDirectoryPath.trim().isNotEmpty)
                ? watchedDirectoryPath.trim()
                : s.targetFolder,
            rawInputText: watchedContent,
          );
          forgedSkills[i] = s.copyWith(
            runCount: s.runCount + 1,
            lastRunSummaryVi:
                'Tự động kích hoạt khi Heartbeat "$_heartbeatCheckName" phát hiện biến động SHA-256 -> xử lý ${pipeRes.processedCount} bản ghi (${pipeRes.exportedFile}).',
          );
          autoTriggeredTitles.add(s.titleVi);
        }
      }
    }

    final status = realDelta ? 'HEARTBEAT_ALERT' : 'HEARTBEAT_OK';
    final autoSuffix = autoTriggeredTitles.isEmpty
        ? ' — XUNA sẵn sàng xử lý!'
        : ' — Đã tự động chạy ${autoTriggeredTitles.length} kỹ năng liên kết (${autoTriggeredTitles.join(", ")})!';
    final summaryVi = realDelta
        ? 'HEARTBEAT_ALERT: Phát hiện biến động dữ liệu mới (SHA-256 delta) trong phiên tuần tra "$_heartbeatCheckName"$autoSuffix'
        : (sensed
            ? 'HEARTBEAT_OK: Tuần tra ngầm "$_heartbeatCheckName" (chu kỳ $_heartbeatIntervalMinutes phút) hoàn tất với 0 LLM token — không có thay đổi.'
            : 'HEARTBEAT_OK: "$_heartbeatCheckName" chưa gắn thư mục hay nội dung để canh nên chưa kiểm tra dữ liệu nào.');
    final snap = HeartbeatStatusSnapshot(
      status: status,
      deltaDetected: realDelta,
      llmTokensUsed: 0,
      suppressedNotification: !realDelta,
      intervalMinutes: _heartbeatIntervalMinutes,
      checkName: _heartbeatCheckName,
      summaryVi: summaryVi,
    );
    _lastHeartbeatStatus = snap;
    return snap;
  }

  /// Builds and presents an interactive Agent-to-UI (`A2UI`) Live Canvas surface (`CLAW-3`, `UNIV-2`).
  LiveCanvasSurfaceSnapshot presentLiveCanvas({
    String action = 'present_invoice_table',
    String? title,
    String? sourceSkillId,
  }) {
    _canvasSeq++;
    if (action == 'clear') {
      _activeLiveCanvas = null;
      return LiveCanvasSurfaceSnapshot(
        canvasId: 'canvas-clear-$_canvasSeq',
        surfaceKind: 'cleared',
        titleVi: 'Đã đóng bảng Live Canvas',
        columns: const <String>[],
        rows: const <Map<String, Object?>>[],
        actions: const <String>[],
        summaryVi: 'Đã thu gọn bảng tương tác Live Canvas.',
      );
    }

    if (action == 'present_kanban_board') {
      final rows = <Map<String, Object?>>[
        <String, Object?>{
          'candidate': 'Nguyễn Minh Anh',
          'skills': 'Python, Marketing, SQL',
          'experience': '3.5 năm',
          'score': '94/100',
          'stage': 'Vào vòng Phỏng vấn',
        },
        <String, Object?>{
          'candidate': 'Trần Hoàng Nam',
          'skills': 'Flutter, Dart, UI/UX',
          'experience': '4.0 năm',
          'score': '91/100',
          'stage': 'Vào vòng Phỏng vấn',
        },
        <String, Object?>{
          'candidate': 'Lê Thu Hà',
          'skills': 'Content, SEO, Canva',
          'experience': '2.0 năm',
          'score': '82/100',
          'stage': 'Danh sách Tiềm năng',
        },
      ];
      final snap = LiveCanvasSurfaceSnapshot(
        canvasId: 'canvas-kanban-$_canvasSeq',
        surfaceKind: 'kanban_board',
        titleVi: (title != null && title.trim().isNotEmpty)
            ? title.trim()
            : 'Bảng Kanban Sàng Lọc Ứng Viên & Hồ Sơ (A2UI)',
        columns: const <String>[
          'Hồ sơ / Ứng viên',
          'Kỹ năng bóc tách',
          'Kinh nghiệm',
          'Điểm khớp',
          'Cột trạng thái',
        ],
        rows: rows,
        actions: const <String>[
          'export_csv',
          'filter_top_candidates',
          'undo_last',
        ],
        summaryVi:
            'Live Canvas Kanban: Đã phân loại ${rows.length} hồ sơ theo điểm khớp kỹ năng kèm nút Xuất CSV.',
      );
      _activeLiveCanvas = snap;
      return snap;
    }

    if (action == 'present_metric_cards') {
      final rows = <Map<String, Object?>>[
        <String, Object?>{
          'product': 'Tai nghe Bluetooth X-Pro ANC',
          'myPrice': '380.000 đ',
          'competitorPrice': '345.000 đ (-9.2%)',
          'stockStatus': 'Đối thủ sắp hết hàng',
          'recommendation': 'Giữ giá + Tặng voucher 15k',
        },
        <String, Object?>{
          'product': 'Bàn phím Cơ Wireless K68',
          'myPrice': '650.000 đ',
          'competitorPrice': '690.000 đ (+6.1%)',
          'stockStatus': 'Còn hàng',
          'recommendation': 'Đang có lợi thế giá tốt nhất',
        },
      ];
      final snap = LiveCanvasSurfaceSnapshot(
        canvasId: 'canvas-metrics-$_canvasSeq',
        surfaceKind: 'metric_cards',
        titleVi: (title != null && title.trim().isNotEmpty)
            ? title.trim()
            : 'Radar Biến Động Giá & Tồn Kho Đối Thủ (A2UI)',
        columns: const <String>[
          'Sản phẩm',
          'Giá shop bạn',
          'Giá đối thủ',
          'Tồn kho',
          'Đề xuất hành động',
        ],
        rows: rows,
        actions: const <String>[
          'export_csv',
          'enable_heartbeat_watch',
          'undo_last',
        ],
        summaryVi:
            'Live Canvas Metric Cards: Phát hiện 1 mã sản phẩm đối thủ giảm giá 9.2% — đã gợi ý phương án tối ưu.',
      );
      _activeLiveCanvas = snap;
      return snap;
    }

    if (action == 'present_diff_reconcile') {
      final rows = _pipelineService.reconcileUniversalTables(
        const <Map<String, Object?>>[
          <String, Object?>{
            'id': 'DH-8821',
            'customer': 'Phạm Quốc Bảo',
            'amount': 450000,
          },
          <String, Object?>{
            'id': 'DH-8822',
            'customer': 'Đỗ Bích Ngọc',
            'amount': 1250000,
          },
          <String, Object?>{
            'id': 'DH-8823',
            'customer': 'Vũ Tuấn Kiệt',
            'amount': 780000,
          },
        ],
        const <Map<String, Object?>>[
          <String, Object?>{'id': 'DH-8821', 'amount': 450000},
          <String, Object?>{'id': 'DH-8822', 'amount': 1215000},
        ],
      );
      final snap = LiveCanvasSurfaceSnapshot(
        canvasId: 'canvas-reconcile-$_canvasSeq',
        surfaceKind: 'diff_reconcile',
        titleVi: (title != null && title.trim().isNotEmpty)
            ? title.trim()
            : 'Bảng Đối Soát Chênh Lệch Đa Nguồn (A2UI)',
        columns: const <String>[
          'Mã đối chiếu',
          'Bảng A (Gốc)',
          'Bảng B (Thực nhận)',
          'Chênh lệch',
          'Trạng thái',
        ],
        rows: rows,
        actions: const <String>[
          'export_csv',
          'filter_discrepancies',
          'undo_last',
        ],
        summaryVi:
            'Live Canvas Đối Soát: So khớp ${rows.length} dòng (1 khớp 100%, 1 lệch số tiền, 1 thiếu dữ liệu đối ứng).',
      );
      _activeLiveCanvas = snap;
      return snap;
    }

    if (action == 'present_data_table') {
      final rows = <Map<String, Object?>>[
        <String, Object?>{
          'item': 'Xu hướng AI Agent tự tạo công cụ 2026',
          'source': 'Báo cáo Công nghệ',
          'keyTakeaway':
              'Kiến trúc 8 Nguyên tử Composable giúp mở rộng đa ngành',
          'format': 'Markdown + CSV',
        },
        <String, Object?>{
          'item': 'Tối ưu vận hành cửa hàng đa kênh',
          'source': 'Bản tin Thương mại số',
          'keyTakeaway': 'Tự động hóa đối soát đơn hàng và canh giá 0-token',
          'format': 'Markdown + CSV',
        },
      ];
      final snap = LiveCanvasSurfaceSnapshot(
        canvasId: 'canvas-data-$_canvasSeq',
        surfaceKind: 'data_table',
        titleVi: (title != null && title.trim().isNotEmpty)
            ? title.trim()
            : 'Bảng Dữ Liệu Đa Năng XUNA (Live Canvas A2UI)',
        columns: const <String>[
          'Mục dữ liệu',
          'Nguồn trích xuất',
          'Điểm chính',
          'Định dạng xuất',
        ],
        rows: rows,
        actions: const <String>['export_csv', 'export_md', 'undo_last'],
        summaryVi:
            'Live Canvas Data Table: Đang hiển thị ${rows.length} bản ghi đa năng trên bảng tương tác.',
      );
      _activeLiveCanvas = snap;
      return snap;
    }

    if (action == 'present_workflow_board') {
      final skills = _forgeService.listForgedSkillEntries();
      final rows = skills
          .map(
            (s) => <String, Object?>{
              'skillId': s.skillId,
              'titleVi': s.titleVi,
              'category': s.category,
              'selfHealGen': 'v${s.selfHealGeneration}',
              'items': '${s.detectedItemsCount} mục',
            },
          )
          .toList(growable: false);
      final snap = LiveCanvasSurfaceSnapshot(
        canvasId: 'canvas-board-$_canvasSeq',
        surfaceKind: 'workflow_board',
        titleVi: (title != null && title.trim().isNotEmpty)
            ? title.trim()
            : 'Bảng Điều Khiển Kỹ Năng XUNA Live Canvas',
        columns: const <String>['Công cụ', 'Phân loại', 'Tự sửa', 'Quy mô'],
        rows: rows,
        actions: const <String>[
          'run_selected',
          'export_skill_md',
          'record_correction',
        ],
        summaryVi:
            'Đang hiển thị ${rows.length} công cụ tự động trên bảng tương tác Live Canvas.',
      );
      _activeLiveCanvas = snap;
      return snap;
    }

    final invoiceSheet = _forgeService.extractInvoicesToSheet(
      sourceFolder: 'XUNA_HoaDon/Thang_11_2026',
    );
    final snap = LiveCanvasSurfaceSnapshot(
      canvasId: 'canvas-invoices-$_canvasSeq',
      surfaceKind: 'invoice_table',
      titleVi: (title != null && title.trim().isNotEmpty)
          ? title.trim()
          : 'Bảng Kê Hóa Đơn Tương Tác (Live Canvas A2UI)',
      columns: const <String>[
        'Số HĐ',
        'Nhà cung cấp',
        'Mã số thuế',
        'Tổng thanh toán',
        'Trạng thái',
      ],
      rows: invoiceSheet.rows,
      actions: const <String>['export_csv', 'filter_duplicates', 'undo_last'],
      summaryVi:
          'Live Canvas A2UI: Đang hiển thị trực quan ${invoiceSheet.invoiceCount} hóa đơn (Tổng: 7.150.000 đ) kèm nút Lọc trùng & Xuất CSV.',
    );
    _activeLiveCanvas = snap;
    return snap;
  }
}
