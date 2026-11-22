import ApplicationServices
import Cocoa
import FlutterMacOS
import UserNotifications

/// App Launch, URL Open, Shortcuts Workflows, TCC Permissions, Host Info, System Actions,
/// and Active Window / Browser Page Context readers for `XunaHostPlugin`.
extension XunaHostPlugin {
  // MARK: - App Launch, URL Open & Workflow Run

  static let hardDeniedTerminalBinaryStems: Set<String> = [
    "terminal",
    "iterm",
    "iterm2",
    "warp",
    "alacritty",
    "kitty",
    "hyper",
    "wezterm",
    "wezterm-gui",
    "ghostty",
    "bash",
    "zsh",
    "sh",
    "fish",
    "pwsh",
    "powershell",
    "cmd",
  ]

  static func isHardDeniedResolvedTarget(url: URL, kind: String) -> Bool {
    let urlsToCheck = [
      url.standardizedFileURL,
      url.resolvingSymlinksInPath().standardizedFileURL,
    ]
    for candidate in urlsToCheck {
      let stem = candidate.deletingPathExtension().lastPathComponent
      let bundleId = Bundle(url: candidate)?.bundleIdentifier
      if isHardDeniedApp(stem, bundleId: bundleId) {
        return true
      }
      if hardDeniedTerminalBinaryStems.contains(stem.lowercased()) {
        return true
      }
      var current = candidate
      for _ in 0..<256 {
        if current.path == "/" || current.path.isEmpty {
          break
        }
        if current.pathExtension.lowercased() == "app" {
          let appStem = current.deletingPathExtension().lastPathComponent
          let appBundleId = Bundle(url: current)?.bundleIdentifier
          if isHardDeniedApp(appStem, bundleId: appBundleId) {
            return true
          }
        }
        let next = current.deletingLastPathComponent()
        if next.path == current.path {
          break
        }
        current = next
      }
    }
    return false
  }

  func handleAppLaunch(args: [String: Any], result: @escaping FlutterResult) {
    guard let kind = args["kind"] as? String,
          let target = args["target"] as? String,
          !target.isEmpty
    else {
      replyError(result, code: "failed", message: "Missing kind or target")
      return
    }

    let rawStem = URL(fileURLWithPath: target).deletingPathExtension().lastPathComponent.lowercased()
    if Self.isHardDeniedApp(target, bundleId: kind == "bundle" ? target : nil)
      || Self.hardDeniedTerminalBinaryStems.contains(rawStem)
    {
      replyError(
        result,
        code: "denied",
        message: "Target application is forbidden by policy",
        errorCode: "denylisted_target_forbidden"
      )
      return
    }

    let appUrl: URL?
    if kind == "bundle" {
      if target.hasPrefix("/") || target.hasSuffix(".app") {
        let candidate = URL(fileURLWithPath: target).standardizedFileURL
        appUrl = FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
      } else {
        appUrl = onMainThread {
          NSWorkspace.shared.urlForApplication(withBundleIdentifier: target)
        }
      }
    } else if kind == "exe" {
      let candidate = URL(fileURLWithPath: target).standardizedFileURL
      appUrl = FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    } else {
      replyError(result, code: "unsupported", message: "Unsupported app kind on macOS")
      return
    }

    guard let rawResolvedUrl = appUrl else {
      replyError(result, code: "failed", message: "Application not found")
      return
    }

    if Self.isHardDeniedResolvedTarget(url: rawResolvedUrl, kind: kind) {
      replyError(
        result,
        code: "denied",
        message: "Target application is forbidden by policy",
        errorCode: "denylisted_target_forbidden"
      )
      return
    }
    let resolvedUrl = rawResolvedUrl.resolvingSymlinksInPath().standardizedFileURL
    if kind == "bundle" &&
      (rawResolvedUrl.standardizedFileURL.pathExtension.lowercased() != "app" ||
        resolvedUrl.pathExtension.lowercased() != "app")
    {
      replyError(
        result,
        code: "invalid_args",
        message: "Bundle target must resolve to a .app application bundle",
        errorCode: "invalid_bundle_target"
      )
      return
    }

    var validatedOpenFileUrl: URL?
    if let rawOpenPath = (args["openPath"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
       !rawOpenPath.isEmpty
    {
      let homeDir = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
      let candidateUrl = URL(fileURLWithPath: rawOpenPath).resolvingSymlinksInPath()
      let candidatePath = candidateUrl.path
      guard candidatePath.hasPrefix(homeDir + "/"),
            FileManager.default.fileExists(atPath: candidatePath)
      else {
        replyError(result, code: "denied", message: "Target path must exist inside user home directory")
        return
      }
      validatedOpenFileUrl = candidateUrl
    }

    if validatedOpenFileUrl == nil {
      let resolvedStdPath = resolvedUrl.resolvingSymlinksInPath().standardizedFileURL.path
      let targetBundleId = (kind == "bundle" && !target.hasPrefix("/") && !target.hasSuffix(".app"))
        ? target.lowercased()
        : (Bundle(url: resolvedUrl)?.bundleIdentifier?.lowercased() ?? "")
      let targetName = target.lowercased()
      let resolvedStem = resolvedUrl.deletingPathExtension().lastPathComponent.lowercased()

      let existingApp: NSRunningApplication? = onMainThread {
        let match = NSWorkspace.shared.runningApplications.first { running in
          guard !running.isTerminated else { return false }
          if !targetBundleId.isEmpty,
             let bid = running.bundleIdentifier?.lowercased(),
             bid == targetBundleId
          {
            return true
          }
          if let bPath = running.bundleURL?.resolvingSymlinksInPath().standardizedFileURL.path,
             bPath == resolvedStdPath
          {
            return true
          }
          if let exePath = running.executableURL?.resolvingSymlinksInPath().standardizedFileURL.path,
             exePath == resolvedStdPath
          {
            return true
          }
          if running.activationPolicy == .regular,
             let locName = running.localizedName?.lowercased(),
             !locName.isEmpty,
             (locName == targetName || locName == resolvedStem)
          {
            return true
          }
          return false
        }
        if let found = match {
          if #available(macOS 14.0, *) {
            _ = found.activate()
          } else {
            _ = found.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
          }
        }
        return match
      }
      if existingApp != nil {
        replySuccess(result, ["launched": true, "alreadyRunning": true])
        return
      }
    }

    if #available(macOS 10.15, *) {
      let semaphore = DispatchSemaphore(value: 0)
      let launchLock = NSLock()
      var launchError: Error?
      var launchedApp: NSRunningApplication?
      var callbackFired = false
      onMainThread {
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = [] // Never pass CLI flags.
        config.activates = true
        config.environment = Self.sanitizedChildEnvironment()
        let completion: (NSRunningApplication?, Error?) -> Void = { runningApp, err in
          launchLock.lock()
          launchedApp = runningApp
          launchError = err
          callbackFired = true
          launchLock.unlock()
          semaphore.signal()
        }
        if let targetDocUrl = validatedOpenFileUrl {
          NSWorkspace.shared.open(
            [targetDocUrl],
            withApplicationAt: resolvedUrl,
            configuration: config,
            completionHandler: completion
          )
        } else {
          NSWorkspace.shared.openApplication(
            at: resolvedUrl,
            configuration: config,
            completionHandler: completion
          )
        }
      }
      // Wait strictly off main thread (`uiActionQueue`) so completion callbacks never deadlock.
      let waitRes = semaphore.wait(timeout: .now() + .seconds(8))
      launchLock.lock()
      let finalError = launchError
      let finalApp = launchedApp
      let didComplete = callbackFired
      launchLock.unlock()

      if waitRes == .success && didComplete && finalError == nil {
        let targetPid = finalApp?.processIdentifier
        for _ in 0..<20 {
          let isFront = onMainThread { () -> Bool in
            if #available(macOS 14.0, *) {
              finalApp?.activate()
            } else {
              finalApp?.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            }
            if let pid = targetPid {
              return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
            }
            return true
          }
          if isFront {
            break
          }
          Thread.sleep(forTimeInterval: 0.04)
        }
        replySuccess(result, ["launched": true, "alreadyRunning": false])
        return
      }

      // Fallback via /usr/bin/open -a <appPath> [-- <openPath>] (no shell) if LaunchServices XPC failed
      let openProcess = Process()
      openProcess.executableURL = URL(fileURLWithPath: "/usr/bin/open")
      if let targetDocUrl = validatedOpenFileUrl {
        openProcess.arguments = ["-a", resolvedUrl.path, targetDocUrl.path]
      } else {
        openProcess.arguments = ["-a", resolvedUrl.path]
      }
      openProcess.environment = Self.sanitizedChildEnvironment()
      do {
        try openProcess.run()
        openProcess.waitUntilExit()
        if openProcess.terminationStatus == 0 {
          replySuccess(result, ["launched": true, "alreadyRunning": false])
          return
        }
      } catch {}

      replyError(result, code: "failed", message: "Failed to launch application")
    } else {
      let opened = onMainThread { NSWorkspace.shared.open(resolvedUrl) }
      if opened {
        replySuccess(result, ["launched": true, "alreadyRunning": false])
      } else {
        replyError(result, code: "failed", message: "Failed to launch application")
      }
    }
  }

  struct BrowserCandidate {
    let id: String
    let bundleId: String
    let displayName: String
    let script: String
  }

  enum BrowserResolutionResult {
    case resolved(BrowserCandidate)
    case error(code: String, errorCode: String, message: String)
  }

  static let supportedBrowserCandidates: [BrowserCandidate] = [
    BrowserCandidate(
      id: "safari",
      bundleId: "com.apple.Safari",
      displayName: "Safari",
      script: "tell application \"Safari\" to get URL of current tab of front window"
    ),
    BrowserCandidate(
      id: "chrome",
      bundleId: "com.google.Chrome",
      displayName: "Google Chrome",
      script: "tell application \"Google Chrome\" to get URL of active tab of front window"
    ),
    BrowserCandidate(
      id: "edge",
      bundleId: "com.microsoft.edgemac",
      displayName: "Microsoft Edge",
      script: "tell application \"Microsoft Edge\" to get URL of active tab of front window"
    ),
  ]

  static func isValidPublicHttpsTabUrl(_ raw: String) -> Bool {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 2048 else { return false }
    guard let comps = URLComponents(string: trimmed) else { return false }
    guard comps.scheme?.lowercased() == "https",
          comps.user == nil,
          comps.password == nil,
          let host = comps.host,
          !host.isEmpty
    else {
      return false
    }
    return true
  }

  static func resolveBrowserCandidate(
    requested: String,
    frontmostBundleId: String?,
    runningBundleIds: Set<String>
  ) -> BrowserResolutionResult {
    let normalizedReq = requested.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let req = normalizedReq.isEmpty ? "auto" : normalizedReq
    let runningLower = Set(runningBundleIds.map { $0.lowercased() })
    let frontLower = frontmostBundleId?.lowercased()

    if req != "auto" {
      guard let candidate = supportedBrowserCandidates.first(where: { $0.id == req }) else {
        return .error(
          code: "invalid_args",
          errorCode: "unsupported_browser",
          message: "Unsupported browser: \(requested)"
        )
      }
      guard runningLower.contains(candidate.bundleId.lowercased()) else {
        return .error(
          code: "failed",
          errorCode: "browser_not_running",
          message: "\(candidate.displayName) is not running"
        )
      }
      return .resolved(candidate)
    }

    let running = supportedBrowserCandidates.filter {
      runningLower.contains($0.bundleId.lowercased())
    }
    if running.isEmpty {
      return .error(
        code: "failed",
        errorCode: "browser_not_running",
        message: "No supported browser (Safari, Chrome, Edge) is running"
      )
    }
    if let front = frontLower,
       let frontCandidate = running.first(where: { $0.bundleId.lowercased() == front })
    {
      return .resolved(frontCandidate)
    }
    if running.count == 1 {
      return .resolved(running[0])
    }
    let names = running.map { $0.id }.joined(separator: ", ")
    return .error(
      code: "invalid_args",
      errorCode: "browser_ambiguous",
      message: "Multiple browsers running (\(names)); specify browser or focus one"
    )
  }

  func handleUrlOpen(args: [String: Any], result: @escaping FlutterResult) {
    guard let rawUrl = args["url"] as? String else {
      replyError(
        result,
        code: "invalid_args",
        message: "Only valid https:// URLs are permitted",
        errorCode: "url_invalid"
      )
      return
    }
    let urlString = rawUrl.trimmingCharacters(in: .whitespacesAndNewlines)
    guard Self.isValidPublicHttpsTabUrl(urlString),
          let url = URL(string: urlString)
    else {
      replyError(
        result,
        code: "invalid_args",
        message: "Only valid https:// URLs without userinfo (<= 2048 chars) are permitted",
        errorCode: "url_invalid"
      )
      return
    }

    let opened = onMainThread { NSWorkspace.shared.open(url) }
    if opened {
      replySuccess(result, [:])
    } else {
      replyError(result, code: "failed", message: "NSWorkspace failed to open URL")
    }
  }

  func handleBrowserCurrentUrl(args: [String: Any], result: @escaping FlutterResult) {
    let requested = args["browser"] as? String ?? "auto"
    let (frontmostBundleId, runningBundles) = onMainThread { () -> (String?, Set<String>) in
      let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
      let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
      return (front, running)
    }

    let candidate: BrowserCandidate
    switch Self.resolveBrowserCandidate(
      requested: requested,
      frontmostBundleId: frontmostBundleId,
      runningBundleIds: runningBundles
    ) {
    case .resolved(let found):
      candidate = found
    case .error(let code, let errorCode, let message):
      replyError(result, code: code, message: message, errorCode: errorCode)
      return
    }

    let scriptRes = runAppleScriptWithResult(candidate.script, timeoutSeconds: 2.0)
    if scriptRes.timedOut {
      replyError(
        result,
        code: "timeout",
        message: "Timed out querying active tab in \(candidate.displayName)",
        errorCode: "deadline_exceeded"
      )
      return
    }
    if scriptRes.exitCode != 0 {
      let errLower = scriptRes.errorOutput.lowercased()
      if errLower.contains("-1743")
        || errLower.contains("not authorized")
        || checkAutomationPermission(bundleId: candidate.bundleId, prompt: false) == "denied"
      {
        replyError(
          result,
          code: "needs_permission",
          message: "Automation permission denied for \(candidate.displayName)",
          errorCode: "automation_denied"
        )
        return
      }
      replyError(
        result,
        code: "invalid_args",
        message: "No active https:// tab found in \(candidate.displayName)",
        errorCode: "url_invalid"
      )
      return
    }

    let rawUrl = (scriptRes.output ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard Self.isValidPublicHttpsTabUrl(rawUrl) else {
      replyError(
        result,
        code: "invalid_args",
        message: "Active tab URL in \(candidate.displayName) is not a valid https:// URL",
        errorCode: "url_invalid"
      )
      return
    }

    replySuccess(result, [
      "url": rawUrl,
      "browser": candidate.id,
    ])
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
    let (axTrusted, screenState) = onMainThread { () -> (Bool, String) in
      let ax = AXIsProcessTrusted()
      let scr: String
      if #available(macOS 10.15, *) {
        scr = CGPreflightScreenCaptureAccess() ? "granted" : "denied"
      } else {
        scr = "granted"
      }
      return (ax, scr)
    }
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

    onMainThread {
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
          "screenRecording": screenState,
          "automation": automationMap,
          "notifications": notifState,
        ])
      }
    }
  }

  func handleRequestPermission(args: [String: Any], result: @escaping FlutterResult) {
    let kind = args["kind"] as? String ?? ""

    if kind == "accessibility" {
      let trusted = onMainThread { () -> Bool in
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
      }
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

    if kind == "screen_recording" || kind == "screenRecording" {
      let trusted = onMainThread { () -> Bool in
        if #available(macOS 10.15, *) {
          return CGRequestScreenCaptureAccess()
        }
        return true
      }
      if !trusted,
         let prefUrl = URL(
           string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
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
      onMainThread {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
          if error != nil {
            self.replySuccess(result, ["state": "not_determined"])
          } else {
            self.replySuccess(result, ["state": granted ? "granted" : "denied"])
          }
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
    return onMainThread {
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
      onMainThread {
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
      }
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

  enum ClipboardValidationResult {
    case valid(String)
    case error(code: String, errorCode: String, message: String)
  }

  static func hasForbiddenControlBytes(_ text: String) -> Bool {
    for unit in text.utf16 {
      if (unit >= 0x00 && unit <= 0x08)
        || unit == 0x0B
        || unit == 0x0C
        || (unit >= 0x0E && unit <= 0x1F)
        || unit == 0x7F
      {
        return true
      }
    }
    return false
  }

  static func clampUtf16Safe(_ value: String, maxCodeUnits: Int) -> String {
    if value.utf16.count <= maxCodeUnits {
      return value
    }
    var out = ""
    var utf16Len = 0
    for scalar in value.unicodeScalars {
      let scalarLen = scalar.utf16.count
      if utf16Len + scalarLen > maxCodeUnits {
        break
      }
      out.unicodeScalars.append(scalar)
      utf16Len += scalarLen
    }
    return out
  }

  static func validateClipboardReadPayload(
    stringValue: String?,
    hasPasteboardItems: Bool
  ) -> ClipboardValidationResult {
    guard let raw = stringValue else {
      if hasPasteboardItems {
        return .error(
          code: "invalid_args",
          errorCode: "clipboard_binary",
          message: "Clipboard contains binary or non-text data"
        )
      }
      return .valid("")
    }
    if hasForbiddenControlBytes(raw) {
      return .error(
        code: "invalid_args",
        errorCode: "clipboard_binary",
        message: "Clipboard contains binary control characters"
      )
    }
    let capped = clampUtf16Safe(raw, maxCodeUnits: 2400)
    return .valid(capped)
  }

  static func validateClipboardWritePayload(_ rawArg: Any?) -> ClipboardValidationResult {
    guard let text = rawArg as? String else {
      return .error(
        code: "invalid_args",
        errorCode: "schema_mismatch",
        message: "Missing clipboard text payload"
      )
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty || text.utf16.count > 4000 || hasForbiddenControlBytes(text) {
      return .error(
        code: "invalid_args",
        errorCode: "schema_mismatch",
        message: "Clipboard write text is empty, > 4000 UTF-16 code units, or contains binary control bytes"
      )
    }
    return .valid(text)
  }

  func handleClipboardReadText(result: @escaping FlutterResult) {
    let (stringValue, hasItems) = onMainThread { () -> (String?, Bool) in
      let pb = NSPasteboard.general
      let str = pb.string(forType: .string)
      let has = !(pb.pasteboardItems?.isEmpty ?? true)
      return (str, has)
    }
    switch Self.validateClipboardReadPayload(
      stringValue: stringValue,
      hasPasteboardItems: hasItems
    ) {
    case .valid(let text):
      replySuccess(result, ["text": text])
    case .error(let code, let errorCode, let message):
      replyError(result, code: code, message: message, errorCode: errorCode)
    }
  }

  func handleClipboardWriteText(args: [String: Any], result: @escaping FlutterResult) {
    switch Self.validateClipboardWritePayload(args["text"]) {
    case .error(let code, let errorCode, let message):
      replyError(result, code: code, message: message, errorCode: errorCode)
    case .valid(let text):
      let ok = onMainThread { () -> Bool in
        let pb = NSPasteboard.general
        pb.clearContents()
        return pb.setString(text, forType: .string)
      }
      if ok {
        replySuccess(result, ["written": true])
      } else {
        replyError(
          result,
          code: "failed",
          message: "Failed to write text to macOS pasteboard",
          errorCode: "clipboard_write_failed"
        )
      }
    }
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

  /// Classifies a live macOS `AXUIElement` into an exact normalized ADR-0015 D2 role
  /// using `AXRole`, `AXSubrole`, and editability attributes (app-agnostic).
  func classifyExactAxControlRole(_ element: AXUIElement) -> String? {
    let role = (extractAxString(element, kAXRoleAttribute as String) ?? "").lowercased()
    let subrole = (extractAxString(element, kAXSubroleAttribute as String) ?? "").lowercased()
    if role.isEmpty { return nil }
    if role.contains("secure") || subrole.contains("secure") {
      return "password"
    }
    var settable = DarwinBoolean(false)
    _ = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
    var selRangeRef: CFTypeRef?
    let hasTextSelection = AXUIElementCopyAttributeValue(
      element,
      kAXSelectedTextRangeAttribute as CFString,
      &selRangeRef
    ) == .success
    let placeholder = extractAxString(element, "AXPlaceholderValue")
    let isTextEditable = settable.boolValue || hasTextSelection || placeholder != nil

    if role == "axsearchfield" || subrole == "axsearchfield" {
      return "searchfield"
    }
    if role == "axcombobox" {
      return isTextEditable ? "searchbox" : "combobox"
    }
    if role == "axtextfield" {
      return isTextEditable ? "textfield" : "statictext"
    }
    if role == "axtextarea" {
      return isTextEditable ? "textarea" : "document"
    }
    if role == "axbutton" || role == "axpopupbutton" || role == "axmenubutton" {
      return "button"
    }
    if role == "axcheckbox" { return "checkbox" }
    if role == "axradiobutton" { return "radiobutton" }
    if role == "axlink" { return "link" }
    if role == "axmenuitem" { return "menuitem" }
    if role == "axrow" || role == "axcell" { return "list_item" }
    return nil
  }

  func handleReadActiveWindowContext(args: [String: Any], result: @escaping FlutterResult) {
    let rawMax = args["maxChars"] as? Int ?? 600
    let maxChars = min(max(rawMax, 80), 1200)
    let selfPid = ProcessInfo.processInfo.processIdentifier
    let (frontApp, axTrusted, runningApps) = onMainThread { () -> (NSRunningApplication?, Bool, [[String: String]]) in
      let front = NSWorkspace.shared.frontmostApplication
      let trusted = AXIsProcessTrusted()
      var appsList: [[String: String]] = []
      for running in NSWorkspace.shared.runningApplications {
        guard running.activationPolicy == .regular,
              !running.isTerminated,
              running.processIdentifier != selfPid
        else {
          continue
        }
        let bid = (running.bundleIdentifier ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let rawName = (running.localizedName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = (running.bundleURL?.deletingPathExtension().lastPathComponent ?? "")
          .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = !rawName.isEmpty ? rawName : (!stem.isEmpty ? stem : bid)
        if name.isEmpty && bid.isEmpty {
          continue
        }
        appsList.append([
          "name": name,
          "bundleId": bid,
        ])
      }
      return (front, trusted, appsList)
    }

    guard let app = frontApp else {
      replySuccess(result, [
        "appName": "unknown",
        "processName": "unknown",
        "windowTitle": "",
        "focusedRole": "window",
        "visibleText": "",
        "isElevated": false,
        "runningApps": runningApps,
      ])
      return
    }
    let appName = app.localizedName ?? "unknown"
    let bundleId = app.bundleIdentifier ?? appName
    var windowTitle = ""
    var focusedRole = "window"
    var exactFocusedRole: String?
    var visibleText = ""

    if axTrusted {
      let axApp = AXUIElementCreateApplication(app.processIdentifier)
      AXUIElementSetMessagingTimeout(axApp, 0.25)
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
        exactFocusedRole = classifyExactAxControlRole(axFocus)
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axFocus, kAXRoleAttribute as CFString, &roleRef) == .success,
           let roleStr = roleRef as? String
        {
          focusedRole = String(roleStr.prefix(40))
        }
        if exactFocusedRole != "password" && focusedRole.lowercased() != "axsecuretextfield" {
          var valRef: CFTypeRef?
          if AXUIElementCopyAttributeValue(axFocus, kAXValueAttribute as CFString, &valRef) == .success,
             let valStr = valRef as? String
          {
            visibleText = String(valStr.prefix(maxChars))
          }
        }
      }
    }

    var out: [String: Any] = [
      "appName": appName,
      "processName": bundleId,
      "windowTitle": windowTitle,
      "focusedRole": focusedRole,
      "visibleText": visibleText,
      "isElevated": false,
      "runningApps": runningApps,
    ]
    if let exact = exactFocusedRole {
      out["exactFocusedRole"] = exact
    }
    replySuccess(result, out)
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
    let runningBundles = onMainThread {
      Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
    }
    for candidate in candidates {
      if requested != "auto" && requested != candidate.id {
        continue
      }
      if !runningBundles.contains(candidate.bundleId) {
        continue
      }
      if let rawUrl = runAppleScript(candidate.urlScript, timeoutSeconds: 2.0),
         rawUrl.lowercased().hasPrefix("https://")
      {
        var pageTitle = onMainThread {
          NSWorkspace.shared.frontmostApplication?.localizedName ?? candidate.id
        }
        if let tVal = runAppleScript(candidate.titleScript, timeoutSeconds: 2.0),
           !tVal.isEmpty
        {
          pageTitle = tVal
        }
        var bodyText = pageTitle
        if let bVal = runAppleScript(candidate.textScript, timeoutSeconds: 2.5),
           !bVal.isEmpty
        {
          bodyText = bVal
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
    replyError(
      result,
      code: "invalid_args",
      message: "No active https:// browser tab found"
    )
  }
}
