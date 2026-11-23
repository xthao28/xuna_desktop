import ApplicationServices
import Cocoa
import CommonCrypto
import CoreServices
import Darwin
import FlutterMacOS

@_silgen_name("proc_pidinfo")
private func darwin_proc_pidinfo(
  _ pid: Int32,
  _ flavor: Int32,
  _ arg: UInt64,
  _ buffer: UnsafeMutableRawPointer?,
  _ buffersize: Int32
) -> Int32

@_silgen_name("proc_listchildpids")
private func darwin_proc_listchildpids(
  _ ppid: Int32,
  _ buffer: UnsafeMutableRawPointer?,
  _ buffersize: Int32
) -> Int32

@_silgen_name("proc_pidpath")
private func darwin_proc_pidpath(
  _ pid: Int32,
  _ buffer: UnsafeMutableRawPointer?,
  _ buffersize: UInt32
) -> Int32

private func xunaAxObserverCallback(
  _ observer: AXObserver,
  _ element: AXUIElement,
  _ notification: CFString,
  _ refcon: UnsafeMutableRawPointer?
) {
  guard let refcon else { return }
  let box = Unmanaged<AxObserverBox>.fromOpaque(refcon).takeUnretainedValue()
  box.recordEvent()
}

private func xunaFsEventCallback(
  _ streamRef: ConstFSEventStreamRef,
  _ clientCallBackInfo: UnsafeMutableRawPointer?,
  _ numEvents: Int,
  _ eventPaths: UnsafeMutableRawPointer,
  _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
  _ eventIds: UnsafePointer<FSEventStreamEventId>
) {
  guard let clientCallBackInfo, numEvents > 0 else { return }
  let box = Unmanaged<FsStreamBox>.fromOpaque(clientCallBackInfo).takeUnretainedValue()
  let cfArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
  let count = CFArrayGetCount(cfArray)
  var relevantCount = 0
  for idx in 0..<min(numEvents, count) {
    guard let rawPtr = CFArrayGetValueAtIndex(cfArray, idx) else { continue }
    let cfStr = unsafeBitCast(rawPtr, to: CFString.self)
    let path = cfStr as String
    if !XunaHostPlugin.shouldIgnoreFsEventPath(path) {
      relevantCount += 1
    }
  }
  if relevantCount > 0 {
    box.recordEvents(count: relevantCount)
  }
}

final class AxObserverBox {
  let lock = NSLock()
  var invalidated = false
  weak var entry: NativeWatchEntry?

  init(entry: NativeWatchEntry) {
    self.entry = entry
  }

  func recordEvent() {
    lock.lock()
    let targetEntry = invalidated ? nil : entry
    lock.unlock()
    targetEntry?.recordActivity(digestChanged: false)
  }
}

final class FsStreamBox {
  let lock = NSLock()
  var invalidated = false
  weak var entry: NativeWatchEntry?

  init(entry: NativeWatchEntry) {
    self.entry = entry
  }

  func recordEvents(count: Int) {
    lock.lock()
    let targetEntry = invalidated ? nil : entry
    lock.unlock()
    targetEntry?.recordFsEvents(count: count)
  }
}

final class AxRunLoopCoordinator {
  static let shared = AxRunLoopCoordinator()

  private let initLock = NSLock()
  private var runLoop: CFRunLoop?
  private var thread: Thread?

  private init() {}

  func ensureRunLoop() -> CFRunLoop? {
    initLock.lock()
    if let existing = runLoop {
      initLock.unlock()
      return existing
    }
    let readySem = DispatchSemaphore(value: 0)
    var capturedLoop: CFRunLoop?
    let worker = Thread {
      let current = CFRunLoopGetCurrent()
      var sourceContext = CFRunLoopSourceContext(
        version: 0,
        info: nil,
        retain: nil,
        release: nil,
        copyDescription: nil,
        equal: nil,
        hash: nil,
        schedule: nil,
        cancel: nil,
        perform: nil
      )
      if let keepAliveSource = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &sourceContext) {
        CFRunLoopAddSource(current, keepAliveSource, .commonModes)
      }
      capturedLoop = current
      readySem.signal()
      CFRunLoopRun()
    }
    worker.name = "ai.xuna.desktop.host.ax-runloop"
    worker.qualityOfService = .userInitiated
    worker.start()
    _ = readySem.wait(timeout: .now() + 1.0)
    self.runLoop = capturedLoop
    self.thread = worker
    initLock.unlock()
    return capturedLoop
  }

  func addSourceSync(
    _ source: CFRunLoopSource,
    observer: AXObserver? = nil,
    box: AxObserverBox? = nil
  ) -> Bool {
    guard let rl = ensureRunLoop() else { return false }
    let sem = DispatchSemaphore(value: 0)
    let stateLock = NSLock()
    var timedOut = false
    var didAdd = false
    CFRunLoopPerformBlock(rl, CFRunLoopMode.commonModes.rawValue) {
      stateLock.lock()
      let alreadyTimedOut = timedOut
      if !alreadyTimedOut {
        CFRunLoopAddSource(rl, source, .commonModes)
        didAdd = true
      }
      stateLock.unlock()
      _ = observer
      _ = box
      sem.signal()
    }
    CFRunLoopWakeUp(rl)
    if sem.wait(timeout: .now() + 0.5) == .success {
      return true
    }
    stateLock.lock()
    timedOut = true
    let addedBeforeLock = didAdd
    stateLock.unlock()
    if addedBeforeLock {
      _ = removeSourceSync(source, observer: observer)
    }
    return false
  }

  @discardableResult
  func removeSourceSync(
    _ source: CFRunLoopSource,
    observer: AXObserver? = nil,
    refconToRelease: UnsafeMutableRawPointer? = nil
  ) -> Bool {
    initLock.lock()
    let rl = runLoop
    initLock.unlock()
    guard let rl else {
      if let refconToRelease {
        Unmanaged<AxObserverBox>.fromOpaque(refconToRelease).release()
      }
      _ = observer
      return true
    }
    let sem = DispatchSemaphore(value: 0)
    let stateLock = NSLock()
    var completed = false
    var timedOut = false
    CFRunLoopPerformBlock(rl, CFRunLoopMode.commonModes.rawValue) {
      if CFRunLoopContainsSource(rl, source, .commonModes) {
        CFRunLoopRemoveSource(rl, source, .commonModes)
      }
      stateLock.lock()
      completed = true
      let shouldReleaseInBlock = timedOut
      stateLock.unlock()
      sem.signal()
      if shouldReleaseInBlock {
        _ = observer
        if let refconToRelease {
          Unmanaged<AxObserverBox>.fromOpaque(refconToRelease).release()
        }
      }
    }
    CFRunLoopWakeUp(rl)
    if sem.wait(timeout: .now() + 0.5) == .success {
      if let refconToRelease {
        Unmanaged<AxObserverBox>.fromOpaque(refconToRelease).release()
      }
      _ = observer
      return true
    }
    stateLock.lock()
    let alreadyCompleted = completed
    if !alreadyCompleted {
      timedOut = true
    }
    stateLock.unlock()
    if alreadyCompleted {
      if let refconToRelease {
        Unmanaged<AxObserverBox>.fromOpaque(refconToRelease).release()
      }
      _ = observer
    }
    return alreadyCompleted
  }
}

final class NativeWatchEntry {
  let watchId: String
  let signal: String
  let key: String
  let stateLock = NSLock()

  var state: String = "idle"
  var changeCount: Int = 0
  var digestChangeCount: Int = 0
  var lastPolledDigestChangeCount: Int = 0
  var eventDriven: Bool
  var fallbackUsed: Bool
  var errorCode: String?
  var lastActivityTime: Date = .distantPast
  var stopped: Bool = false

  var targetPid: pid_t?
  var workspaceCanonicalPath: String?
  var prevAxDigestHex: String?
  var prevCpuNsByPid: [pid_t: UInt64] = [:]
  var prevSampleWallNs: UInt64 = 0
  var wasProcessBusy: Bool = false

  var timer: DispatchSourceTimer?
  var axObserver: AXObserver?
  var axRunLoopSource: CFRunLoopSource?
  var axBox: AxObserverBox?
  var axRefcon: UnsafeMutableRawPointer?

  var fsStream: FSEventStreamRef?
  var fsBox: FsStreamBox?
  var fsRefcon: UnsafeMutableRawPointer?

  weak var plugin: XunaHostPlugin?

  init(
    watchId: String,
    signal: String,
    eventDriven: Bool,
    fallbackUsed: Bool,
    plugin: XunaHostPlugin
  ) {
    self.watchId = watchId
    self.signal = signal
    self.key = "\(watchId):\(signal)"
    self.eventDriven = eventDriven
    self.fallbackUsed = fallbackUsed
    self.plugin = plugin
  }

  func recordActivity(digestChanged: Bool) {
    stateLock.lock()
    defer { stateLock.unlock() }
    guard !stopped, state != "lost", state != "error" else { return }
    changeCount += 1
    if digestChanged {
      digestChangeCount += 1
    }
    lastActivityTime = Date()
    state = "active"
  }

  func recordFsEvents(count: Int) {
    guard count > 0 else { return }
    stateLock.lock()
    defer { stateLock.unlock() }
    guard !stopped, state != "lost", state != "error" else { return }
    changeCount += count
    lastActivityTime = Date()
    state = "active"
  }

  func markLost() {
    stateLock.lock()
    let t = timer
    timer = nil
    if !stopped && state != "lost" {
      state = "lost"
    }
    stateLock.unlock()
    t?.cancel()
  }

  func markError(_ code: String) {
    stateLock.lock()
    let t = timer
    timer = nil
    if !stopped {
      state = "error"
      errorCode = code
    }
    stateLock.unlock()
    t?.cancel()
  }

  func stop(asyncFsTeardownOnMainThread: Bool = false) {
    stateLock.lock()
    if stopped {
      stateLock.unlock()
      return
    }
    stopped = true
    let t = timer
    timer = nil
    let box = axBox
    axBox = nil
    let source = axRunLoopSource
    axRunLoopSource = nil
    let observer = axObserver
    axObserver = nil
    let refcon = axRefcon
    axRefcon = nil

    let fBox = fsBox
    fsBox = nil
    let fStream = fsStream
    fsStream = nil
    let fRefcon = fsRefcon
    fsRefcon = nil
    let hostPlugin = plugin
    stateLock.unlock()

    t?.cancel()

    if let box {
      box.lock.lock()
      box.invalidated = true
      box.entry = nil
      box.lock.unlock()
    }
    if let source {
      AxRunLoopCoordinator.shared.removeSourceSync(
        source,
        observer: observer,
        refconToRelease: refcon
      )
    } else {
      _ = observer
      if let refcon {
        Unmanaged<AxObserverBox>.fromOpaque(refcon).release()
      }
    }

    if let fBox {
      fBox.lock.lock()
      fBox.invalidated = true
      fBox.entry = nil
      fBox.lock.unlock()
    }
    if let fStream {
      let teardownFs = {
        FSEventStreamStop(fStream)
        FSEventStreamInvalidate(fStream)
        FSEventStreamRelease(fStream)
        if let fRefcon {
          Unmanaged<FsStreamBox>.fromOpaque(fRefcon).release()
        }
      }
      if let hostPlugin {
        if asyncFsTeardownOnMainThread
          && Thread.isMainThread
          && DispatchQueue.getSpecific(key: XunaHostPlugin.watchQueueSpecificKey) == nil
        {
          let q = hostPlugin.watchQueue
          q.async {
            teardownFs()
          }
        } else {
          hostPlugin.runOnWatchQueueSync(teardownFs)
        }
      } else {
        teardownFs()
      }
    } else if let fRefcon {
      Unmanaged<FsStreamBox>.fromOpaque(fRefcon).release()
    }
  }
}

extension XunaHostPlugin {
  static let maxNativeWatchEntries = 12
  static let supportedWatchSignals: Set<String> = [
    "ui_quiescence",
    "ui_change",
    "process_idle",
    "fs_quiescence",
  ]
  static let forbiddenWorkspaceSegments: Set<String> = [
    ".ssh",
    ".aws",
    ".gnupg",
    ".kube",
    ".docker",
    ".claude",
    ".gemini",
    ".npmrc",
    ".netrc",
    ".pypirc",
    "library",
    "appdata",
    "keychains",
  ]

  func runOnWatchQueueSync(_ block: () -> Void) {
    if DispatchQueue.getSpecific(key: Self.watchQueueSpecificKey) != nil {
      block()
    } else {
      watchQueue.sync(execute: block)
    }
  }

  func stopAllWatchEntries() {
    watchLock.lock()
    let entries = Array(activeWatchEntries.values)
    activeWatchEntries.removeAll()
    watchLock.unlock()
    let asyncFsTeardown = Thread.isMainThread
      && DispatchQueue.getSpecific(key: Self.watchQueueSpecificKey) == nil
    for entry in entries {
      entry.stop(asyncFsTeardownOnMainThread: asyncFsTeardown)
    }
  }

  // MARK: - MethodChannel Handlers

  func handleWatchStart(args: [String: Any], result: @escaping FlutterResult) {
    guard let rawWatchId = args["watchId"] as? String,
          !rawWatchId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          let signal = args["signal"] as? String,
          Self.supportedWatchSignals.contains(signal)
    else {
      replyError(
        result,
        code: "invalid_args",
        message: "Missing or invalid watchId/signal",
        errorCode: "invalid_args"
      )
      return
    }
    let watchId = rawWatchId.trimmingCharacters(in: .whitespacesAndNewlines)
    let key = "\(watchId):\(signal)"

    watchLock.lock()
    let existing = activeWatchEntries.removeValue(forKey: key)
    let currentCount = activeWatchEntries.count
    watchLock.unlock()
    existing?.stop()

    if currentCount >= Self.maxNativeWatchEntries {
      replyError(
        result,
        code: "failed",
        message: "Maximum concurrent native watches reached",
        errorCode: "watch_limit_reached"
      )
      return
    }

    switch signal {
    case "ui_quiescence", "ui_change":
      startUiWatch(watchId: watchId, signal: signal, args: args, result: result)
    case "process_idle":
      startProcessIdleWatch(watchId: watchId, signal: signal, args: args, result: result)
    case "fs_quiescence":
      startFsWatch(watchId: watchId, signal: signal, args: args, result: result)
    default:
      replyError(
        result,
        code: "unsupported",
        message: "Unsupported watch signal",
        errorCode: "watch_unsupported"
      )
    }
  }

  func handleWatchPoll(args: [String: Any], result: @escaping FlutterResult) {
    guard let rawWatchId = args["watchId"] as? String,
          !rawWatchId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          let signal = args["signal"] as? String,
          !signal.isEmpty
    else {
      replyError(
        result,
        code: "invalid_args",
        message: "Missing or invalid watchId/signal",
        errorCode: "invalid_args"
      )
      return
    }
    let watchId = rawWatchId.trimmingCharacters(in: .whitespacesAndNewlines)
    let key = "\(watchId):\(signal)"

    watchLock.lock()
    let entry = activeWatchEntries[key]
    watchLock.unlock()

    guard let entry else {
      replySuccess(result, [
        "watchId": watchId,
        "signal": signal,
        "state": "lost",
        "changeCount": 0,
        "digestChangeCount": 0,
        "digestChanged": false,
        "eventDriven": false,
        "fallbackUsed": false,
      ])
      return
    }

    refreshWatchLivenessOnPoll(entry)

    entry.stateLock.lock()
    let curState = entry.state
    let changes = entry.changeCount
    let digestChanges = entry.digestChangeCount
    let digestChanged = digestChanges > entry.lastPolledDigestChangeCount
    entry.lastPolledDigestChangeCount = digestChanges
    let isEventDriven = entry.eventDriven
    let isFallbackUsed = entry.fallbackUsed
    let errCode = entry.errorCode
    entry.stateLock.unlock()

    var payload: [String: Any] = [
      "watchId": watchId,
      "signal": signal,
      "state": curState,
      "changeCount": changes,
      "digestChangeCount": digestChanges,
      "digestChanged": digestChanged,
      "eventDriven": isEventDriven,
      "fallbackUsed": isFallbackUsed,
    ]
    if let errCode, !errCode.isEmpty {
      payload["errorCode"] = errCode
    }
    replySuccess(result, payload)
  }

  func handleWatchStop(args: [String: Any], result: @escaping FlutterResult) {
    guard let rawWatchId = args["watchId"] as? String,
          !rawWatchId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      replyError(
        result,
        code: "invalid_args",
        message: "Missing watchId",
        errorCode: "invalid_args"
      )
      return
    }
    let watchId = rawWatchId.trimmingCharacters(in: .whitespacesAndNewlines)
    let rawSignal = (args["signal"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let signal = (rawSignal?.isEmpty == false) ? rawSignal : nil

    var toStop: [NativeWatchEntry] = []
    watchLock.lock()
    if let signal {
      let key = "\(watchId):\(signal)"
      if let entry = activeWatchEntries.removeValue(forKey: key) {
        toStop.append(entry)
      }
    } else {
      let prefix = "\(watchId):"
      let matchingKeys = activeWatchEntries.keys.filter { $0.hasPrefix(prefix) }
      for k in matchingKeys {
        if let entry = activeWatchEntries.removeValue(forKey: k) {
          toStop.append(entry)
        }
      }
    }
    watchLock.unlock()

    for entry in toStop {
      entry.stop()
    }

    replySuccess(result, [
      "stopped": true,
      "cancelledCount": toStop.count,
    ])
  }

  func insertActiveWatchEntry(_ entry: NativeWatchEntry) -> Bool {
    watchLock.lock()
    let existing = activeWatchEntries.removeValue(forKey: entry.key)
    if activeWatchEntries.count >= Self.maxNativeWatchEntries {
      watchLock.unlock()
      existing?.stop()
      return false
    }
    activeWatchEntries[entry.key] = entry
    watchLock.unlock()
    existing?.stop()
    return true
  }

  private func refreshWatchLivenessOnPoll(_ entry: NativeWatchEntry) {
    entry.stateLock.lock()
    let signal = entry.signal
    let curState = entry.state
    let pid = entry.targetPid
    let workspacePath = entry.workspaceCanonicalPath
    let lastActivity = entry.lastActivityTime
    entry.stateLock.unlock()

    if curState == "lost" || curState == "error" {
      return
    }

    switch signal {
    case "ui_quiescence", "ui_change":
      if !onMainThread({ AXIsProcessTrusted() }) {
        entry.markError("needs_permission")
        return
      }
      if let pid, !Self.isProcessAlive(pid) {
        entry.markLost()
        return
      }
      entry.stateLock.lock()
      if entry.state != "lost" && entry.state != "error" {
        entry.state = Date().timeIntervalSince(lastActivity) < 2.0 ? "active" : "idle"
      }
      entry.stateLock.unlock()
    case "process_idle":
      if let pid, !Self.isProcessAlive(pid) {
        entry.markLost()
      }
    case "fs_quiescence":
      if let workspacePath {
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: workspacePath, isDirectory: &isDir) || !isDir.boolValue {
          entry.markLost()
          return
        }
      }
      entry.stateLock.lock()
      if entry.state != "lost" && entry.state != "error" {
        entry.state = Date().timeIntervalSince(lastActivity) < 1.5 ? "active" : "idle"
      }
      entry.stateLock.unlock()
    default:
      break
    }
  }

  // MARK: - UI Quiescence / UI Change (AXObserver + 2s Structural Digest)

  private func startUiWatch(
    watchId: String,
    signal: String,
    args: [String: Any],
    result: @escaping FlutterResult
  ) {
    let trusted = onMainThread { AXIsProcessTrusted() }
    if !trusted {
      replyError(
        result,
        code: "needs_permission",
        message: "Accessibility permission is required",
        errorCode: "needs_permission"
      )
      return
    }

    if let rawAppId = args["appId"] as? String,
       !rawAppId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
       Self.isHardDeniedApp(rawAppId, bundleId: rawAppId)
    {
      replyError(
        result,
        code: "denied",
        message: "Target application is blocked by policy",
        errorCode: "policy_blocked"
      )
      return
    }

    let pidResolution = resolveUiTargetPid(args: args)
    switch pidResolution {
    case .failure(let err):
      replyError(result, code: err.code, message: err.message, errorCode: err.errorCode)
      return
    case .success(let targetPid):
      let entry = NativeWatchEntry(
        watchId: watchId,
        signal: signal,
        eventDriven: true,
        fallbackUsed: false,
        plugin: self
      )
      entry.targetPid = targetPid

      let axApp = AXUIElementCreateApplication(targetPid)
      AXUIElementSetMessagingTimeout(axApp, 0.05)

      let box = AxObserverBox(entry: entry)
      let refcon = Unmanaged.passRetained(box).toOpaque()
      var observerOpt: AXObserver?
      let createErr = AXObserverCreate(targetPid, xunaAxObserverCallback, &observerOpt)

      var registeredCount = 0
      var addedToRunLoop = false
      if createErr == .success, let observer = observerOpt {
        let notifications: [CFString] = [
          kAXValueChangedNotification as CFString,
          kAXUIElementDestroyedNotification as CFString,
          kAXCreatedNotification as CFString,
          kAXTitleChangedNotification as CFString,
          kAXLayoutChangedNotification as CFString,
        ]
        for notif in notifications {
          if AXObserverAddNotification(observer, axApp, notif, refcon) == .success {
            registeredCount += 1
          }
        }
        if registeredCount > 0 {
          let source = AXObserverGetRunLoopSource(observer)
          addedToRunLoop = AxRunLoopCoordinator.shared.addSourceSync(
            source,
            observer: observer,
            box: box
          )
          if addedToRunLoop {
            entry.axBox = box
            entry.axObserver = observer
            entry.axRunLoopSource = source
            entry.axRefcon = refcon
          }
        }
      }

      if !addedToRunLoop {
        box.lock.lock()
        box.invalidated = true
        box.entry = nil
        box.lock.unlock()
        Unmanaged<AxObserverBox>.fromOpaque(refcon).release()
        entry.eventDriven = false
        entry.fallbackUsed = true
      }

      // Capture baseline structural digest off main thread without stealing focus.
      var initBudget = ScanBudget(maxIpcCalls: 120, timeoutSeconds: 0.12)
      let initTuples = Self.collectAxStructure(axApp: axApp, budget: &initBudget)
      entry.prevAxDigestHex = Self.computeAxDigestHex(tuples: initTuples)

      if !insertActiveWatchEntry(entry) {
        entry.stop()
        replyError(
          result,
          code: "failed",
          message: "Maximum concurrent native watches reached",
          errorCode: "watch_limit_reached"
        )
        return
      }

      let timer = DispatchSource.makeTimerSource(queue: watchQueue)
      timer.schedule(deadline: .now() + 2.0, repeating: 2.0, leeway: .milliseconds(200))
      timer.setEventHandler { [weak self, weak entry] in
        guard let self, let entry else { return }
        self.runUiDigestSafetyTick(entry: entry)
      }
      entry.stateLock.lock()
      let alreadyStopped = entry.stopped
      if !alreadyStopped {
        entry.timer = timer
      }
      entry.stateLock.unlock()
      if alreadyStopped {
        timer.setEventHandler(handler: nil)
        timer.cancel()
        timer.resume()
      } else {
        timer.resume()
      }

      replySuccess(result, [
        "accepted": true,
        "watchId": watchId,
        "signal": signal,
        "eventDriven": entry.eventDriven,
        "fallbackUsed": entry.fallbackUsed,
      ])
    }
  }

  private func runUiDigestSafetyTick(entry: NativeWatchEntry) {
    entry.stateLock.lock()
    let stopped = entry.stopped
    let pid = entry.targetPid
    let prevDigest = entry.prevAxDigestHex
    entry.stateLock.unlock()

    guard !stopped, let pid else { return }

    if !onMainThread({ AXIsProcessTrusted() }) {
      entry.markError("needs_permission")
      return
    }
    if !Self.isProcessAlive(pid) {
      entry.markLost()
      return
    }

    let axApp = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(axApp, 0.05)
    var budget = ScanBudget(maxIpcCalls: 120, timeoutSeconds: 0.12)
    let tuples = Self.collectAxStructure(axApp: axApp, budget: &budget)
    let newDigest = Self.computeAxDigestHex(tuples: tuples)

    entry.stateLock.lock()
    if !entry.stopped && entry.state != "lost" && entry.state != "error" {
      if let prevDigest, prevDigest != newDigest {
        entry.prevAxDigestHex = newDigest
        entry.digestChangeCount += 1
        entry.changeCount += 1
        entry.lastActivityTime = Date()
        entry.state = "active"
      } else {
        if entry.prevAxDigestHex == nil {
          entry.prevAxDigestHex = newDigest
        }
        if Date().timeIntervalSince(entry.lastActivityTime) >= 2.0 {
          entry.state = "idle"
        }
      }
    }
    entry.stateLock.unlock()
  }

  struct WatchResolveError: Error {
    let code: String
    let errorCode: String
    let message: String
  }

  private func resolveUiTargetPid(args: [String: Any]) -> Result<pid_t, WatchResolveError> {
    let rawPid = Self.extractIntArg(args["pid"])
    let rawWindowId = Self.extractIntArg(args["windowId"])
    let rawAppId = (args["appId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

    if let pidVal = rawPid, pidVal > 0 {
      let pid = pid_t(pidVal)
      if isHardDeniedPid(pid) {
        return .failure(
          WatchResolveError(
            code: "denied",
            errorCode: "policy_blocked",
            message: "Target process is blocked by policy"
          )
        )
      }
      if !Self.isProcessAlive(pid) {
        return .failure(
          WatchResolveError(
            code: "failed",
            errorCode: "target_not_found",
            message: "Target PID is not running"
          )
        )
      }
      return .success(pid)
    }

    if let winId = rawWindowId, winId >= 0 {
      if let winInfoList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] {
        for info in winInfoList {
          if let num = (info[kCGWindowNumber as String] as? NSNumber)?.intValue,
             num == winId,
             let ownerPid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
             ownerPid > 0
          {
            if isHardDeniedPid(ownerPid) {
              return .failure(
                WatchResolveError(
                  code: "denied",
                  errorCode: "policy_blocked",
                  message: "Target window belongs to a blocked application"
                )
              )
            }
            if !Self.isProcessAlive(ownerPid) {
              return .failure(
                WatchResolveError(
                  code: "failed",
                  errorCode: "target_not_found",
                  message: "Target window owner is not running"
                )
              )
            }
            return .success(ownerPid)
          }
        }
      }
      return .failure(
        WatchResolveError(
          code: "failed",
          errorCode: "target_not_found",
          message: "Target windowId was not found"
        )
      )
    }

    if let appId = rawAppId, !appId.isEmpty {
      let reqNorm = Self.normalizeForegroundAppId(appId) ?? appId.lowercased()
      let reqLower = appId.lowercased()
      let matches: [(pid: pid_t, name: String, bundleId: String?)] = onMainThread {
        var found: [(pid: pid_t, name: String, bundleId: String?)] = []
        for app in NSWorkspace.shared.runningApplications {
          guard !app.isTerminated, app.activationPolicy == .regular else { continue }
          let name = app.localizedName ?? ""
          let bundleId = app.bundleIdentifier
          let stem = app.bundleURL?.deletingPathExtension().lastPathComponent
          let normStem = stem.flatMap { Self.normalizeForegroundAppId($0) }
          let normName = Self.normalizeForegroundAppId(name)
          let exactBundle = bundleId?.lowercased() == reqLower
          if exactBundle || normStem == reqNorm || normName == reqNorm {
            found.append((pid: app.processIdentifier, name: name, bundleId: bundleId))
          }
        }
        return found
      }

      if matches.count != 1 {
        return .failure(
          WatchResolveError(
            code: "failed",
            errorCode: "target_not_found",
            message: matches.isEmpty
              ? "No running application matched appId"
              : "Multiple applications matched appId"
          )
        )
      }
      let match = matches[0]
      if Self.isHardDeniedApp(match.name, bundleId: match.bundleId)
        || isHardDeniedPid(match.pid)
      {
        return .failure(
          WatchResolveError(
            code: "denied",
            errorCode: "policy_blocked",
            message: "Target application is blocked by policy"
          )
        )
      }
      if !Self.isProcessAlive(match.pid) {
        return .failure(
          WatchResolveError(
            code: "failed",
            errorCode: "target_not_found",
            message: "Target application is not running"
          )
        )
      }
      return .success(match.pid)
    }

    return .failure(
      WatchResolveError(
        code: "failed",
        errorCode: "target_not_found",
        message: "No pid, windowId, or appId target was provided"
      )
    )
  }

  static func collectAxStructure(
    axApp: AXUIElement,
    budget: inout ScanBudget,
    maxNodes: Int = 250,
    maxDepth: Int = 10
  ) -> [(depth: Int, role: String, labelLen: Int, valueLen: Int, childCount: Int)] {
    var result: [(depth: Int, role: String, labelLen: Int, valueLen: Int, childCount: Int)] = []
    var queue: [(element: AXUIElement, depth: Int)] = []

    var windowsRef: CFTypeRef?
    if budget.canContinue() {
      let winErr = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)
      budget.recordIpc(1)
      if winErr == .success, let windows = windowsRef as? [AXUIElement], !windows.isEmpty {
        for win in windows.prefix(8) {
          queue.append((win, 0))
        }
      } else {
        queue.append((axApp, 0))
      }
    }

    var idx = 0
    while idx < queue.count && result.count < maxNodes && budget.canContinue() {
      let (elem, depth) = queue[idx]
      idx += 1

      var roleRef: CFTypeRef?
      let roleErr = AXUIElementCopyAttributeValue(elem, kAXRoleAttribute as CFString, &roleRef)
      budget.recordIpc(1)
      let role = (roleErr == .success ? (roleRef as? String) : nil) ?? ""

      var subrole = ""
      if budget.canContinue() {
        var subRef: CFTypeRef?
        let subErr = AXUIElementCopyAttributeValue(elem, kAXSubroleAttribute as CFString, &subRef)
        budget.recordIpc(1)
        if subErr == .success, let s = subRef as? String {
          subrole = s
        }
      }

      var labelLen = 0
      if budget.canContinue() {
        var titleRef: CFTypeRef?
        let titleErr = AXUIElementCopyAttributeValue(elem, kAXTitleAttribute as CFString, &titleRef)
        budget.recordIpc(1)
        if titleErr == .success, let t = titleRef as? String {
          labelLen = t.utf8.count
        } else if budget.canContinue() {
          var descRef: CFTypeRef?
          let descErr = AXUIElementCopyAttributeValue(elem, kAXDescriptionAttribute as CFString, &descRef)
          budget.recordIpc(1)
          if descErr == .success, let d = descRef as? String {
            labelLen = d.utf8.count
          }
        }
      }

      var valueLen = 0
      if !Self.isSecureAxControl(role: role, subrole: subrole) && budget.canContinue() {
        var valRef: CFTypeRef?
        let valErr = AXUIElementCopyAttributeValue(elem, kAXValueAttribute as CFString, &valRef)
        budget.recordIpc(1)
        if valErr == .success {
          if let s = valRef as? String {
            valueLen = s.utf8.count
          } else if let n = valRef as? NSNumber {
            valueLen = n.stringValue.utf8.count
          }
        }
      }

      var childCount = 0
      if depth < maxDepth && budget.canContinue() {
        var childrenRef: CFTypeRef?
        let chErr = AXUIElementCopyAttributeValue(elem, kAXChildrenAttribute as CFString, &childrenRef)
        budget.recordIpc(1)
        if chErr == .success, let children = childrenRef as? [AXUIElement] {
          childCount = children.count
          for child in children.prefix(40) {
            if queue.count >= maxNodes * 2 { break }
            queue.append((child, depth + 1))
          }
        }
      }

      result.append((
        depth: depth,
        role: role,
        labelLen: labelLen,
        valueLen: valueLen,
        childCount: childCount
      ))
    }

    return result
  }

  static func computeAxDigestHex(
    tuples: [(depth: Int, role: String, labelLen: Int, valueLen: Int, childCount: Int)]
  ) -> String {
    var ctx = CC_SHA256_CTX()
    CC_SHA256_Init(&ctx)

    func updateUInt32(_ value: Int) {
      var clamped = UInt32(max(0, min(value, Int(UInt32.max)))).bigEndian
      withUnsafeBytes(of: &clamped) { ptr in
        if let base = ptr.baseAddress {
          CC_SHA256_Update(&ctx, base, CC_LONG(ptr.count))
        }
      }
    }

    updateUInt32(tuples.count)
    for item in tuples {
      updateUInt32(item.depth)
      let roleBytes = Array(item.role.utf8)
      updateUInt32(roleBytes.count)
      if !roleBytes.isEmpty {
        roleBytes.withUnsafeBytes { ptr in
          if let base = ptr.baseAddress {
            CC_SHA256_Update(&ctx, base, CC_LONG(ptr.count))
          }
        }
      }
      updateUInt32(item.labelLen)
      updateUInt32(item.valueLen)
      updateUInt32(item.childCount)
    }

    var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    CC_SHA256_Final(&digest, &ctx)
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  // MARK: - Process Idle (libproc CPU + Descendant Children)

  private func startProcessIdleWatch(
    watchId: String,
    signal: String,
    args: [String: Any],
    result: @escaping FlutterResult
  ) {
    guard let rawPid = Self.extractIntArg(args["pid"]), rawPid > 0 else {
      replyError(
        result,
        code: "failed",
        message: "process_idle requires a positive pid",
        errorCode: "target_not_found"
      )
      return
    }
    let pid = pid_t(rawPid)

    if kill(pid, 0) != 0 {
      if errno == EPERM {
        replyError(
          result,
          code: "denied",
          message: "Process permission denied",
          errorCode: "policy_blocked"
        )
      } else {
        replyError(
          result,
          code: "failed",
          message: "Target PID does not exist",
          errorCode: "target_not_found"
        )
      }
      return
    }

    if isHardDeniedPid(pid) {
      replyError(
        result,
        code: "denied",
        message: "Target process is blocked by policy",
        errorCode: "policy_blocked"
      )
      return
    }

    if !Self.isProcessAlive(pid) {
      replyError(
        result,
        code: "failed",
        message: "Target PID is not alive",
        errorCode: "target_not_found"
      )
      return
    }

    let entry = NativeWatchEntry(
      watchId: watchId,
      signal: signal,
      eventDriven: false,
      fallbackUsed: false,
      plugin: self
    )
    entry.targetPid = pid

    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)

    let initialPids = Self.collectProcessTree(rootPid: pid)
    var initialCpu: [pid_t: UInt64] = [:]
    for p in initialPids {
      if let cpuNs = Self.readProcessCpuNanoseconds(pid: p, timebase: timebase) {
        initialCpu[p] = cpuNs
      }
    }
    entry.prevCpuNsByPid = initialCpu
    entry.prevSampleWallNs = Self.scaleMachTicksToNanoseconds(mach_absolute_time(), timebase: timebase)

    if !insertActiveWatchEntry(entry) {
      entry.stop()
      replyError(
        result,
        code: "failed",
        message: "Maximum concurrent native watches reached",
        errorCode: "watch_limit_reached"
      )
      return
    }

    let timer = DispatchSource.makeTimerSource(queue: watchQueue)
    timer.schedule(deadline: .now() + 1.0, repeating: 1.0, leeway: .milliseconds(100))
    timer.setEventHandler { [weak self, weak entry] in
      guard let self, let entry else { return }
      self.runProcessSampleTick(entry: entry, timebase: timebase)
    }
    entry.stateLock.lock()
    let alreadyStopped = entry.stopped
    if !alreadyStopped {
      entry.timer = timer
    }
    entry.stateLock.unlock()
    if alreadyStopped {
      timer.setEventHandler(handler: nil)
      timer.cancel()
      timer.resume()
    } else {
      timer.resume()
    }

    replySuccess(result, [
      "accepted": true,
      "watchId": watchId,
      "signal": signal,
      "eventDriven": false,
      "fallbackUsed": false,
    ])
  }

  private func runProcessSampleTick(entry: NativeWatchEntry, timebase: mach_timebase_info_data_t) {
    entry.stateLock.lock()
    let stopped = entry.stopped
    let pid = entry.targetPid
    let prevMap = entry.prevCpuNsByPid
    let prevWall = entry.prevSampleWallNs
    let wasBusy = entry.wasProcessBusy
    entry.stateLock.unlock()

    guard !stopped, let pid else { return }

    if !Self.isProcessAlive(pid) {
      entry.markLost()
      return
    }

    let nowWall = Self.scaleMachTicksToNanoseconds(mach_absolute_time(), timebase: timebase)
    let elapsedWallNs = nowWall > prevWall ? (nowWall - prevWall) : 1_000_000_000

    let treePids = Self.collectProcessTree(rootPid: pid)
    var nextMap: [pid_t: UInt64] = [:]
    var totalDeltaCpuNs: UInt64 = 0
    var hasBusyChild = false

    for p in treePids {
      guard let curNs = Self.readProcessCpuNanoseconds(pid: p, timebase: timebase) else { continue }
      nextMap[p] = curNs
      let prevNs = prevMap[p]
      let delta = (prevNs != nil && curNs >= prevNs!) ? (curNs - prevNs!) : (prevNs == nil ? curNs : 0)
      totalDeltaCpuNs += delta

      if p != pid {
        let childCpuPercent = Double(delta) / Double(elapsedWallNs) * 100.0
        if childCpuPercent > 3.0 || (prevNs == nil && curNs > 0) {
          hasBusyChild = true
        }
      }
    }

    let totalCpuPercent = Double(totalDeltaCpuNs) / Double(elapsedWallNs) * 100.0
    let nextState = Self.evaluateProcessIdleState(
      cpuPercent: totalCpuPercent,
      hasBusyChild: hasBusyChild,
      wasBusy: wasBusy
    )
    let nextBusy = (nextState == "active")

    entry.stateLock.lock()
    if !entry.stopped && entry.state != "lost" && entry.state != "error" {
      entry.prevCpuNsByPid = nextMap
      entry.prevSampleWallNs = nowWall
      entry.wasProcessBusy = nextBusy
      entry.state = nextState
      if nextBusy {
        entry.changeCount += 1
        entry.lastActivityTime = Date()
      }
    }
    entry.stateLock.unlock()
  }

  static func evaluateProcessIdleState(
    cpuPercent: Double,
    hasBusyChild: Bool,
    wasBusy: Bool
  ) -> String {
    if cpuPercent > 8.0 || hasBusyChild {
      return "active"
    }
    if cpuPercent < 3.0 && !hasBusyChild {
      return "idle"
    }
    return wasBusy ? "active" : "idle"
  }

  static func scaleMachTicksToNanoseconds(
    _ ticks: UInt64,
    timebase: mach_timebase_info_data_t
  ) -> UInt64 {
    let denom = UInt64(max(1, timebase.denom))
    let numer = UInt64(timebase.numer)
    return (ticks / denom) * numer + ((ticks % denom) * numer) / denom
  }

  static func collectProcessTree(rootPid: pid_t, maxPids: Int = 256) -> [pid_t] {
    var result: [pid_t] = []
    var visited: Set<pid_t> = []
    var queue: [pid_t] = [rootPid]
    visited.insert(rootPid)

    var idx = 0
    var childBuf = [pid_t](repeating: 0, count: 128)
    while idx < queue.count && result.count < maxPids {
      let cur = queue[idx]
      idx += 1
      result.append(cur)

      let byteSize = Int32(childBuf.count * MemoryLayout<pid_t>.stride)
      let childCount = darwin_proc_listchildpids(cur, &childBuf, byteSize)
      if childCount > 0 {
        let validCount = min(Int(childCount), childBuf.count)
        for i in 0..<validCount {
          let child = childBuf[i]
          if child > 0 && !visited.contains(child) {
            visited.insert(child)
            queue.append(child)
          }
        }
      }
    }
    return result
  }

  static func readProcessCpuNanoseconds(
    pid: pid_t,
    timebase: mach_timebase_info_data_t
  ) -> UInt64? {
    var info = proc_taskinfo()
    let expectedSize = Int32(MemoryLayout<proc_taskinfo>.size)
    let ret = darwin_proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, expectedSize)
    guard ret == expectedSize else { return nil }
    let totalTicks = info.pti_total_user &+ info.pti_total_system
    return scaleMachTicksToNanoseconds(totalTicks, timebase: timebase)
  }

  static func isProcessAlive(_ pid: pid_t) -> Bool {
    guard pid > 0 else { return false }
    if kill(pid, 0) != 0 && errno != EPERM {
      return false
    }
    var bsd = proc_bsdinfo()
    let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
    let ret = darwin_proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, expectedSize)
    if ret == expectedSize {
      return bsd.pbi_status != UInt32(SZOMB)
    }
    return kill(pid, 0) == 0
  }

  private func isHardDeniedPid(_ pid: pid_t) -> Bool {
    if let appInfo = onMainThread({ () -> (name: String, bundleId: String?)? in
      guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
      return (name: app.localizedName ?? "", bundleId: app.bundleIdentifier)
    }) {
      if Self.isHardDeniedApp(appInfo.name, bundleId: appInfo.bundleId) {
        return true
      }
    }
    var pathBuf = [CChar](repeating: 0, count: 4096)
    let len = darwin_proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
    if len > 0 {
      let path = String(cString: pathBuf)
      if Self.isHardDeniedResolvedTarget(url: URL(fileURLWithPath: path), kind: "exe") {
        return true
      }
    }
    return false
  }

  // MARK: - Filesystem Quiescence (FSEvents strictly inside $HOME)

  private func startFsWatch(
    watchId: String,
    signal: String,
    args: [String: Any],
    result: @escaping FlutterResult
  ) {
    guard let rawPath = args["workspacePath"] as? String else {
      replyError(
        result,
        code: "invalid_args",
        message: "fs_quiescence requires workspacePath",
        errorCode: "workspace_not_found"
      )
      return
    }

    let validation = Self.validateWatchWorkspacePath(rawPath, homeRoot: watchHomeRootOverride)
    switch validation {
    case .failure(let err):
      replyError(result, code: err.code, message: err.message, errorCode: err.errorCode)
      return
    case .success(let canonicalPath):
      let entry = NativeWatchEntry(
        watchId: watchId,
        signal: signal,
        eventDriven: true,
        fallbackUsed: false,
        plugin: self
      )
      entry.workspaceCanonicalPath = canonicalPath

      let box = FsStreamBox(entry: entry)
      let refcon = Unmanaged.passRetained(box).toOpaque()
      var context = FSEventStreamContext(
        version: 0,
        info: refcon,
        retain: nil,
        release: nil,
        copyDescription: nil
      )
      let pathsToWatch = [canonicalPath] as CFArray
      let flags = FSEventStreamCreateFlags(
        kFSEventStreamCreateFlagUseCFTypes
          | kFSEventStreamCreateFlagFileEvents
          | kFSEventStreamCreateFlagNoDefer
      )

      guard let stream = FSEventStreamCreate(
        kCFAllocatorDefault,
        xunaFsEventCallback,
        &context,
        pathsToWatch,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
        0.25,
        flags
      ) else {
        box.lock.lock()
        box.invalidated = true
        box.entry = nil
        box.lock.unlock()
        Unmanaged<FsStreamBox>.fromOpaque(refcon).release()
        replyError(
          result,
          code: "unsupported",
          message: "Unable to create FSEventStream",
          errorCode: "watch_unsupported"
        )
        return
      }

      entry.fsBox = box
      entry.fsStream = stream
      entry.fsRefcon = refcon

      if !insertActiveWatchEntry(entry) {
        entry.stop()
        replyError(
          result,
          code: "failed",
          message: "Maximum concurrent native watches reached",
          errorCode: "watch_limit_reached"
        )
        return
      }

      FSEventStreamSetDispatchQueue(stream, watchQueue)
      if !FSEventStreamStart(stream) {
        watchLock.lock()
        activeWatchEntries.removeValue(forKey: entry.key)
        watchLock.unlock()
        entry.stop()
        replyError(
          result,
          code: "failed",
          message: "Unable to start FSEventStream",
          errorCode: "watch_unsupported"
        )
        return
      }

      replySuccess(result, [
        "accepted": true,
        "watchId": watchId,
        "signal": signal,
        "eventDriven": true,
        "fallbackUsed": false,
      ])
    }
  }

  static func validateWatchWorkspacePath(
    _ rawPath: String,
    homeRoot: String? = nil
  ) -> Result<String, WatchResolveError> {
    let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty || trimmed.count > 1024 {
      return .failure(
        WatchResolveError(
          code: "invalid_args",
          errorCode: "invalid_args",
          message: "Workspace path is empty or exceeds maximum length"
        )
      )
    }
    for scalar in trimmed.unicodeScalars {
      if scalar.value < 0x20 || scalar.value == 0x7F {
        return .failure(
          WatchResolveError(
            code: "invalid_args",
            errorCode: "invalid_args",
            message: "Workspace path contains control characters"
          )
        )
      }
    }

    let rawHome = homeRoot ?? FileManager.default.homeDirectoryForCurrentUser.path
    let canonicalHome = URL(fileURLWithPath: rawHome)
      .resolvingSymlinksInPath()
      .standardizedFileURL
      .path

    let rawUrl = URL(fileURLWithPath: trimmed).standardizedFileURL
    let resolvedPath = rawUrl.resolvingSymlinksInPath().standardizedFileURL.path

    if resolvedPath == canonicalHome || !resolvedPath.hasPrefix(canonicalHome + "/") {
      return .failure(
        WatchResolveError(
          code: "denied",
          errorCode: "policy_blocked",
          message: "Workspace path must reside strictly inside home directory"
        )
      )
    }

    let rel = String(resolvedPath.dropFirst(canonicalHome.count + 1))
    let segments = rel.split(separator: "/").map { String($0).lowercased() }
    if segments.isEmpty {
      return .failure(
        WatchResolveError(
          code: "denied",
          errorCode: "policy_blocked",
          message: "Workspace path cannot be home root"
        )
      )
    }

    for (index, seg) in segments.enumerated() {
      if forbiddenWorkspaceSegments.contains(seg) || seg.hasPrefix(".env") {
        return .failure(
          WatchResolveError(
            code: "denied",
            errorCode: "policy_blocked",
            message: "Sensitive directory is excluded from filesystem watching"
          )
        )
      }
      if seg == ".git" && index + 1 < segments.count && segments[index + 1] == "objects" {
        return .failure(
          WatchResolveError(
            code: "denied",
            errorCode: "policy_blocked",
            message: "Internal git object store is excluded from filesystem watching"
          )
        )
      }
    }

    var isDir: ObjCBool = false
    if !FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDir) || !isDir.boolValue {
      return .failure(
        WatchResolveError(
          code: "failed",
          errorCode: "workspace_not_found",
          message: "Workspace directory does not exist"
        )
      )
    }

    return .success(resolvedPath)
  }

  static func shouldIgnoreFsEventPath(_ path: String) -> Bool {
    let lower = path.lowercased()
    if lower.contains("/.git/objects/") || lower.hasSuffix("/.git/objects") {
      return true
    }
    if lower.hasSuffix("/.ds_store") || lower.contains("/.ds_store/") {
      return true
    }
    let components = lower.split(separator: "/")
    for (idx, comp) in components.enumerated() {
      let s = String(comp)
      if s.hasPrefix(".env") || forbiddenWorkspaceSegments.contains(s) {
        return true
      }
      if s == ".git" && idx + 1 < components.count && components[idx + 1] == "objects" {
        return true
      }
    }
    return false
  }

  private static func extractIntArg(_ value: Any?) -> Int? {
    if let i = value as? Int {
      return i
    }
    if let n = value as? NSNumber {
      return n.intValue
    }
    return nil
  }
}
