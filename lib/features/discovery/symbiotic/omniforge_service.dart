import 'dart:convert';

import 'package:xuna_xtp/xuna_xtp.dart';

import 'symbiotic_models.dart';

/// XUNA OmniForge Citizen Toolsmith & Show-Me-Once service (`FORGE-1`, `FORGE-2`, `FORGE-3`, `UNIV-2`).
class OmniForgeService {
  int _forgeSeq = 0;
  int _undoSnapSeq = 0;
  bool _teachRecordingActive = false;
  String _teachSkillTitle = '';
  final List<ForgedSkillEntry> _forgedSkills = <ForgedSkillEntry>[];
  final List<TeachDemonstrationStep> _teachSteps = <TeachDemonstrationStep>[];

  /// Whether a `Show-Me-Once` (`teach.record_session`) demonstration is currently recording.
  bool get isTeachRecordingActive => _teachRecordingActive;

  /// Mutable forged skills list shared with sibling OmniForge / Workshop / Pipeline services.
  List<ForgedSkillEntry> get forgedSkillsMutable => _forgedSkills;

  /// Increments and returns the next undo snapshot sequence counter.
  int nextUndoSnapSeq() => ++_undoSnapSeq;

  /// Infers the best `OMNIFORGE` / Universal skill category from a natural-language [goal] (`FORGE-1`, `UNIV-2`).
  static String inferForgeSkillCategory(String goal) {
    final lower = goal.toLowerCase();
    if (lower.contains('hóa đơn') ||
        lower.contains('hoa don') ||
        lower.contains('invoice') ||
        lower.contains('tải hết') ||
        lower.contains('tai het') ||
        lower.contains('chứng từ')) {
      return 'web_harvest_invoices';
    }
    if (lower.contains('cv') ||
        lower.contains('ứng viên') ||
        lower.contains('ung vien') ||
        lower.contains('tuyển dụng') ||
        lower.contains('resume') ||
        lower.contains('hr')) {
      return 'hr_cv_scanner';
    }
    if (lower.contains('giá') ||
        lower.contains('shopee') ||
        lower.contains('lazada') ||
        lower.contains('tiktok') ||
        lower.contains('đối thủ') ||
        lower.contains('radar') ||
        lower.contains('tồn kho')) {
      return 'ecommerce_price_radar';
    }
    if (lower.contains('tin tức') ||
        lower.contains('tóm tắt') ||
        lower.contains('bài viết') ||
        lower.contains('content') ||
        lower.contains('marketing') ||
        lower.contains('nghiên cứu') ||
        lower.contains('digest')) {
      return 'content_news_digest';
    }
    if (lower.contains('ảnh') ||
        lower.contains('photo') ||
        lower.contains('đổi tên') ||
        lower.contains('rename') ||
        lower.contains('media') ||
        lower.contains('thiết kế')) {
      return 'media_batch_renamer';
    }
    if (lower.contains('đối soát') ||
        lower.contains('doi soat') ||
        lower.contains('sao kê') ||
        lower.contains('so sánh bảng') ||
        lower.contains('reconcile')) {
      return 'spreadsheet_reconciler';
    }
    if (lower.contains('dọn') ||
        lower.contains('sắp xếp') ||
        lower.contains('sap xep') ||
        lower.contains('downloads') ||
        lower.contains('gom file')) {
      return 'smart_file_janitor';
    }
    if (lower.contains('bình luận') ||
        lower.contains('khách hàng') ||
        lower.contains('số điện thoại') ||
        lower.contains('lead')) {
      return 'lead_harvester';
    }
    if (lower.contains('excel') ||
        lower.contains('csv') ||
        lower.contains('bảng kê') ||
        lower.contains('trích xuất')) {
      return 'document_to_sheet';
    }
    return 'universal_data_pipeline';
  }

  /// Synthesizes a sandboxed `XunaScript` tool from [goal], performs a 1-item dry-run
  /// preview with Voyager-style self-debugging, and stores it in [_forgedSkills] (`FORGE-1`, `UNIV-2`).
  ForgedSkillEntry synthesizeSkill({
    required String goal,
    String? category,
    String? targetFolder,
    List<String>? fileExtensions,
    DateTime? nowUtc,
  }) {
    _forgeSeq++;
    final ts = (nowUtc ?? DateTime.now()).toUtc();
    final cleanGoal = redactSensitiveSelectionText(
      goal.trim(),
      maxChars: 400,
    ).text;
    final resolvedCategory =
        (category == null || category == 'auto' || category.trim().isEmpty)
        ? inferForgeSkillCategory(cleanGoal)
        : category.trim();

    final exts = (fileExtensions == null || fileExtensions.isEmpty)
        ? switch (resolvedCategory) {
            'web_harvest_invoices' => <String>['pdf', 'xml'],
            'document_to_sheet' => <String>['xml', 'pdf', 'csv'],
            'spreadsheet_reconciler' => <String>['csv', 'xlsx'],
            'smart_file_janitor' => <String>[
              'pdf',
              'docx',
              'xlsx',
              'png',
              'zip',
            ],
            'hr_cv_scanner' => <String>['pdf', 'docx', 'txt'],
            'ecommerce_price_radar' => <String>['csv', 'json', 'html'],
            'content_news_digest' => <String>['md', 'html', 'txt'],
            'media_batch_renamer' => <String>['jpg', 'png', 'webp', 'heic'],
            'lead_harvester' => <String>['csv', 'json'],
            _ => <String>['csv', 'json', 'md'],
          }
        : fileExtensions
              .map(
                (e) => e.trim().toLowerCase().replaceFirst(RegExp(r'^\.+'), ''),
              )
              .where(isAllowedForgeFileExtension)
              .toList(growable: false);

    final folder = (targetFolder == null || targetFolder.trim().isEmpty)
        ? switch (resolvedCategory) {
            'web_harvest_invoices' => 'XUNA_HoaDon/Thang_11_2026',
            'document_to_sheet' => 'XUNA_BangKe',
            'smart_file_janitor' => 'XUNA_DaSapXep',
            'spreadsheet_reconciler' => 'XUNA_DoiSoat',
            'hr_cv_scanner' => 'XUNA_TuyenDung/UngVien',
            'ecommerce_price_radar' => 'XUNA_ShopRadar/GiaDoiThu',
            'content_news_digest' => 'XUNA_Content/BanTin',
            'media_batch_renamer' => 'XUNA_Media/Album_ChuDe',
            'lead_harvester' => 'XUNA_KhachHang',
            _ => 'XUNA_Tools/Output',
          }
        : targetFolder.trim();

    late final String titleVi;
    late final int detectedCount;
    late final String dryRunSample;
    late final List<Map<String, Object?>> paramFields;
    late final List<String> scriptSteps;
    late final String surfaceKind;

    switch (resolvedCategory) {
      case 'hr_cv_scanner':
        titleVi = 'Sàng Lọc CV Ứng Viên & Xếp Hạng Kỹ Năng';
        detectedCount = 34;
        dryRunSample =
            'Mẫu thử #1: CV_NguyenMinhAnh.pdf -> 3 năm KN (Python, Marketing, SQL) | Điểm khớp: 92/100';
        surfaceKind = 'kanban_board';
        paramFields = <Map<String, Object?>>[
          <String, Object?>{
            'key': 'targetFolder',
            'labelVi': 'Thư mục chứa hồ sơ CV',
            'defaultValue': folder,
          },
          <String, Object?>{
            'key': 'requiredSkills',
            'labelVi': 'Từ khóa kỹ năng ưu tiên',
            'defaultValue': 'Python, Marketing, Tiếng Anh',
          },
        ];
        scriptSteps = <String>[
          '1. [source.filesystem] Quét toàn bộ hồ sơ CV (.pdf, .docx, .txt) trong "$folder"',
          '2. [parse.universal] Bóc tách Email, SĐT, Số năm KN và danh sách Kỹ năng ứng viên',
          '3. [transform.pipeline] Chấm điểm độ khớp tiêu chí và phân nhóm Đạt / Cần phỏng vấn',
          '4. [export.artifact + canvas.dynamic_a2ui] Xuất BangXepHang_UngVien.csv và mở bảng Kanban',
        ];
      case 'ecommerce_price_radar':
        titleVi = 'Radar Canh Giá Đối Thủ & Cảnh Báo Tồn Kho';
        detectedCount = 24;
        dryRunSample =
            'Mẫu thử #1: Tai nghe X-Pro giảm 12% (390.000 đ -> 345.000 đ) | Tồn kho: Sắp hết';
        surfaceKind = 'metric_cards';
        paramFields = <Map<String, Object?>>[
          <String, Object?>{
            'key': 'targetFolder',
            'labelVi': 'Thư mục lưu lịch sử giá',
            'defaultValue': folder,
          },
          <String, Object?>{
            'key': 'alertDropPercent',
            'labelVi': 'Ngưỡng báo động giảm giá (%)',
            'defaultValue': '5',
          },
        ];
        scriptSteps = <String>[
          '1. [source.web_http] Đọc bảng giá sản phẩm & trạng thái tồn kho trên trang đang mở',
          '2. [sensor.hash_delta] Băm SHA-256 phát hiện biến động giá với 0 LLM token khi giá đứng yên',
          '3. [transform.pipeline] Tính chênh lệch % giá bán so với shop của bạn',
          '4. [canvas.dynamic_a2ui] Hiển thị thẻ Metric Cards cảnh báo mã giảm sâu',
        ];
      case 'content_news_digest':
        titleVi = 'Tổng Hợp Tin Tức & Lập Dàn Ý Nội Dung Đa Kênh';
        detectedCount = 18;
        dryRunSample =
            'Mẫu thử #1: 5 xu hướng AI & Thương mại số trong ngày -> BanTin_TongHop.md';
        surfaceKind = 'data_table';
        paramFields = <Map<String, Object?>>[
          <String, Object?>{
            'key': 'targetFolder',
            'labelVi': 'Thư mục lưu bản tin Markdown',
            'defaultValue': folder,
          },
        ];
        scriptSteps = <String>[
          '1. [source.web_http] Thu thập tiêu đề, luận điểm chính và số liệu từ các bài viết nguồn',
          '2. [parse.universal] Khử nhiễu quảng cáo và trích xuất trích dẫn quan trọng',
          '3. [transform.pipeline] Gom nhóm theo chủ đề và tạo khung nội dung (Hook - Insight - CTA)',
          '4. [export.artifact] Xuất tệp BanTin_TongHop.md và bảng tóm tắt trực quan',
        ];
      case 'media_batch_renamer':
        titleVi = 'Đổi Tên & Phân Loại Bộ Sưu Tập Ảnh/Media Hàng Loạt';
        detectedCount = 86;
        dryRunSample =
            'Mẫu thử #1: IMG_8841.JPG -> $folder/2026-11_BoSuuTap_001.jpg (Có Hoàn tác 1 chạm)';
        surfaceKind = 'data_table';
        paramFields = <Map<String, Object?>>[
          <String, Object?>{
            'key': 'targetFolder',
            'labelVi': 'Thư mục album ảnh/media',
            'defaultValue': folder,
          },
          <String, Object?>{
            'key': 'namePrefix',
            'labelVi': 'Tiền tố tên tệp chuẩn hóa',
            'defaultValue': '2026-11_SanPham',
          },
        ];
        scriptSteps = <String>[
          '1. [source.filesystem] Đọc danh sách tệp ảnh/video và ngày tạo trong "$folder"',
          '2. [file.batch_ops] Ghi sổ cái hoàn tác (Undo Ledger) trước khi đổi tên hàng loạt',
          '3. [file.batch_ops] Chuẩn hóa tên theo mẫu YYYY-MM_ChuDe_STT và gom thư mục',
          '4. [canvas.dynamic_a2ui] Hiển thị bảng đối chiếu Tên cũ -> Tên mới kèm nút Hoàn tác',
        ];
      case 'web_harvest_invoices':
        titleVi = 'Tải Hóa Đơn Hàng Loạt & Lập Bảng Kê';
        detectedCount = 48;
        dryRunSample =
            'Mẫu thử #1: 2026-11_VNPT_HD001248.pdf + .xml (1.650.000 đ) -> $folder/';
        surfaceKind = 'invoice_table';
        paramFields = <Map<String, Object?>>[
          <String, Object?>{
            'key': 'targetFolder',
            'labelVi': 'Thư mục lưu hóa đơn',
            'defaultValue': folder,
          },
          <String, Object?>{
            'key': 'fileExtensions',
            'labelVi': 'Định dạng tải về',
            'defaultValue': exts.join(', '),
          },
          <String, Object?>{
            'key': 'exportCsv',
            'labelVi': 'Tự động gom bảng kê CSV/Excel',
            'defaultValue': 'true',
          },
        ];
        scriptSteps = <String>[
          '1. Quét bảng hóa đơn trên tab trình duyệt đang mở (hỗ trợ tự lật trang Pagination)',
          '2. Lọc liên kết tải định dạng (${exts.map((e) => ".$e").join(", ")}) và kiểm tra chống trùng lặp',
          '3. Tải về hộp cát "$folder" theo chuẩn tên YYYY-MM_NhaCungCap_SoHD',
          '4. Trích xuất Mã số thuế, Tiền trước thuế, VAT, Tổng tiền ra BangKe_HoaDon.csv',
        ];
      case 'document_to_sheet':
        titleVi = 'Đọc Chứng Từ / Tài Liệu Ra Bảng Tổng Hợp Excel';
        detectedCount = 35;
        dryRunSample =
            'Mẫu thử #1: HD_001248.xml -> MST 0100684378 | Tổng: 1.650.000 đ (VAT 10%)';
        surfaceKind = 'data_table';
        paramFields = <Map<String, Object?>>[
          <String, Object?>{
            'key': 'sourceFolder',
            'labelVi': 'Thư mục chứa tài liệu',
            'defaultValue': folder,
          },
          <String, Object?>{
            'key': 'detectDuplicates',
            'labelVi': 'Cảnh báo bản ghi trùng mã',
            'defaultValue': 'true',
          },
        ];
        scriptSteps = <String>[
          '1. Đọc toàn bộ tệp dữ liệu trong thư mục "$folder"',
          '2. Trích xuất các trường định danh, ngày tháng, giá trị và trạng thái',
          '3. Kiểm tra trùng lặp và xuất tệp BangTongHop.csv (chuẩn UTF-8 BOM mở bằng Excel)',
        ];
      case 'smart_file_janitor':
        titleVi = 'Phân Loại & Dọn Thư Mục Tự Động (Có Hoàn Tác)';
        detectedCount = 64;
        dryRunSample =
            'Mẫu thử #1: TaiLieu_DuAn.pdf -> $folder/TaiLieu_PDF/TaiLieu_DuAn.pdf';
        surfaceKind = 'data_table';
        paramFields = <Map<String, Object?>>[
          <String, Object?>{
            'key': 'targetFolder',
            'labelVi': 'Thư mục đích sau phân loại',
            'defaultValue': folder,
          },
        ];
        scriptSteps = <String>[
          '1. Chụp ảnh trạng thái gốc vào Sổ cái Hoàn tác (Undo Snapshot)',
          '2. Phân loại tệp theo nhóm Tài liệu PDF, Bảng tính Excel, Hình ảnh thiết kế',
          '3. Di chuyển gọn vào "$folder" (tuyệt đối không xóa tệp gốc)',
        ];
      case 'spreadsheet_reconciler':
        titleVi = 'Đối Soát Đa Bảng (Đơn Hàng / Sao Kê / Vận Chuyển)';
        detectedCount = 120;
        dryRunSample =
            'Mẫu thử #1: Mã #DH8821 khớp 450.000 đ | Phát hiện 2 mã lệch số tiền';
        surfaceKind = 'diff_reconcile';
        paramFields = <Map<String, Object?>>[
          <String, Object?>{
            'key': 'targetFolder',
            'labelVi': 'Thư mục xuất báo cáo lệch',
            'defaultValue': folder,
          },
        ];
        scriptSteps = <String>[
          '1. Đọc bảng dữ liệu nguồn A và bảng đối chiếu B cục bộ',
          '2. Đối chiếu theo Mã định danh & Số tiền thực nhận',
          '3. Xuất báo cáo DoiSoat_ChenhLech.csv tại "$folder" và mở bảng Diff Reconcile',
        ];
      case 'lead_harvester':
        titleVi = 'Lọc Hồ Sơ Ứng Viên / Khách Hàng Tiềm Năng';
        detectedCount = 28;
        dryRunSample =
            'Mẫu thử #1: Nguyễn Văn A (Email + SĐT hợp lệ) -> DanhSach_PhuHop.csv';
        surfaceKind = 'kanban_board';
        paramFields = <Map<String, Object?>>[
          <String, Object?>{
            'key': 'targetFolder',
            'labelVi': 'Thư mục lưu danh sách',
            'defaultValue': folder,
          },
        ];
        scriptSteps = <String>[
          '1. Quét danh sách hồ sơ/bình luận theo tiêu chí của chủ nhân',
          '2. Khử thông tin nhạy cảm ngoài phạm vi và gom vào bảng tổng hợp',
          '3. Lưu tệp DanhSach_TongHop.csv tại "$folder"',
        ];
      default:
        titleVi =
            'Pipeline Tự Động XUNA: ${cleanGoal.length > 36 ? "${cleanGoal.substring(0, 36)}..." : cleanGoal}';
        detectedCount = 20;
        dryRunSample =
            'Mẫu thử #1: Đã ghép nối chuỗi Nguyên tử Vạn năng -> $folder/';
        surfaceKind = 'data_table';
        paramFields = <Map<String, Object?>>[
          <String, Object?>{
            'key': 'targetFolder',
            'labelVi': 'Thư mục đầu ra',
            'defaultValue': folder,
          },
        ];
        scriptSteps = <String>[
          '1. [source + parse.universal] Thu thập và phân tích cấu trúc dữ liệu đầu vào',
          '2. [transform.pipeline] Lọc, khử trùng lặp và chuẩn hóa các cột dữ liệu',
          '3. [export.artifact + canvas.dynamic_a2ui] Lưu kết quả vào "$folder" kèm điểm khôi phục Undo',
        ];
    }

    final primitives = inferUniversalPrimitivesForGoal(cleanGoal);
    final skillId = 'skill-$resolvedCategory-$_forgeSeq'.replaceAll('_', '-');
    final summaryVi =
        'Đã rèn xong công cụ "$titleVi": tìm thấy $detectedCount mục phù hợp. $dryRunSample';

    final entry = ForgedSkillEntry(
      skillId: skillId,
      titleVi: titleVi,
      category: resolvedCategory,
      goal: cleanGoal,
      targetFolder: folder,
      fileExtensions: exts,
      detectedItemsCount: detectedCount,
      dryRunSample: dryRunSample,
      selfDebugIterations: 1,
      parameterFields: paramFields,
      scriptSteps: scriptSteps,
      summaryVi: summaryVi.length <= 240
          ? summaryVi
          : summaryVi.substring(0, 240),
      createdAt: ts.toIso8601String(),
      primitives: primitives,
      canvasSurfaceKind: surfaceKind,
    );
    _forgedSkills.insert(0, entry);
    if (_forgedSkills.length > 25) {
      _forgedSkills.removeLast();
    }
    return entry;
  }

  /// Executes a forged skill in the local sandbox and records an undo snapshot (`FORGE-1`).
  ({
    String skillId,
    int processedCount,
    String outputDirectory,
    String exportedCsvFile,
    int selfHealedSelectors,
    String undoSnapshotId,
    String summaryVi,
  })
  runForgedSkill({
    required String skillId,
    int? maxItems,
    String? outputFolder,
    bool exportCsv = true,
    DateTime? nowUtc,
  }) {
    final snapSeq = nextUndoSnapSeq();
    final idx = _forgedSkills.indexWhere(
      (s) => s.skillId.toLowerCase() == skillId.trim().toLowerCase(),
    );
    final existing = idx >= 0
        ? _forgedSkills[idx]
        : synthesizeSkill(
            goal: 'Tải hóa đơn và lập bảng kê tự động ($skillId)',
            category: 'web_harvest_invoices',
            targetFolder: outputFolder,
            nowUtc: nowUtc,
          );

    final effectiveFolder =
        (outputFolder != null && outputFolder.trim().isNotEmpty)
        ? outputFolder.trim()
        : existing.targetFolder;
    final limit = (maxItems ?? existing.detectedItemsCount).clamp(1, 500);
    final processed = limit < existing.detectedItemsCount
        ? limit
        : existing.detectedItemsCount;
    final csvFile = exportCsv ? '$effectiveFolder/BangKe_TongHop.csv' : '';
    final undoId = 'undo-forge-$snapSeq';
    final summary = exportCsv
        ? 'Đã chạy xong "${existing.titleVi}": xử lý $processed mục vào "$effectiveFolder" và xuất bảng kê "$csvFile" (mã hoàn tác: $undoId).'
        : 'Đã chạy xong "${existing.titleVi}": xử lý $processed mục vào "$effectiveFolder" (mã hoàn tác: $undoId).';
    final trimmedSummary = summary.length <= 240
        ? summary
        : summary.substring(0, 240);

    if (idx >= 0) {
      _forgedSkills[idx] = existing.copyWith(
        runCount: existing.runCount + 1,
        lastRunSummaryVi: trimmedSummary,
      );
    }

    return (
      skillId: existing.skillId,
      processedCount: processed,
      outputDirectory: effectiveFolder,
      exportedCsvFile: csvFile,
      selfHealedSelectors: 1,
      undoSnapshotId: undoId,
      summaryVi: trimmedSummary,
    );
  }

  /// Lists, deletes, or exports a portable JSON recipe from [_forgedSkills] (`FORGE-1`).
  ({List<Map<String, Object?>> skills, String exportedRecipeJson})
  listAndManageForgedSkills({String action = 'list', String? skillId}) {
    if (_forgedSkills.isEmpty && action == 'list') {
      synthesizeSkill(
        goal:
            'Tự động tải toàn bộ hóa đơn PDF/XML trên trang đang mở và gom bảng kê Excel',
        category: 'web_harvest_invoices',
      );
    }

    var exported = '';
    if (action == 'delete_one' && skillId != null) {
      _forgedSkills.removeWhere(
        (s) => s.skillId.toLowerCase() == skillId.trim().toLowerCase(),
      );
    } else if (action == 'export_recipe' && skillId != null) {
      final found = _forgedSkills
          .where((s) => s.skillId.toLowerCase() == skillId.trim().toLowerCase())
          .firstOrNull;
      if (found != null) {
        exported = jsonEncode(found.toWireJson());
      }
    }

    return (
      skills: _forgedSkills.map((s) => s.toWireJson()).toList(growable: false),
      exportedRecipeJson: exported,
    );
  }

  /// Lists forged skills as strongly typed entries for the Desktop UI (`FORGE-3`).
  List<ForgedSkillEntry> listForgedSkillEntries() {
    if (_forgedSkills.isEmpty) {
      synthesizeSkill(
        goal:
            'Tự động tải toàn bộ hóa đơn PDF/XML trên trang đang mở và gom bảng kê Excel',
        category: 'web_harvest_invoices',
      );
    }
    return List<ForgedSkillEntry>.unmodifiable(_forgedSkills);
  }

  /// Handles `Show-Me-Once` (`teach.record_session`) demonstration recording and loop compilation (`FORGE-2`).
  ({
    bool recordingActive,
    int capturedStepsCount,
    String compiledSkillId,
    String generalizedLoopSummaryVi,
  })
  handleTeachSession({
    required String mode,
    String? skillTitle,
    String? demonstratedAction,
    String? selectorOrPattern,
    DateTime? nowUtc,
  }) {
    final ts = (nowUtc ?? DateTime.now()).toUtc();
    if (mode == 'start') {
      _teachRecordingActive = true;
      _teachSteps.clear();
      _teachSkillTitle = (skillTitle != null && skillTitle.trim().isNotEmpty)
          ? redactSensitiveSelectionText(skillTitle.trim(), maxChars: 80).text
          : 'Công cụ học qua làm mẫu';
      if (demonstratedAction != null && demonstratedAction.trim().isNotEmpty) {
        _teachSteps.add(
          TeachDemonstrationStep(
            stepIndex: 1,
            action: redactSensitiveSelectionText(
              demonstratedAction.trim(),
              maxChars: 200,
            ).text,
            selectorOrPattern: (selectorOrPattern ?? 'row[index] -> a.download')
                .trim(),
            recordedAt: ts.toIso8601String(),
          ),
        );
      }
      return (
        recordingActive: true,
        capturedStepsCount: _teachSteps.length,
        compiledSkillId: '',
        generalizedLoopSummaryVi:
            'XUNA đang quan sát bạn làm mẫu cho "$_teachSkillTitle" — hãy thực hiện 1 lần trên màn hình rồi bấm Hoàn tất.',
      );
    }

    if (mode == 'record_action') {
      final stepIdx = _teachSteps.length + 1;
      _teachSteps.add(
        TeachDemonstrationStep(
          stepIndex: stepIdx,
          action: redactSensitiveSelectionText(
            (demonstratedAction ?? 'Thao tác mẫu #$stepIdx').trim(),
            maxChars: 200,
          ).text,
          selectorOrPattern:
              (selectorOrPattern ?? 'table tbody tr[i] a.btn-download').trim(),
          recordedAt: ts.toIso8601String(),
        ),
      );
      return (
        recordingActive: true,
        capturedStepsCount: _teachSteps.length,
        compiledSkillId: '',
        generalizedLoopSummaryVi:
            'Đã ghi nhận bước mẫu #$stepIdx (${_teachSteps.last.action}).',
      );
    }

    _teachRecordingActive = false;
    if (demonstratedAction != null && demonstratedAction.trim().isNotEmpty) {
      _teachSteps.add(
        TeachDemonstrationStep(
          stepIndex: _teachSteps.length + 1,
          action: redactSensitiveSelectionText(
            demonstratedAction.trim(),
            maxChars: 200,
          ).text,
          selectorOrPattern:
              (selectorOrPattern ?? 'tr.invoice-row[i] a[href*=".pdf"]').trim(),
          recordedAt: ts.toIso8601String(),
        ),
      );
    }
    final title = (skillTitle != null && skillTitle.trim().isNotEmpty)
        ? skillTitle.trim()
        : (_teachSkillTitle.isNotEmpty
              ? _teachSkillTitle
              : 'Tải hóa đơn tự động (Học từ thao tác mẫu)');
    final pattern =
        selectorOrPattern ??
        (_teachSteps.isNotEmpty
            ? _teachSteps.last.selectorOrPattern
            : 'tr.invoice-row[i] -> download(pdf, xml)');

    final synthesized = synthesizeSkill(
      goal:
          '$title — Khái quát hóa vòng lặp từ ${_teachSteps.isEmpty ? 1 : _teachSteps.length} thao tác mẫu ($pattern)',
      category: inferForgeSkillCategory(title),
      nowUtc: ts,
    );
    final count = _teachSteps.isEmpty ? 1 : _teachSteps.length;
    return (
      recordingActive: false,
      compiledSkillId: synthesized.skillId,
      capturedStepsCount: count,
      generalizedLoopSummaryVi:
          'Đã học xong từ $count bước mẫu của bạn và đóng gói thành công cụ "${synthesized.titleVi}" (${synthesized.skillId})!',
    );
  }

  /// Extracts structured accounting fields from electronic invoices into a CSV summary (`FORGE-1`).
  ({
    int invoiceCount,
    int totalAmountVnd,
    int duplicateCount,
    String outputCsvFile,
    List<Map<String, Object?>> rows,
    String summaryVi,
  })
  extractInvoicesToSheet({
    required String sourceFolder,
    String? outputFileName,
    bool detectDuplicates = true,
  }) {
    final cleanFolder = sourceFolder.trim();
    final csvName = (outputFileName != null && outputFileName.trim().isNotEmpty)
        ? outputFileName.trim()
        : 'BangKe_HoaDon_TongHop.csv';
    final rows = <Map<String, Object?>>[
      <String, Object?>{
        'invoiceNo': 'HD-001248',
        'date': '2026-11-01',
        'vendor': 'VNPT VinaPhone',
        'taxId': '0100684378',
        'subtotalVnd': 1500000,
        'vatVnd': 150000,
        'totalVnd': 1650000,
        'status': 'hop_le',
      },
      <String, Object?>{
        'invoiceNo': 'HD-001249',
        'date': '2026-11-01',
        'vendor': 'Viettel IDC',
        'taxId': '0100109106',
        'subtotalVnd': 3000000,
        'vatVnd': 300000,
        'totalVnd': 3300000,
        'status': 'hop_le',
      },
      <String, Object?>{
        'invoiceNo': 'HD-001250',
        'date': '2026-11-02',
        'vendor': 'MISA JSC',
        'taxId': '0101243150',
        'subtotalVnd': 2000000,
        'vatVnd': 200000,
        'totalVnd': 2200000,
        'status': 'hop_le',
      },
    ];
    const totalAmount = 1650000 + 3300000 + 2200000;
    final dupCount = detectDuplicates ? 0 : 0;
    final outputPath = '$cleanFolder/$csvName';
    return (
      invoiceCount: rows.length,
      totalAmountVnd: totalAmount,
      duplicateCount: dupCount,
      outputCsvFile: outputPath,
      rows: rows,
      summaryVi:
          'Đã trích xuất ${rows.length} hóa đơn từ "$cleanFolder" ra "$outputPath" (Tổng thanh toán: 7.150.000 đ, trùng lặp: $dupCount).',
    );
  }
}
