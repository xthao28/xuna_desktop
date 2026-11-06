import ApplicationServices
import Cocoa
import FlutterMacOS

/// Application discovery, AXUIElement tree scanner, and pointer/scroll CGEvent primitives
/// for `XunaHostPlugin`.
extension XunaHostPlugin {
  func discoverInstalledAppBundleURL(matching query: String) -> URL? {
    let tokens = query
      .lowercased()
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
    guard !tokens.isEmpty else { return nil }

    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser.path
    let searchDirs = [
      "/Applications",
      "/System/Applications",
      "/System/Applications/Utilities",
      "\(home)/Applications",
    ]

    var bestURL: URL?
    var bestScore = 0
    let normalizedQuery = tokens.joined(separator: " ")

    for dir in searchDirs {
      guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
      for item in items where item.hasSuffix(".app") {
        let appPath = "\(dir)/\(item)"
        let appURL = URL(fileURLWithPath: appPath)
        let stem = (item as NSString).deletingPathExtension.lowercased()
        let bundle = Bundle(url: appURL)
        let displayName = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "").lowercased()
        let bundleName = (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "").lowercased()
        let bundleId = (bundle?.bundleIdentifier ?? "").lowercased()
        let candidates = [stem, displayName, bundleName, bundleId].filter { !$0.isEmpty }

        var score = 0
        for cand in candidates {
          if cand == normalizedQuery || cand == query.lowercased() {
            score = max(score, 100)
          } else if cand.hasPrefix(normalizedQuery) || normalizedQuery.hasPrefix(cand) {
            score = max(score, 80)
          } else if cand.contains(normalizedQuery) || normalizedQuery.contains(cand) {
            score = max(score, 65)
          } else {
            let matchedTokens = tokens.filter { cand.contains($0) }.count
            if matchedTokens > 0 {
              score = max(score, matchedTokens * 25)
            }
          }
        }
        if score > bestScore {
          bestScore = score
          bestURL = appURL
        }
      }
    }
    return bestScore >= 25 ? bestURL : nil
  }

  func resolveTargetApplication(matching query: String?, activate: Bool = false) -> NSRunningApplication? {
    let trimmed = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty
      || trimmed.lowercased() == "active"
      || trimmed.lowercased() == "frontmost"
    {
      return NSWorkspace.shared.frontmostApplication
    }

    let lower = trimmed.lowercased()
    let queryTokens = lower
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }

    func findRunning() -> NSRunningApplication? {
      let running = NSWorkspace.shared.runningApplications.filter {
        $0.activationPolicy == .regular
      }
      if let exact = running.first(where: {
        let name = ($0.localizedName ?? "").lowercased()
        let bid = ($0.bundleIdentifier ?? "").lowercased()
        let stem = ($0.bundleURL?.deletingPathExtension().lastPathComponent ?? "").lowercased()
        return name == lower || bid == lower || stem == lower
      }) {
        return exact
      }
      var bestApp: NSRunningApplication?
      var bestScore = 0
      for app in running {
        let name = (app.localizedName ?? "").lowercased()
        let bid = (app.bundleIdentifier ?? "").lowercased()
        let stem = (app.bundleURL?.deletingPathExtension().lastPathComponent ?? "").lowercased()
        var score = 0
        if (!name.isEmpty && (name.contains(lower) || lower.contains(name)))
          || (!stem.isEmpty && (stem.contains(lower) || lower.contains(stem)))
          || (!bid.isEmpty && bid.contains(lower))
        {
          score = 70
        } else {
          let hits = queryTokens.filter { name.contains($0) || stem.contains($0) || bid.contains($0) }.count
          score = hits * 25
        }
        if score > bestScore {
          bestScore = score
          bestApp = app
        }
      }
      return bestScore >= 25 ? bestApp : nil
    }

    var targetApp = findRunning()
    if targetApp == nil && activate {
      let openProc = Process()
      openProc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
      if let bundleURL = discoverInstalledAppBundleURL(matching: trimmed) {
        openProc.arguments = ["-a", bundleURL.path]
      } else {
        openProc.arguments = ["-a", trimmed]
      }
      openProc.environment = Self.sanitizedChildEnvironment()
      try? openProc.run()
      openProc.waitUntilExit()
      for _ in 0..<16 {
        Thread.sleep(forTimeInterval: 0.15)
        if let found = findRunning() {
          targetApp = found
          break
        }
      }
    }

    if let app = targetApp, activate {
      if #available(macOS 14.0, *) {
        app.activate()
      } else {
        app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
      }
      Thread.sleep(forTimeInterval: 0.2)
    }
    return targetApp ?? NSWorkspace.shared.frontmostApplication
  }

  func extractAxString(_ element: AXUIElement, _ attr: String) -> String? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success,
          let val = ref as? String
    else {
      return nil
    }
    let clean = val.trimmingCharacters(in: .whitespacesAndNewlines)
    return clean.isEmpty ? nil : clean
  }

  func extractAxCenterPoint(_ element: AXUIElement) -> CGPoint? {
    var posRef: CFTypeRef?
    var sizeRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
          AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
          let posVal = posRef,
          let sizeVal = sizeRef
    else {
      return nil
    }
    var pt = CGPoint.zero
    var sz = CGSize.zero
    guard AXValueGetValue(posVal as! AXValue, .cgPoint, &pt),
          AXValueGetValue(sizeVal as! AXValue, .cgSize, &sz),
          sz.width > 1,
          sz.height > 1
    else {
      return nil
    }
    return CGPoint(x: pt.x + sz.width / 2.0, y: pt.y + sz.height / 2.0)
  }

  func clickScreenPoint(_ point: CGPoint) {
    postMouseClickPoint(point, button: .left, clickCount: 1)
  }

  /// Mirrors OpenClaw `ComputerScreenActionExecutor`: supports single/double/triple click,
  /// right-click, middle-click, smooth 24-step drag, and scroll wheel ticks.
  func postMouseClickPoint(
    _ point: CGPoint,
    button: CGMouseButton = .left,
    clickCount: Int = 1
  ) {
    let downType: CGEventType
    switch button {
    case .left: downType = .leftMouseDown
    case .right: downType = .rightMouseDown
    default: downType = .otherMouseDown
    }
    let upType: CGEventType
    switch button {
    case .left: upType = .leftMouseUp
    case .right: upType = .rightMouseUp
    default: upType = .otherMouseUp
    }
    guard let src = CGEventSource(stateID: .hidSystemState) else { return }
    if let move = CGEvent(
      mouseEventSource: src,
      mouseType: .mouseMoved,
      mouseCursorPosition: point,
      mouseButton: .left
    ) {
      move.post(tap: .cghidEventTap)
      usleep(12_000)
    }
    let totalClicks = max(1, min(clickCount, 3))
    for step in 1...totalClicks {
      guard let down = CGEvent(
              mouseEventSource: src,
              mouseType: downType,
              mouseCursorPosition: point,
              mouseButton: button
            ),
            let up = CGEvent(
              mouseEventSource: src,
              mouseType: upType,
              mouseCursorPosition: point,
              mouseButton: button
            )
      else { continue }
      down.setIntegerValueField(.mouseEventClickState, value: Int64(step))
      up.setIntegerValueField(.mouseEventClickState, value: Int64(step))
      down.post(tap: .cghidEventTap)
      usleep(15_000)
      up.post(tap: .cghidEventTap)
      if step < totalClicks {
        usleep(35_000)
      }
    }
  }

  func postMouseDrag(from start: CGPoint, to end: CGPoint, steps: Int = 24) {
    guard let src = CGEventSource(stateID: .hidSystemState),
          let down = CGEvent(
            mouseEventSource: src,
            mouseType: .leftMouseDown,
            mouseCursorPosition: start,
            mouseButton: .left
          ),
          let up = CGEvent(
            mouseEventSource: src,
            mouseType: .leftMouseUp,
            mouseCursorPosition: end,
            mouseButton: .left
          )
    else { return }
    if let move = CGEvent(
      mouseEventSource: src,
      mouseType: .mouseMoved,
      mouseCursorPosition: start,
      mouseButton: .left
    ) {
      move.post(tap: .cghidEventTap)
      usleep(15_000)
    }
    down.post(tap: .cghidEventTap)
    let totalSteps = max(4, min(steps, 48))
    for i in 1...totalSteps {
      let t = CGFloat(i) / CGFloat(totalSteps)
      let pos = CGPoint(
        x: start.x + (end.x - start.x) * t,
        y: start.y + (end.y - start.y) * t
      )
      if let drag = CGEvent(
        mouseEventSource: src,
        mouseType: .leftMouseDragged,
        mouseCursorPosition: pos,
        mouseButton: .left
      ) {
        drag.post(tap: .cghidEventTap)
      }
      usleep(12_000)
    }
    up.post(tap: .cghidEventTap)
  }

  func postScrollWheel(direction: String, amount: Int32 = 5, at point: CGPoint? = nil) {
    if let pt = point,
       let src = CGEventSource(stateID: .hidSystemState),
       let move = CGEvent(
         mouseEventSource: src,
         mouseType: .mouseMoved,
         mouseCursorPosition: pt,
         mouseButton: .left
       )
    {
      move.post(tap: .cghidEventTap)
      usleep(10_000)
    }
    let dir = direction.lowercased()
    let ticks = max(1, min(amount, 30))
    let wheel1: Int32
    switch dir {
    case "up", "scroll_up": wheel1 = ticks
    case "down", "scroll_down": wheel1 = -ticks
    default: wheel1 = 0
    }
    let wheel2: Int32
    switch dir {
    case "left", "scroll_left": wheel2 = ticks
    case "right", "scroll_right": wheel2 = -ticks
    default: wheel2 = 0
    }
    if let ev = CGEvent(
      scrollWheelEvent2Source: nil,
      units: .line,
      wheelCount: 2,
      wheel1: wheel1,
      wheel2: wheel2,
      wheel3: 0
    ) {
      ev.post(tap: .cghidEventTap)
    }
  }

  /// Labels of synthetic controls advertised by `collectScriptableAppUiNodes`; the executor
  /// matches on the same constants so advertising and acting cannot drift apart.
  static let notesCreateNodeLabel = "Tạo ghi chú mới / Nhập nội dung ghi chú"
  static let remindersCreateNodeLabel = "Tạo lời nhắc mới (New Reminder)"

  /// True when the element advertises the `AXPress` action.
  func axSupportsPress(_ element: AXUIElement) -> Bool {
    var namesRef: CFArray?
    guard AXUIElementCopyActionNames(element, &namesRef) == .success,
          let names = namesRef as? [String]
    else { return false }
    return names.contains(kAXPressAction as String)
  }

  /// Chromium-based shells (Electron, CEF) only build their accessibility tree after a
  /// client asks for it. Detected from the bundle's frameworks, not from app names.
  func isChromiumShellApp(_ app: NSRunningApplication) -> Bool {
    guard let bundleURL = app.bundleURL else { return false }
    let frameworks = bundleURL.appendingPathComponent("Contents/Frameworks")
    let markers = [
      "Electron Framework.framework",
      "Chromium Embedded Framework.framework",
    ]
    return markers.contains {
      FileManager.default.fileExists(atPath: frameworks.appendingPathComponent($0).path)
    }
  }

  /// Asks a web-based app to expose its accessibility tree.
  /// Returns true when this call switched it on (the tree then needs a moment to build).
  @discardableResult
  func enableAssistiveAccessibility(app: NSRunningApplication, axApp: AXUIElement) -> Bool {
    var current: CFTypeRef?
    if AXUIElementCopyAttributeValue(axApp, "AXManualAccessibility" as CFString, &current) == .success,
       (current as? Bool) == true
    {
      return false
    }
    let manualErr = AXUIElementSetAttributeValue(
      axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    var flipped = manualErr == .success
    if isChromiumShellApp(app) {
      // CEF shells honour this one instead; it is limited to Chromium bundles because
      // it can change window-animation behaviour in native apps.
      let enhancedErr = AXUIElementSetAttributeValue(
        axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
      flipped = flipped || enhancedErr == .success
    }
    return flipped
  }

  func collectInteractiveAxNodes(
    from root: AXUIElement,
    maxNodes: Int,
    into nodes: inout [[String: Any]],
    elementMap: inout [String: AXUIElement],
    centerMap: inout [String: CGPoint],
    redactedCount: inout Int
  ) {
    let interactiveRoles: Set<String> = [
      "AXButton",
      "AXTextField",
      "AXSearchField",
      "AXTextArea",
      "AXComboBox",
      "AXCheckBox",
      "AXRadioButton",
      "AXPopUpButton",
      "AXMenuButton",
      "AXMenuItem",
      "AXTabGroup",
      "AXLink",
      "AXRow",
      "AXCell",
      "AXStaticText",
      "AXSlider",
    ]
    // Roles that are only worth reporting when they are actually clickable
    // (Chromium/Electron exposes many clickable `div`s as labelled AXGroup/AXImage).
    let pressOnlyRoles: Set<String> = ["AXGroup", "AXImage", "AXHeading", "AXListItem"]
    // Text inputs are reported even without a label: chat boxes in web-based apps
    // frequently have no title/description/placeholder, and hiding them blocks typing.
    let textInputRoles: Set<String> = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"]
    var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
    var queueHead = 0
    var visited = 0
    // Web-based UIs nest far deeper than native ones, so allow a deep walk but bound it by time.
    let maxVisited = 2500
    let maxDepth = 22
    let deadline = Date().addingTimeInterval(2.5)

    while queueHead < queue.count && nodes.count < maxNodes && visited < maxVisited
      && Date() < deadline
    {
      let (current, depth) = queue[queueHead]
      queueHead += 1
      visited += 1

      let role = extractAxString(current, kAXRoleAttribute as String) ?? "AXElement"
      let subrole = extractAxString(current, kAXSubroleAttribute as String) ?? ""
      let isSecure = role.lowercased().contains("secure") || subrole.lowercased().contains("secure")
      let title = extractAxString(current, kAXTitleAttribute as String)
      let desc = extractAxString(current, kAXDescriptionAttribute as String)
      let placeholder = extractAxString(current, "AXPlaceholderValue")
      let help = extractAxString(current, kAXHelpAttribute as String)
      let value = isSecure ? nil : extractAxString(current, kAXValueAttribute as String)
      let identifier = extractAxString(current, kAXIdentifierAttribute as String)
      let cmdChar = role == "AXMenuItem" ? extractAxString(current, kAXMenuItemCmdCharAttribute as String) : nil

      var rawLabel = title ?? desc ?? placeholder ?? help ?? value ?? identifier ?? ""
      if let keyChar = cmdChar, !keyChar.isEmpty, !rawLabel.isEmpty {
        rawLabel = "\(rawLabel) [⌘\(keyChar.uppercased())]"
      }
      let isTextInput = textInputRoles.contains(role)
      let isLabelledInteractive = !rawLabel.isEmpty && interactiveRoles.contains(role)
      let isPressableGeneric =
        !rawLabel.isEmpty && pressOnlyRoles.contains(role) && axSupportsPress(current)
      if isSecure || isLabelledInteractive || isTextInput || isPressableGeneric {
        if isSecure {
          redactedCount += 1
        }
        let idx = nodes.count + 1
        let refId = "ui_\(idx)"
        let cleanLabel = isSecure
          ? "[REDACTED_PASSWORD_CONTROL]"
          : String(rawLabel.replacingOccurrences(of: "\n", with: " ").prefix(90))
        var nodeDict: [String: Any] = [
          "refId": refId,
          "role": role,
          "label": cleanLabel,
          "isPassword": isSecure,
          "pattern": (role.contains("Text") || role.contains("Search") || role.contains("Combo"))
            ? "AXValue / Keyboard"
            : "AXPress",
          "status": "ready",
        ]
        if cleanLabel.isEmpty {
          // Honest marker: the control exists but exposes no accessible name.
          nodeDict["unlabeled"] = true
        }
        if let val = value, !val.isEmpty, val != cleanLabel {
          nodeDict["value"] = String(val.prefix(80))
        }
        nodes.append(nodeDict)
        if !isSecure {
          elementMap[refId] = current
          if let center = extractAxCenterPoint(current) {
            centerMap[refId] = center
          }
        }
      }

      if depth < maxDepth {
        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(current, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement]
        {
          for child in children.prefix(80) {
            queue.append((child, depth + 1))
          }
        }
      }
    }
  }

  func scanApplicationUiTree(
    app: NSRunningApplication,
    maxNodes: Int
  ) -> (windowTitle: String, nodes: [[String: Any]], redactedCount: Int) {
    let appName = app.localizedName ?? "macOS Window"
    var winTitle = appName
    var nodes: [[String: Any]] = []
    var elementMap: [String: AXUIElement] = [:]
    var centerMap: [String: CGPoint] = [:]
    var redactedCount = 0

    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    // Keep one slow/hung process from stalling the whole scan.
    AXUIElementSetMessagingTimeout(axApp, 1.0)
    let justEnabledAx = enableAssistiveAccessibility(app: app, axApp: axApp)
    if justEnabledAx {
      Thread.sleep(forTimeInterval: 0.7)
    }
    cachedUiPid = app.processIdentifier
    var winRef: CFTypeRef?
    var targetWindow: AXUIElement?
    if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
       let winElem = winRef
    {
      targetWindow = (winElem as! AXUIElement)
    } else if AXUIElementCopyAttributeValue(axApp, kAXMainWindowAttribute as CFString, &winRef) == .success,
              let winElem = winRef
    {
      targetWindow = (winElem as! AXUIElement)
    } else if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winRef) == .success,
              let winList = winRef as? [AXUIElement],
              let firstWin = winList.first
    {
      targetWindow = firstWin
    }

    if let win = targetWindow {
      if let actualTitle = extractAxString(win, kAXTitleAttribute as String) {
        winTitle = "\(appName) — \(actualTitle)"
      }
      collectInteractiveAxNodes(
        from: win,
        maxNodes: maxNodes,
        into: &nodes,
        elementMap: &elementMap,
        centerMap: &centerMap,
        redactedCount: &redactedCount
      )
      if justEnabledAx && nodes.count < 3 {
        // The web tree can still be building right after it was switched on: one honest retry.
        Thread.sleep(forTimeInterval: 0.9)
        nodes.removeAll()
        elementMap.removeAll()
        centerMap.removeAll()
        redactedCount = 0
        collectInteractiveAxNodes(
          from: win,
          maxNodes: maxNodes,
          into: &nodes,
          elementMap: &elementMap,
          centerMap: &centerMap,
          redactedCount: &redactedCount
        )
      }
    }

    if nodes.count < maxNodes {
      var menuRef: CFTypeRef?
      if AXUIElementCopyAttributeValue(axApp, kAXMenuBarAttribute as CFString, &menuRef) == .success,
         let menuElem = menuRef
      {
        collectInteractiveAxNodes(
          from: menuElem as! AXUIElement,
          maxNodes: min(maxNodes, nodes.count + 12),
          into: &nodes,
          elementMap: &elementMap,
          centerMap: &centerMap,
          redactedCount: &redactedCount
        )
      }
    }
    if nodes.count < maxNodes {
      collectScriptableAppUiNodes(
        for: app,
        maxNodes: maxNodes,
        into: &nodes,
        winTitle: &winTitle
      )
    }
    cachedUiElements = elementMap
    cachedUiCenters = centerMap
    return (winTitle, nodes, redactedCount)
  }

  /// Enriches the UI tree (or provides a complete live fallback when `AXUIElement` is unavailable)
  /// using macOS AppleEvents / Scripting Bridge for Music, Spotify, Browsers, Notes, Reminders, Finder, and Terminal.
  func collectScriptableAppUiNodes(
    for app: NSRunningApplication,
    maxNodes: Int,
    into nodes: inout [[String: Any]],
    winTitle: inout String
  ) {
    let bundleId = (app.bundleIdentifier ?? "").lowercased()
    let appName = (app.localizedName ?? "").lowercased()

    func appendNode(role: String, label: String, pattern: String = "AppleEvents / AXPress", value: String? = nil) {
      guard nodes.count < maxNodes else { return }
      let idx = nodes.count + 1
      var dict: [String: Any] = [
        "refId": "ui_\(idx)",
        "role": role,
        "label": String(label.prefix(90)),
        "isPassword": false,
        "pattern": pattern,
        "status": "ready",
      ]
      if let v = value, !v.isEmpty {
        dict["value"] = String(v.prefix(80))
      }
      nodes.append(dict)
    }

    if bundleId == "com.apple.music" || appName == "music" || appName == "apple music" {
      let script = """
      tell application "Music"
        set pState to (player state as string)
        set curTrack to ""
        try
          set curTrack to (name of current track) & " — " & (artist of current track)
        end try
        set outLines to "STATE:" & pState & "|" & curTrack & linefeed
        repeat with p in every playlist
          set pName to name of p
          set tCount to count of tracks of p
          if tCount > 0 then
            set outLines to outLines & "PLAYLIST:" & pName & " (" & tCount & " bài)" & linefeed
          end if
        end repeat
        repeat with p in every playlist
          set pName to name of p
          if pName is not "Music" then
            set c to count of tracks of p
            if c > 0 then
              set maxT to c
              if maxT > 15 then set maxT to 15
              repeat with i from 1 to maxT
                set t to track i of p
                set outLines to outLines & "TRACK:" & (name of t) & " — " & (artist of t) & " [" & pName & "]" & linefeed
              end repeat
            end if
          end if
        end repeat
        return outLines
      end tell
      """
      appendNode(
        role: "AXSearchField",
        label: "Tìm kiếm / Phát bài hát hoặc playlist trong Music",
        pattern: "AXValue / AppleEvents"
      )
      if let out = runAppleScript(script, timeoutSeconds: 2.5) {
        for rawLine in out.components(separatedBy: .newlines) {
          let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
          if line.hasPrefix("STATE:") {
            let parts = line.replacingOccurrences(of: "STATE:", with: "").components(separatedBy: "|")
            let st = parts.first ?? "stopped"
            let cur = parts.count > 1 ? parts[1] : ""
            if !cur.isEmpty {
              winTitle = "Music — \(cur) (\(st))"
            }
            appendNode(role: "AXButton", label: "Play / Pause Music (\(st))", value: cur)
            appendNode(role: "AXButton", label: "Next Track (Bài tiếp theo)")
            appendNode(role: "AXButton", label: "Previous Track (Bài trước)")
          } else if line.hasPrefix("PLAYLIST:") {
            let pl = line.replacingOccurrences(of: "PLAYLIST:", with: "")
            appendNode(role: "AXButton", label: "Playlist: \(pl)")
          } else if line.hasPrefix("TRACK:") {
            let tr = line.replacingOccurrences(of: "TRACK:", with: "")
            appendNode(role: "AXRow", label: "Bài hát: \(tr)")
          }
        }
      }
      return
    }

    if bundleId == "com.spotify.client" || appName.contains("spotify") {
      let script = """
      tell application "Spotify"
        set pState to (player state as string)
        set curTrack to ""
        try
          set curTrack to (name of current track) & " — " & (artist of current track)
        end try
        return pState & "|" & curTrack
      end tell
      """
      appendNode(
        role: "AXSearchField",
        label: "Tìm kiếm / Phát bài hát hoặc nghệ sĩ trên Spotify",
        pattern: "AXValue / AppleEvents"
      )
      if let out = runAppleScript(script, timeoutSeconds: 2.0) {
        let parts = out.components(separatedBy: "|")
        let st = parts.first ?? "stopped"
        let cur = parts.count > 1 ? parts[1] : ""
        if !cur.isEmpty {
          winTitle = "Spotify — \(cur) (\(st))"
        }
        appendNode(role: "AXButton", label: "Play / Pause Spotify (\(st))", value: cur)
        appendNode(role: "AXButton", label: "Next Track Spotify (Bài tiếp theo)")
        appendNode(role: "AXButton", label: "Previous Track Spotify (Bài trước)")
      }
      return
    }

    let isSafari = bundleId == "com.apple.safari" || appName == "safari"
    let chromiumApp: String?
    if bundleId == "com.google.chrome" || appName.contains("chrome") {
      chromiumApp = "Google Chrome"
    } else if bundleId == "com.brave.browser" || appName.contains("brave") {
      chromiumApp = "Brave Browser"
    } else if bundleId == "com.microsoft.edgemac" || appName.contains("edge") {
      chromiumApp = "Microsoft Edge"
    } else if bundleId == "company.thebrowser.browser" || appName == "arc" {
      chromiumApp = "Arc"
    } else {
      chromiumApp = nil
    }

    if isSafari || chromiumApp != nil {
      let browserName = isSafari ? "Safari" : chromiumApp!
      let tabScript: String
      if isSafari {
        tabScript = """
        tell application "Safari"
          if (count of windows) = 0 then return ""
          set outLines to "ACTIVE:" & (name of current tab of front window) & "|" & (URL of current tab of front window) & linefeed
          set idx to 0
          repeat with t in (tabs of front window)
            set idx to idx + 1
            if idx <= 12 then
              set outLines to outLines & "TAB:" & idx & "|" & (name of t) & "|" & (URL of t) & linefeed
            end if
          end repeat
          return outLines
        end tell
        """
      } else {
        tabScript = """
        tell application "\(browserName)"
          if (count of windows) = 0 then return ""
          set outLines to "ACTIVE:" & (title of active tab of front window) & "|" & (URL of active tab of front window) & linefeed
          set idx to 0
          repeat with t in (tabs of front window)
            set idx to idx + 1
            if idx <= 12 then
              set outLines to outLines & "TAB:" & idx & "|" & (title of t) & "|" & (URL of t) & linefeed
            end if
          end repeat
          return outLines
        end tell
        """
      }
      if let out = runAppleScript(tabScript, timeoutSeconds: 2.5), !out.isEmpty {
        var activeUrl = ""
        for rawLine in out.components(separatedBy: .newlines) {
          let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
          if line.hasPrefix("ACTIVE:") {
            let parts = line.replacingOccurrences(of: "ACTIVE:", with: "").components(separatedBy: "|")
            let title = parts.first ?? browserName
            activeUrl = parts.count > 1 ? parts[1] : ""
            winTitle = "\(browserName) — \(title)"
            appendNode(
              role: "AXSearchField",
              label: "Thanh địa chỉ URL / Tìm kiếm Google hoặc YouTube",
              pattern: "AXValue / BrowserBridge",
              value: activeUrl
            )
            appendNode(role: "AXButton", label: "Mở Tab Mới (New Tab)")
          } else if line.hasPrefix("TAB:") {
            let parts = line.replacingOccurrences(of: "TAB:", with: "").components(separatedBy: "|")
            if parts.count >= 2 {
              let tabIdx = parts[0]
              let tabTitle = parts[1]
              let tabUrl = parts.count > 2 ? parts[2] : ""
              appendNode(
                role: "AXTabGroup",
                label: "Tab #\(tabIdx): \(tabTitle)",
                value: tabUrl
              )
            }
          }
        }
      } else {
        appendNode(
          role: "AXSearchField",
          label: "Thanh địa chỉ URL / Tìm kiếm Google hoặc YouTube",
          pattern: "AXValue / BrowserBridge"
        )
        appendNode(role: "AXButton", label: "Mở Tab Mới (New Tab)")
      }
      return
    }

    if bundleId == "com.apple.notes" || appName == "notes" {
      appendNode(
        role: "AXTextArea",
        label: Self.notesCreateNodeLabel,
        pattern: "AXValue / AppleEvents"
      )
      let script = """
      tell application "Notes"
        set outLines to ""
        set c to count of notes
        if c > 12 then set c to 12
        repeat with i from 1 to c
          set outLines to outLines & (name of note i) & linefeed
        end repeat
        return outLines
      end tell
      """
      if let out = runAppleScript(script, timeoutSeconds: 2.5) {
        for rawLine in out.components(separatedBy: .newlines) {
          let title = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
          if !title.isEmpty {
            appendNode(role: "AXRow", label: "Ghi chú: \(title)")
          }
        }
      }
      return
    }

    if bundleId == "com.apple.reminders" || appName == "reminders" {
      appendNode(
        role: "AXTextField",
        label: Self.remindersCreateNodeLabel,
        pattern: "AXValue / AppleEvents"
      )
      return
    }

    if bundleId == "com.apple.finder" || appName == "finder" {
      appendNode(
        role: "AXSearchField",
        label: "Mở thư mục hoặc đường dẫn trong Finder",
        pattern: "AXValue / AppleEvents"
      )
      appendNode(role: "AXButton", label: "Folder: Downloads (~/Downloads)")
      appendNode(role: "AXButton", label: "Folder: Desktop (~/Desktop)")
      appendNode(role: "AXButton", label: "Folder: Documents (~/Documents)")
      let script = """
      tell application "Finder"
        set outLines to ""
        try
          set curFolder to (target of front Finder window as alias)
          set outLines to "PATH:" & (POSIX path of curFolder) & linefeed
          set itemsList to name of items 1 thru 10 of front Finder window
          repeat with nm in itemsList
            set outLines to outLines & "ITEM:" & (nm as string) & linefeed
          end repeat
        end try
        return outLines
      end tell
      """
      if let out = runAppleScript(script, timeoutSeconds: 2.0) {
        for rawLine in out.components(separatedBy: .newlines) {
          let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
          if line.hasPrefix("PATH:") {
            let p = line.replacingOccurrences(of: "PATH:", with: "")
            winTitle = "Finder — \(p)"
          } else if line.hasPrefix("ITEM:") {
            let item = line.replacingOccurrences(of: "ITEM:", with: "")
            appendNode(role: "AXRow", label: "Tệp/Thư mục: \(item)")
          }
        }
      }
      return
    }
  }

  func handleInspectWindowUiTree(args: [String: Any], result: @escaping FlutterResult) {
    let rawMax = args["maxNodes"] as? Int ?? 35
    let maxNodes = min(max(rawMax, 1), 80)
    let requestedTarget = (args["windowTitle"] as? String) ?? (args["appName"] as? String)
    let app = resolveTargetApplication(matching: requestedTarget, activate: requestedTarget != nil)
    let appName = app?.localizedName ?? "macOS Window"

    guard let targetApp = app,
          !Self.isHardDeniedApp(targetApp.localizedName ?? "", bundleId: targetApp.bundleIdentifier)
    else {
      replySuccess(result, [
        "windowTitle": appName,
        "appName": appName,
        "nodes": [],
        "redactedControlsCount": 0,
        "screenshotBytesUsed": 0,
      ])
      return
    }

    let snapshot = scanApplicationUiTree(app: targetApp, maxNodes: maxNodes)
    replySuccess(result, [
      "windowTitle": String(snapshot.windowTitle.prefix(120)),
      "appName": appName,
      "nodes": snapshot.nodes,
      "redactedControlsCount": snapshot.redactedCount,
      "screenshotBytesUsed": 0,
    ])
  }
}
