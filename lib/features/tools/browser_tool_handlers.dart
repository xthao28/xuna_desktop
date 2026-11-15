import 'package:xuna_desktop/features/browser_bridge/browser_engine_provider.dart';
import 'package:xuna_desktop/features/tools/host_tool_dispatcher.dart';

/// Builds the default list of 7 browser tool handlers (`UDC-18` §Wave B).
List<HostToolHandler> defaultBrowserToolHandlers(BrowserEngineProvider provider) =>
    <HostToolHandler>[
      WebNavigateTool(provider),
      WebSnapshotTool(provider),
      WebClickTool(provider),
      WebFillTool(provider),
      WebSelectTool(provider),
      WebExtractTool(provider),
      WebWaitForTool(provider),
    ];

class WebNavigateTool extends HostToolHandler {
  const WebNavigateTool(this.provider);

  final BrowserEngineProvider provider;

  @override
  String get name => 'web.navigate';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final url = context.arguments['url']! as String;
    final timeoutMs = context.arguments['timeoutMs'] as int?;

    final result = await provider.navigate(
      url: url,
      timeoutMs: timeoutMs,
    );
    return ToolHandlerOutput(
      text: 'Đã điều hướng trình duyệt tới $url.',
      structuredContent: result,
      toastBody: 'đã mở trang web',
    );
  }
}

class WebSnapshotTool extends HostToolHandler {
  const WebSnapshotTool(this.provider);

  final BrowserEngineProvider provider;

  @override
  String get name => 'web.snapshot';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final compact = (context.arguments['compact'] as bool?) ?? true;
    final maxBytes = (context.arguments['maxBytes'] as int?) ?? 6144;

    final result = await provider.snapshot(
      compact: compact,
      maxBytes: maxBytes,
    );
    final count = result['elementCount'] as int? ?? 0;
    return ToolHandlerOutput(
      text: 'Đã chụp cây trợ năng DOM/ARIA ($count phần tử).',
      structuredContent: result,
    );
  }
}

class WebClickTool extends HostToolHandler {
  const WebClickTool(this.provider);

  final BrowserEngineProvider provider;

  @override
  String get name => 'web.click';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final ref = context.arguments['ref']! as String;
    final selector = context.arguments['selector'] as String?;

    final result = await provider.click(
      ref: ref,
      selector: selector,
    );
    return ToolHandlerOutput(
      text: 'Đã nhấp phần tử $ref.',
      structuredContent: result,
      toastBody: 'đã nhấp phần tử web',
    );
  }
}

class WebFillTool extends HostToolHandler {
  const WebFillTool(this.provider);

  final BrowserEngineProvider provider;

  @override
  String get name => 'web.fill';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final ref = context.arguments['ref']! as String;
    final value = context.arguments['value']! as String;
    final selector = context.arguments['selector'] as String?;

    final result = await provider.fill(
      ref: ref,
      value: value,
      selector: selector,
    );
    return ToolHandlerOutput(
      text: 'Đã nhập dữ liệu vào phần tử $ref.',
      structuredContent: result,
      toastBody: 'đã điền dữ liệu web',
    );
  }
}

class WebSelectTool extends HostToolHandler {
  const WebSelectTool(this.provider);

  final BrowserEngineProvider provider;

  @override
  String get name => 'web.select';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final ref = context.arguments['ref']! as String;
    final value = context.arguments['value']! as String;
    final selector = context.arguments['selector'] as String?;

    final result = await provider.select(
      ref: ref,
      value: value,
      selector: selector,
    );
    return ToolHandlerOutput(
      text: 'Đã chọn giá trị trong phần tử $ref.',
      structuredContent: result,
      toastBody: 'đã chọn tùy chọn web',
    );
  }
}

class WebExtractTool extends HostToolHandler {
  const WebExtractTool(this.provider);

  final BrowserEngineProvider provider;

  @override
  String get name => 'web.extract';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final ref = context.arguments['ref'] as String?;
    final selector = context.arguments['selector'] as String?;
    final attribute = context.arguments['attribute'] as String?;

    final result = await provider.extract(
      ref: ref,
      selector: selector,
      attribute: attribute,
    );
    return ToolHandlerOutput(
      text: 'Đã trích xuất thông tin từ trang web.',
      structuredContent: result,
    );
  }
}

class WebWaitForTool extends HostToolHandler {
  const WebWaitForTool(this.provider);

  final BrowserEngineProvider provider;

  @override
  String get name => 'web.wait_for';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final selector = context.arguments['selector'] as String?;
    final state = context.arguments['state'] as String?;
    final timeoutMs = context.arguments['timeoutMs'] as int?;

    final result = await provider.waitFor(
      selector: selector,
      state: state,
      timeoutMs: timeoutMs,
    );
    return ToolHandlerOutput(
      text: 'Đã hoàn tất chờ trạng thái phần tử web ($state).',
      structuredContent: result,
    );
  }
}
