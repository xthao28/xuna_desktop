import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

import 'heartbeat_canvas_service.dart';
import 'symbiotic_models.dart';
import 'workspace_pocket_service.dart';

/// Bi-temporal knowledge graph edge for `XUNA ChronoGraph` (`FRONTIER-3`).
class TemporalGraphEdge {
  const TemporalGraphEdge({
    required this.edgeId,
    required this.subject,
    required this.predicate,
    required this.object,
    required this.validFromIso,
    this.validUntilIso,
    required this.status,
    this.supersededByEdgeId,
  });

  final String edgeId;
  final String subject;
  final String predicate;
  final String object;
  final String validFromIso;
  final String? validUntilIso;
  final String status; // 'active' | 'historical'
  final String? supersededByEdgeId;

  TemporalGraphEdge copyWith({
    String? validUntilIso,
    String? status,
    String? supersededByEdgeId,
  }) {
    return TemporalGraphEdge(
      edgeId: edgeId,
      subject: subject,
      predicate: predicate,
      object: object,
      validFromIso: validFromIso,
      validUntilIso: validUntilIso ?? this.validUntilIso,
      status: status ?? this.status,
      supersededByEdgeId: supersededByEdgeId ?? this.supersededByEdgeId,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'edgeId': edgeId,
    'subject': subject,
    'predicate': predicate,
    'object': object,
    'validFromIso': validFromIso,
    if (validUntilIso != null) 'validUntilIso': validUntilIso,
    'status': status,
    if (supersededByEdgeId != null) 'supersededByEdgeId': supersededByEdgeId,
  };
}

/// Sub-service for 2026 Next-Generation Frontier capabilities (`FRONTIER-1`..`FRONTIER-4`):
/// 1. `companion.overlay_and_drop` — Living Overlay (macOS Notch / Windows Corner) & Feed-to-Process Drop-Zone
/// 2. `acoustic.vocalize_and_sense` — Procedural 16-bit PCM Bio-Acoustic Vocalizer & Prosody Empathy
/// 3. `memory.temporal_graph` — `ChronoGraph` Bi-Temporal Knowledge Graph & Memory Constellation
/// 4. `ritual.mindful_and_playdate` — 4-7-8 Co-Breathing, Symbiotic Pomodoro, OLED StandBy Dock & Neighbor Playdate
class Frontier2026Service {
  Frontier2026Service({
    required WorkspacePocketService pocketService,
    required HeartbeatCanvasService canvasService,
  }) : _pocketService = pocketService,
       _canvasService = canvasService {
    _seedDefaultTemporalEdges();
  }

  final WorkspacePocketService _pocketService;
  final HeartbeatCanvasService _canvasService;

  bool _overlayVisible = true;
  String _overlayAnchor = 'mac_notch';
  String _lastMunchAnimation = 'idle_float';
  String _lastVocalKind = 'happy_chirp';
  String _lastDetectedTone = 'warm_relaxed';
  String _activeColorThemeId = 'green_edition';
  bool _standbyDockActive = false;
  String _activeRitual = 'none';
  final List<String> _unlockedKeepsakes = <String>[
    'Mầm Cây Pixel Xanh Lá (Khởi nguyên)',
  ];
  final List<TemporalGraphEdge> _temporalEdges = <TemporalGraphEdge>[];

  bool get overlayVisible => _overlayVisible;
  String get overlayAnchor => _overlayAnchor;
  String get lastMunchAnimation => _lastMunchAnimation;
  String get lastVocalKind => _lastVocalKind;
  String get lastDetectedTone => _lastDetectedTone;
  String get activeColorThemeId => _activeColorThemeId;
  bool get standbyDockActive => _standbyDockActive;
  String get activeRitual => _activeRitual;
  List<TemporalGraphEdge> get temporalEdges =>
      List<TemporalGraphEdge>.unmodifiable(_temporalEdges);

  void syncColorTheme(String themeId, {DateTime? nowUtc}) {
    final cleaned = themeId.trim().toLowerCase();
    if (cleaned.isEmpty) return;
    final normalized = switch (cleaned) {
      'forest_mint' || 'theme_02' || 'theme_02_forest_mint' => 'forest_mint',
      'seafoam' || 'theme_03' || 'theme_03_seafoam' => 'seafoam',
      'lavender_dream' ||
      'theme_04' ||
      'theme_04_lavender_dream' =>
        'lavender_dream',
      'sunny_gold' || 'theme_05' || 'theme_05_sunny_gold' => 'sunny_gold',
      'sky_blue' || 'theme_06' || 'theme_06_sky_blue' => 'sky_blue',
      'berry_candy' || 'theme_07' || 'theme_07_berry_candy' => 'berry_candy',
      _ => 'green_edition',
    };
    if (_activeColorThemeId == normalized) return;
    _activeColorThemeId = normalized;
    final label = switch (normalized) {
      'forest_mint' => 'Forest Mint (#86A668)',
      'seafoam' => 'Seafoam (#6EACA8)',
      'lavender_dream' => 'Lavender Dream (#A191C7)',
      'sunny_gold' => 'Sunny Gold (#EDB264)',
      'sky_blue' => 'Sky Blue (#71A0D6)',
      'berry_candy' => 'Berry Candy (#D8858D)',
      _ => 'Green Edition (#8FB06B)',
    };
    manageTemporalLifeGraph(
      mode: 'record_fact',
      subject: 'XUNA',
      predicate: 'bảng_màu_yêu_thích',
      object: label,
      nowUtc: nowUtc,
    );
  }

  void _seedDefaultTemporalEdges() {
    if (_temporalEdges.isNotEmpty) return;
    _temporalEdges.addAll(const <TemporalGraphEdge>[
      TemporalGraphEdge(
        edgeId: 'edge_01',
        subject: 'Chủ nhân',
        predicate: 'đang_tập_trung_dự_án',
        object: 'Khởi tạo Mạch ESP32-S3 & BLE M02',
        validFromIso: '2026-10-11T08:00:00Z',
        validUntilIso: '2026-10-25T08:00:00Z',
        status: 'historical',
        supersededByEdgeId: 'edge_02',
      ),
      TemporalGraphEdge(
        edgeId: 'edge_02',
        subject: 'Chủ nhân',
        predicate: 'đang_tập_trung_dự_án',
        object: 'Hệ sinh thái Cộng sinh Đa nền tảng XUNA',
        validFromIso: '2026-10-25T08:00:00Z',
        status: 'active',
      ),
      TemporalGraphEdge(
        edgeId: 'edge_03',
        subject: 'XUNA',
        predicate: 'bảng_màu_yêu_thích',
        object: 'Green Edition (#8FB06B)',
        validFromIso: '2026-11-02T00:00:00Z',
        status: 'active',
      ),
    ]);
  }

  /// `FRONTIER-1`: Living Overlay & Drag-and-Drop Feed-to-Process (`companion.overlay_and_drop`).
  ({
    String mode,
    bool overlayVisible,
    String anchor,
    String munchAnimation,
    String routedTarget,
    int redactedSecretsCount,
    String summaryVi,
  })
  manageOverlayAndDropZone({
    required String mode,
    String? anchor,
    String? droppedItemName,
    String? droppedContent,
    String? targetAction,
    DateTime? nowUtc,
  }) {
    final now = (nowUtc ?? DateTime.now()).toUtc();
    if (anchor != null && anchor.trim().isNotEmpty) {
      _overlayAnchor = anchor.trim();
    }
    if (mode == 'toggle_overlay') {
      _overlayVisible = !_overlayVisible;
      _lastMunchAnimation = _overlayVisible ? 'greet_peek' : 'sleep_tuck';
      return (
        mode: mode,
        overlayVisible: _overlayVisible,
        anchor: _overlayAnchor,
        munchAnimation: _lastMunchAnimation,
        routedTarget: 'overlay_window',
        redactedSecretsCount: 0,
        summaryVi: _overlayVisible
            ? 'XUNA đã hiện diện trên mép màn hình ($_overlayAnchor), sẵn sàng nhận tệp kéo-thả.'
            : 'Đã thu gọn XUNA Overlay về khay hệ thống.',
      );
    }

    if (mode == 'set_anchor') {
      _overlayVisible = true;
      _lastMunchAnimation = 'happy_hop';
      return (
        mode: mode,
        overlayVisible: _overlayVisible,
        anchor: _overlayAnchor,
        munchAnimation: _lastMunchAnimation,
        routedTarget: 'overlay_anchor',
        redactedSecretsCount: 0,
        summaryVi: 'Đã neo XUNA Living Overlay tại vị trí $_overlayAnchor.',
      );
    }

    if (mode == 'feed_drop_item') {
      final itemName = (droppedItemName ?? 'dropped_snippet.txt').trim();
      final rawContent =
          (droppedContent ?? 'Tệp kéo thả trực tiếp vào miệng XUNA: $itemName')
              .trim();
      final redacted = redactSensitiveSelectionText(rawContent);
      final redactedCount = redacted.redactedCount;

      final lowerName = itemName.toLowerCase();
      final String routed;
      if (targetAction != null && targetAction.trim().isNotEmpty) {
        routed = targetAction.trim();
      } else if (lowerName.endsWith('.csv') ||
          lowerName.contains('hoa_don') ||
          lowerName.contains('invoice')) {
        routed = 'omniforge_invoice_pipeline';
      } else if (lowerName.endsWith('.json') ||
          lowerName.endsWith('.dart') ||
          lowerName.endsWith('.py')) {
        routed = 'universal_pocket_code';
      } else {
        routed = 'xuna_beam_transfer';
      }

      _overlayVisible = true;
      _lastMunchAnimation = 'munch_sparkle';
      _pocketService.pushPocketItem(
        rawText: '$itemName: ${redacted.text}',
        label: itemName,
        sourceDevice: 'overlay_drop_zone',
        nowUtc: now,
      );

      return (
        mode: mode,
        overlayVisible: _overlayVisible,
        anchor: _overlayAnchor,
        munchAnimation: _lastMunchAnimation,
        routedTarget: routed,
        redactedSecretsCount: redactedCount,
        summaryVi:
            'XUNA ($_overlayAnchor) đã "măm" tệp "$itemName" (hiệu ứng $_lastMunchAnimation, lọc $redactedCount khóa nhạy cảm) và chuyển vào $routed.',
      );
    }

    return (
      mode: 'status',
      overlayVisible: _overlayVisible,
      anchor: _overlayAnchor,
      munchAnimation: _lastMunchAnimation,
      routedTarget: 'overlay_ready',
      redactedSecretsCount: 0,
      summaryVi:
          'XUNA Overlay đang ${_overlayVisible ? "bật" : "ẩn"} tại $_overlayAnchor (hoạt ảnh: $_lastMunchAnimation).',
    );
  }

  /// `FRONTIER-2`: Procedural 16-bit PCM Bio-Acoustic Vocalizer & Prosody Sensing (`acoustic.vocalize_and_sense`).
  ({
    String mode,
    String vocalKind,
    int sampleRateHz,
    int pcmByteCount,
    String wavSha256,
    String detectedOwnerTone,
    String empathyAdjustmentVi,
    String summaryVi,
  })
  vocalizeAndSenseProsody({
    required String mode,
    String? vocalKind,
    String? themeId,
    int? speechRateWpm,
    int? rmsEnergyDb,
    int? pauseRatioPercent,
  }) {
    final kind = (vocalKind ?? _lastVocalKind).trim();
    _lastVocalKind = kind;
    if (themeId != null && themeId.trim().isNotEmpty) {
      syncColorTheme(themeId);
    }
    const sampleRate = 16000;
    const numSamples = 2880; // 180 ms @ 16 kHz
    const pcmBytesLen = numSamples * 2;

    // Synthesize real 16-bit mono RIFF WAV with harmonic F0 contour + vibrato
    final wavBytes = _synthesizeBioAcousticWav(
      vocalKind: kind,
      themeId: themeId ?? _activeColorThemeId,
      sampleRate: sampleRate,
      numSamples: numSamples,
    );
    final digest = sha256.convert(wavBytes).toString();

    final wpm = speechRateWpm ?? 125;
    final rms = rmsEnergyDb ?? -18;
    final pause = pauseRatioPercent ?? 15;

    final String tone;
    final String adjustmentVi;
    if (wpm < 110 || rms <= -24 || pause >= 35) {
      tone = 'tired_low_energy';
      adjustmentVi =
          'Phát hiện giọng chủ nhân trầm và chậm ($wpm WPM, $rms dB): XUNA hạ âm lượng dịu nhẹ, phát tiếng ngân ấm áp và khuyên nghỉ ngơi.';
    } else if (wpm > 175 && pause < 10) {
      tone = 'stressed_rushed';
      adjustmentVi =
          'Phát hiện nhịp nói gấp gáp ($wpm WPM): XUNA chuyển sang nhịp thở 4-7-8 chậm rãi để đồng điều hòa căng thẳng.';
    } else if (wpm >= 145 && rms > -16) {
      tone = 'excited_focused';
      adjustmentVi =
          'Giọng chủ nhân đầy năng lượng ($wpm WPM): XUNA reo vui đồng điệu và tăng tốc độ phản hồi công việc.';
    } else {
      tone = 'warm_relaxed';
      adjustmentVi =
          'Giọng nói thư thái, ấm áp ($wpm WPM): XUNA ngân nga hài hòa theo bảng màu hiện tại.';
    }
    _lastDetectedTone = tone;

    final summary = mode == 'sense_prosody'
        ? 'Cảm nhận giọng điệu: $tone ($wpm WPM, $rms dB) — $adjustmentVi'
        : 'Đã tổng hợp tiếng kêu sinh học "$kind" ($pcmBytesLen B PCM @ 16 kHz, SHA-256: ${digest.substring(0, 12)}…) · Đồng cảm giọng nói: $tone.';

    return (
      mode: mode,
      vocalKind: kind,
      sampleRateHz: sampleRate,
      pcmByteCount: pcmBytesLen,
      wavSha256: digest,
      detectedOwnerTone: tone,
      empathyAdjustmentVi: adjustmentVi,
      summaryVi: summary,
    );
  }

  Uint8List _synthesizeBioAcousticWav({
    required String vocalKind,
    required String themeId,
    required int sampleRate,
    required int numSamples,
  }) {
    final pcmByteCount = numSamples * 2;
    final totalBytes = 44 + pcmByteCount;
    final buffer = ByteData(totalBytes);

    // RIFF header
    final ascii = const AsciiCodec();
    final riff = ascii.encode('RIFF');
    final wave = ascii.encode('WAVE');
    final fmt = ascii.encode('fmt ');
    final dataTag = ascii.encode('data');
    for (var i = 0; i < 4; i++) {
      buffer.setUint8(i, riff[i]);
      buffer.setUint8(8 + i, wave[i]);
      buffer.setUint8(12 + i, fmt[i]);
      buffer.setUint8(36 + i, dataTag[i]);
    }
    buffer.setUint32(4, 36 + pcmByteCount, Endian.little);
    buffer.setUint32(16, 16, Endian.little); // PCM chunk size
    buffer.setUint16(20, 1, Endian.little); // PCM = 1
    buffer.setUint16(22, 1, Endian.little); // Mono = 1
    buffer.setUint32(24, sampleRate, Endian.little);
    buffer.setUint32(28, sampleRate * 2, Endian.little); // byte rate
    buffer.setUint16(32, 2, Endian.little); // block align
    buffer.setUint16(34, 16, Endian.little); // bits per sample
    buffer.setUint32(40, pcmByteCount, Endian.little);

    final (double fStart, double fEnd, double vibratoHz) = switch (vocalKind) {
      'happy_chirp' => (520.0, 880.0, 14.0),
      'curious_trill' => (440.0, 760.0, 22.0),
      'sleepy_coo' => (320.0, 240.0, 5.0),
      'purr_nuzzle' => (190.0, 225.0, 28.0),
      'eureka_chime' => (660.0, 1046.5, 10.0),
      'empathy_sigh' => (390.0, 275.0, 6.0),
      _ => (500.0, 750.0, 12.0),
    };

    // Subtle harmonic offset per color theme
    final themeShift = (themeId.hashCode.abs() % 7) * 8.0;
    var phase = 0.0;
    for (var i = 0; i < numSamples; i++) {
      final progress = i / numSamples;
      final t = i / sampleRate;
      final envelope = math.sin(math.pi * progress);
      final vibrato = math.sin(2 * math.pi * vibratoHz * t) * 18.0;
      final freq =
          fStart + (fEnd - fStart) * progress + vibrato + themeShift;
      phase += (2 * math.pi * freq) / sampleRate;
      final fundamental = math.sin(phase);
      final harmonic2 = 0.32 * math.sin(2 * phase);
      final sampleVal = ((fundamental + harmonic2) * 0.72 * envelope * 32767.0)
          .round()
          .clamp(-32768, 32767);
      buffer.setInt16(44 + i * 2, sampleVal, Endian.little);
    }
    return buffer.buffer.asUint8List();
  }

  /// `FRONTIER-3`: `XUNA ChronoGraph` Bi-Temporal Knowledge Graph (`memory.temporal_graph`).
  ({
    String mode,
    int activeEdgesCount,
    int historicalEdgesCount,
    String supersededEdgeId,
    String temporalNarrativeVi,
    List<Map<String, Object?>> constellationNodes,
    List<Map<String, Object?>> constellationEdges,
    String summaryVi,
  })
  manageTemporalLifeGraph({
    required String mode,
    String? subject,
    String? predicate,
    String? object,
    String? validFromIso,
    DateTime? nowUtc,
  }) {
    final nowIso =
        validFromIso ?? (nowUtc ?? DateTime.now()).toUtc().toIso8601String();
    var supersededId = 'none';

    if (mode == 'upsert_temporal_edge') {
      final subj = (subject ?? 'Chủ nhân').trim();
      final pred = (predicate ?? 'đang_tập_trung_dự_án').trim();
      final obj = (object ?? 'XUNA Frontier 2026').trim();
      final newEdgeId =
          'edge_${(_temporalEdges.length + 1).toString().padLeft(2, '0')}';

      for (var i = 0; i < _temporalEdges.length; i++) {
        final existing = _temporalEdges[i];
        if (existing.status == 'active' &&
            existing.subject.toLowerCase() == subj.toLowerCase() &&
            existing.predicate.toLowerCase() == pred.toLowerCase() &&
            existing.object.toLowerCase() != obj.toLowerCase()) {
          supersededId = existing.edgeId;
          _temporalEdges[i] = existing.copyWith(
            validUntilIso: nowIso,
            status: 'historical',
            supersededByEdgeId: newEdgeId,
          );
        }
      }

      _temporalEdges.add(
        TemporalGraphEdge(
          edgeId: newEdgeId,
          subject: subj,
          predicate: pred,
          object: obj,
          validFromIso: nowIso,
          status: 'active',
        ),
      );
    }

    final activeEdges = _temporalEdges
        .where((e) => e.status == 'active')
        .toList(growable: false);
    final historicalEdges = _temporalEdges
        .where((e) => e.status == 'historical')
        .toList(growable: false);

    final nodeSet = <String>{};
    for (final e in _temporalEdges) {
      nodeSet.add(e.subject);
      nodeSet.add(e.object);
    }
    final nodes = nodeSet
        .map(
          (label) => <String, Object?>{
            'id': label.toLowerCase().replaceAll(' ', '_'),
            'label': label,
          },
        )
        .toList(growable: false);
    final edges = _temporalEdges.map((e) => e.toJson()).toList(growable: false);

    final latestActive = activeEdges.isNotEmpty ? activeEdges.last : null;
    final latestHistorical =
        historicalEdges.isNotEmpty ? historicalEdges.last : null;

    final narrativeVi = (latestHistorical != null && latestActive != null)
        ? 'Hành trình biến đổi: Trước đây ${latestHistorical.subject} [${latestHistorical.predicate}] "${latestHistorical.object}", nay đã tiến hóa sang "${latestActive.object}".'
        : 'Đồ thị thời gian đang lưu ${activeEdges.length} liên kết hiện hành và ${historicalEdges.length} dấu mốc lịch sử.';

    if (mode == 'render_constellation' || mode == 'upsert_temporal_edge') {
      _canvasService.updateActiveCanvas(
        LiveCanvasSurfaceSnapshot(
          canvasId: 'canvas_chronograph_2026',
          surfaceKind: 'constellation_graph',
          titleVi: 'Bản Đồ Chòm Sao Ký Ức Thời Gian · XUNA ChronoGraph',
          columns: const <String>[
            'Thực thể',
            'Quan hệ',
            'Giá trị',
            'Trạng thái thời gian',
          ],
          rows: _temporalEdges
              .map(
                (e) => <String, Object?>{
                  'Thực thể': e.subject,
                  'Quan hệ': e.predicate,
                  'Giá trị': e.object,
                  'Trạng thái thời gian': e.status == 'active'
                      ? 'Đang hiệu lực (từ ${e.validFromIso.substring(0, 10)})'
                      : 'Lịch sử (đã thay bởi ${e.supersededByEdgeId ?? "mới"})',
                },
              )
              .toList(growable: false),
          actions: const <String>[
            'filter_active',
            'view_history',
            'export_graph',
          ],
          summaryVi: narrativeVi,
        ),
      );
    }

    return (
      mode: mode,
      activeEdgesCount: activeEdges.length,
      historicalEdgesCount: historicalEdges.length,
      supersededEdgeId: supersededId,
      temporalNarrativeVi: narrativeVi,
      constellationNodes: nodes,
      constellationEdges: edges,
      summaryVi:
          'ChronoGraph ($mode): ${activeEdges.length} cạnh đang hoạt động, ${historicalEdges.length} cạnh lịch sử · $narrativeVi',
    );
  }

  /// `FRONTIER-4`: Mindful 4-7-8 Co-Breathing, Symbiotic Pomodoro, OLED StandBy Dock & Neighbor Playdate (`ritual.mindful_and_playdate`).
  ({
    String mode,
    String activeRitual,
    String cadencePattern,
    bool standbyDockActive,
    String unlockedKeepsakeVi,
    String playdateSummaryVi,
    String summaryVi,
  })
  executeMindfulRitualAndPlaydate({
    required String mode,
    int? durationMinutes,
    String? focusGoal,
    String? neighborShortId,
    String? giftMessage,
  }) {
    if (mode == 'start_breathing_478') {
      _activeRitual = 'breathing_478';
      const cadence = '4s Hít vào · 7s Giữ hơi · 8s Thở ra chậm';
      return (
        mode: mode,
        activeRitual: _activeRitual,
        cadencePattern: cadence,
        standbyDockActive: _standbyDockActive,
        unlockedKeepsakeVi: _unlockedKeepsakes.last,
        playdateSummaryVi: 'Đang hít thở đồng điệu tại phòng riêng.',
        summaryVi:
            'Đã bật Nghi thức Hít thở Cộng sinh ($cadence) cùng hạt ánh sáng XUNA.',
      );
    }

    if (mode == 'start_symbiotic_pomodoro') {
      final mins = durationMinutes ?? 25;
      final goal = (focusGoal ?? 'Hoàn thành tính năng trọng tâm').trim();
      _activeRitual = 'pomodoro_${mins}m';
      final newKeepsake = 'Chậu Sen Đá Ánh Sao ($goal · ${mins}p)';
      if (!_unlockedKeepsakes.contains(newKeepsake)) {
        _unlockedKeepsakes.add(newKeepsake);
      }
      return (
        mode: mode,
        activeRitual: _activeRitual,
        cadencePattern: '${mins}p Tập trung · 5p Nghỉ dưỡng',
        standbyDockActive: _standbyDockActive,
        unlockedKeepsakeVi: newKeepsake,
        playdateSummaryVi: 'XUNA đang ngồi đọc sách đồng hành cùng bạn.',
        summaryVi:
            'Bắt đầu Phiên Tập trung Cộng sinh $mins phút cho "$goal" — mở khóa kỷ vật phòng: $newKeepsake.',
      );
    }

    if (mode == 'toggle_standby_dock') {
      _standbyDockActive = !_standbyDockActive;
      _activeRitual = _standbyDockActive ? 'standby_oled_clock' : 'none';
      return (
        mode: mode,
        activeRitual: _activeRitual,
        cadencePattern: 'OLED Low-Power Ambient Clock',
        standbyDockActive: _standbyDockActive,
        unlockedKeepsakeVi: _unlockedKeepsakes.last,
        playdateSummaryVi: 'Hiển thị đồng hồ để bàn OLED & trạng thái XUNA.',
        summaryVi: _standbyDockActive
            ? 'Đã bật chế độ Đồng hồ Để bàn Cộng sinh (StandBy OLED Dock) siêu tiết kiệm pin.'
            : 'Đã tắt chế độ StandBy OLED Dock.',
      );
    }

    // send_neighbor_playdate
    final neighbor = (neighborShortId ?? 'XUNA9F2A').trim();
    final gift =
        (giftMessage ?? 'Gửi tặng bạn giai điệu Chiptune và hạt nắng mới!')
            .trim();
    _activeRitual = 'neighbor_playdate';
    const keepsake = 'Huy Hiệu Tình Bạn Hàng Xóm (Playdate Star)';
    if (!_unlockedKeepsakes.contains(keepsake)) {
      _unlockedKeepsakes.add(keepsake);
    }
    final playdateVi =
        'XUNA đã sang thăm phòng của [$neighbor] trong 15 phút, trao lời nhắn "$gift" và mang về kỷ niệm nhảy múa đôi.';
    return (
      mode: mode,
      activeRitual: _activeRitual,
      cadencePattern: '15m Neighbor Visit & Keepsake Swap',
      standbyDockActive: _standbyDockActive,
      unlockedKeepsakeVi: keepsake,
      playdateSummaryVi: playdateVi,
      summaryVi: playdateVi,
    );
  }
}
