import Cocoa
import CoreAudio
import CoreGraphics
import FlutterMacOS
import IOKit.ps

/// Fast, non-blocking, zero-AXUIElement presence probe for `XunaHostPlugin` (`M3` Phase 2).
///
/// Runs on `fastContextQueue` (with only `NSWorkspace.shared.frontmostApplication`
/// read via `onMainThread`), never scans accessibility trees, and never runs
/// blocking AppleEvents or AppleScript.
extension XunaHostPlugin {
  private typealias MediaRemoteIsPlayingFn =
    @convention(c) (DispatchQueue, @escaping @convention(block) (UInt8) -> Void) -> Void

  private static let mediaProbeQueue = DispatchQueue(
    label: "ai.xuna.desktop.host.media-probe",
    qos: .userInitiated,
    attributes: .concurrent
  )

  private static let cachedMediaRemoteIsPlayingFn: MediaRemoteIsPlayingFn? = {
    let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
    guard let handle = dlopen(path, RTLD_LAZY) else {
      return nil
    }
    guard let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") else {
      return nil
    }
    return unsafeBitCast(sym, to: MediaRemoteIsPlayingFn.self)
  }()

  private static let foregroundAppInvalidCharsRegex = try! NSRegularExpression(
    pattern: "[^a-z0-9_.-]+"
  )
  private static let foregroundAppSuffixRegex = try! NSRegularExpression(
    pattern: "\\.(app|exe|lnk|cmd)$"
  )
  private static let foregroundAppUnderscoresRegex = try! NSRegularExpression(
    pattern: "_+"
  )
  private static let validShortIdRegex = try! NSRegularExpression(
    pattern: "^[a-z0-9_.-]{1,64}$"
  )

  func handlePresenceProbe(result: @escaping FlutterResult) {
    switch buildPresenceProbePayload() {
    case .success(let payload):
      replySuccess(result, payload)
    case .failure(let error):
      replyError(result, code: "failed", message: error.message)
    }
  }

  struct PresenceProbeFailure: Error {
    let message: String
  }

  func buildPresenceProbePayload() -> Result<[String: Any], PresenceProbeFailure> {
    let rawIdle = CGEventSource.secondsSinceLastEventType(
      .combinedSessionState,
      eventType: CGEventType(rawValue: ~0)! // kCGAnyInputEventType / .null
    )
    guard let idleSeconds = Self.parseIdleSeconds(rawIdle) else {
      return .failure(PresenceProbeFailure(message: "Unable to read local input idle time"))
    }

    let sessionDict = CGSessionCopyCurrentDictionary() as? [String: Any]
    guard let screenLocked = Self.parseScreenLocked(fromSessionDict: sessionDict) else {
      return .failure(
        PresenceProbeFailure(message: "Window server session dictionary unavailable")
      )
    }

    guard let mediaPlaying = Self.queryMediaPlayingFast() else {
      return .failure(
        PresenceProbeFailure(message: "Unable to query audio/media playback state")
      )
    }

    let frontAppInfo: (name: String, bundleId: String?, stem: String?)? = onMainThread {
      guard let app = NSWorkspace.shared.frontmostApplication else {
        return nil
      }
      let name = app.localizedName ?? ""
      let bundleId = app.bundleIdentifier
      let stem = app.bundleURL?.deletingPathExtension().lastPathComponent
      return (name: name, bundleId: bundleId, stem: stem)
    }

    var foregroundAppId: String?
    if let info = frontAppInfo,
       !Self.isHardDeniedApp(info.name, bundleId: info.bundleId) {
      let candidate = (info.stem?.isEmpty == false) ? info.stem : info.name
      foregroundAppId = Self.normalizeForegroundAppId(candidate)
    }

    var payload: [String: Any] = [
      "idleSeconds": idleSeconds,
      "screenLocked": screenLocked,
      "mediaPlaying": mediaPlaying,
    ]

    if let battery = Self.readInternalBatteryFromIOKit() {
      payload["batteryPercent"] = battery.percent
      payload["isCharging"] = battery.isCharging
    }

    if let fg = foregroundAppId {
      payload["foregroundAppId"] = fg
    }

    return .success(payload)
  }

  static func parseIdleSeconds(_ raw: Double) -> Int? {
    guard raw.isFinite, raw >= 0.0, raw < Double(Int.max) else {
      return nil
    }
    return Int(floor(raw))
  }

  static func parseScreenLocked(fromSessionDict dict: [String: Any]?) -> Bool? {
    guard let dict else {
      return nil
    }
    if let lockedBool = dict["CGSSessionScreenIsLocked"] as? Bool {
      if lockedBool {
        return true
      }
    } else if let lockedNum = dict["CGSSessionScreenIsLocked"] as? NSNumber {
      if lockedNum.boolValue {
        return true
      }
    }

    let onConsoleKey = kCGSessionOnConsoleKey as String
    if let onConsoleBool = dict[onConsoleKey] as? Bool {
      if !onConsoleBool {
        return true
      }
    } else if let onConsoleNum = dict[onConsoleKey] as? NSNumber {
      if !onConsoleNum.boolValue {
        return true
      }
    }
    return false
  }

  static func readInternalBatteryFromIOKit() -> (percent: Int, isCharging: Bool)? {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
    else {
      return nil
    }
    var descriptions: [[String: Any]] = []
    descriptions.reserveCapacity(list.count)
    for source in list {
      if let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] {
        descriptions.append(desc)
      }
    }
    return parseInternalBattery(fromPowerSources: descriptions)
  }

  static func parseInternalBattery(
    fromPowerSources list: [[String: Any]]
  ) -> (percent: Int, isCharging: Bool)? {
    for desc in list {
      guard let type = desc[kIOPSTypeKey as String] as? String,
            type == (kIOPSInternalBatteryType as String)
      else {
        continue
      }
      if let isPresent = (desc[kIOPSIsPresentKey as String] as? NSNumber)?.boolValue,
         !isPresent {
        continue
      }
      guard let curNum = desc[kIOPSCurrentCapacityKey as String] as? NSNumber,
            let maxNum = desc[kIOPSMaxCapacityKey as String] as? NSNumber
      else {
        continue
      }
      let cur = curNum.doubleValue
      let maxCap = maxNum.doubleValue
      guard cur.isFinite, maxCap.isFinite, maxCap > 0.0 else {
        continue
      }
      let rawPct = Int(((cur * 100.0) / maxCap).rounded())
      let pct = min(100, max(0, rawPct))
      let chargingFlag = (desc[kIOPSIsChargingKey as String] as? NSNumber)?.boolValue ?? false
      let acPower = (desc[kIOPSPowerSourceStateKey as String] as? String) == (kIOPSACPowerValue as String)
      return (percent: pct, isCharging: chargingFlag || acPower)
    }
    return nil
  }

  static func queryMediaPlayingFast() -> Bool? {
    if let mrFn = cachedMediaRemoteIsPlayingFn {
      let sem = DispatchSemaphore(value: 0)
      let lock = NSLock()
      var mrResult: Bool?
      let callback: @convention(block) (UInt8) -> Void = { playing in
        lock.lock()
        mrResult = (playing != 0)
        lock.unlock()
        sem.signal()
      }
      mrFn(mediaProbeQueue, callback)
      if sem.wait(timeout: .now() + .milliseconds(4)) == .success {
        lock.lock()
        let resolved = mrResult
        lock.unlock()
        if let resolved {
          return resolved
        }
      }
    }
    return queryCoreAudioOutputRunning()
  }

  static func queryCoreAudioOutputRunning() -> Bool? {
    var deviceId = AudioDeviceID(0)
    var propSize = UInt32(MemoryLayout<AudioDeviceID>.size)
    var defaultOutputAddr = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    let devStatus = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &defaultOutputAddr,
      0,
      nil,
      &propSize,
      &deviceId
    )
    guard devStatus == noErr else {
      return nil
    }
    if deviceId == kAudioObjectUnknown {
      return false
    }

    var runningAddr = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    guard AudioObjectHasProperty(deviceId, &runningAddr) else {
      return false
    }
    var isRunning: UInt32 = 0
    var runningSize = UInt32(MemoryLayout<UInt32>.size)
    let runStatus = AudioObjectGetPropertyData(
      deviceId,
      &runningAddr,
      0,
      nil,
      &runningSize,
      &isRunning
    )
    guard runStatus == noErr else {
      return nil
    }
    return isRunning != 0
  }

  static func normalizeForegroundAppId(_ raw: String?) -> String? {
    guard let raw else {
      return nil
    }
    var working = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !working.isEmpty else {
      return nil
    }

    let suffixRange = NSRange(location: 0, length: working.utf16.count)
    working = foregroundAppSuffixRegex.stringByReplacingMatches(
      in: working,
      range: suffixRange,
      withTemplate: ""
    )

    let invalidRange = NSRange(location: 0, length: working.utf16.count)
    working = foregroundAppInvalidCharsRegex.stringByReplacingMatches(
      in: working,
      range: invalidRange,
      withTemplate: "_"
    )

    let underscoreRange = NSRange(location: 0, length: working.utf16.count)
    working = foregroundAppUnderscoresRegex.stringByReplacingMatches(
      in: working,
      range: underscoreRange,
      withTemplate: "_"
    )

    working = working.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    guard !working.isEmpty else {
      return nil
    }

    if working.count > 64 {
      working = String(working.prefix(64))
      working = working.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }
    guard !working.isEmpty else {
      return nil
    }

    let validRange = NSRange(location: 0, length: working.utf16.count)
    guard validShortIdRegex.firstMatch(in: working, range: validRange) != nil else {
      return nil
    }
    return working
  }
}
