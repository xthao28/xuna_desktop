import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_desktop/features/tools/host_tool_dispatcher.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

class TvListDevicesTool extends HostToolHandler {
  const TvListDevicesTool();

  @override
  String get name => 'tv.list_devices';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final devices = await context.tvScanner.discoverDevices();
    return ToolHandlerOutput(
      text: 'Tìm thấy ${devices.length} Smart TV trên mạng LAN.',
      structuredContent: <String, Object?>{
        'devices': devices.map((d) => d.toWireJson()).toList(growable: false),
      },
    );
  }
}

class TvControlTool extends HostToolHandler {
  const TvControlTool();

  @override
  String get name => 'tv.control';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final deviceQuery = context.arguments['device'] as String?;
    final action = context.arguments['action'] as String;
    final level = context.arguments['level'] as int?;
    try {
      final res = await context.tvScanner.executeControl(
        deviceQuery: deviceQuery,
        action: action,
        level: level,
      );
      if (action == 'volume_set' && res.previousVolume != null) {
        context.actionLedger.pushEntry(
          ReversibleActionEntry(
            originalTool: 'tv.control',
            inverseTool: 'tv.control',
            inverseArgs: <String, Object?>{
              'device': res.tv.name,
              'action': 'volume_set',
              'level': res.previousVolume!,
            },
            description:
                'khôi phục âm lượng ${res.tv.name} về ${res.previousVolume}%',
            recordedAt: context.nowUtc,
          ),
        );
      } else if (action == 'mute_toggle' || action == 'play_pause') {
        context.actionLedger.pushEntry(
          ReversibleActionEntry(
            originalTool: 'tv.control',
            inverseTool: 'tv.control',
            inverseArgs: <String, Object?>{
              'device': res.tv.name,
              'action': action,
            },
            description: 'đảo lại $action trên ${res.tv.name}',
            recordedAt: context.nowUtc,
          ),
        );
      }
      return ToolHandlerOutput(
        text: 'Đã gửi lệnh $action tới ${res.tv.name} (${res.state}).',
        structuredContent: <String, Object?>{
          'deviceId': res.tv.id,
          'name': res.tv.name,
          'action': action,
          'state': res.state,
          if (res.newVolume != null) 'level': res.newVolume,
        },
        toastBody: '${res.tv.name}: $action',
      );
    } on StateError {
      throw const XunaHostChannelException(
        status: XtpStatus.invalidArgs,
        errorCode: 'tv_not_found',
      );
    }
  }
}

class TvLaunchAppTool extends HostToolHandler {
  const TvLaunchAppTool();

  @override
  String get name => 'tv.launch_app';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final deviceQuery = context.arguments['device'] as String?;
    final appId = context.arguments['appId'] as String;
    try {
      final tv = await context.tvScanner.launchApp(
        deviceQuery: deviceQuery,
        appId: appId,
      );
      return ToolHandlerOutput(
        text: 'Đã mở $appId trên ${tv.name}.',
        structuredContent: <String, Object?>{
          'deviceId': tv.id,
          'name': tv.name,
          'appId': appId,
          'launched': true,
        },
        toastBody: 'đã mở $appId trên ${tv.name}',
      );
    } on StateError {
      throw const XunaHostChannelException(
        status: XtpStatus.invalidArgs,
        errorCode: 'tv_not_found',
      );
    }
  }
}

class TvCastMediaTool extends HostToolHandler {
  const TvCastMediaTool();

  @override
  String get name => 'tv.cast_media';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final deviceQuery = context.arguments['device'] as String?;
    final url = context.arguments['url'] as String;
    final title = context.arguments['title'] as String?;
    try {
      final res = await context.tvScanner.castMedia(
        deviceQuery: deviceQuery,
        url: url,
        title: title,
      );
      return ToolHandlerOutput(
        text: 'Đã chiếu nội dung (${res.host}) lên ${res.tv.name}.',
        structuredContent: <String, Object?>{
          'deviceId': res.tv.id,
          'name': res.tv.name,
          'appId': res.appId,
          'host': res.host,
          'casted': true,
        },
        toastBody: 'đã chiếu ${res.host} lên ${res.tv.name}',
      );
    } on StateError {
      throw const XunaHostChannelException(
        status: XtpStatus.invalidArgs,
        errorCode: 'tv_not_found',
      );
    }
  }
}

class SmartHomeListEntitiesTool extends HostToolHandler {
  const SmartHomeListEntitiesTool();

  @override
  String get name => 'smarthome.list_entities';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final domain = context.arguments['domain'] as String?;
    final entities = await context.smartHomeBridge.listEntities(domain: domain);
    return ToolHandlerOutput(
      text: 'Tìm thấy ${entities.length} thiết bị nhà thông minh được phép.',
      structuredContent: <String, Object?>{
        'entities': entities.map((e) => e.toWireJson()).toList(growable: false),
      },
    );
  }
}

class SmartHomeControlTool extends HostToolHandler {
  const SmartHomeControlTool();

  @override
  String get name => 'smarthome.control';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final entityId = context.arguments['entityId'] as String;
    final action = context.arguments['action'] as String;
    final value = context.arguments['value'] as int?;
    try {
      final res = await context.smartHomeBridge.controlEntity(
        entityId: entityId,
        action: action,
        value: value,
      );
      context.actionLedger.pushEntry(
        ReversibleActionEntry(
          originalTool: 'smarthome.control',
          inverseTool: 'smarthome.control',
          inverseArgs: <String, Object?>{
            'entityId': res.entity.entityId,
            'action': res.inverseAction,
            if (res.previousValue != null) 'value': res.previousValue,
          },
          description: 'hoàn tác ${res.entity.name} về ${res.previousState}',
          recordedAt: context.nowUtc,
        ),
      );
      return ToolHandlerOutput(
        text:
            'Đã điều khiển ${res.entity.name} ($action → ${res.entity.state}).',
        structuredContent: <String, Object?>{
          'entityId': res.entity.entityId,
          'domain': res.entity.domain,
          'action': action,
          'state': res.entity.state,
          if (res.entity.value != null) 'value': res.entity.value,
        },
        toastBody: '${res.entity.name}: $action',
      );
    } on StateError {
      throw const XunaHostChannelException(
        status: XtpStatus.denied,
        errorCode: 'smarthome_domain_forbidden',
      );
    }
  }
}

const List<HostToolHandler> defaultTvSmartHomeToolHandlers = <HostToolHandler>[
  TvListDevicesTool(),
  TvControlTool(),
  TvLaunchAppTool(),
  TvCastMediaTool(),
  SmartHomeListEntitiesTool(),
  SmartHomeControlTool(),
];
