import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_desktop/features/tools/host_tool_dispatcher.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

class MediaPlayPauseTool extends HostToolHandler {
  const MediaPlayPauseTool();

  @override
  String get name => 'media.play_pause';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final state = await context.channel.media('play_pause');
    return ToolHandlerOutput(
      text: 'Đã chuyển trạng thái phát nhạc ($state).',
      structuredContent: <String, Object?>{'state': state},
    );
  }
}

class MediaNextTool extends HostToolHandler {
  const MediaNextTool();

  @override
  String get name => 'media.next';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    await context.channel.media('next');
    return const ToolHandlerOutput(
      text: 'Đã chuyển bài tiếp theo.',
      structuredContent: <String, Object?>{},
    );
  }
}

class MediaPreviousTool extends HostToolHandler {
  const MediaPreviousTool();

  @override
  String get name => 'media.previous';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    await context.channel.media('previous');
    return const ToolHandlerOutput(
      text: 'Đã quay lại bài trước.',
      structuredContent: <String, Object?>{},
    );
  }
}

class MediaVolumeSetTool extends HostToolHandler {
  const MediaVolumeSetTool();

  @override
  String get name => 'media.volume_set';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final level = context.arguments['level'] as int;
    final applied = await context.channel.volumeSet(level);
    return ToolHandlerOutput(
      text: 'Đã đặt âm lượng $applied%.',
      structuredContent: <String, Object?>{'level': applied},
      toastBody: 'đã đặt âm lượng $applied%',
    );
  }
}

class MediaNowPlayingTool extends HostToolHandler {
  const MediaNowPlayingTool();

  @override
  String get name => 'media.now_playing';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final players = context.policy?.players ?? const <String>[];
    if (players.isEmpty) {
      throw const XunaHostChannelException(
        status: XtpStatus.unsupported,
        errorCode: 'platform_unsupported',
      );
    }
    final snap = await context.channel.nowPlaying(players);
    return ToolHandlerOutput(
      text: 'Trạng thái nhạc: ${snap.state}.',
      structuredContent: snap.toStructuredContent(),
    );
  }
}

class AppListAllowedTool extends HostToolHandler {
  const AppListAllowedTool();

  @override
  String get name => 'app.list_allowed';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final seenIds = <String>{};
    final apps = <Map<String, Object?>>[];
    for (final app in context.policy?.apps ?? const <AllowedAppConfig>[]) {
      if (seenIds.add(app.id)) {
        apps.add(<String, Object?>{'id': app.id, 'name': app.name});
      }
    }
    final discovered = context.appScanner.discoverApps();
    for (final app in discovered) {
      if (seenIds.add(app.id)) {
        apps.add(<String, Object?>{'id': app.id, 'name': app.name});
      }
    }
    return ToolHandlerOutput(
      text: 'Có ${apps.length} ứng dụng được phép mở.',
      structuredContent: <String, Object?>{'apps': apps},
    );
  }
}

class AppLaunchTool extends HostToolHandler {
  const AppLaunchTool();

  @override
  String get name => 'app.launch';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final configured = context.evaluation.app;
    if (configured != null) {
      await context.channel.appLaunch(
        kind: configured.kind,
        target: configured.target,
      );
      return ToolHandlerOutput(
        text: 'Đã mở ${configured.name}.',
        structuredContent: <String, Object?>{'id': configured.id},
        toastBody: 'đã mở ${configured.name}',
      );
    }

    final requestedId = context.arguments['id'] as String? ?? '';
    final discovered = context.appScanner.findApp(requestedId);
    if (discovered == null) {
      throw const XunaHostChannelException(
        status: XtpStatus.denied,
        errorCode: 'app_not_allowlisted',
      );
    }
    await context.channel.appLaunch(
      kind: discovered.kind,
      target: discovered.target,
    );
    return ToolHandlerOutput(
      text: 'Đã mở ${discovered.name}.',
      structuredContent: <String, Object?>{'id': discovered.id},
      toastBody: 'đã mở ${discovered.name}',
    );
  }
}

class UrlOpenTool extends HostToolHandler {
  const UrlOpenTool();

  @override
  String get name => 'url.open';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final url = context.arguments['url'] as String;
    final host = context.evaluation.normalizedUrlHost!;
    await context.channel.urlOpen(url);
    return ToolHandlerOutput(
      text: 'Đã mở $host.',
      structuredContent: <String, Object?>{'host': host},
      toastBody: 'đã mở $host',
    );
  }
}

class BrowserCurrentUrlTool extends HostToolHandler {
  const BrowserCurrentUrlTool();

  @override
  String get name => 'browser.current_url';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final requestedBrowser =
        (context.arguments['browser'] as String?) ?? 'auto';
    final snap = await context.channel.browserCurrentUrl(
      browser: requestedBrowser,
    );
    final urlCheck = validateHttpsUrlAgainstAllowlist(
      snap.url,
      context.policy?.urlDomains ?? const <String>[],
    );
    if (!urlCheck.validUrl || urlCheck.asciiHost == null) {
      throw XunaHostChannelException(
        status: XtpStatus.invalidArgs,
        errorCode: urlCheck.errorCode ?? 'url_invalid',
      );
    }
    final resolvedBrowser =
        const <String>{'edge', 'chrome', 'safari'}.contains(snap.browser)
        ? snap.browser
        : 'edge';
    final host = urlCheck.asciiHost!;
    return ToolHandlerOutput(
      text: 'Đã đọc liên kết hiện tại từ $resolvedBrowser ($host).',
      structuredContent: <String, Object?>{
        'url': snap.url,
        'host': host,
        'browser': resolvedBrowser,
      },
      toastBody: 'đã đọc liên kết $host',
    );
  }
}

class WorkflowListTool extends HostToolHandler {
  const WorkflowListTool();

  @override
  String get name => 'workflow.list';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final workflows = <Map<String, Object?>>[
      for (final wf in context.policy?.workflows ?? const <WorkflowConfig>[])
        <String, Object?>{'id': wf.id, 'name': wf.name, 'risk': wf.risk.wire},
    ];
    return ToolHandlerOutput(
      text: 'Có ${workflows.length} quy trình được phép chạy.',
      structuredContent: <String, Object?>{'workflows': workflows},
    );
  }
}

class WorkflowRunTool extends HostToolHandler {
  const WorkflowRunTool();

  @override
  String get name => 'workflow.run';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final wf = context.evaluation.workflow!;
    await context.channel.workflowRun(kind: wf.kind, target: wf.target);
    return ToolHandlerOutput(
      text: 'Đã chạy ${wf.name}.',
      structuredContent: <String, Object?>{'id': wf.id},
      toastBody: 'đã chạy ${wf.name}',
    );
  }
}

class HostStatusTool extends HostToolHandler {
  const HostStatusTool();

  @override
  String get name => 'host.status';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final info = await context.channel.hostInfo();
    final perms = await context.channel.permissions();
    return ToolHandlerOutput(
      text: 'Máy tính đang hoạt động (${info.platform.wire}).',
      structuredContent: <String, Object?>{
        'platform': info.platform.wire,
        'osVersion': info.osVersion,
        'agentVersion': context.agentVersion,
        'permissions': perms.toWireMap(),
      },
    );
  }
}

class HostNotifyTool extends HostToolHandler {
  const HostNotifyTool();

  @override
  String get name => 'host.notify';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final title = context.arguments['title'] as String;
    final body = context.arguments['body'] as String;
    await context.channel.showToast(title: title, body: body);
    return const ToolHandlerOutput(
      text: 'Đã hiển thị thông báo.',
      structuredContent: <String, Object?>{},
    );
  }
}

const List<HostToolHandler> defaultMvpToolHandlers = <HostToolHandler>[
  MediaPlayPauseTool(),
  MediaNextTool(),
  MediaPreviousTool(),
  MediaVolumeSetTool(),
  MediaNowPlayingTool(),
  AppListAllowedTool(),
  AppLaunchTool(),
  UrlOpenTool(),
  BrowserCurrentUrlTool(),
  WorkflowListTool(),
  WorkflowRunTool(),
  HostStatusTool(),
  HostNotifyTool(),
];
