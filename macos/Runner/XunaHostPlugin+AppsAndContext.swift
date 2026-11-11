import ApplicationServices
import Cocoa
import FlutterMacOS
import UserNotifications

/// App Launch, URL Open, Shortcuts Workflows, TCC Permissions, Host Info, System Actions,
/// and Active Window / Browser Page Context readers for `XunaHostPlugin`.
extension XunaHostPlugin {
  // MARK: - App Launch, URL Open & Workflow Run

  func handleAppLaunch(args: [String: Any], result: @escaping FlutterResult) {
    guard let kind = args["kind"] as? String,
          let target = args["target"] as? String,
          !target.isEmpty
    else {
      replyError(result, code: "failed", message: "Missing kind or target")
      return
    }

    let appUrl: URL?
    if kind == "bundle" {
      if target.hasPrefix("/") || target.hasSuffix(".app") {
        let candidate = URL(fileURLWithPath: target)
        appUrl = FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
      } else {
        appUrl = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target)
      }
    } else if kind == "exe" {
      appUrl = URL(fileURLWithPath: target)
    } else {
      replyError(result, code: "unsupported", message: "Unsupported app kind on macOS")
      return
    }

    guard let resolvedUrl = appUrl else {
      replyError(result, code: "failed", message: "Application not found")
      return
    }

    if #available(macOS 10.15, *) {
      let config = NSWorkspace.OpenConfiguration()
      config.arguments = [] // Never pass arguments.
      config.activates = true
      config.environment = Self.sanitizedChildEnvironment()

      let semaphore = DispatchSemaphore(value: 0)
      var launchError: Error?
      var launchedApp: NSRunningApplication?
      NSWorkspace.shared.openApplication(at: resolvedUrl, configuration: config) { runningApp, err in
        launchedApp = runningApp
        launchError = err
        semaphore.signal()
      }
      _ = semaphore.wait(timeout: .now() + .seconds(8))

      if launchError == nil {
        DispatchQueue.main.async {
          if #available(macOS 14.0, *) {
            launchedApp?.activate()
          } else {
            launchedApp?.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
          }
        }
        replySuccess(result, [:])
        return
      }

      // Fallback via /usr/bin/open -a <appPath> (no shell, no arguments) if LaunchServices XPC failed
      let openProcess = Process()
      openProcess.executableURL = URL(fileURLWithPath: "/usr/bin/open")
      openProcess.arguments = ["-a", resolvedUrl.path]
      openProcess.environment = Self.sanitizedChildEnvironment()
      do {
        try openProcess.run()
        openProcess.waitUntilExit()
        if openProcess.terminationStatus == 0 {
          replySuccess(result, [:])
          return
        }
      } catch {}

      replyError(result, code: "failed", message: "Failed to launch application")
    } else {
      let opened = NSWorkspace.shared.open(resolvedUrl)
      if opened {
        replySuccess(result, [:])
      } else {
        replyError(result, code: "failed", message: "Failed to launch application")
      }
    }
  }

  func handleUrlOpen(args: [String: Any], result: @escaping FlutterResult) {
    guard let urlString = args["url"] as? String,
          urlString.lowercased().hasPrefix("https://"),
          let url = URL(string: urlString),
          url.scheme?.lowercased() == "https"
    else {
      replyError(result, code: "failed", message: "Only https:// URLs are permitted")
      return
    }

    let opened = NSWorkspace.shared.open(url)
    if opened {
      replySuccess(result, [:])
    } else {
      replyError(result, code: "failed", message: "NSWorkspace failed to open URL")
    }
  }

  func handleBrowserCurrentUrl(args: [String: Any], result: @escaping FlutterResult) {
    let requested = (args["browser"] as? String ?? "auto").lowercased()
    let candidates: [(id: String, bundleId: String, script: String)] = [
      (
        "safari",
        "com.apple.Safari",
        "tell application \"Safari\" to get URL of current tab of front window"
      ),
      (
        "chrome",
        "com.google.Chrome",
        "tell application \"Google Chrome\" to get URL of active tab of front window"
      ),
    ]

    let runningBundles = Set(
      NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier }
    )

    for candidate in candidates {
      if requested != "auto" && requested != candidate.id {
        continue
      }
      if !runningBundles.contains(candidate.bundleId) {
        continue
      }
      var errDict: NSDictionary?
      if let scriptObj = NSAppleScript(source: candidate.script) {
        let output = scriptObj.executeAndReturnError(&errDict)
        if let rawUrl = output.stringValue,
           rawUrl.lowercased().hasPrefix("https://")
        {
          replySuccess(result, [
            "url": rawUrl,
            "browser": candidate.id,
          ])
          return
        }
      }
    }

    replyError(
      result,
      code: "invalid_args",
      message: "No active https:// browser tab found"
    )
  }

  func handleWorkflowRun(args: [String: Any], result: @escaping FlutterResult) {
    guard let kind = args["kind"] as? String,
          let target = args["target"] as? String,
          !target.isEmpty
    else {
      replyError(result, code: "failed", message: "Missing kind or target")
      return
    }

    guard kind == "shortcut" else {
      replyError(result, code: "unsupported", message: "Only shortcut workflows are supported on macOS")
      return
    }

    // Reject control characters in shortcut name.
    if target.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
      replyError(result, code: "failed", message: "Invalid shortcut target")
      return
    }

    let shortcutsBin = URL(fileURLWithPath: "/usr/bin/shortcuts")
    guard FileManager.default.isExecutableFile(atPath: shortcutsBin.path) else {
      replyError(result, code: "unsupported", message: "/usr/bin/shortcuts is not available")
      return
    }

    let process = Process()
    process.executableURL = shortcutsBin
    process.arguments = ["run", target]
    process.standardOutput = Pipe()
    process.standardError = Pipe()

    do {
      try process.run()
      process.waitUntilExit()
      if process.terminationStatus == 0 {
        replySuccess(result, [:])
      } else {
        replyError(result, code: "failed", message: "Shortcut execution returned non-zero status")
      }
    } catch {
      replyError(result, code: "failed", message: "Failed to start /usr/bin/shortcuts")
    }
  }

  // MARK: - Permissions, Host Info & Toast

  func handlePermissions(result: @escaping FlutterResult) {
    let axTrusted = AXIsProcessTrusted()
    let axState = axTrusted ? "granted" : "denied"

    let bundles = [
      "com.spotify.client",
      "com.apple.Music",
      "com.apple.systemevents",
    ]
    var automationMap: [String: String] = [:]
    for bundle in bundles {
      automationMap[bundle] = checkAutomationPermission(bundleId: bundle, prompt: false)
    }

    UNUserNotificationCenter.current().getNotificationSettings { settings in
      let notifState: String
      switch settings.authorizationStatus {
      case .authorized, .provisional:
        notifState = "granted"
      case .denied:
        notifState = "denied"
      case .notDetermined:
        notifState = "not_determined"
      @unknown default:
        notifState = "not_determined"
      }
      self.replySuccess(result, [
        "accessibility": axState,
        "automation": automationMap,
        "notifications": notifState,
      ])
    }
  }

  func handleRequestPermission(args: [String: Any], result: @escaping FlutterResult) {
    let kind = args["kind"] as? String ?? ""

    if kind == "accessibility" {
      let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
      let trusted = AXIsProcessTrustedWithOptions(options)
      if !trusted,
         let prefUrl = URL(
           string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
         )
      {
        openSystemSettingsUrl(prefUrl)
      }
      replySuccess(result, ["state": trusted ? "granted" : "denied"])
      return
    }

    if kind.hasPrefix("automation") {
      let parts = kind.split(separator: ":", maxSplits: 1)
      let bundleId = parts.count == 2 ? String(parts[1]) : "com.apple.Music"
      let state = checkAutomationPermission(bundleId: bundleId, prompt: true)
      replySuccess(result, ["state": state])
      return
    }

    if kind == "notifications" {
      UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
        if error != nil {
          self.replySuccess(result, ["state": "not_determined"])
        } else {
          self.replySuccess(result, ["state": granted ? "granted" : "denied"])
        }
      }
      return
    }

    replyError(result, code: "invalid_args", message: "Unsupported permission kind: \(kind)")
  }

  func openSystemSettingsUrl(_ url: URL) {
    let openProcess = Process()
    openProcess.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    openProcess.arguments = [url.absoluteString]
    openProcess.environment = Self.sanitizedChildEnvironment()
    try? openProcess.run()
  }

  func checkAutomationPermission(bundleId: String, prompt: Bool) -> String {
    let targetDesc = NSAppleEventDescriptor(bundleIdentifier: bundleId)
    guard let aeDesc = targetDesc.aeDesc else {
      return "not_determined"
    }
    let status = AEDeterminePermissionToAutomateTarget(
      aeDesc,
      typeWildCard,
      typeWildCard,
      prompt
    )
    switch status {
    case noErr:
      return "granted"
    case OSStatus(errAEEventNotPermitted):
      return "denied"
    case OSStatus(procNotFound), -1744: // errAEEventWouldRequireUserConsent
      return "not_determined"
    default:
      return "not_determined"
    }
  }

  func queryNotificationPermissionState() -> String {
    let semaphore = DispatchSemaphore(value: 0)
    var state = "not_determined"
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      switch settings.authorizationStatus {
      case .authorized, .provisional:
        state = "granted"
      case .denied:
        state = "denied"
      case .notDetermined:
        state = "not_determined"
      @unknown default:
        state = "not_determined"
      }
      semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + .seconds(3))
    return state
  }

  func handleHostInfo(result: @escaping FlutterResult) {
    let ver = ProcessInfo.processInfo.operatingSystemVersion
    let osVersion = "\(ver.majorVersion).\(ver.minorVersion).\(ver.patchVersion)"
    let rawHost = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    let hostname = rawHost
      .replacingOccurrences(of: "’", with: "")
      .replacingOccurrences(of: "'", with: "")
    replySuccess(result, [
      "platform": "macos",
      "osVersion": osVersion,
      "hostname": hostname,
    ])
  }

  func handleShowToast(args: [String: Any], result: @escaping FlutterResult) {
    let rawTitle = (args["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let title = rawTitle.isEmpty ? "XUNA" : truncate(rawTitle)
    let rawBody = (args["body"] as? String) ?? (args["message"] as? String) ?? ""
    let message = truncate(rawBody)
    if !message.isEmpty {
      let content = UNMutableNotificationContent()
      content.title = title
      content.body = message
      let request = UNNotificationRequest(
        identifier: UUID().uuidString,
        content: content,
        trigger: nil
      )
      UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
    replySuccess(result, ["shown": true])
  }

  func handleDisplayWake(result: @escaping FlutterResult) {
    let caffeinateBin = URL(fileURLWithPath: "/usr/bin/caffeinate")
    guard FileManager.default.isExecutableFile(atPath: caffeinateBin.path) else {
      replySuccess(result, ["awake": true])
      return
    }
    let process = Process()
    process.executableURL = caffeinateBin
    process.arguments = ["-u", "-t", "2"]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    do {
      try process.run()
      replySuccess(result, ["awake": true])
    } catch {
      replyError(result, code: "failed", message: "Failed to wake display via caffeinate")
    }
  }

  func handleClipboardReadText(result: @escaping FlutterResult) {
    let raw = NSPasteboard.general.string(forType: .string) ?? ""
    let capped = raw.count > 2400 ? String(raw.prefix(2400)) : raw
    replySuccess(result, ["text": capped])
  }

  func handleLockScreen(result: @escaping FlutterResult) {
    let pmsetBin = URL(fileURLWithPath: "/usr/bin/pmset")
    guard FileManager.default.isExecutableFile(atPath: pmsetBin.path) else {
      replySuccess(result, ["locked": true])
      return
    }
    let process = Process()
    process.executableURL = pmsetBin
    process.arguments = ["displaysleepnow"]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    do {
      try process.run()
      replySuccess(result, ["locked": true])
    } catch {
      replyError(result, code: "failed", message: "Failed to lock/sleep display via pmset")
    }
  }

  func handleReadActiveWindowContext(args: [String: Any], result: @escaping FlutterResult) {
    let rawMax = args["maxChars"] as? Int ?? 600
    let maxChars = min(max(rawMax, 80), 1200)
    guard let app = NSWorkspace.shared.frontmostApplication else {
      replySuccess(result, [
        "appName": "unknown",
        "processName": "unknown",
        "windowTitle": "",
        "focusedRole": "window",
        "visibleText": "",
        "isElevated": false,
      ])
      return
    }
    let appName = app.localizedName ?? "unknown"
    let bundleId = app.bundleIdentifier ?? appName
    var windowTitle = ""
    var focusedRole = "window"
    var visibleText = ""

    if AXIsProcessTrusted() {
      let axApp = AXUIElementCreateApplication(app.processIdentifier)
      var winRef: CFTypeRef?
      if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
         let winElem = winRef
      {
        var titleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(winElem as! AXUIElement, kAXTitleAttribute as CFString, &titleRef) == .success,
           let titleStr = titleRef as? String
        {
          windowTitle = String(titleStr.prefix(160))
        }
      }

      var focusRef: CFTypeRef?
      if AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusRef) == .success,
         let focusElem = focusRef
      {
        let axFocus = focusElem as! AXUIElement
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axFocus, kAXRoleAttribute as CFString, &roleRef) == .success,
           let roleStr = roleRef as? String
        {
          focusedRole = String(roleStr.prefix(40))
        }
        if focusedRole.lowercased() != "axsecuretextfield" {
          var valRef: CFTypeRef?
          if AXUIElementCopyAttributeValue(axFocus, kAXValueAttribute as CFString, &valRef) == .success,
             let valStr = valRef as? String
          {
            visibleText = String(valStr.prefix(maxChars))
          }
        }
      }
    }

    replySuccess(result, [
      "appName": appName,
      "processName": bundleId,
      "windowTitle": windowTitle,
      "focusedRole": focusedRole,
      "visibleText": visibleText,
      "isElevated": false,
    ])
  }

  func handleReadBrowserPageSummary(args: [String: Any], result: @escaping FlutterResult) {
    let rawMax = args["maxChars"] as? Int ?? 800
    let maxChars = min(max(rawMax, 80), 1600)
    let requested = (args["browser"] as? String ?? "auto").lowercased()
    let candidates: [(id: String, bundleId: String, urlScript: String, titleScript: String, textScript: String)] = [
      (
        "safari",
        "com.apple.Safari",
        "tell application \"Safari\" to get URL of current tab of front window",
        "tell application \"Safari\" to get name of current tab of front window",
        "tell application \"Safari\" to do JavaScript \"document.body ? document.body.innerText.slice(0, 1600) : ''\" in current tab of front window"
      ),
      (
        "chrome",
        "com.google.Chrome",
        "tell application \"Google Chrome\" to get URL of active tab of front window",
        "tell application \"Google Chrome\" to get title of active tab of front window",
        "tell application \"Google Chrome\" to execute active tab of front window javascript \"document.body ? document.body.innerText.slice(0, 1600) : ''\""
      ),
      (
        "edge",
        "com.microsoft.edgemac",
        "tell application \"Microsoft Edge\" to get URL of active tab of front window",
        "tell application \"Microsoft Edge\" to get title of active tab of front window",
        "tell application \"Microsoft Edge\" to execute active tab of front window javascript \"document.body ? document.body.innerText.slice(0, 1600) : ''\""
      ),
    ]
    let runningBundles = Set(
      NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier }
    )
    for candidate in candidates {
      if requested != "auto" && requested != candidate.id {
        continue
      }
      if !runningBundles.contains(candidate.bundleId) {
        continue
      }
      var errDict: NSDictionary?
      if let scriptObj = NSAppleScript(source: candidate.urlScript) {
        let output = scriptObj.executeAndReturnError(&errDict)
        if let rawUrl = output.stringValue,
           rawUrl.lowercased().hasPrefix("https://")
        {
          var pageTitle = NSWorkspace.shared.frontmostApplication?.localizedName ?? candidate.id
          if let titleObj = NSAppleScript(source: candidate.titleScript),
             let tVal = titleObj.executeAndReturnError(nil).stringValue,
             !tVal.isEmpty
          {
            pageTitle = tVal
          }
          var bodyText = pageTitle
          if let textObj = NSAppleScript(source: candidate.textScript),
             let bVal = textObj.executeAndReturnError(nil).stringValue,
             !bVal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          {
            bodyText = bVal.trimmingCharacters(in: .whitespacesAndNewlines)
          }
          let lines = bodyText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
          let headings = Array(lines.prefix(5).map { String($0.prefix(120)) })
          replySuccess(result, [
            "url": rawUrl,
            "browser": candidate.id,
            "title": String(pageTitle.prefix(160)),
            "headings": headings.isEmpty ? [String(pageTitle.prefix(160))] : headings,
            "actions": ["scroll_down", "focus_address_bar", "copy_url"],
            "excerpt": String(bodyText.prefix(maxChars)),
          ])
          return
        }
      }
    }
    replyError(
      result,
      code: "invalid_args",
      message: "No active https:// browser tab found"
    )
  }
}
