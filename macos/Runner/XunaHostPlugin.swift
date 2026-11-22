import ApplicationServices
import Cocoa
import FlutterMacOS
import Security

/// Native macOS implementation of `MethodChannel("xuna/host")` (`UDC-3` §5.6.3).
///
/// Decomposed into modular domain extensions:
/// - `XunaHostPlugin.swift`: Channel registration, dispatch router, environment sanitization, and shared state.
/// - `XunaHostPlugin+CryptoAndMedia.swift`: Keychain/SE P-256 signing, media transport, CoreAudio volume, NowPlaying.
/// - `XunaHostPlugin+AppsAndContext.swift`: App launch, URL open, Shortcuts, permissions, and active window/browser context.
/// - `XunaHostPlugin+UiTreeScanner.swift`: App discovery, AXUIElement UI tree inspection, and pointer/scroll primitives.
/// - `XunaHostPlugin+UiActionExecutor.swift`: Universal AXUIElement/DOM/AppleEvents/CGEvent UI control execution.
final class XunaHostPlugin: NSObject, FlutterPlugin {
  static let channelName = "xuna/host"
  static let keyTag = "ai.xuna.desktop.host.signing.v1"
  static let maxMetadataChars = 120

  let fastContextQueue = DispatchQueue(
    label: "ai.xuna.desktop.host.fast-context",
    qos: .userInitiated,
    attributes: .concurrent
  )
  let uiActionQueue = DispatchQueue(
    label: "ai.xuna.desktop.host.ui-action",
    qos: .userInitiated
  )
  let captureQueue = DispatchQueue(
    label: "ai.xuna.desktop.host.capture",
    qos: .userInitiated
  )
  let uiCacheLock = NSLock()
  let keyCacheLock = NSLock()
  var cachedKey: (SecKey, String)?
  var cachedUiElements: [String: AXUIElement] = [:]
  var cachedUiCenters: [String: CGPoint] = [:]
  var cachedUiDescriptors: [String: (role: String, label: String)] = [:]
  var cachedUiPid: pid_t = 0

  static func register(with registrar: FlutterPluginRegistrar) {
    register(messenger: registrar.messenger)
  }

  static func register(messenger: FlutterBinaryMessenger) {
    sanitizeProcessEnvironment()
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: messenger
    )
    let instance = XunaHostPlugin()
    channel.setMethodCallHandler(instance.handle(_:result:))
  }

  /// Strips IDE/Electron parent environment variables (`ELECTRON_RUN_AS_NODE`, `VSCODE_*`,
  /// `ANTIGRAVITY_*`) so any GUI apps launched via `NSWorkspace` do not exit immediately
  /// in Node.js CLI mode when the agent itself was started from a terminal.
  static func sanitizeProcessEnvironment() {
    for key in ProcessInfo.processInfo.environment.keys {
      if isPoisonedParentEnvKey(key) {
        unsetenv(key)
      }
    }
  }

  static func isPoisonedParentEnvKey(_ key: String) -> Bool {
    let upper = key.uppercased()
    return upper == "ELECTRON_RUN_AS_NODE"
      || upper == "ELECTRON_NO_ATTACH_CONSOLE"
      || upper == "CHROME_DESKTOP"
      || upper.hasPrefix("VSCODE_")
      || upper.hasPrefix("ANTIGRAVITY_")
      || upper.hasPrefix("AGY_")
  }

  static func sanitizedChildEnvironment() -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    for key in env.keys where isPoisonedParentEnvKey(key) {
      env.removeValue(forKey: key)
    }
    return env
  }

  static func isHardDeniedApp(_ appName: String, bundleId: String?) -> Bool {
    let trimmedName = appName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if trimmedName == "hyper"
      || trimmedName == "system settings"
      || trimmedName == "system preferences"
    {
      return true
    }
    let combined = "\(appName) \(bundleId ?? "")".lowercased()
    let deniedTokens = [
      "1password",
      "bitwarden",
      "keepass",
      "lastpass",
      "dashlane",
      "keychain",
      "securityagent",
      "coreautha",
      "cleanmymac",
      "systemsettings",
      "systempreferences",
      "com.apple.systempreferences",
      "co.zeit.hyper",
      // Terminal emulators: typing into them is arbitrary command execution, which
      // desktop/AGENTS.md §3 forbids. Matched by bundle id, not by display name.
      "com.apple.terminal",
      "com.googlecode.iterm2",
      "dev.warp.warp",
      "com.mitchellh.ghostty",
      "io.alacritty",
      "net.kovidgoyal.kitty",
      "com.github.wez.wezterm",
    ]
    for token in deniedTokens {
      if combined.contains(token.trimmingCharacters(in: .whitespaces).lowercased()) {
        return true
      }
    }
    return false
  }

  func onMainThread<T>(_ block: () -> T) -> T {
    if Thread.isMainThread {
      return block()
    }
    return DispatchQueue.main.sync(execute: block)
  }

  struct AppleScriptRunResult {
    let output: String?
    let errorOutput: String
    let exitCode: Int32
    let timedOut: Bool
  }

  /// Executes AppleScript out-of-process via `/usr/bin/osascript` (`runInShell: false`) with a hard
  /// timeout. Never uses in-process `NSAppleScript` on background queues, which loads OSA/SharedFileList
  /// (`LSSharedFileListCreate`) and triggers a `libdispatch` main-thread assertion crash on macOS 12+.
  func runAppleScriptWithResult(
    _ source: String,
    timeoutSeconds: TimeInterval = 2.5
  ) -> AppleScriptRunResult {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    proc.arguments = ["-e", source]
    proc.environment = Self.sanitizedChildEnvironment()
    let outPipe = Pipe()
    let errPipe = Pipe()
    proc.standardOutput = outPipe
    proc.standardError = errPipe

    let done = DispatchSemaphore(value: 0)
    proc.terminationHandler = { _ in
      done.signal()
    }
    do {
      try proc.run()
    } catch {
      return AppleScriptRunResult(
        output: nil,
        errorOutput: error.localizedDescription,
        exitCode: -1,
        timedOut: false
      )
    }
    let waitRes = done.wait(timeout: .now() + max(0.5, timeoutSeconds))
    if waitRes == .timedOut {
      proc.terminate()
      if done.wait(timeout: .now() + 0.2) == .timedOut, proc.isRunning {
        kill(proc.processIdentifier, SIGKILL)
        _ = done.wait(timeout: .now() + 0.2)
      }
      outPipe.fileHandleForReading.closeFile()
      errPipe.fileHandleForReading.closeFile()
      return AppleScriptRunResult(
        output: nil,
        errorOutput: "AppleScript execution timed out",
        exitCode: -1,
        timedOut: true
      )
    }
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    let outText = String(data: outData, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let errText = String(data: errData, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return AppleScriptRunResult(
      output: proc.terminationStatus == 0 ? outText : nil,
      errorOutput: errText,
      exitCode: proc.terminationStatus,
      timedOut: false
    )
  }

  func runAppleScript(_ source: String, timeoutSeconds: TimeInterval = 2.5) -> String? {
    let res = runAppleScriptWithResult(source, timeoutSeconds: timeoutSeconds)
    return (!res.timedOut && res.exitCode == 0) ? res.output : nil
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let method = call.method

    switch method {
    case "keyEnsure":
      fastContextQueue.async { self.handleKeyEnsure(result: result) }
    case "keySign":
      fastContextQueue.async { self.handleKeySign(args: args, result: result) }
    case "nowPlaying":
      fastContextQueue.async { self.handleNowPlaying(args: args, result: result) }
    case "browserCurrentUrl":
      fastContextQueue.async { self.handleBrowserCurrentUrl(args: args, result: result) }
    case "permissions":
      fastContextQueue.async { self.handlePermissions(result: result) }
    case "hostInfo":
      fastContextQueue.async { self.handleHostInfo(result: result) }
    case "clipboardReadText":
      fastContextQueue.async { self.handleClipboardReadText(result: result) }
    case "clipboardWriteText":
      fastContextQueue.async { self.handleClipboardWriteText(args: args, result: result) }
    case "readActiveWindowContext":
      fastContextQueue.async { self.handleReadActiveWindowContext(args: args, result: result) }
    case "presenceProbe":
      fastContextQueue.async { self.handlePresenceProbe(result: result) }
    case "media":
      uiActionQueue.async { self.handleMedia(args: args, result: result) }
    case "volumeSet":
      uiActionQueue.async { self.handleVolumeSet(args: args, result: result) }
    case "appLaunch":
      uiActionQueue.async { self.handleAppLaunch(args: args, result: result) }
    case "urlOpen":
      uiActionQueue.async { self.handleUrlOpen(args: args, result: result) }
    case "workflowRun":
      uiActionQueue.async { self.handleWorkflowRun(args: args, result: result) }
    case "requestPermission":
      uiActionQueue.async { self.handleRequestPermission(args: args, result: result) }
    case "showToast":
      uiActionQueue.async { self.handleShowToast(args: args, result: result) }
    case "displayWake":
      uiActionQueue.async { self.handleDisplayWake(result: result) }
    case "lockScreen":
      uiActionQueue.async { self.handleLockScreen(result: result) }
    case "readBrowserPageSummary":
      uiActionQueue.async { self.handleReadBrowserPageSummary(args: args, result: result) }
    case "inspectWindowUiTree":
      uiActionQueue.async { self.handleInspectWindowUiTree(args: args, result: result) }
    case "invokeWindowUiControl":
      uiActionQueue.async { self.handleInvokeWindowUiControl(args: args, result: result) }
    case "captureScreen":
      captureQueue.async { self.handleCaptureScreen(args: args, result: result) }
    default:
      DispatchQueue.main.async {
        result(FlutterMethodNotImplemented)
      }
    }
  }

  // MARK: - Helpers

  func truncate(_ value: String) -> String {
    if value.count <= Self.maxMetadataChars {
      return value
    }
    return String(value.prefix(Self.maxMetadataChars))
  }

  func replySuccess(_ result: @escaping FlutterResult, _ payload: [String: Any]) {
    DispatchQueue.main.async {
      result(payload)
    }
  }

  func replyError(
    _ result: @escaping FlutterResult,
    code: String,
    message: String,
    errorCode: String? = nil
  ) {
    let details: [String: Any]? = errorCode.flatMap { ec in
      ec.isEmpty ? nil : ["errorCode": ec]
    }
    DispatchQueue.main.async {
      result(FlutterError(code: code, message: message, details: details))
    }
  }
}
