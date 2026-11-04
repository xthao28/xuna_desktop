import ApplicationServices
import Cocoa
import FlutterMacOS

/// Universal macOS UI Action Executor (AXUIElement actions, Menu Bar traversal, Browser DOM JS bridge,
/// AppleEvents scripting, and CGEvent keyboard/grapheme/pointer escalation) for `XunaHostPlugin`.
extension XunaHostPlugin {
  func postKeyboardShortcut(keyCode: CGKeyCode, flags: CGEventFlags = []) {
    guard let src = CGEventSource(stateID: .hidSystemState),
          let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
          let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
    else {
      return
    }
    down.flags = flags
    up.flags = flags
    down.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.04)
    up.post(tap: .cghidEventTap)
  }

  /// Mirrors OpenClaw `ComputerScreenActionExecutor.postTextGrapheme`: iterates Swift graphemes,
  /// maps newline/tab to physical keys, and posts UTF-16 Unicode via `keyboardSetUnicodeString`.
  func postUnicodeTextGraphemes(_ text: String, submit: Bool) {
    for grapheme in text {
      let keyCode: CGKeyCode = switch grapheme {
      case "\n": 0x24
      case "\t": 0x30
      default: 0
      }
      guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
      else { continue }
      if grapheme != "\n" && grapheme != "\t" {
        let utf16 = Array(String(grapheme).utf16)
        utf16.withUnsafeBufferPointer { buffer in
          guard let baseAddress = buffer.baseAddress else { return }
          keyDown.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: baseAddress)
          keyUp.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: baseAddress)
        }
      }
      keyDown.post(tap: .cghidEventTap)
      usleep(1200)
      keyUp.post(tap: .cghidEventTap)
    }
    if submit {
      Thread.sleep(forTimeInterval: 0.12)
      postKeyboardShortcut(keyCode: 36)
    }
  }

  /// Mirrors OpenClaw `ComputerWindowActionExecutor.invokeMenu`: traverses `kAXMenuBarAttribute`
  /// of the target application, supporting both hierarchical paths (`"File > Open..."`, `"View -> Terminal"`)
  /// and single menu item searches.
  func invokeAppMenuBarItem(app: NSRunningApplication, query: String) -> String? {
    let raw = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else { return nil }
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    var menuBarRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axApp, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
          let menuBar = menuBarRef
    else { return nil }

    let segments = raw
      .replacingOccurrences(of: "->", with: ">")
      .split(separator: ">")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
      .filter { !$0.isEmpty }

    if segments.count >= 2 {
      var currentContainer = (menuBar as! AXUIElement)
      var matchedTitles: [String] = []
      for (idx, seg) in segments.enumerated() {
        func findInLevel(_ el: AXUIElement, depth: Int) -> AXUIElement? {
          if depth > 3 { return nil }
          let role = extractAxString(el, kAXRoleAttribute as String) ?? ""
          let title = (extractAxString(el, kAXTitleAttribute as String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
          if (role.contains("MenuBarItem") || role.contains("MenuItem")) && !title.isEmpty && title.lowercased().contains(seg) {
            matchedTitles.append(title)
            return el
          }
          var childrenRef: CFTypeRef?
          if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &childrenRef) == .success,
             let children = childrenRef as? [AXUIElement]
          {
            for child in children.prefix(40) {
              if let hit = findInLevel(child, depth: depth + 1) {
                return hit
              }
            }
          }
          return nil
        }
        guard let item = findInLevel(currentContainer, depth: 0) else { break }
        _ = AXUIElementPerformAction(item, kAXPressAction as CFString)
        if idx == segments.count - 1 {
          return "MENU_PATH_INVOKED:\(matchedTitles.joined(separator: " > "))"
        }
        Thread.sleep(forTimeInterval: 0.12)
        currentContainer = item
      }
    }

    let needle = (segments.last ?? raw.lowercased())
    func searchMenu(_ element: AXUIElement, depth: Int) -> String? {
      if depth > 4 { return nil }
      let role = extractAxString(element, kAXRoleAttribute as String) ?? ""
      let title = (extractAxString(element, kAXTitleAttribute as String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      if role.contains("MenuItem") && !title.isEmpty && title.lowercased().contains(needle) {
        if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
          return "MENU_INVOKED:\(title)"
        }
      }
      var childrenRef: CFTypeRef?
      if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
         let children = childrenRef as? [AXUIElement]
      {
        for child in children.prefix(35) {
          if let hit = searchMenu(child, depth: depth + 1) {
            return hit
          }
        }
      }
      return nil
    }
    return searchMenu(menuBar as! AXUIElement, depth: 0)
  }

  /// Mirrors OpenClaw `BrowserInspectScript.generated.swift` & `window-actions.ts`:
  /// Executes DOM JavaScript inside Safari, Google Chrome, Brave Browser, Microsoft Edge, or Arc
  /// to click interactive DOM elements (`browser_click`) or type/submit inputs (`browser_type`).
  func tryBrowserDomJavaScriptAction(
    app: NSRunningApplication,
    action: String,
    targetSelectorOrText: String,
    valueText: String,
    submit: Bool
  ) -> String? {
    let bundleId = (app.bundleIdentifier ?? "").lowercased()
    let appName = (app.localizedName ?? "").lowercased()
    let isSafari = bundleId == "com.apple.safari" || appName == "safari"
    let chromiumAppName: String? = switch true {
    case bundleId == "com.google.chrome" || appName.contains("chrome"): "Google Chrome"
    case bundleId == "com.brave.browser" || appName.contains("brave"): "Brave Browser"
    case bundleId == "com.microsoft.edgemac" || appName.contains("edge"): "Microsoft Edge"
    case bundleId == "company.thebrowser.browser" || appName == "arc": "Arc"
    default: nil
    }
    guard isSafari || chromiumAppName != nil else { return nil }

    let escapedTarget = targetSelectorOrText
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "'", with: "\\'")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: " ")
    let escapedValue = valueText
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "'", with: "\\'")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: " ")

    let isTypeAction = action == "browser_type" || action == "set_value_ref" || (!valueText.isEmpty && action != "browser_click" && action != "invoke_ref")
    let submitJs = submit ? "true" : "false"
    let jsPayload: String
    if isTypeAction {
      jsPayload = """
      (function(){
        var q = '\(escapedTarget)'.toLowerCase();
        var val = '\(escapedValue)';
        var doSubmit = \(submitJs);
        var inputs = Array.from(document.querySelectorAll('input:not([type=hidden]):not([type=password]), textarea, [contenteditable="true"], [role="searchbox"], [role="textbox"]'));
        var target = inputs.find(function(el){
          var lbl = ((el.placeholder||'')+' '+(el.getAttribute('aria-label')||'')+' '+(el.name||'')+' '+(el.id||'')).toLowerCase();
          return q && q !== 'auto_search' && lbl.indexOf(q) !== -1;
        }) || inputs.find(function(el){
          var r = el.getBoundingClientRect();
          return r.width > 20 && r.height > 12;
        }) || document.activeElement;
        if (!target) return '';
        target.focus();
        if (target.isContentEditable) {
          target.textContent = val;
        } else {
          var proto = target.tagName === 'TEXTAREA' ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype;
          var setter = Object.getOwnPropertyDescriptor(proto, 'value');
          if (setter && setter.set) { setter.set.call(target, val); } else { target.value = val; }
        }
        target.dispatchEvent(new Event('input', {bubbles:true}));
        target.dispatchEvent(new Event('change', {bubbles:true}));
        if (doSubmit) {
          target.dispatchEvent(new KeyboardEvent('keydown', {key:'Enter', code:'Enter', keyCode:13, which:13, bubbles:true}));
          if (target.form && typeof target.form.requestSubmit === 'function') {
            try { target.form.requestSubmit(); } catch(e){}
          }
        }
        return 'BROWSER_DOM_TYPED:' + (target.placeholder || target.name || target.tagName);
      })()
      """
    } else {
      jsPayload = """
      (function(){
        var q = '\(escapedTarget)'.toLowerCase();
        if (!q) return '';
        try {
          var direct = document.querySelector('\(escapedTarget)');
          if (direct) { direct.click(); return 'BROWSER_DOM_CLICKED_SELECTOR'; }
        } catch(e){}
        var nodes = Array.from(document.querySelectorAll('button, a, [role="button"], input[type="submit"], input[type="button"], [onclick]'));
        var hit = nodes.find(function(el){
          var txt = ((el.innerText||el.value||'')+' '+(el.getAttribute('aria-label')||'')+' '+(el.title||'')).trim().toLowerCase();
          return txt.indexOf(q) !== -1;
        });
        if (!hit) return '';
        hit.scrollIntoView({block:'center', inline:'center'});
        hit.click();
        return 'BROWSER_DOM_CLICKED:' + ((hit.innerText||hit.getAttribute('aria-label')||hit.tagName)||'').trim().slice(0, 40);
      })()
      """
    }

    let oneLineJs = jsPayload
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")

    let appleScript: String
    if isSafari {
      appleScript = """
      tell application "Safari"
        if (count of windows) = 0 then return ""
        return do JavaScript "\(oneLineJs)" in current tab of front window
      end tell
      """
    } else if let chr = chromiumAppName {
      appleScript = """
      tell application "\(chr)"
        if (count of windows) = 0 then return ""
        return execute active tab of front window javascript "\(oneLineJs)"
      end tell
      """
    } else {
      return nil
    }
    if let out = runAppleScript(appleScript, timeoutSeconds: 2.5), !out.isEmpty {
      return out
    }
    return nil
  }

  /// Uses macOS AppleEvents / Scripting Bridge / Deep URI schemes for scriptable apps
  /// (Music, Spotify, Notes, Reminders) before or alongside AXUIElement interaction.
  func tryNativeAppleEventsInAppAction(app: NSRunningApplication, query: String) -> String? {
    let clean = query.replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\\", with: "\\\\")
    guard !clean.isEmpty else { return nil }
    let bundleId = (app.bundleIdentifier ?? "").lowercased()
    let appName = (app.localizedName ?? "").lowercased()
    if bundleId == "com.apple.music" || appName == "music" || appName == "apple music" {
      let script = """
      tell application "Music"
        activate
        try
          set matchedTracks to (every track of playlist 1 whose name contains "\(clean)" or artist contains "\(clean)")
          if (count of matchedTracks) > 0 then
            play item 1 of matchedTracks
            return "APPLE_MUSIC_PLAYED_LIBRARY_TRACK"
          end if
        end try
      end tell
      return ""
      """
      if let out = runAppleScript(script, timeoutSeconds: 2.5), !out.isEmpty {
        return out
      }
    } else if bundleId == "com.spotify.client" || appName.contains("spotify") {
      if let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
         let url = URL(string: "spotify:search:\(encoded)")
      {
        NSWorkspace.shared.open(url)
        Thread.sleep(forTimeInterval: 0.45)
        return "SPOTIFY_URI_SEARCH_OPENED"
      }
    } else if bundleId == "com.apple.notes" || appName == "notes" {
      let script = """
      tell application "Notes"
        activate
        make new note at folder "Notes" with properties {body:"\(clean)"}
        return "APPLE_NOTES_CREATED"
      end tell
      """
      if let out = runAppleScript(script, timeoutSeconds: 2.5), !out.isEmpty {
        return out
      }
    } else if bundleId == "com.apple.reminders" || appName == "reminders" {
      let script = """
      tell application "Reminders"
        activate
        make new reminder with properties {name:"\(clean)"}
        return "APPLE_REMINDERS_CREATED"
      end tell
      """
      if let out = runAppleScript(script, timeoutSeconds: 2.5), !out.isEmpty {
        return out
      }
    }
    return nil
  }

  func pasteTextAndOptionallySubmit(_ text: String, selectAllFirst: Bool = false, submit: Bool) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(text, forType: .string)
    Thread.sleep(forTimeInterval: 0.06)
    if selectAllFirst {
      postKeyboardShortcut(keyCode: 0, flags: .maskCommand)
      Thread.sleep(forTimeInterval: 0.05)
    }
    postKeyboardShortcut(keyCode: 9, flags: .maskCommand)
    if submit {
      Thread.sleep(forTimeInterval: 0.18)
      postKeyboardShortcut(keyCode: 36)
    }
  }

  func sendShortcutByName(_ rawShortcut: String) -> Bool {
    let lower = rawShortcut.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    var flags: CGEventFlags = []
    if lower.contains("cmd") || lower.contains("command") || lower.contains("⌘") {
      flags.insert(.maskCommand)
    }
    if lower.contains("shift") || lower.contains("⇧") {
      flags.insert(.maskShift)
    }
    if lower.contains("alt") || lower.contains("opt") || lower.contains("⌥") {
      flags.insert(.maskAlternate)
    }
    if lower.contains("ctrl") || lower.contains("control") || lower.contains("⌃") {
      flags.insert(.maskControl)
    }

    let keyMap: [String: CGKeyCode] = [
      "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
      "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
      "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
      "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "enter": 36,
      "return": 36, "l": 37, "j": 38, "k": 40, ";": 41, "n": 45, "m": 46, ".": 47,
      "tab": 48, "space": 49, "`": 50, "delete": 51, "backspace": 51, "escape": 53,
      "esc": 53, "left": 123, "right": 124, "down": 125, "up": 126,
    ]
    let tokens = lower
      .replacingOccurrences(of: "+", with: " ")
      .replacingOccurrences(of: "-", with: " ")
      .split(separator: " ")
      .map(String.init)
    guard let lastToken = tokens.last, let code = keyMap[lastToken] else {
      return false
    }
    postKeyboardShortcut(keyCode: code, flags: flags)
    return true
  }

  func handleInvokeWindowUiControl(args: [String: Any], result: @escaping FlutterResult) {
    let action = (args["action"] as? String ?? "invoke_ref").lowercased()
    let refId = (args["refId"] as? String ?? "ui_1").trimmingCharacters(in: .whitespacesAndNewlines)
    let valueText = (args["valueText"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let targetAppQuery = (args["windowTitle"] as? String) ?? (args["appName"] as? String)
    let submit = (args["submit"] as? Bool) ?? true

    let targetApp = resolveTargetApplication(
      matching: targetAppQuery,
      activate: targetAppQuery != nil && !targetAppQuery!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    )
    if let app = targetApp,
       Self.isHardDeniedApp(app.localizedName ?? "", bundleId: app.bundleIdentifier)
    {
      replySuccess(result, [
        "ok": false,
        "invokedRefId": refId,
        "detail": "HARD_DENIED_APP",
        "windowTitle": app.localizedName ?? "macOS Window",
        "nodes": [],
        "screenshotBytesUsed": 0,
      ])
      return
    }

    // 1. Universal keyboard shortcut execution
    if action == "shortcut" || refId.lowercased().hasPrefix("shortcut:") || refId.lowercased().hasPrefix("key:") {
      let shortcutSpec = refId.contains(":")
        ? String(refId.split(separator: ":", maxSplits: 1).last ?? "")
        : (valueText.isEmpty ? refId : valueText)
      let sent = sendShortcutByName(shortcutSpec)
      Thread.sleep(forTimeInterval: 0.35)
      let postSnap = targetApp != nil ? scanApplicationUiTree(app: targetApp!, maxNodes: 45) : nil
      replySuccess(result, [
        "ok": sent,
        "invokedRefId": refId,
        "detail": sent ? "SHORTCUT_SENT:\(shortcutSpec)" : "UNSUPPORTED_SHORTCUT:\(shortcutSpec)",
        "windowTitle": postSnap?.windowTitle ?? targetApp?.localizedName ?? "macOS Window",
        "nodes": postSnap?.nodes ?? [],
        "screenshotBytesUsed": 0,
      ])
      return
    }

    // 1b. Window & App Lifecycle actions
    if action == "bring_to_front" || action == "focus_window" {
      if let app = targetApp {
        app.activate(options: [.activateIgnoringOtherApps])
        Thread.sleep(forTimeInterval: 0.25)
        let postSnap = scanApplicationUiTree(app: app, maxNodes: 45)
        replySuccess(result, [
          "ok": true,
          "invokedRefId": refId,
          "detail": "BROUGHT_TO_FRONT:\(app.localizedName ?? "App")",
          "windowTitle": postSnap.windowTitle,
          "nodes": postSnap.nodes,
          "screenshotBytesUsed": 0,
        ])
        return
      }
    }

    if action == "kill_app" || action == "close_window" {
      if let app = targetApp, !Self.isHardDeniedApp(app.localizedName ?? "", bundleId: app.bundleIdentifier) {
        if action == "close_window" {
          _ = sendShortcutByName("cmd+w")
        } else {
          _ = app.terminate()
        }
        Thread.sleep(forTimeInterval: 0.25)
        replySuccess(result, [
          "ok": true,
          "invokedRefId": refId,
          "detail": action == "close_window" ? "WINDOW_CLOSED" : "APP_TERMINATED",
          "windowTitle": app.localizedName ?? "macOS Window",
          "nodes": [],
          "screenshotBytesUsed": 0,
        ])
        return
      }
    }

    if action == "invoke_menu" || action == "menu_path" {
      if let app = targetApp,
         let menuHit = invokeAppMenuBarItem(app: app, query: valueText.isEmpty ? refId : valueText)
      {
        Thread.sleep(forTimeInterval: 0.35)
        let postSnap = scanApplicationUiTree(app: app, maxNodes: 45)
        replySuccess(result, [
          "ok": true,
          "invokedRefId": refId,
          "detail": menuHit,
          "windowTitle": postSnap.windowTitle,
          "nodes": postSnap.nodes,
          "screenshotBytesUsed": 0,
        ])
        return
      }
    }

    if action.hasPrefix("scroll") {
      let dir = valueText.isEmpty ? action.replacingOccurrences(of: "scroll_", with: "") : valueText
      let pt = cachedUiCenters[refId]
      postScrollWheel(direction: dir.isEmpty ? "down" : dir, amount: 6, at: pt)
      Thread.sleep(forTimeInterval: 0.35)
      let postSnap = targetApp != nil ? scanApplicationUiTree(app: targetApp!, maxNodes: 45) : nil
      replySuccess(result, [
        "ok": true,
        "invokedRefId": refId,
        "detail": "SCROLLED:\(dir.isEmpty ? "down" : dir)",
        "windowTitle": postSnap?.windowTitle ?? targetApp?.localizedName ?? "macOS Window",
        "nodes": postSnap?.nodes ?? [],
        "screenshotBytesUsed": 0,
      ])
      return
    }

    if action == "drag" || action == "left_click_drag" {
      var startPt = cachedUiCenters[refId] ?? CGPoint(x: 400, y: 400)
      var endPt = cachedUiCenters[valueText] ?? CGPoint(x: startPt.x + 160, y: startPt.y)
      if valueText.contains("->") {
        let parts = valueText.split(separator: ">").map {
          $0.replacingOccurrences(of: "-", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if parts.count == 2 {
          let p1 = parts[0].split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
          let p2 = parts[1].split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
          if p1.count == 2 && p2.count == 2 {
            startPt = CGPoint(x: p1[0], y: p1[1])
            endPt = CGPoint(x: p2[0], y: p2[1])
          }
        }
      }
      postMouseDrag(from: startPt, to: endPt)
      Thread.sleep(forTimeInterval: 0.35)
      let postSnap = targetApp != nil ? scanApplicationUiTree(app: targetApp!, maxNodes: 45) : nil
      replySuccess(result, [
        "ok": true,
        "invokedRefId": refId,
        "detail": "DRAGGED:(\(Int(startPt.x)),\(Int(startPt.y)))->(\(Int(endPt.x)),\(Int(endPt.y)))",
        "windowTitle": postSnap?.windowTitle ?? targetApp?.localizedName ?? "macOS Window",
        "nodes": postSnap?.nodes ?? [],
        "screenshotBytesUsed": 0,
      ])
      return
    }

    if action == "browser_click" || action == "browser_type" {
      if let app = targetApp,
         let domRes = tryBrowserDomJavaScriptAction(
           app: app,
           action: action,
           targetSelectorOrText: refId,
           valueText: valueText,
           submit: submit
         )
      {
        Thread.sleep(forTimeInterval: 0.4)
        let postSnap = scanApplicationUiTree(app: app, maxNodes: 45)
        replySuccess(result, [
          "ok": true,
          "invokedRefId": refId,
          "detail": domRes,
          "windowTitle": postSnap.windowTitle,
          "nodes": postSnap.nodes,
          "screenshotBytesUsed": 0,
        ])
        return
      }
    }

    // 2. Ensure live AX tree is populated for the target application
    var currentNodes: [[String: Any]] = []
    if let app = targetApp {
      if cachedUiElements.isEmpty || cachedUiPid != app.processIdentifier {
        let snap = scanApplicationUiTree(app: app, maxNodes: 55)
        currentNodes = snap.nodes
      }
    }

    var matchedKey: String? = cachedUiElements[refId] != nil ? refId : nil
    if let app = targetApp, currentNodes.isEmpty {
      let snap = scanApplicationUiTree(app: app, maxNodes: 55)
      currentNodes = snap.nodes
    }
    if let targetNode = currentNodes.first(where: { ($0["refId"] as? String) == refId }),
       (targetNode["isPassword"] as? Bool) == true
    {
      replySuccess(result, [
        "ok": false,
        "invokedRefId": refId,
        "detail": "REFUSED_PASSWORD_CONTROL",
        "windowTitle": targetApp?.localizedName ?? "macOS Window",
        "nodes": currentNodes,
        "screenshotBytesUsed": 0,
      ])
      return
    }
    if action == "set_value_ref", let existingKey = matchedKey {
      let existingNode = currentNodes.first { ($0["refId"] as? String) == existingKey }
      let existingRole = (existingNode?["role"] as? String ?? "").lowercased()
      if !existingRole.contains("text")
        && !existingRole.contains("search")
        && !existingRole.contains("combo")
        && !existingRole.contains("edit")
        && !existingRole.contains("document")
      {
        matchedKey = nil
      }
    }
    if matchedKey == nil {
      let searchKey = refId.lowercased()
      for node in currentNodes {
        let label = (node["label"] as? String ?? "").lowercased()
        let role = (node["role"] as? String ?? "").lowercased()
        guard let nRef = node["refId"] as? String else { continue }
        if action == "set_value_ref" {
          if role.contains("search") || role.contains("text") || role.contains("combo") || role.contains("edit") {
            matchedKey = nRef
            break
          }
        } else if label.contains(searchKey)
          || ((searchKey.contains("search") || searchKey.contains("input"))
              && (role.contains("search") || role.contains("text") || role.contains("combo")))
        {
          matchedKey = nRef
          break
        }
      }
    }

    let matchedElement = matchedKey != nil ? cachedUiElements[matchedKey!] : nil
    let matchedCenter = matchedKey != nil ? cachedUiCenters[matchedKey!] : nil

    // 2b. Rich pointer click actions
    if action == "double_click" || action == "triple_click" || action == "right_click" || action == "middle_click" || action == "mouse_move" || action == "hover_ref" {
      var targetPoint = matchedCenter ?? (matchedElement != nil ? extractAxCenterPoint(matchedElement!) : nil)
      if targetPoint == nil && valueText.contains(",") {
        let coords = valueText.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        if coords.count == 2 {
          targetPoint = CGPoint(x: coords[0], y: coords[1])
        }
      }
      if let pt = targetPoint {
        if action == "mouse_move" || action == "hover_ref" {
          if let src = CGEventSource(stateID: .hidSystemState),
             let move = CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: pt, mouseButton: .left)
          {
            move.post(tap: .cghidEventTap)
          }
        } else if action == "right_click" {
          postMouseClickPoint(pt, button: .right, clickCount: 1)
        } else if action == "middle_click" {
          postMouseClickPoint(pt, button: .center, clickCount: 1)
        } else if action == "triple_click" {
          postMouseClickPoint(pt, button: .left, clickCount: 3)
        } else {
          postMouseClickPoint(pt, button: .left, clickCount: 2)
        }
        Thread.sleep(forTimeInterval: 0.35)
        let postSnap = targetApp != nil ? scanApplicationUiTree(app: targetApp!, maxNodes: 45) : nil
        replySuccess(result, [
          "ok": true,
          "invokedRefId": matchedKey ?? refId,
          "detail": "\(action.uppercased()):(\(Int(pt.x)),\(Int(pt.y)))",
          "windowTitle": postSnap?.windowTitle ?? targetApp?.localizedName ?? "macOS Window",
          "nodes": postSnap?.nodes ?? [],
          "screenshotBytesUsed": 0,
        ])
        return
      }
    }

    // 3. Universal `set_value_ref`
    if action == "set_value_ref" || (!valueText.isEmpty && action != "invoke_ref") {
      var detail = "CLIPBOARD_PASTED"
      if let app = targetApp, let scripted = tryNativeAppleEventsInAppAction(app: app, query: valueText) {
        detail = scripted
        if scripted == "APPLE_MUSIC_PLAYED_LIBRARY_TRACK" || scripted == "APPLE_NOTES_CREATED" || scripted == "APPLE_REMINDERS_CREATED" {
          Thread.sleep(forTimeInterval: 0.35)
          let postSnap = scanApplicationUiTree(app: app, maxNodes: 45)
          replySuccess(result, [
            "ok": true,
            "invokedRefId": matchedKey ?? refId,
            "detail": detail,
            "windowTitle": postSnap.windowTitle,
            "nodes": postSnap.nodes,
            "screenshotBytesUsed": 0,
          ])
          return
        }
      }
      if let app = targetApp,
         let domTyped = tryBrowserDomJavaScriptAction(
           app: app,
           action: "browser_type",
           targetSelectorOrText: refId,
           valueText: valueText,
           submit: submit
         )
      {
        Thread.sleep(forTimeInterval: 0.4)
        let postSnap = scanApplicationUiTree(app: app, maxNodes: 45)
        replySuccess(result, [
          "ok": true,
          "invokedRefId": matchedKey ?? refId,
          "detail": domTyped,
          "windowTitle": postSnap.windowTitle,
          "nodes": postSnap.nodes,
          "screenshotBytesUsed": 0,
        ])
        return
      }
      if let el = matchedElement {
        _ = AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let err = AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, valueText as CFTypeRef)
        let afterVal = extractAxString(el, kAXValueAttribute as String)
        if err == .success && afterVal == valueText {
          detail = "VERIFIED_AX_VALUE_SET"
          if submit {
            _ = AXUIElementPerformAction(el, kAXConfirmAction as CFString)
            postKeyboardShortcut(keyCode: 36)
          }
        } else {
          targetApp?.activate(options: [.activateIgnoringOtherApps])
          _ = AXUIElementPerformAction(el, kAXPressAction as CFString)
          if let center = matchedCenter ?? extractAxCenterPoint(el) {
            clickScreenPoint(center)
            Thread.sleep(forTimeInterval: 0.1)
          }
          if action == "type_unicode" {
            postUnicodeTextGraphemes(valueText, submit: submit)
            detail = "ESCALATED_FOCUSED_AND_TYPED_UNICODE"
          } else {
            pasteTextAndOptionallySubmit(valueText, selectAllFirst: true, submit: submit)
            detail = "ESCALATED_FOCUSED_AND_PASTED"
          }
        }
      } else {
        targetApp?.activate(options: [.activateIgnoringOtherApps])
        postKeyboardShortcut(keyCode: 3, flags: .maskCommand)
        Thread.sleep(forTimeInterval: 0.22)
        pasteTextAndOptionallySubmit(valueText, selectAllFirst: true, submit: submit)
        detail = detail == "CLIPBOARD_PASTED" ? "SEARCH_OPENED_AND_PASTED" : "\(detail)+SEARCH_PASTED"
      }

      Thread.sleep(forTimeInterval: 0.45)
      let postSnap = targetApp != nil ? scanApplicationUiTree(app: targetApp!, maxNodes: 45) : nil
      replySuccess(result, [
        "ok": true,
        "invokedRefId": matchedKey ?? refId,
        "detail": detail,
        "windowTitle": postSnap?.windowTitle ?? targetApp?.localizedName ?? "macOS Window",
        "nodes": postSnap?.nodes ?? [],
        "screenshotBytesUsed": 0,
      ])
      return
    }

    // 4. Universal `invoke_ref`
    if let app = targetApp,
       let domClicked = tryBrowserDomJavaScriptAction(
         app: app,
         action: "browser_click",
         targetSelectorOrText: valueText.isEmpty ? refId : valueText,
         valueText: "",
         submit: false
       )
    {
      Thread.sleep(forTimeInterval: 0.4)
      let postSnap = scanApplicationUiTree(app: app, maxNodes: 45)
      replySuccess(result, [
        "ok": true,
        "invokedRefId": matchedKey ?? refId,
        "detail": domClicked,
        "windowTitle": postSnap.windowTitle,
        "nodes": postSnap.nodes,
        "screenshotBytesUsed": 0,
      ])
      return
    }

    if let el = matchedElement {
      let preNodeCount = currentNodes.count
      let preVal = extractAxString(el, kAXValueAttribute as String) ?? ""
      var detail = "VERIFIED_AX_PRESSED"
      var err = AXUIElementPerformAction(el, kAXPressAction as CFString)
      if err != .success {
        err = AXUIElementPerformAction(el, kAXConfirmAction as CFString)
      }
      if err != .success {
        err = AXUIElementPerformAction(el, kAXPickAction as CFString)
      }
      if err == .success {
        Thread.sleep(forTimeInterval: 0.2)
        let postVal = extractAxString(el, kAXValueAttribute as String) ?? ""
        let midSnap = targetApp != nil ? scanApplicationUiTree(app: targetApp!, maxNodes: 45) : nil
        let postNodeCount = midSnap?.nodes.count ?? preNodeCount
        if postVal == preVal && postNodeCount == preNodeCount,
           let center = matchedCenter ?? extractAxCenterPoint(el)
        {
          targetApp?.activate(options: [.activateIgnoringOtherApps])
          clickScreenPoint(center)
          detail = "ESCALATED_COORDINATE_CLICKED"
        }
      } else {
        targetApp?.activate(options: [.activateIgnoringOtherApps])
        if let center = matchedCenter ?? extractAxCenterPoint(el) {
          clickScreenPoint(center)
          detail = "COORDINATE_CLICKED"
        } else {
          _ = AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
          postKeyboardShortcut(keyCode: 36)
          detail = "FOCUSED_AND_ENTER"
        }
      }
      Thread.sleep(forTimeInterval: 0.35)
      let postSnap = targetApp != nil ? scanApplicationUiTree(app: targetApp!, maxNodes: 45) : nil
      replySuccess(result, [
        "ok": true,
        "invokedRefId": matchedKey ?? refId,
        "detail": detail,
        "windowTitle": postSnap?.windowTitle ?? targetApp?.localizedName ?? "macOS Window",
        "nodes": postSnap?.nodes ?? [],
        "screenshotBytesUsed": 0,
      ])
      return
    }

    if let app = targetApp, let menuHit = invokeAppMenuBarItem(app: app, query: valueText.isEmpty ? refId : valueText) {
      Thread.sleep(forTimeInterval: 0.35)
      let postSnap = scanApplicationUiTree(app: app, maxNodes: 45)
      replySuccess(result, [
        "ok": true,
        "invokedRefId": refId,
        "detail": menuHit,
        "windowTitle": postSnap.windowTitle,
        "nodes": postSnap.nodes,
        "screenshotBytesUsed": 0,
      ])
      return
    }

    let postSnap = targetApp != nil ? scanApplicationUiTree(app: targetApp!, maxNodes: 45) : nil
    replySuccess(result, [
      "ok": false,
      "invokedRefId": refId,
      "detail": "ELEMENT_NOT_FOUND",
      "windowTitle": postSnap?.windowTitle ?? targetApp?.localizedName ?? "macOS Window",
      "nodes": postSnap?.nodes ?? [],
      "screenshotBytesUsed": 0,
    ])
  }
}
