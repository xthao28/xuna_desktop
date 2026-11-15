import 'dart:io';

import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

import 'macos_native_app_bridge.dart';
import 'native_app_bridge.dart';

/// Windows implementation of [NativeAppBridge] (`UDC-18` §3.1).
///
/// Executes native Windows primitives (e.g. `explorer.exe /select`) using explicit
/// process argument lists.
/// For macOS-native ecosystems (Apple Notes, Apple Reminders, Apple Calendar, Shortcuts),
/// strictly fails closed with `platform_unsupported` in accordance with Rule H1.
class WindowsNativeAppBridge implements NativeAppBridge {
  WindowsNativeAppBridge({ProcessRunner? processRunner})
    : _processRunner = processRunner ?? Process.run;

  final ProcessRunner _processRunner;

  @override
  Future<Map<String, Object?>> notesCreate({
    required String title,
    required String body,
    String? folder,
  }) async {
    throw const XunaHostChannelException(
      status: XtpStatus.unsupported,
      errorCode: 'platform_unsupported',
      message: 'Native Notes bridge is only available on macOS.',
    );
  }

  @override
  Future<Map<String, Object?>> notesAppend({
    String? id,
    String? title,
    required String text,
  }) async {
    throw const XunaHostChannelException(
      status: XtpStatus.unsupported,
      errorCode: 'platform_unsupported',
      message: 'Native Notes bridge is only available on macOS.',
    );
  }

  @override
  Future<Map<String, Object?>> notesSearch({
    required String query,
    int maxResults = 5,
  }) async {
    throw const XunaHostChannelException(
      status: XtpStatus.unsupported,
      errorCode: 'platform_unsupported',
      message: 'Native Notes bridge is only available on macOS.',
    );
  }

  @override
  Future<Map<String, Object?>> remindersCreate({
    required String title,
    String? list,
    String? dueDate,
    String? notes,
    int? priority,
  }) async {
    throw const XunaHostChannelException(
      status: XtpStatus.unsupported,
      errorCode: 'platform_unsupported',
      message: 'Native Reminders bridge is only available on macOS.',
    );
  }

  @override
  Future<Map<String, Object?>> calendarListEvents({
    required String timeMin,
    required String timeMax,
    String? calendarName,
    int maxResults = 10,
  }) async {
    throw const XunaHostChannelException(
      status: XtpStatus.unsupported,
      errorCode: 'platform_unsupported',
      message: 'Native Calendar bridge is only available on macOS.',
    );
  }

  @override
  Future<Map<String, Object?>> calendarCreateEvent({
    required String title,
    required String startTime,
    required String endTime,
    String? location,
    String? notes,
    String? calendarName,
  }) async {
    throw const XunaHostChannelException(
      status: XtpStatus.unsupported,
      errorCode: 'platform_unsupported',
      message: 'Native Calendar bridge is only available on macOS.',
    );
  }

  @override
  Future<Map<String, Object?>> finderReveal({required String path}) async {
    final file = File(path);
    final dir = Directory(path);
    if (!file.existsSync() && !dir.existsSync()) {
      throw XunaHostChannelException(
        status: XtpStatus.invalidArgs,
        errorCode: 'file_not_found',
        message: 'File or directory does not exist: $path',
      );
    }
    final result = await _processRunner('explorer.exe', <String>['/select,$path']);
    if (result.exitCode != 0) {
      throw XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'provider_error',
        message: result.stderr.toString().trim(),
      );
    }
    return <String, Object?>{'path': path, 'revealed': true};
  }

  @override
  Future<Map<String, Object?>> shortcutsRun({
    required String shortcutName,
    Object? input,
  }) async {
    throw const XunaHostChannelException(
      status: XtpStatus.unsupported,
      errorCode: 'platform_unsupported',
      message: 'Apple Shortcuts are only available on macOS.',
    );
  }

  @override
  Future<Map<String, Object?>> mailCreateDraft({
    required List<String> to,
    List<String>? cc,
    List<String>? bcc,
    required String subject,
    required String body,
  }) async {
    throw const XunaHostChannelException(
      status: XtpStatus.unsupported,
      errorCode: 'platform_unsupported',
      message: 'Native Mail draft bridge is only available on macOS.',
    );
  }
}
