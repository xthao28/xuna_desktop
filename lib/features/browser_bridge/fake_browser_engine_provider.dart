import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

import 'browser_engine_provider.dart';

/// In-memory deterministic fake implementation of [BrowserEngineProvider] for testing.
class FakeBrowserEngineProvider implements BrowserEngineProvider {
  final List<Map<String, Object?>> recordedCalls = <Map<String, Object?>>[];
  final List<SimulatedDomElement> elements = <SimulatedDomElement>[];

  String? currentUrl;
  String pageTitle = 'Blank Page';
  bool isLoaded = false;
  Exception? nextException;
  int _snapshotCounter = 0;

  void reset() {
    recordedCalls.clear();
    elements.clear();
    currentUrl = null;
    pageTitle = 'Blank Page';
    isLoaded = false;
    nextException = null;
    _snapshotCounter = 0;
  }

  void loadFixturePage({
    required String url,
    required String title,
    required List<SimulatedDomElement> fixtureElements,
  }) {
    currentUrl = url;
    pageTitle = title;
    elements.clear();
    elements.addAll(fixtureElements);
    isLoaded = true;
  }

  @override
  Future<Map<String, Object?>> navigate({
    required String url,
    int? timeoutMs,
  }) async {
    recordedCalls.add(<String, Object?>{
      'method': 'navigate',
      'url': url,
      if (timeoutMs != null) 'timeoutMs': timeoutMs,
    });
    if (nextException != null) {
      final ex = nextException!;
      nextException = null;
      throw ex;
    }

    currentUrl = url;
    pageTitle = 'Page for $url';
    isLoaded = true;

    // Populate standard deterministic elements if none exist
    if (elements.isEmpty) {
      elements.addAll(<SimulatedDomElement>[
        SimulatedDomElement(ref: 'e1', role: 'heading', name: 'Main Heading'),
        SimulatedDomElement(
          ref: 'e2',
          role: 'textbox',
          name: 'Search',
          selector: '#search-box',
          value: '',
        ),
        SimulatedDomElement(
          ref: 'e3',
          role: 'button',
          name: 'Search Submit',
          selector: '#btn-search',
        ),
        SimulatedDomElement(
          ref: 'e4',
          role: 'combobox',
          name: 'Sort By',
          selector: '#sort-select',
          value: 'relevance',
          options: const <String>['relevance', 'price_asc', 'price_desc'],
        ),
        SimulatedDomElement(
          ref: 'e5',
          role: 'button',
          name: 'Checkout & Pay',
          selector: '#btn-checkout',
          isConsequential: true,
        ),
      ]);
    }

    return <String, Object?>{
      'url': url,
      'title': pageTitle,
      'status': 200,
      'loaded': true,
      'navigated': true,
    };
  }

  @override
  Future<Map<String, Object?>> snapshot({
    bool compact = true,
    int maxBytes = 6144,
  }) async {
    recordedCalls.add(<String, Object?>{
      'method': 'snapshot',
      'compact': compact,
      'maxBytes': maxBytes,
    });
    if (nextException != null) {
      final ex = nextException!;
      nextException = null;
      throw ex;
    }
    if (!isLoaded || currentUrl == null) {
      throw const XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'no_page_loaded',
        message: 'No page is currently loaded in browser.',
      );
    }

    _snapshotCounter++;
    final buffer = StringBuffer('# ARIA Tree — $pageTitle ($currentUrl)\n');
    for (final el in elements) {
      final line = '[${el.ref}] ${el.role} "${el.name}"'
          '${el.value != null ? ' value="${el.value}"' : ''}'
          '${el.options.isNotEmpty ? ' options=${el.options}' : ''}'
          '${el.isConsequential ? ' [consequential]' : ''}\n';
      if (buffer.length + line.length > maxBytes) {
        buffer.write('... [truncated to $maxBytes bytes]\n');
        break;
      }
      buffer.write(line);
    }

    final compactTree = buffer.toString();
    return <String, Object?>{
      'snapshotId': 'snap-$_snapshotCounter',
      'url': currentUrl!,
      'pageTitle': pageTitle,
      'title': pageTitle,
      'elementCount': elements.length,
      'compactAriaTree': compactTree,
      'snapshot': compactTree,
      'elements': elements
          .map((e) => <String, Object?>{
                'ref': e.ref,
                'role': e.role,
                'name': e.name,
                if (e.selector != null) 'selector': e.selector,
                if (e.value != null) 'value': e.value,
                'actionable': e.isActionable,
              })
          .toList(),
    };
  }

  @override
  Future<Map<String, Object?>> click({
    required String ref,
    String? selector,
  }) async {
    recordedCalls.add(<String, Object?>{
      'method': 'click',
      'ref': ref,
      if (selector != null) 'selector': selector,
    });
    if (nextException != null) {
      final ex = nextException!;
      nextException = null;
      throw ex;
    }

    final element = _findElement(ref: ref, selector: selector);
    return <String, Object?>{
      'ref': element.ref,
      'role': element.role,
      'clicked': true,
      'action': 'click',
      'pageTitle': pageTitle,
    };
  }

  @override
  Future<Map<String, Object?>> fill({
    required String ref,
    required String value,
    String? selector,
  }) async {
    recordedCalls.add(<String, Object?>{
      'method': 'fill',
      'ref': ref,
      'value': value,
      if (selector != null) 'selector': selector,
    });
    if (nextException != null) {
      final ex = nextException!;
      nextException = null;
      throw ex;
    }

    final element = _findElement(ref: ref, selector: selector);
    element.value = value;
    return <String, Object?>{
      'ref': element.ref,
      'filled': true,
      'valueLength': value.length,
    };
  }

  @override
  Future<Map<String, Object?>> select({
    required String ref,
    required String value,
    String? selector,
  }) async {
    recordedCalls.add(<String, Object?>{
      'method': 'select',
      'ref': ref,
      'value': value,
      if (selector != null) 'selector': selector,
    });
    if (nextException != null) {
      final ex = nextException!;
      nextException = null;
      throw ex;
    }

    final element = _findElement(ref: ref, selector: selector);
    element.value = value;
    return <String, Object?>{
      'ref': element.ref,
      'selected': true,
      'value': value,
      'selectedValue': value,
    };
  }

  @override
  Future<Map<String, Object?>> extract({
    String? ref,
    String? selector,
    String? attribute,
  }) async {
    recordedCalls.add(<String, Object?>{
      'method': 'extract',
      if (ref != null) 'ref': ref,
      if (selector != null) 'selector': selector,
      if (attribute != null) 'attribute': attribute,
    });
    if (nextException != null) {
      final ex = nextException!;
      nextException = null;
      throw ex;
    }

    if (ref == null && selector == null) {
      return <String, Object?>{
        'title': pageTitle,
        'url': currentUrl,
        'elementCount': elements.length,
        'extracted': true,
      };
    }

    final element = _findElement(ref: ref ?? '', selector: selector);
    String extractedValue;
    if (attribute != null) {
      extractedValue = element.attributes[attribute] ?? element.value ?? '';
    } else {
      extractedValue = element.name;
    }

    return <String, Object?>{
      if (ref != null) 'ref': ref,
      if (attribute != null) 'attribute': attribute,
      'value': extractedValue,
      'content': extractedValue,
      'extracted': true,
    };
  }

  @override
  Future<Map<String, Object?>> waitFor({
    String? selector,
    String? state,
    int? timeoutMs,
  }) async {
    recordedCalls.add(<String, Object?>{
      'method': 'waitFor',
      if (selector != null) 'selector': selector,
      if (state != null) 'state': state,
      if (timeoutMs != null) 'timeoutMs': timeoutMs,
    });
    if (nextException != null) {
      final ex = nextException!;
      nextException = null;
      throw ex;
    }

    if (selector != null &&
        (selector.contains('nonexistent') || selector.contains('missing'))) {
      throw XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'timeout',
        message:
            'Timed out waiting for selector "$selector" to become ${state ?? "visible"}.',
      );
    }

    return <String, Object?>{
      'selector': selector ?? 'body',
      'state': state ?? 'visible',
      'waited': true,
      'satisfied': true,
      'elapsedMs': 20,
    };
  }

  SimulatedDomElement _findElement({required String ref, String? selector}) {
    for (final el in elements) {
      if (ref.isNotEmpty && el.ref == ref) return el;
      if (selector != null && el.selector == selector) return el;
    }
    // Rule H3: Never guess targets
    throw XunaHostChannelException(
      status: XtpStatus.failed,
      errorCode: 'element_not_found',
      message: 'Element "$ref" was not found in active snapshot.',
    );
  }
}
