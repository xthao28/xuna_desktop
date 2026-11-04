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
    let downType: CGEventType = switch button {
    case .left: .leftMouseDown
    case .right: .rightMouseDown
    default: .otherMouseDown
    }
    let upType: CGEventType = switch button {
    case .left: .leftMouseUp
    case .right: .rightMouseUp
    default: .otherMouseUp
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
    let wheel1: Int32 = switch dir {
    case "up", "scroll_up": ticks
    case "down", "scroll_down": -ticks
    default: 0
    }
    let wheel2: Int32 = switch dir {
    case "left", "scroll_left": ticks
    case "right", "scroll_right": -ticks
    default: 0
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
    var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
    var visited = 0
    let maxVisited = 500

    while !queue.isEmpty && nodes.count < maxNodes && visited < maxVisited {
      let (current, depth) = queue.removeFirst()
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
      if isSecure || (!rawLabel.isEmpty && interactiveRoles.contains(role)) {
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

      if depth < 8 {
        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(current, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement]
        {
          for child in children.prefix(45) {
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

    guard AXIsProcessTrusted() else {
      return (winTitle, nodes, redactedCount)
    }

    let axApp = AXUIElementCreateApplication(app.processIdentifier)
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
    cachedUiElements = elementMap
    cachedUiCenters = centerMap
    return (winTitle, nodes, redactedCount)
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
