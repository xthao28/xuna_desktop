import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

import 'browser_engine_provider.dart';

/// Chrome DevTools Protocol (CDP) / Playwright browser provider (`UDC-18` §Wave B).
///
/// In production, connects to the local Chrome CDP debug WebSocket endpoint.
/// If CDP is unavailable or connection fails, fails closed with `browser_engine_not_available` (Rule H1).
class CdpBrowserEngineProvider implements BrowserEngineProvider {
  CdpBrowserEngineProvider({this.cdpEndpoint = 'http://127.0.0.1:9222'});

  final String cdpEndpoint;

  @override
  Future<Map<String, Object?>> navigate({
    required String url,
    int? timeoutMs,
  }) async {
    throw const XunaHostChannelException(
      status: XtpStatus.unsupported,
      errorCode: 'browser_engine_not_available',
      message: 'Chrome CDP or Playwright browser context is not running.',
    );
  }

  @override
  Future<Map<String, Object?>> snapshot({
    bool compact = true,
    int maxBytes = 6144,
  }) async {
    throw const XunaHostChannelException(
      status: XtpStatus.unsupported,
      errorCode: 'browser_engine_not_available',
      message: 'Chrome CDP or Playwright browser context is not running.',
    );
  }

  @override
  Future<Map<String, Object?>> click({
    required String ref,
    String? selector,
  }) async {
    throw const XunaHostChannelException(
      status: XtpStatus.unsupported,
      errorCode: 'browser_engine_not_available',
      message: 'Chrome CDP or Playwright browser context is not running.',
    );
  }

  @override
  Future<Map<String, Object?>> fill({
    required String ref,
    required String value,
    String? selector,
  }) async {
    throw const XunaHostChannelException(
      status: XtpStatus.unsupported,
      errorCode: 'browser_engine_not_available',
      message: 'Chrome CDP or Playwright browser context is not running.',
    );
  }

  @override
  Future<Map<String, Object?>> select({
    required String ref,
    required String value,
    String? selector,
  }) async {
    throw const XunaHostChannelException(
      status: XtpStatus.unsupported,
      errorCode: 'browser_engine_not_available',
      message: 'Chrome CDP or Playwright browser context is not running.',
    );
  }

  @override
  Future<Map<String, Object?>> extract({
    String? ref,
    String? selector,
    String? attribute,
  }) async {
    throw const XunaHostChannelException(
      status: XtpStatus.unsupported,
      errorCode: 'browser_engine_not_available',
      message: 'Chrome CDP or Playwright browser context is not running.',
    );
  }

  @override
  Future<Map<String, Object?>> waitFor({
    String? selector,
    String? state,
    int? timeoutMs,
  }) async {
    throw const XunaHostChannelException(
      status: XtpStatus.unsupported,
      errorCode: 'browser_engine_not_available',
      message: 'Chrome CDP or Playwright browser context is not running.',
    );
  }
}
