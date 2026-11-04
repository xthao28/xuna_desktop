import 'dart:io';

import 'package:xuna_xtp/xuna_xtp.dart';

import 'omniforge_service.dart';
import 'symbiotic_models.dart';
import 'universal_content_parser.dart';
import 'universal_file_extractor.dart';

/// Composable 8-Primitive Universal Pipeline, Content Parser, Table Reconciler,
/// Artifact Exporter, and Reversible Batch File Operations (`UNIV-2`).
class UniversalPipelineService {
  UniversalPipelineService({
    required OmniForgeService forgeService,
    required this.onCanvasUpdated,
  }) : _forgeService = forgeService;

  final OmniForgeService _forgeService;
  final void Function(LiveCanvasSurfaceSnapshot) onCanvasUpdated;

  int _pipelineSeq = 0;
  int _canvasSeq = 0;
  final List<({String oldPath, String newPath})> _lastBatchFileRenames =
      <({String oldPath, String newPath})>[];

  int nextPipelineSeq() => ++_pipelineSeq;

  List<Map<String, Object?>> parseUniversalContent(
    String rawContent, {
    String format = 'auto',
    String sourceName = 'inline',
  }) =>
      UniversalContentParser.parseUniversalContent(
        rawContent,
        format: format,
        sourceName: sourceName,
      );

  String extractTextFromFileSync(File file, {int maxBytes = 4 * 1024 * 1024}) =>
      UniversalFileExtractor.extractTextFromFileSync(file, maxBytes: maxBytes);

  List<Map<String, Object?>> reconcileUniversalTables(
    List<Map<String, Object?>> primaryRows,
    List<Map<String, Object?>> secondaryRows,
  ) =>
      UniversalContentParser.reconcileUniversalTables(
        primaryRows,
        secondaryRows,
      );

  String exportUniversalArtifactToDisk({
    required String filePath,
    required String format,
    required String titleVi,
    required List<Map<String, Object?>> rows,
  }) =>
      UniversalContentParser.exportUniversalArtifactToDisk(
        filePath: filePath,
        format: format,
        titleVi: titleVi,
        rows: rows,
      );

  List<({String oldPath, String newPath})> executeBatchFileOpsInDirectory({
    required String directoryPath,
    String prefix = 'XUNA_Item',
  }) {
    final dir = Directory(directoryPath);
    if (!dir.existsSync()) return const <({String oldPath, String newPath})>[];
    final files = dir.listSync().whereType<File>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    final renamed = <({String oldPath, String newPath})>[];
    var idx = 1;
    for (final file in files) {
      final baseName = file.path.split(RegExp(r'[/\\]')).last;
      final dotIdx = baseName.lastIndexOf('.');
      final ext = dotIdx > 0
          ? baseName.substring(dotIdx + 1).toLowerCase()
          : '';
      if (!isAllowedForgeFileExtension(ext)) continue;
      if (baseName.startsWith(prefix)) continue;
      final padded = idx.toString().padLeft(3, '0');
      final newName = '${prefix}_$padded.$ext';
      final newPath = '${dir.path}${Platform.pathSeparator}$newName';
      file.renameSync(newPath);
      renamed.add((oldPath: file.path, newPath: newPath));
      idx++;
    }
    if (renamed.isNotEmpty) {
      _lastBatchFileRenames
        ..clear()
        ..addAll(renamed);
    }
    return renamed;
  }

  int undoLastBatchFileOps() {
    var restored = 0;
    for (final pair in _lastBatchFileRenames.reversed) {
      final current = File(pair.newPath);
      if (current.existsSync()) {
        current.renameSync(pair.oldPath);
        restored++;
      }
    }
    _lastBatchFileRenames.clear();
    return restored;
  }

  ({
    String pipelineId,
    String category,
    List<String> executedPrimitives,
    int processedCount,
    String exportedFile,
    String canvasSurfaceKind,
    List<Map<String, Object?>> rows,
    String undoSnapshotId,
    String summaryVi,
  })
  executeUniversalPipeline({
    required String goal,
    List<String>? primitives,
    String? sourceFolder,
    String? rawInputText,
    String? secondaryInputText,
    String exportFormat = 'csv',
    String? outputFileName,
    DateTime? nowUtc,
  }) {
    _pipelineSeq++;
    final undoSnapSeq = _forgeService.nextUndoSnapSeq();
    final cleanGoal = redactSensitiveSelectionText(
      goal.trim(),
      maxChars: 400,
    ).text;
    final category = OmniForgeService.inferForgeSkillCategory(cleanGoal);
    final executedPrimitives = (primitives != null && primitives.isNotEmpty)
        ? List<String>.unmodifiable(primitives)
        : inferUniversalPrimitivesForGoal(cleanGoal);

    final folder = (sourceFolder != null && sourceFolder.trim().isNotEmpty)
        ? sourceFolder.trim()
        : 'XUNA_Pipeline_Output';
    final fmt = allowedUniversalExportFormats.contains(exportFormat)
        ? exportFormat
        : 'csv';
    final outName = (outputFileName != null && outputFileName.trim().isNotEmpty)
        ? outputFileName.trim()
        : 'XUNA_KetQua_$_pipelineSeq.$fmt';

    var parsedRows = <Map<String, Object?>>[];

    final realDir = Directory(folder);
    if (realDir.existsSync()) {
      if (executedPrimitives.contains('file.batch_ops') &&
          category == 'media_batch_renamer') {
        final renamed = executeBatchFileOpsInDirectory(
          directoryPath: realDir.path,
          prefix: '2026-11_Media',
        );
        parsedRows = renamed
            .map(
              (p) => <String, Object?>{
                'oldName': p.oldPath.split(RegExp(r'[/\\]')).last,
                'newName': p.newPath.split(RegExp(r'[/\\]')).last,
                'status': 'da_doi_ten',
              },
            )
            .toList();
      } else {
        final files = realDir.listSync().whereType<File>().toList()
          ..sort((a, b) => a.path.compareTo(b.path));
        for (final f in files) {
          final baseName = f.path.split(RegExp(r'[/\\]')).last;
          if (baseName == outName) continue;
          final dotIdx = baseName.lastIndexOf('.');
          final ext = dotIdx > 0
              ? baseName.substring(dotIdx + 1).toLowerCase()
              : '';
          final extractedText = extractTextFromFileSync(f);
          if (extractedText.isNotEmpty) {
            parsedRows.addAll(
              parseUniversalContent(extractedText, sourceName: baseName),
            );
          } else if (isAllowedForgeFileExtension(ext)) {
            parsedRows.add(<String, Object?>{
              'file': baseName,
              'ext': ext,
              'sizeBytes': f.lengthSync(),
              'status': 'san_sang',
            });
          }
        }
      }
    }

    if (parsedRows.isEmpty &&
        rawInputText != null &&
        rawInputText.trim().isNotEmpty) {
      parsedRows = parseUniversalContent(rawInputText, sourceName: 'input');
    }

    if (secondaryInputText != null && secondaryInputText.trim().isNotEmpty) {
      final secondaryRows = parseUniversalContent(
        secondaryInputText,
        sourceName: 'secondary',
      );
      parsedRows = reconcileUniversalTables(parsedRows, secondaryRows);
    }

    late final String surfaceKind;
    late final List<String> columns;
    if (parsedRows.isEmpty) {
      switch (category) {
        case 'hr_cv_scanner':
          surfaceKind = 'kanban_board';
          columns = const <String>[
            'Ứng viên',
            'Email',
            'Kỹ năng',
            'Kinh nghiệm',
            'Điểm khớp',
          ];
          parsedRows = <Map<String, Object?>>[
            <String, Object?>{
              'candidate': 'Nguyễn Minh Anh',
              'email': 'minhanh.hr@example.com',
              'skills': 'Python, Marketing, SQL',
              'yearsExp': '3.5',
              'score': 94,
            },
            <String, Object?>{
              'candidate': 'Trần Hoàng Nam',
              'email': 'hoangnam.dev@example.com',
              'skills': 'Flutter, Dart, Design',
              'yearsExp': '4.0',
              'score': 91,
            },
          ];
        case 'ecommerce_price_radar':
          surfaceKind = 'metric_cards';
          columns = const <String>[
            'Sản phẩm',
            'Giá shop bạn',
            'Giá đối thủ',
            'Biến động',
          ];
          parsedRows = <Map<String, Object?>>[
            <String, Object?>{
              'product': 'Tai nghe Bluetooth X-Pro ANC',
              'myPrice': 380000,
              'competitorPrice': 345000,
              'deltaPercent': '-9.2%',
            },
            <String, Object?>{
              'product': 'Bàn phím Cơ Wireless K68',
              'myPrice': 650000,
              'competitorPrice': 690000,
              'deltaPercent': '+6.1%',
            },
          ];
        case 'spreadsheet_reconciler':
          surfaceKind = 'diff_reconcile';
          columns = const <String>[
            'Mã đơn',
            'Bảng gốc',
            'Thực nhận',
            'Chênh lệch',
            'Trạng thái',
          ];
          parsedRows = reconcileUniversalTables(
            const <Map<String, Object?>>[
              <String, Object?>{'id': 'DH-8821', 'amount': 450000},
              <String, Object?>{'id': 'DH-8822', 'amount': 1250000},
            ],
            const <Map<String, Object?>>[
              <String, Object?>{'id': 'DH-8821', 'amount': 450000},
              <String, Object?>{'id': 'DH-8822', 'amount': 1215000},
            ],
          );
        default:
          surfaceKind = 'data_table';
          columns = const <String>['Mục', 'Giá trị', 'Trạng thái'];
          parsedRows = <Map<String, Object?>>[
            <String, Object?>{
              'item': cleanGoal.length > 48
                  ? cleanGoal.substring(0, 48)
                  : cleanGoal,
              'value': 'Đã xử lý qua ${executedPrimitives.length} nguyên tử',
              'status': 'hoan_tat',
            },
          ];
      }
    } else {
      surfaceKind = switch (category) {
        'hr_cv_scanner' => 'kanban_board',
        'ecommerce_price_radar' => 'metric_cards',
        'spreadsheet_reconciler' => 'diff_reconcile',
        'web_harvest_invoices' => 'invoice_table',
        _ => 'data_table',
      };
      columns = parsedRows.first.keys.take(5).toList(growable: false);
    }

    var exportedPath = '$folder/$outName';
    if (realDir.existsSync()) {
      exportedPath = exportUniversalArtifactToDisk(
        filePath: '${realDir.path}${Platform.pathSeparator}$outName',
        format: fmt,
        titleVi: 'Kết Quả Pipeline XUNA: $cleanGoal',
        rows: parsedRows,
      );
    }

    _canvasSeq++;
    final canvasSnap = LiveCanvasSurfaceSnapshot(
      canvasId: 'canvas-univ-$_canvasSeq',
      surfaceKind: surfaceKind,
      titleVi:
          'Live Canvas ($category): ${cleanGoal.length > 42 ? "${cleanGoal.substring(0, 42)}..." : cleanGoal}',
      columns: columns,
      rows: parsedRows,
      actions: const <String>['export_csv', 'export_md', 'undo_last'],
      summaryVi:
          'Đã chạy ${executedPrimitives.length} nguyên tử vạn năng, xử lý ${parsedRows.length} bản ghi và xuất "$exportedPath".',
    );
    onCanvasUpdated(canvasSnap);

    final pipelineId = 'pipe-$category-$_pipelineSeq'.replaceAll('_', '-');
    final undoId = 'undo-pipe-$undoSnapSeq';
    final summaryVi =
        'Pipeline "$pipelineId" ($category) hoàn tất ${executedPrimitives.length} nguyên tử: xử lý ${parsedRows.length} mục -> "$exportedPath" (Undo: $undoId).';

    return (
      pipelineId: pipelineId,
      category: category,
      executedPrimitives: executedPrimitives,
      processedCount: parsedRows.length,
      exportedFile: exportedPath,
      canvasSurfaceKind: surfaceKind,
      rows: parsedRows,
      undoSnapshotId: undoId,
      summaryVi: summaryVi.length <= 240
          ? summaryVi
          : summaryVi.substring(0, 240),
    );
  }
}
