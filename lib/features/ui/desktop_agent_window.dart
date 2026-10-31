import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:xuna_desktop/core/controller/desktop_agent_controller.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

/// Main settings and status window of the XUNA Desktop Agent.
///
/// Includes:
/// - Header bar with live connection status, fail-closed policy banner
///   (`"Cấu hình lỗi"`), and emergency stop button (`"Dừng XUNA"` /
///   `"Bật lại XUNA"`).
/// - 4 tabs:
///   1. Ghép nối (Enrollment QR + 6-digit SAS / enrolled host info)
///   2. Chính sách (Local `host-policy.json` families, apps, domains, workflows)
///   3. Quyền hệ thống (OS permissions onboarding & re-check)
///   4. Nhật ký (30-day content-free local audit JSONL viewer)
class DesktopAgentWindow extends StatelessWidget {
  const DesktopAgentWindow({super.key, required this.controller});

  static const statusBadgeKey = Key('desktop.header.status');
  static const cuOverlayBannerKey = Key('desktop.cu.overlay_banner');
  static const stopButtonKey = Key('desktop.header.stop');
  static const resumeButtonKey = Key('desktop.header.resume');
  static const sasCodeKey = Key('desktop.enroll.sas');
  static const lanModeSwitchKey = Key('desktop.enroll.lan_mode');
  static const restorePolicyButtonKey = Key('desktop.policy.restore');
  static const recheckPermissionsButtonKey = Key('desktop.permissions.recheck');

  final DesktopAgentController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F2E8),
      body: Obx(() {
        final cuSession = controller.activeCuSession.value;
        return Container(
          decoration: cuSession != null
              ? BoxDecoration(
                  border: Border.all(
                    color: const Color(0xFFE67E22),
                    width: 4,
                  ),
                )
              : null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeader(),
              if (cuSession != null)
                Container(
                  key: cuOverlayBannerKey,
                  color: const Color(0xFFE67E22),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 6,
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.visibility,
                        size: 16,
                        color: Colors.white,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'XUNA đang quan sát và điều khiển màn hình · Bước ${cuSession.stepsExecuted}/${cuSession.maxSteps} · ${cuSession.goal}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              _buildTabBar(),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: switch (controller.activeTab.value) {
                    AgentWindowTab.enrollment => _buildEnrollmentTab(),
                    AgentWindowTab.policy => _buildPolicyTab(),
                    AgentWindowTab.permissions => _buildPermissionsTab(),
                    AgentWindowTab.audit => _buildAuditTab(),
                  },
                ),
              ),
            ],
          ),
        );
      }),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        color: Color(0xFF1F2421),
        border: Border(bottom: BorderSide(color: Color(0xFF111111), width: 2)),
      ),
      child: Obx(() {
        final stopped = controller.isStopped.value;
        final healthy = controller.isPolicyHealthy.value;
        return Row(
          children: [
            const Expanded(
              child: Text(
                'XUNA Desktop Agent',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Container(
              key: statusBadgeKey,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: !healthy || stopped
                    ? const Color(0xFFD9534F)
                    : const Color(0xFF8CD867),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                controller.trayStatusLabel,
                style: const TextStyle(
                  color: Color(0xFF111111),
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 12),
            if (stopped)
              ElevatedButton(
                key: resumeButtonKey,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF8CD867),
                  foregroundColor: const Color(0xFF111111),
                ),
                onPressed: controller.resumeEmergencyStop,
                child: const Text('Bật lại XUNA'),
              )
            else
              ElevatedButton(
                key: stopButtonKey,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFD9534F),
                  foregroundColor: Colors.white,
                ),
                onPressed: controller.triggerEmergencyStop,
                child: const Text('Dừng XUNA'),
              ),
          ],
        );
      }),
    );
  }

  Widget _buildTabBar() {
    return Container(
      color: const Color(0xFFEBE4D4),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Obx(() {
        final current = controller.activeTab.value;
        return Wrap(
          spacing: 8,
          children: [
            _tabButton(AgentWindowTab.enrollment, 'Ghép nối', current),
            _tabButton(AgentWindowTab.policy, 'Chính sách', current),
            _tabButton(AgentWindowTab.permissions, 'Quyền hệ thống', current),
            _tabButton(AgentWindowTab.audit, 'Nhật ký', current),
          ],
        );
      }),
    );
  }

  Widget _tabButton(AgentWindowTab tab, String label, AgentWindowTab current) {
    final selected = tab == current;
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        backgroundColor: selected
            ? const Color(0xFF1F2421)
            : Colors.transparent,
        foregroundColor: selected ? Colors.white : const Color(0xFF1F2421),
      ),
      onPressed: () {
        controller.activeTab.value = tab;
        if (tab == AgentWindowTab.audit) {
          controller.refreshAudit();
        } else if (tab == AgentWindowTab.permissions) {
          controller.refreshPermissions();
        }
      },
      child: Text(label),
    );
  }

  Widget _buildEnrollmentTab() {
    return Obx(() {
      final enrolled = controller.enrolledState.value;
      if (enrolled != null) {
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Đã ghép nối: ${enrolled.alias}',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text('Host ID: ${enrolled.hostId}'),
                const SizedBox(height: 12),
                SwitchListTile(
                  key: lanModeSwitchKey,
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    'Chế độ LAN ngoại tuyến (chỉ điều khiển nhạc)',
                  ),
                  subtitle: const Text(
                    'Cho phép điện thoại đã ghép nối điều khiển nhạc (media.*) trực tiếp qua mạng LAN nội bộ khi mất kết nối máy chủ.',
                  ),
                  value: controller.lanModeEnabled.value,
                  onChanged: controller.toggleLanMode,
                ),
                const SizedBox(height: 16),
                OutlinedButton(
                  onPressed: controller.unpairAndRestartEnrollment,
                  child: const Text('Hủy ghép nối và tạo mã QR mới'),
                ),
              ],
            ),
          ),
        );
      }

      final display = controller.pendingEnrollment.value;
      if (display == null) {
        return const Center(
          child: Text('Đang chuẩn bị mã ghép nối với máy chủ XUNA...'),
        );
      }

      final spacedSas = display.sas.length == 6
          ? '${display.sas.substring(0, 3)} ${display.sas.substring(3)}'
          : display.sas;

      return SingleChildScrollView(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const Text(
                  'Quét mã QR bằng ứng dụng XUNA trên điện thoại',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                QrImageView(
                  data: display.qrUri,
                  size: 180,
                  backgroundColor: Colors.white,
                ),
                const SizedBox(height: 12),
                const Text('Mã xác nhận 6 chữ số (SAS):'),
                const SizedBox(height: 6),
                Text(
                  spacedSas,
                  key: sasCodeKey,
                  style: const TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(height: 6),
                Text('Tên máy: ${display.hostname}'),
              ],
            ),
          ),
        ),
      );
    });
  }

  Widget _buildPolicyTab() {
    return Obx(() {
      if (!controller.isPolicyHealthy.value ||
          controller.activePolicy.value == null) {
        return Card(
          color: const Color(0xFFFFF3CD),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Cấu hình lỗi (Fail-closed)',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Tệp host-policy.json bị thiếu hoặc không hợp lệ. Mọi công cụ trừ host.status đều bị từ chối cho tới khi khôi phục chính sách.',
                ),
                const SizedBox(height: 12),
                ElevatedButton(
                  key: restorePolicyButtonKey,
                  onPressed: controller.restoreDefaultPolicy,
                  child: const Text('Khôi phục chính sách mặc định'),
                ),
              ],
            ),
          ),
        );
      }

      final policy = controller.activePolicy.value!;
      return ListView(
        children: [
          for (final family in const <ToolFamily>[
            ToolFamily.media,
            ToolFamily.app,
            ToolFamily.url,
            ToolFamily.workflow,
          ])
            SwitchListTile(
              title: Text('Nhóm quyền: ${family.wire}'),
              value: policy.isFamilyAllowed(family),
              onChanged: (val) => controller.toggleFamilyPolicy(family, val),
            ),
          const Divider(),
          ListTile(
            title: const Text('Tên miền cho phép (url.open)'),
            subtitle: Text(
              policy.urlDomains.isEmpty
                  ? 'Chưa có tên miền nào'
                  : policy.urlDomains.join(', '),
            ),
          ),
          ListTile(
            title: const Text('Ứng dụng cho phép (app.launch)'),
            subtitle: Text(
              policy.apps.isEmpty
                  ? 'Chưa có ứng dụng nào'
                  : policy.apps.map((a) => '${a.name} (${a.id})').join(', '),
            ),
          ),
        ],
      );
    });
  }

  Widget _buildPermissionsTab() {
    return Obx(() {
      final snap = controller.permissionsSnapshot.value;
      final automationEntries = snap.automation.entries.toList(growable: false);
      return ListView(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Expanded(
                child: Text(
                  'Quyền hệ thống được tự động kiểm tra lại khi cửa sổ nhận tiêu điểm (Focus).',
                  style: TextStyle(fontSize: 13),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                key: recheckPermissionsButtonKey,
                onPressed: controller.refreshPermissions,
                child: const Text('Kiểm tra lại ngay'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              title: const Text('Bước 1 · Trợ năng (Accessibility)'),
              subtitle: Text(
                'Điều khiển phím đa phương tiện · Trạng thái: ${snap.accessibility.wire}',
              ),
              trailing: OutlinedButton(
                onPressed: () =>
                    controller.requestOsPermission('accessibility'),
                child: const Text('Kiểm tra / Cấp quyền'),
              ),
            ),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ListTile(
                    title: const Text(
                      'Bước 2 · Tự động hóa (Automation / AppleEvents)',
                    ),
                    subtitle: Text(
                      automationEntries.isEmpty
                          ? 'Chỉ áp dụng trên macOS khi điều khiển Music / Spotify'
                          : automationEntries
                                .map((e) => '${e.key}: ${e.value.wire}')
                                .join(' · '),
                    ),
                    trailing: OutlinedButton(
                      onPressed: () => controller.requestOsPermission(
                        'automation:com.apple.Music',
                      ),
                      child: const Text('Cấp quyền Music'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Card(
            child: ListTile(
              title: const Text('Bước 3 · Thông báo (Notifications)'),
              subtitle: Text(
                'Hiển thị thông báo khi XUNA thực thi công cụ · Trạng thái: ${snap.notifications.wire}',
              ),
              trailing: OutlinedButton(
                onPressed: () =>
                    controller.requestOsPermission('notifications'),
                child: const Text('Kiểm tra / Cấp quyền'),
              ),
            ),
          ),
        ],
      );
    });
  }

  Widget _buildAuditTab() {
    return Obx(() {
      final items = controller.recentAuditRecords;
      if (items.isEmpty) {
        return const Center(
          child: Text('Chưa có nhật ký thực thi công cụ nào.'),
        );
      }
      return ListView.separated(
        itemCount: items.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final item = items[index];
          return ListTile(
            dense: true,
            title: Text('${item.tool} → ${item.status.wire}'),
            subtitle: Text(
              '${item.ts.toIso8601String()} · ${item.durationMs} ms · ${item.invocationId}',
            ),
          );
        },
      );
    });
  }
}
