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

  let workQueue = DispatchQueue(
    label: "ai.xuna.desktop.host.queue",
    qos: .userInitiated
  )
  var cachedKey: (SecKey, String)?
  var cachedUiElements: [String: AXUIElement] = [:]
  var cachedUiCenters: [String: CGPoint] = [:]
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
      " CleanMyMac",
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
      if combined.contains(token.trimmingCharacters(in: .whitespaces)) {
        return true
      }
    }
    return false
  }

  func runAppleScript(_ source: String, timeoutSeconds: TimeInterval = 2.5) -> String? {
    var errDict: NSDictionary?
    guard let scriptObj = NSAppleScript(source: source) else {
      return nil
    }
    let desc = scriptObj.executeAndReturnError(&errDict)
    if errDict != nil {
      return nil
    }
    return desc.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let method = call.method

    workQueue.async {
      switch method {
      case "keyEnsure":
        self.handleKeyEnsure(result: result)
      case "keySign":
        self.handleKeySign(args: args, result: result)
      case "media":
        self.handleMedia(args: args, result: result)
      case "volumeSet":
        self.handleVolumeSet(args: args, result: result)
      case "nowPlaying":
        self.handleNowPlaying(args: args, result: result)
      case "appLaunch":
        self.handleAppLaunch(args: args, result: result)
      case "urlOpen":
        self.handleUrlOpen(args: args, result: result)
      case "browserCurrentUrl":
        self.handleBrowserCurrentUrl(args: args, result: result)
      case "workflowRun":
        self.handleWorkflowRun(args: args, result: result)
      case "permissions":
        self.handlePermissions(result: result)
      case "requestPermission":
        self.handleRequestPermission(args: args, result: result)
      case "hostInfo":
        self.handleHostInfo(result: result)
      case "showToast":
        self.handleShowToast(args: args, result: result)
      case "displayWake":
        self.handleDisplayWake(result: result)
      case "clipboardReadText":
        self.handleClipboardReadText(result: result)
      case "lockScreen":
        self.handleLockScreen(result: result)
      case "readActiveWindowContext":
        self.handleReadActiveWindowContext(args: args, result: result)
      case "readBrowserPageSummary":
        self.handleReadBrowserPageSummary(args: args, result: result)
      case "inspectWindowUiTree":
        self.handleInspectWindowUiTree(args: args, result: result)
      case "invokeWindowUiControl":
        self.handleInvokeWindowUiControl(args: args, result: result)
      default:
        DispatchQueue.main.async {
          result(FlutterMethodNotImplemented)
        }
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
    message: String
  ) {
    DispatchQueue.main.async {
      result(FlutterError(code: code, message: message, details: nil))
    }
  }
}
