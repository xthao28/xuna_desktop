import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

import 'browser_engine_provider.dart';

typedef CdpBrowserLauncher =
    Future<Process?> Function(int port, String profileDir);

/// Chrome DevTools Protocol (CDP) browser provider (`UDC-18` §Wave B).
///
/// Connects to a local loopback Chromium CDP endpoint (`http://127.0.0.1:9222`).
/// When [autoLaunchBrowser] is enabled (production Desktop Agent), automatically
/// spawns an isolated Chromium profile (`--user-data-dir`) on first `navigate`
/// if port `9222` is not yet listening. If CDP is unavailable or fails, fails
/// closed with `browser_engine_not_available` (Rule H1).
class CdpBrowserEngineProvider implements BrowserEngineProvider {
  CdpBrowserEngineProvider({
    this.cdpEndpoint = 'http://127.0.0.1:9222',
    this.autoLaunchBrowser = false,
    this.userDataDirPath,
    this.connectTimeout = const Duration(milliseconds: 1500),
    CdpBrowserLauncher? browserLauncher,
  }) : _browserLauncher = browserLauncher;

  final String cdpEndpoint;
  final bool autoLaunchBrowser;
  final String? userDataDirPath;
  final Duration connectTimeout;
  final CdpBrowserLauncher? _browserLauncher;

  int _snapshotCounter = 0;
  Process? _spawnedBrowser;

  @override
  Future<Map<String, Object?>> navigate({
    required String url,
    int? timeoutMs,
  }) async {
    final parsed = Uri.tryParse(url.trim());
    if (parsed == null || parsed.scheme.toLowerCase() != 'https') {
      throw const XunaHostChannelException(
        status: XtpStatus.invalidArgs,
        errorCode: 'url_invalid',
        message: 'Only public https:// URLs are permitted in web.navigate.',
      );
    }

    return _withCdpSession(allowAutoLaunch: true, (cdp) async {
      await cdp.send('Page.enable');
      final navRes = await cdp.send('Page.navigate', <String, Object?>{
        'url': url.trim(),
      });
      final errorText = navRes['errorText'];
      if (errorText is String && errorText.trim().isNotEmpty) {
        throw XunaHostChannelException(
          status: XtpStatus.failed,
          errorCode: 'navigation_failed',
          message: 'Browser navigation failed: $errorText',
        );
      }

      final budgetMs = (timeoutMs ?? 6000).clamp(400, 8500);
      final sw = Stopwatch()..start();
      while (sw.elapsedMilliseconds < budgetMs) {
        final ready = await cdp.evaluateJson('''
(() => {
  const href = String(window.location && window.location.href || '');
  const state = String(document.readyState || '');
  return {
    href,
    title: String(document.title || ''),
    ready: href !== '' && href !== 'about:blank' && (state === 'interactive' || state === 'complete')
  };
})()
''');
        if (ready['ready'] == true) {
          final finalUrl = (ready['href'] as String?)?.trim();
          final finalTitle = (ready['title'] as String?)?.trim() ?? '';
          return <String, Object?>{
            'url': (finalUrl != null && finalUrl.isNotEmpty)
                ? finalUrl
                : url.trim(),
            'title': finalTitle,
            'status': 200,
            'loaded': true,
            'navigated': true,
          };
        }
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }

      final fallback = await cdp.evaluateJson(
        '({href: String(location.href || ""), title: String(document.title || "")})',
      );
      final currentHref = (fallback['href'] as String?)?.trim() ?? url.trim();
      final currentTitle = (fallback['title'] as String?)?.trim() ?? '';
      return <String, Object?>{
        'url': currentHref.isEmpty ? url.trim() : currentHref,
        'title': currentTitle,
        'status': 200,
        'loaded': true,
        'navigated': true,
      };
    });
  }

  @override
  Future<Map<String, Object?>> snapshot({
    bool compact = true,
    int maxBytes = 6144,
  }) async {
    final effectiveCap = maxBytes.clamp(512, maxToolOutputBytes);
    return _withCdpSession((cdp) async {
      final raw = await cdp.evaluateJson('''
(() => {
  const href = String(window.location && window.location.href || '');
  if (!href || href === 'about:blank') {
    return { error: 'no_page_loaded' };
  }
  const title = String(document.title || '');
  const candidates = Array.from(document.querySelectorAll(
    'h1, h2, h3, h4, a[href], button, input:not([type="hidden"]), textarea, select, summary, [role="button"], [role="link"], [role="textbox"], [role="searchbox"], [role="combobox"], [role="checkbox"], [role="tab"], [contenteditable="true"]'
  ));
  const seen = new Set();
  const elements = [];
  let idx = 0;
  for (const el of candidates) {
    if (seen.has(el)) continue;
    seen.add(el);
    const style = window.getComputedStyle(el);
    if (!style || style.display === 'none' || style.visibility === 'hidden') continue;
    const rect = el.getBoundingClientRect();
    if (rect.width < 2 && rect.height < 2) continue;
    idx += 1;
    if (idx > 80) break;
    const ref = 'e' + idx;
    el.setAttribute('data-xuna-ref', ref);
    const tag = (el.tagName || '').toLowerCase();
    const inputType = tag === 'input' ? String(el.type || 'text').toLowerCase() : '';
    const isPassword = inputType === 'password';
    let role = el.getAttribute('role') || '';
    if (!role) {
      if (tag.match(/^h[1-6]\$/)) role = 'heading';
      else if (tag === 'a') role = 'link';
      else if (tag === 'button' || inputType === 'submit' || inputType === 'button') role = 'button';
      else if (tag === 'select') role = 'combobox';
      else if (inputType === 'checkbox') role = 'checkbox';
      else if (inputType === 'radio') role = 'radio';
      else if (tag === 'input' || tag === 'textarea' || el.isContentEditable) role = isPassword ? 'password' : 'textbox';
      else role = tag;
    }
    const rawName = (
      el.getAttribute('aria-label') ||
      el.getAttribute('placeholder') ||
      (tag === 'input' || tag === 'textarea' || tag === 'select' ? '' : el.innerText) ||
      el.getAttribute('title') ||
      el.getAttribute('name') ||
      el.id ||
      ''
    ).replace(/\\s+/g, ' ').trim().slice(0, 90);
    const name = isPassword ? '[REDACTED_PASSWORD_FIELD]' : rawName;
    let val = null;
    if (isPassword) {
      val = '[REDACTED]';
    } else if (tag === 'input' || tag === 'textarea' || tag === 'select') {
      const v = String(el.value || '').trim();
      if (v) val = v.slice(0, 80);
    }
    let options = [];
    if (tag === 'select' && el.options) {
      options = Array.from(el.options).slice(0, 10).map(o => String(o.value || o.text || '').trim()).filter(Boolean);
    }
    const selector = el.id ? ('#' + el.id) : null;
    const actionable = role !== 'heading';
    elements.push({ ref, role, name, selector, value: val, options, actionable, isPassword });
  }
  return { url: href, title, elements };
})()
''');

      if (raw['error'] == 'no_page_loaded') {
        throw const XunaHostChannelException(
          status: XtpStatus.failed,
          errorCode: 'no_page_loaded',
          message: 'No page is currently loaded in browser.',
        );
      }

      final currentUrl = (raw['url'] as String?) ?? '';
      final pageTitle = (raw['title'] as String?) ?? '';
      final rawElements = (raw['elements'] as List?) ?? const <Object?>[];

      _snapshotCounter++;
      final snapId = 'snap-$_snapshotCounter';
      final treeCap = compact
          ? (effectiveCap ~/ 2).clamp(256, 2600)
          : effectiveCap;
      final buffer = StringBuffer('# ARIA Tree — $pageTitle ($currentUrl)\n');
      final mappedElements = <Map<String, Object?>>[];

      for (final item in rawElements) {
        if (item is! Map) continue;
        final ref = (item['ref'] as String?) ?? '';
        final role = (item['role'] as String?) ?? 'element';
        final rawName = (item['name'] as String?) ?? '';
        final safeName = redactSensitiveTokens(rawName, maxChars: 90);
        final rawVal = item['value'] as String?;
        final safeVal = rawVal != null
            ? (item['isPassword'] == true
                  ? '[REDACTED]'
                  : redactSensitiveTokens(rawVal, maxChars: 80))
            : null;
        final rawOpts =
            (item['options'] as List?)?.whereType<String>().toList() ??
            const <String>[];
        final isConseq = isConsequentialElementName(safeName);

        final line =
            '[$ref] $role "$safeName"'
            '${safeVal != null ? ' value="$safeVal"' : ''}'
            '${rawOpts.isNotEmpty ? ' options=$rawOpts' : ''}'
            '${isConseq ? ' [consequential]' : ''}\n';
        if (utf8.encode(buffer.toString()).length + utf8.encode(line).length <=
            treeCap) {
          buffer.write(line);
        }

        if (mappedElements.length < 30) {
          mappedElements.add(<String, Object?>{
            'ref': ref,
            'role': role,
            'name': safeName,
            if (item['selector'] is String) 'selector': item['selector'],
            if (safeVal != null) 'value': safeVal,
            'actionable': item['actionable'] != false,
          });
        }
      }

      final redactedTree = redactBrowserSnapshot(
        buffer.toString(),
        maxBytes: treeCap,
      ).text;

      var result = <String, Object?>{
        'snapshotId': snapId,
        'url': currentUrl,
        'pageTitle': pageTitle,
        'title': pageTitle,
        'elementCount': rawElements.length,
        'compactAriaTree': redactedTree,
        if (!compact) 'snapshot': redactedTree,
        'elements': mappedElements,
      };
      while (mappedElements.isNotEmpty &&
          utf8.encode(jsonEncode(result)).length > effectiveCap) {
        mappedElements.removeLast();
        result = <String, Object?>{
          'snapshotId': snapId,
          'url': currentUrl,
          'pageTitle': pageTitle,
          'title': pageTitle,
          'elementCount': rawElements.length,
          'compactAriaTree': redactedTree,
          'elements': mappedElements,
        };
      }
      return result;
    });
  }

  @override
  Future<Map<String, Object?>> click({
    required String ref,
    String? selector,
  }) async {
    return _withCdpSession((cdp) async {
      final refJson = jsonEncode(ref);
      final selJson = jsonEncode(selector ?? '');
      final res = await cdp.evaluateJson('''
(() => {
  const ref = $refJson;
  const sel = $selJson;
  let el = ref ? document.querySelector('[data-xuna-ref=' + JSON.stringify(ref) + ']') : null;
  if (!el && sel) {
    try { el = document.querySelector(sel); } catch (_) { el = null; }
  }
  if (!el) return { error: 'element_not_found' };
  const role = el.getAttribute('role') || (el.tagName || '').toLowerCase();
  if (typeof el.scrollIntoView === 'function') {
    el.scrollIntoView({ block: 'center', inline: 'center' });
  }
  if (typeof el.focus === 'function') el.focus();
  el.click();
  return {
    ref: el.getAttribute('data-xuna-ref') || ref,
    role,
    clicked: true,
    action: 'click',
    pageTitle: String(document.title || '')
  };
})()
''');
      _throwIfDomError(res, ref: ref);
      return res;
    });
  }

  @override
  Future<Map<String, Object?>> fill({
    required String ref,
    required String value,
    String? selector,
  }) async {
    return _withCdpSession((cdp) async {
      final refJson = jsonEncode(ref);
      final selJson = jsonEncode(selector ?? '');
      final valJson = jsonEncode(value);
      final res = await cdp.evaluateJson('''
(() => {
  const ref = $refJson;
  const sel = $selJson;
  const val = $valJson;
  let el = ref ? document.querySelector('[data-xuna-ref=' + JSON.stringify(ref) + ']') : null;
  if (!el && sel) {
    try { el = document.querySelector(sel); } catch (_) { el = null; }
  }
  if (!el) return { error: 'element_not_found' };
  const tag = (el.tagName || '').toLowerCase();
  if (tag === 'input' && String(el.type || '').toLowerCase() === 'password') {
    return { error: 'password_field_forbidden' };
  }
  if (typeof el.focus === 'function') el.focus();
  if (el.isContentEditable) {
    el.textContent = val;
  } else {
    const proto = tag === 'textarea'
      ? window.HTMLTextAreaElement && window.HTMLTextAreaElement.prototype
      : window.HTMLInputElement && window.HTMLInputElement.prototype;
    const desc = proto ? Object.getOwnPropertyDescriptor(proto, 'value') : null;
    if (desc && typeof desc.set === 'function') {
      desc.set.call(el, val);
    } else {
      el.value = val;
    }
  }
  el.dispatchEvent(new Event('input', { bubbles: true }));
  el.dispatchEvent(new Event('change', { bubbles: true }));
  return {
    ref: el.getAttribute('data-xuna-ref') || ref,
    filled: true,
    valueLength: val.length
  };
})()
''');
      _throwIfDomError(res, ref: ref);
      return res;
    });
  }

  @override
  Future<Map<String, Object?>> select({
    required String ref,
    required String value,
    String? selector,
  }) async {
    return _withCdpSession((cdp) async {
      final refJson = jsonEncode(ref);
      final selJson = jsonEncode(selector ?? '');
      final valJson = jsonEncode(value);
      final res = await cdp.evaluateJson('''
(() => {
  const ref = $refJson;
  const sel = $selJson;
  const val = $valJson;
  let el = ref ? document.querySelector('[data-xuna-ref=' + JSON.stringify(ref) + ']') : null;
  if (!el && sel) {
    try { el = document.querySelector(sel); } catch (_) { el = null; }
  }
  if (!el) return { error: 'element_not_found' };
  if ((el.tagName || '').toLowerCase() !== 'select') {
    return { error: 'invalid_select_element' };
  }
  const opts = Array.from(el.options || []);
  const matched = opts.find(o => o.value === val || (o.text || '').trim() === val);
  if (!matched) return { error: 'option_not_found' };
  el.value = matched.value;
  el.dispatchEvent(new Event('input', { bubbles: true }));
  el.dispatchEvent(new Event('change', { bubbles: true }));
  return {
    ref: el.getAttribute('data-xuna-ref') || ref,
    selected: true,
    value: matched.value,
    selectedValue: matched.value
  };
})()
''');
      _throwIfDomError(res, ref: ref);
      return res;
    });
  }

  @override
  Future<Map<String, Object?>> extract({
    String? ref,
    String? selector,
    String? attribute,
  }) async {
    return _withCdpSession((cdp) async {
      if ((ref == null || ref.trim().isEmpty) &&
          (selector == null || selector.trim().isEmpty)) {
        final summary = await cdp.evaluateJson('''
(() => {
  const href = String(window.location && window.location.href || '');
  if (!href || href === 'about:blank') return { error: 'no_page_loaded' };
  const bodyText = String(document.body && document.body.innerText || '').replace(/\\s+/g, ' ').trim().slice(0, 1600);
  const count = document.querySelectorAll('[data-xuna-ref]').length;
  return {
    title: String(document.title || ''),
    url: href,
    elementCount: count,
    content: bodyText,
    extracted: true
  };
})()
''');
        _throwIfDomError(summary, ref: '');
        final rawContent = summary['content'] as String? ?? '';
        return <String, Object?>{
          'title': summary['title'] ?? '',
          'url': summary['url'] ?? '',
          'elementCount': summary['elementCount'] ?? 0,
          'content': redactSensitiveTokens(rawContent, maxChars: 1600),
          'extracted': true,
        };
      }

      final refJson = jsonEncode(ref ?? '');
      final selJson = jsonEncode(selector ?? '');
      final attrJson = jsonEncode(attribute ?? '');
      final res = await cdp.evaluateJson('''
(() => {
  const ref = $refJson;
  const sel = $selJson;
  const attr = $attrJson;
  let el = ref ? document.querySelector('[data-xuna-ref=' + JSON.stringify(ref) + ']') : null;
  if (!el && sel) {
    try { el = document.querySelector(sel); } catch (_) { el = null; }
  }
  if (!el) return { error: 'element_not_found' };
  const tag = (el.tagName || '').toLowerCase();
  if (tag === 'input' && String(el.type || '').toLowerCase() === 'password') {
    return { value: '[REDACTED]' };
  }
  let extracted = '';
  if (attr) {
    extracted = String(el.getAttribute(attr) || '');
  } else if (tag === 'input' || tag === 'textarea' || tag === 'select') {
    extracted = String(el.value || '');
  } else {
    extracted = String(el.innerText || el.textContent || '').replace(/\\s+/g, ' ').trim();
  }
  return { value: extracted.slice(0, 1600) };
})()
''');
      _throwIfDomError(res, ref: ref ?? selector ?? '');
      final safeVal = redactSensitiveTokens(
        (res['value'] as String?) ?? '',
        maxChars: 1600,
      );
      return <String, Object?>{
        if (ref != null) 'ref': ref,
        if (attribute != null) 'attribute': attribute,
        'value': safeVal,
        'content': safeVal,
        'extracted': true,
      };
    });
  }

  @override
  Future<Map<String, Object?>> waitFor({
    String? selector,
    String? state,
    int? timeoutMs,
  }) async {
    final targetSelector = (selector != null && selector.trim().isNotEmpty)
        ? selector.trim()
        : 'body';
    final desiredState = (state ?? 'visible').trim().toLowerCase();
    final budgetMs = (timeoutMs ?? 3000).clamp(100, 8000);

    return _withCdpSession((cdp) async {
      final selJson = jsonEncode(targetSelector);
      final stateJson = jsonEncode(desiredState);
      final sw = Stopwatch()..start();
      while (sw.elapsedMilliseconds <= budgetMs) {
        final probe = await cdp.evaluateJson('''
(() => {
  const sel = $selJson;
  const desired = $stateJson;
  let el = null;
  try { el = document.querySelector(sel); } catch (_) { return { invalidSelector: true }; }
  const attached = el !== null;
  let visible = false;
  if (el) {
    const st = window.getComputedStyle(el);
    const r = el.getBoundingClientRect();
    visible = !!st && st.display !== 'none' && st.visibility !== 'hidden' && (r.width > 0 || r.height > 0);
  }
  const ok = desired === 'hidden'
    ? !visible
    : desired === 'detached'
      ? !attached
      : desired === 'attached'
        ? attached
        : visible;
  return { ok };
})()
''');
        if (probe['invalidSelector'] == true) {
          throw XunaHostChannelException(
            status: XtpStatus.invalidArgs,
            errorCode: 'invalid_selector',
            message: 'Invalid CSS selector "$targetSelector".',
          );
        }
        if (probe['ok'] == true) {
          return <String, Object?>{
            'selector': targetSelector,
            'state': desiredState,
            'waited': true,
            'satisfied': true,
            'elapsedMs': sw.elapsedMilliseconds,
          };
        }
        if (sw.elapsedMilliseconds >= budgetMs) break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }

      throw XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'timeout',
        message:
            'Timed out waiting for selector "$targetSelector" to become $desiredState.',
      );
    });
  }

  Future<void> dispose() async {
    final proc = _spawnedBrowser;
    _spawnedBrowser = null;
    proc?.kill();
  }

  void _throwIfDomError(Map<String, Object?> res, {required String ref}) {
    final err = res['error'];
    if (err == null) return;
    switch (err) {
      case 'no_page_loaded':
        throw const XunaHostChannelException(
          status: XtpStatus.failed,
          errorCode: 'no_page_loaded',
          message: 'No page is currently loaded in browser.',
        );
      case 'element_not_found':
        throw XunaHostChannelException(
          status: XtpStatus.failed,
          errorCode: 'element_not_found',
          message: 'Element "$ref" was not found in active DOM.',
        );
      case 'password_field_forbidden':
        throw const XunaHostChannelException(
          status: XtpStatus.denied,
          errorCode: 'password_field_forbidden',
          message: 'Refused to fill or read a password input field.',
        );
      case 'option_not_found':
      case 'invalid_select_element':
        throw XunaHostChannelException(
          status: XtpStatus.invalidArgs,
          errorCode: err.toString(),
          message: 'Cannot select option on element "$ref" ($err).',
        );
      default:
        throw XunaHostChannelException(
          status: XtpStatus.failed,
          errorCode: 'browser_dom_error',
          message: 'Browser DOM operation failed: $err',
        );
    }
  }

  Uri _validatedBaseUri() {
    final uri = Uri.tryParse(cdpEndpoint);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        !_isLoopbackHost(uri.host)) {
      throw const XunaHostChannelException(
        status: XtpStatus.unsupported,
        errorCode: 'browser_engine_not_available',
        message: 'CDP endpoint must be a loopback address.',
      );
    }
    return uri;
  }

  static bool _isLoopbackHost(String host) {
    final lower = host.trim().toLowerCase();
    return lower == '127.0.0.1' || lower == 'localhost' || lower == '::1';
  }

  Future<T> _withCdpSession<T>(
    Future<T> Function(_CdpPageClient client) action, {
    bool allowAutoLaunch = false,
  }) async {
    final wsUrl = await _resolvePageWebSocketUrl(
      allowAutoLaunch: allowAutoLaunch,
    );
    WebSocket socket;
    try {
      socket = await WebSocket.connect(wsUrl).timeout(connectTimeout);
    } catch (_) {
      throw const XunaHostChannelException(
        status: XtpStatus.unsupported,
        errorCode: 'browser_engine_not_available',
        message: 'Chrome CDP or Playwright browser context is not running.',
      );
    }
    final client = _CdpPageClient(socket);
    try {
      return await action(client);
    } finally {
      await client.close();
    }
  }

  Future<String> _resolvePageWebSocketUrl({
    required bool allowAutoLaunch,
  }) async {
    final baseUri = _validatedBaseUri();
    var wsUrl = await _tryFetchPageWsUrl(baseUri);
    if (wsUrl != null) return wsUrl;

    if (allowAutoLaunch && autoLaunchBrowser) {
      final launched = await _ensureIsolatedBrowserRunning(
        baseUri.port == 0 ? 9222 : baseUri.port,
      );
      if (launched) {
        final sw = Stopwatch()..start();
        while (sw.elapsedMilliseconds < 4000) {
          await Future<void>.delayed(const Duration(milliseconds: 220));
          wsUrl = await _tryFetchPageWsUrl(baseUri);
          if (wsUrl != null) return wsUrl;
        }
      }
    }

    throw const XunaHostChannelException(
      status: XtpStatus.unsupported,
      errorCode: 'browser_engine_not_available',
      message: 'Chrome CDP or Playwright browser context is not running.',
    );
  }

  Future<String?> _tryFetchPageWsUrl(Uri baseUri) async {
    final client = HttpClient()..connectionTimeout = connectTimeout;
    try {
      final listUri = baseUri.replace(path: '/json/list', query: null);
      final req = await client.getUrl(listUri).timeout(connectTimeout);
      final res = await req.close().timeout(connectTimeout);
      if (res.statusCode != 200) return null;
      final body = await utf8.decoder.bind(res).join().timeout(connectTimeout);
      final decoded = jsonDecode(body);
      if (decoded is List) {
        for (final entry in decoded) {
          if (entry is Map && entry['type'] == 'page') {
            final ws = entry['webSocketDebuggerUrl'];
            if (ws is String && ws.isNotEmpty) {
              final wsUri = Uri.tryParse(ws);
              if (wsUri != null &&
                  (wsUri.scheme == 'ws' || wsUri.scheme == 'wss') &&
                  _isLoopbackHost(wsUri.host)) {
                return ws;
              }
            }
          }
        }
      }
      // Open a blank page tab if the browser has 0 page targets open.
      final newUri = baseUri.replace(path: '/json/new', query: 'about:blank');
      final newReq = await client.putUrl(newUri).timeout(connectTimeout);
      final newRes = await newReq.close().timeout(connectTimeout);
      if (newRes.statusCode == 200) {
        final newBody = await utf8.decoder
            .bind(newRes)
            .join()
            .timeout(connectTimeout);
        final created = jsonDecode(newBody);
        if (created is Map && created['webSocketDebuggerUrl'] is String) {
          final ws = created['webSocketDebuggerUrl'] as String;
          final wsUri = Uri.tryParse(ws);
          if (wsUri != null &&
              (wsUri.scheme == 'ws' || wsUri.scheme == 'wss') &&
              _isLoopbackHost(wsUri.host)) {
            return ws;
          }
        }
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<bool> _ensureIsolatedBrowserRunning(int port) async {
    final profileDir =
        userDataDirPath ??
        '${Directory.systemTemp.path}/xuna_cdp_profile_$port';
    if (_browserLauncher != null) {
      try {
        _spawnedBrowser ??= await _browserLauncher(port, profileDir);
        return _spawnedBrowser != null;
      } catch (_) {
        return false;
      }
    }

    final binary = _findInstalledChromiumBinary();
    if (binary == null) return false;

    try {
      final dir = Directory(profileDir);
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
        if (!Platform.isWindows) {
          await Process.run('chmod', <String>['0700', dir.path]);
        }
      }
      final cleanEnv = Map<String, String>.from(Platform.environment)
        ..removeWhere((k, _) {
          final upper = k.toUpperCase();
          return upper == 'ELECTRON_RUN_AS_NODE' ||
              upper == 'CHROME_DESKTOP' ||
              upper.startsWith('VSCODE_') ||
              upper.startsWith('ANTIGRAVITY_') ||
              upper.startsWith('AGY_');
        });
      _spawnedBrowser = await Process.start(
        binary,
        <String>[
          '--remote-debugging-port=$port',
          '--remote-debugging-address=127.0.0.1',
          '--user-data-dir=$profileDir',
          '--no-first-run',
          '--no-default-browser-check',
          'about:blank',
        ],
        runInShell: false,
        environment: cleanEnv,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  static String? _findInstalledChromiumBinary() {
    if (Platform.isMacOS) {
      const macCandidates = <String>[
        '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
        '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser',
        '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
        '/Applications/Chromium.app/Contents/MacOS/Chromium',
      ];
      for (final path in macCandidates) {
        if (File(path).existsSync()) return path;
      }
      return null;
    }
    if (Platform.isWindows) {
      final programFiles =
          Platform.environment['ProgramFiles'] ?? r'C:\Program Files';
      final programFilesX86 =
          Platform.environment['ProgramFiles(x86)'] ??
          r'C:\Program Files (x86)';
      final localAppData = Platform.environment['LOCALAPPDATA'] ?? '';
      final winCandidates = <String>[
        '$programFiles\\Google\\Chrome\\Application\\chrome.exe',
        '$programFilesX86\\Google\\Chrome\\Application\\chrome.exe',
        if (localAppData.isNotEmpty)
          '$localAppData\\Google\\Chrome\\Application\\chrome.exe',
        '$programFilesX86\\Microsoft\\Edge\\Application\\msedge.exe',
        '$programFiles\\Microsoft\\Edge\\Application\\msedge.exe',
      ];
      for (final path in winCandidates) {
        if (File(path).existsSync()) return path;
      }
    }
    return null;
  }
}

class _CdpPageClient {
  _CdpPageClient(this._socket) {
    _sub = _socket.listen(
      (dynamic raw) {
        if (raw is! String) return;
        try {
          final decoded = jsonDecode(raw);
          if (decoded is Map && decoded['id'] is int) {
            final id = decoded['id'] as int;
            final completer = _pending.remove(id);
            if (completer != null && !completer.isCompleted) {
              if (decoded['error'] is Map) {
                final errMap = decoded['error'] as Map;
                completer.completeError(
                  XunaHostChannelException(
                    status: XtpStatus.failed,
                    errorCode: 'cdp_protocol_error',
                    message: '${errMap['message'] ?? 'CDP error'}',
                  ),
                );
              } else {
                final res = decoded['result'];
                completer.complete(
                  res is Map
                      ? res.map((k, v) => MapEntry(k.toString(), v))
                      : const <String, Object?>{},
                );
              }
            }
          }
        } catch (_) {
          // Ignore malformed event frames.
        }
      },
      onDone: _failAllPending,
      onError: (_) => _failAllPending(),
    );
  }

  final WebSocket _socket;
  late final StreamSubscription<dynamic> _sub;
  final Map<int, Completer<Map<String, Object?>>> _pending =
      <int, Completer<Map<String, Object?>>>{};
  int _nextId = 1;

  void _failAllPending() {
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.completeError(
          const XunaHostChannelException(
            status: XtpStatus.failed,
            errorCode: 'browser_connection_closed',
            message: 'CDP WebSocket connection closed unexpectedly.',
          ),
        );
      }
    }
    _pending.clear();
  }

  Future<Map<String, Object?>> send(
    String method, [
    Map<String, Object?>? params,
  ]) async {
    final id = _nextId++;
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = completer;
    _socket.add(
      jsonEncode(<String, Object?>{
        'id': id,
        'method': method,
        if (params != null) 'params': params,
      }),
    );
    return completer.future.timeout(
      const Duration(seconds: 8),
      onTimeout: () {
        _pending.remove(id);
        throw const XunaHostChannelException(
          status: XtpStatus.timeout,
          errorCode: 'deadline_exceeded',
          message: 'Timed out waiting for CDP command response.',
        );
      },
    );
  }

  Future<Map<String, Object?>> evaluateJson(String expression) async {
    final res = await send('Runtime.evaluate', <String, Object?>{
      'expression': expression,
      'returnByValue': true,
      'awaitPromise': true,
    });
    if (res['exceptionDetails'] != null) {
      throw const XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'browser_eval_failed',
        message: 'JavaScript evaluation inside browser page failed.',
      );
    }
    final inner = res['result'];
    if (inner is Map && inner['value'] is Map) {
      final valMap = inner['value'] as Map;
      return valMap.map((k, v) => MapEntry(k.toString(), v));
    }
    return const <String, Object?>{};
  }

  Future<void> close() async {
    await _sub.cancel();
    _failAllPending();
    try {
      await _socket.close();
    } catch (_) {}
  }
}
