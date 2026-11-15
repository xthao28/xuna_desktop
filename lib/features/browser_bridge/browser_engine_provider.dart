import 'dart:async';

/// Model representing a simulated or inspectable DOM/ARIA element in the browser.
class SimulatedDomElement {
  SimulatedDomElement({
    required this.ref,
    required this.role,
    required this.name,
    this.selector,
    this.value,
    this.options = const <String>[],
    this.attributes = const <String, String>{},
    this.isActionable = true,
    this.isConsequential = false,
  });

  final String ref; // e.g. "e1", "e2"
  final String role; // "button", "link", "textbox", "combobox", "heading", "checkbox"
  final String name; // Label or inner text
  final String? selector;
  String? value;
  final List<String> options;
  final Map<String, String> attributes;
  final bool isActionable;
  final bool isConsequential;
}

/// Abstract interface for browser engine operations (`UDC-18` §Wave B).
abstract interface class BrowserEngineProvider {
  /// Navigates the browser to [url].
  Future<Map<String, Object?>> navigate({
    required String url,
    int? timeoutMs,
  });

  /// Captures a compact DOM/ARIA accessibility snapshot bounded by [maxBytes].
  Future<Map<String, Object?>> snapshot({
    bool compact = true,
    int maxBytes = 6144,
  });

  /// Clicks an element identified by [ref] or [selector].
  Future<Map<String, Object?>> click({
    required String ref,
    String? selector,
  });

  /// Fills text into an input element identified by [ref] or [selector].
  Future<Map<String, Object?>> fill({
    required String ref,
    required String value,
    String? selector,
  });

  /// Selects an option in a dropdown identified by [ref] or [selector].
  Future<Map<String, Object?>> select({
    required String ref,
    required String value,
    String? selector,
  });

  /// Extracts text or attribute value from an element or page.
  Future<Map<String, Object?>> extract({
    String? ref,
    String? selector,
    String? attribute,
  });

  /// Waits for an element to reach [state] within [timeoutMs].
  Future<Map<String, Object?>> waitFor({
    String? selector,
    String? state,
    int? timeoutMs,
  });
}
