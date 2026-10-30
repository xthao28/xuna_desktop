import ApplicationServices
import AudioToolbox
import Carbon
import Cocoa
import CoreAudio
import FlutterMacOS
import Security
import UserNotifications

/// Native macOS implementation of `MethodChannel("xuna/host")` (`UDC-3` §5.6.3).
///
/// Security invariants:
/// - No shell, `osascript`, or arbitrary AppleScript source execution.
/// - `keyEnsure` / `keySign` use Keychain / Secure Enclave ECDSA P-256 non-extractable keys
///   and convert ANSI X9.62 DER signatures to 64-byte raw `r || s`.
/// - `urlOpen` enforces `https://` at the native boundary before calling `NSWorkspace`.
/// - `appLaunch` opens bundles/executables without arguments.
/// - `workflowRun` invokes `/usr/bin/shortcuts run <target>` directly via `Process` without a shell.
final class XunaHostPlugin: NSObject, FlutterPlugin {
  private static let channelName = "xuna/host"
  private static let keyTag = "ai.xuna.desktop.host.signing.v1"
  private static let maxMetadataChars = 120

  private let workQueue = DispatchQueue(
    label: "ai.xuna.desktop.host.queue",
    qos: .userInitiated
  )

  static func register(with registrar: FlutterPluginRegistrar) {
    register(messenger: registrar.messenger)
  }

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: messenger
    )
    let instance = XunaHostPlugin()
    channel.setMethodCallHandler(instance.handle(_:result:))
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
      default:
        DispatchQueue.main.async {
          result(FlutterMethodNotImplemented)
        }
      }
    }
  }

  // MARK: - Key Provider (Secure Enclave / Keychain ECDSA P-256)

  private func ensurePrivateKey() -> (SecKey, String)? {
    let tagData = Data(Self.keyTag.utf8)
    let query: [String: Any] = [
      kSecClass as String: kSecClassKey,
      kSecAttrApplicationTag as String: tagData,
      kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
      kSecReturnRef as String: true,
    ]

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecSuccess, let existingKey = item {
      // CFTypeRef to SecKey is toll-free bridged once errSecSuccess is verified.
      let secKey = existingKey as! SecKey
      return (secKey, "keychain")
    }

    // Attempt Secure Enclave first when available.
    if let access = SecAccessControlCreateWithFlags(
      kCFAllocatorDefault,
      kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      .privateKeyUsage,
      nil
    ) {
      let seAttributes: [String: Any] = [
        kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
        kSecAttrKeySizeInBits as String: 256,
        kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
        kSecPrivateKeyAttrs as String: [
          kSecAttrIsPermanent as String: true,
          kSecAttrApplicationTag as String: tagData,
          kSecAttrAccessControl as String: access,
        ],
      ]
      var error: Unmanaged<CFError>?
      if let seKey = SecKeyCreateRandomKey(seAttributes as CFDictionary, &error) {
        return (seKey, "secure_enclave")
      }
    }

    // Fallback to non-extractable Keychain key.
    let kcAttributes: [String: Any] = [
      kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
      kSecAttrKeySizeInBits as String: 256,
      kSecPrivateKeyAttrs as String: [
        kSecAttrIsPermanent as String: true,
        kSecAttrIsExtractable as String: false,
        kSecAttrApplicationTag as String: tagData,
        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      ],
    ]
    var kcError: Unmanaged<CFError>?
    if let kcKey = SecKeyCreateRandomKey(kcAttributes as CFDictionary, &kcError) {
      return (kcKey, "keychain")
    }
    return nil
  }

  private func handleKeyEnsure(result: @escaping FlutterResult) {
    guard let (privateKey, provider) = ensurePrivateKey(),
          let publicKey = SecKeyCopyPublicKey(privateKey)
    else {
      replyError(result, code: "failed", message: "Unable to create or load P-256 key")
      return
    }

    var error: Unmanaged<CFError>?
    guard let pubData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data?,
          pubData.count == 65,
          pubData.first == 0x04
    else {
      replyError(result, code: "failed", message: "Invalid uncompressed SEC1 public key")
      return
    }

    replySuccess(result, [
      "publicKey": pubData.base64EncodedString(),
      "provider": provider,
    ])
  }

  private func handleKeySign(args: [String: Any], result: @escaping FlutterResult) {
    guard let messageB64 = args["message"] as? String,
          let messageData = Data(base64Encoded: messageB64)
    else {
      replyError(result, code: "failed", message: "Missing or invalid message")
      return
    }

    guard let (privateKey, _) = ensurePrivateKey() else {
      replyError(result, code: "failed", message: "Signing key unavailable")
      return
    }

    var error: Unmanaged<CFError>?
    guard let derSig = SecKeyCreateSignature(
      privateKey,
      .ecdsaSignatureMessageX962SHA256,
      messageData as CFData,
      &error
    ) as Data?,
          let rawRS = Self.derEcdsaToRawRS(derSig)
    else {
      replyError(result, code: "failed", message: "ECDSA signing failed")
      return
    }

    replySuccess(result, [
      "signature": rawRS.base64EncodedString(),
    ])
  }

  /// Converts an ANSI X9.62 DER-encoded P-256 signature (`SEQUENCE { INTEGER r, INTEGER s }`)
  /// into a fixed 64-byte raw `r || s` representation (32-byte big-endian `r` + 32-byte `s`).
  static func derEcdsaToRawRS(_ der: Data) -> Data? {
    let bytes = [UInt8](der)
    guard bytes.count >= 8, bytes[0] == 0x30 else { return nil }

    var index = 1
    let seqLen: Int
    if (bytes[index] & 0x80) == 0 {
      seqLen = Int(bytes[index])
      index += 1
    } else {
      let lenBytes = Int(bytes[index] & 0x7F)
      guard lenBytes == 1, index + 1 < bytes.count else { return nil }
      seqLen = Int(bytes[index + 1])
      index += 2
    }
    guard index + seqLen <= bytes.count else { return nil }

    guard index + 2 <= bytes.count, bytes[index] == 0x02 else { return nil }
    let rLen = Int(bytes[index + 1])
    index += 2
    guard index + rLen <= bytes.count else { return nil }
    let rSlice = Array(bytes[index..<(index + rLen)])
    index += rLen

    guard index + 2 <= bytes.count, bytes[index] == 0x02 else { return nil }
    let sLen = Int(bytes[index + 1])
    index += 2
    guard index + sLen <= bytes.count else { return nil }
    let sSlice = Array(bytes[index..<(index + sLen)])

    guard let rPadded = padCoordinate32(rSlice),
          let sPadded = padCoordinate32(sSlice)
    else {
      return nil
    }

    var raw = Data(capacity: 64)
    raw.append(contentsOf: rPadded)
    raw.append(contentsOf: sPadded)
    return raw
  }

  private static func padCoordinate32(_ slice: [UInt8]) -> [UInt8]? {
    var trimmed = slice
    while trimmed.count > 1 && trimmed.first == 0x00 {
      trimmed.removeFirst()
    }
    guard !trimmed.isEmpty, trimmed.count <= 32 else { return nil }
    if trimmed.count == 32 {
      return trimmed
    }
    return Array(repeating: 0x00, count: 32 - trimmed.count) + trimmed
  }

  // MARK: - Media Transport & Volume

  private func handleMedia(args: [String: Any], result: @escaping FlutterResult) {
    guard let cmd = args["cmd"] as? String else {
      replyError(result, code: "failed", message: "Missing cmd")
      return
    }

    let keyType: Int32
    let stateLabel: String
    switch cmd {
    case "play_pause":
      keyType = 16 // NX_KEYTYPE_PLAY
      stateLabel = "toggled"
    case "next":
      keyType = 17 // NX_KEYTYPE_NEXT
      stateLabel = "playing"
    case "previous":
      keyType = 18 // NX_KEYTYPE_PREVIOUS
      stateLabel = "playing"
    default:
      replyError(result, code: "unsupported", message: "Unsupported media command")
      return
    }

    guard AXIsProcessTrusted() else {
      replyError(
        result,
        code: "needs_permission",
        message: "Accessibility permission is required to send media key events"
      )
      return
    }

    let posted = postMediaKeyEvent(keyType: keyType)
    if posted {
      replySuccess(result, ["state": stateLabel])
    } else {
      replyError(result, code: "failed", message: "Failed to post media key event")
    }
  }

  private func postMediaKeyEvent(keyType: Int32) -> Bool {
    func postKey(down: Bool) -> Bool {
      let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
      let data1 = Int((keyType << 16) | ((down ? 0xA : 0xB) << 8))
      guard let nsEvent = NSEvent.otherEvent(
        with: .systemDefined,
        location: .zero,
        modifierFlags: flags,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        subtype: 8,
        data1: data1,
        data2: -1
      ),
            let cgEvent = nsEvent.cgEvent
      else {
        return false
      }
      cgEvent.post(tap: .cghidEventTap)
      return true
    }

    return postKey(down: true) && postKey(down: false)
  }

  private func handleVolumeSet(args: [String: Any], result: @escaping FlutterResult) {
    guard let level = args["level"] as? Int, (0...100).contains(level) else {
      replyError(result, code: "failed", message: "Volume level must be 0..100")
      return
    }

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
    guard devStatus == noErr, deviceId != kAudioObjectUnknown else {
      replyError(result, code: "failed", message: "No default audio output device")
      return
    }

    var scalar = Float32(level) / 100.0
    let scalarSize = UInt32(MemoryLayout<Float32>.size)
    var volumeAddr = AudioObjectPropertyAddress(
      mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
      mScope: kAudioDevicePropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain
    )

    var setStatus = AudioObjectSetPropertyData(
      deviceId,
      &volumeAddr,
      0,
      nil,
      scalarSize,
      &scalar
    )

    if setStatus != noErr {
      // Fallback to channel 1 + 2 scalar volume.
      for channel: UInt32 in [0, 1, 2] {
        var chAddr = AudioObjectPropertyAddress(
          mSelector: kAudioDevicePropertyVolumeScalar,
          mScope: kAudioDevicePropertyScopeOutput,
          mElement: channel
        )
        if AudioObjectHasProperty(deviceId, &chAddr) {
          let st = AudioObjectSetPropertyData(
            deviceId,
            &chAddr,
            0,
            nil,
            scalarSize,
            &scalar
          )
          if st == noErr {
            setStatus = noErr
          }
        }
      }
    }

    guard setStatus == noErr else {
      replyError(result, code: "failed", message: "Failed to set system audio volume")
      return
    }

    replySuccess(result, ["level": level])
  }

  private func handleNowPlaying(args: [String: Any], result: @escaping FlutterResult) {
    let allowlisted = (args["players"] as? [String] ?? [])
      .map { $0.lowercased() }
    guard !allowlisted.isEmpty else {
      replySuccess(result, ["state": "stopped"])
      return
    }

    let candidateBundles: [(id: String, bundleId: String, displayName: String)] = [
      ("spotify", "com.spotify.client", "Spotify"),
      ("music", "com.apple.Music", "Music"),
    ]

    let runningBundles = Set(
      NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier }
    )

    for candidate in candidateBundles {
      let allowed = allowlisted.contains {
        candidate.id.contains($0) || candidate.bundleId.lowercased().contains($0)
      }
      if !allowed || !runningBundles.contains(candidate.bundleId) {
        continue
      }

      let perm = checkAutomationPermission(bundleId: candidate.bundleId, prompt: false)
      if perm == "denied" {
        replyError(
          result,
          code: "needs_permission",
          message: "Automation permission denied for \(candidate.displayName)"
        )
        return
      }

      if let info = queryPlayerNowPlaying(
        bundleId: candidate.bundleId,
        displayName: candidate.displayName
      ) {
        replySuccess(result, info)
        return
      }
    }

    replySuccess(result, ["state": "stopped"])
  }

  private func queryPlayerNowPlaying(
    bundleId: String,
    displayName: String
  ) -> [String: Any]? {
    // Query via typed AppleEvents (kAECoreSuite / kAEGetData) without any AppleScript source.
    let cProperty: DescType = 0x70726F70 // 'prop'
    let pPlayerState: DescType = 0x70506C53 // 'pPlS'
    let pCurrentTrack: DescType = 0x7054726B // 'pTrk'
    let pName: DescType = 0x706E616D // 'pnam'
    let pArtist: DescType = 0x70417274 // 'pArt'
    let kPlaying: DescType = 0x6B505350 // 'kPSP'
    let kPaused: DescType = 0x6B505370 // 'kPSp'

    guard let stateDesc = sendGetPropertyEvent(
      bundleId: bundleId,
      propertyCode: pPlayerState,
      container: nil,
      cProperty: cProperty
    ) else {
      return nil
    }

    let stateEnum = stateDesc.enumCodeValue
    let rawState: String
    if stateEnum == kPlaying {
      rawState = "playing"
    } else if stateEnum == kPaused {
      rawState = "paused"
    } else {
      return ["state": "stopped", "app": truncate(displayName)]
    }

    var response: [String: Any] = [
      "state": rawState,
      "app": truncate(displayName),
    ]

    let trackSpecifier = makePropertySpecifier(
      propertyCode: pCurrentTrack,
      container: nil,
      cProperty: cProperty
    )
    if let titleDesc = sendGetPropertyEvent(
      bundleId: bundleId,
      propertyCode: pName,
      container: trackSpecifier,
      cProperty: cProperty
    ),
       let title = titleDesc.stringValue,
       !title.isEmpty
    {
      response["title"] = truncate(title)
    }

    if let artistDesc = sendGetPropertyEvent(
      bundleId: bundleId,
      propertyCode: pArtist,
      container: trackSpecifier,
      cProperty: cProperty
    ),
       let artist = artistDesc.stringValue,
       !artist.isEmpty
    {
      response["artist"] = truncate(artist)
    }

    return response
  }

  private func makePropertySpecifier(
    propertyCode: DescType,
    container: NSAppleEventDescriptor?,
    cProperty: DescType
  ) -> NSAppleEventDescriptor {
    let record = NSAppleEventDescriptor.record()
    record.setDescriptor(
      NSAppleEventDescriptor(typeCode: cProperty),
      forKeyword: AEKeyword(keyAEDesiredClass)
    )
    record.setDescriptor(
      container ?? NSAppleEventDescriptor.null(),
      forKeyword: AEKeyword(keyAEContainer)
    )
    record.setDescriptor(
      NSAppleEventDescriptor(enumCode: DescType(formPropertyID)),
      forKeyword: AEKeyword(keyAEKeyForm)
    )
    record.setDescriptor(
      NSAppleEventDescriptor(typeCode: propertyCode),
      forKeyword: AEKeyword(keyAEKeyData)
    )
    return record.coerce(toDescriptorType: DescType(typeObjectSpecifier)) ?? record
  }

  private func sendGetPropertyEvent(
    bundleId: String,
    propertyCode: DescType,
    container: NSAppleEventDescriptor?,
    cProperty: DescType
  ) -> NSAppleEventDescriptor? {
    let target = NSAppleEventDescriptor(bundleIdentifier: bundleId)
    let event = NSAppleEventDescriptor.appleEvent(
      withEventClass: AEEventClass(kAECoreSuite),
      eventID: AEEventID(kAEGetData),
      targetDescriptor: target,
      returnID: AEReturnID(kAutoGenerateReturnID),
      transactionID: AETransactionID(kAnyTransactionID)
    )
    let specifier = makePropertySpecifier(
      propertyCode: propertyCode,
      container: container,
      cProperty: cProperty
    )
    event.setParam(specifier, forKeyword: AEKeyword(keyDirectObject))

    guard let aePtr = event.aeDesc else { return nil }
    var reply = AEDesc()
    let status = AESendMessage(
      aePtr,
      &reply,
      AESendMode(kAEWaitReply | kAENeverInteract),
      300 // ~5 seconds in ticks
    )
    guard status == noErr else { return nil }
    let replyDesc = NSAppleEventDescriptor(aeDescNoCopy: &reply)
    return replyDesc.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))
  }

  // MARK: - App Launch, URL Open & Workflow Run

  private func handleAppLaunch(args: [String: Any], result: @escaping FlutterResult) {
    guard let kind = args["kind"] as? String,
          let target = args["target"] as? String,
          !target.isEmpty
    else {
      replyError(result, code: "failed", message: "Missing kind or target")
      return
    }

    let appUrl: URL?
    if kind == "bundle" {
      appUrl = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target)
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

    let config = NSWorkspace.OpenConfiguration()
    config.arguments = [] // Never pass arguments.
    config.activates = true

    let semaphore = DispatchSemaphore(value: 0)
    var launchError: Error?
    NSWorkspace.shared.openApplication(at: resolvedUrl, configuration: config) { _, err in
      launchError = err
      semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + .seconds(8))

    if launchError != nil {
      replyError(result, code: "failed", message: "Failed to launch application")
    } else {
      replySuccess(result, [:])
    }
  }

  private func handleUrlOpen(args: [String: Any], result: @escaping FlutterResult) {
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

  private func handleWorkflowRun(args: [String: Any], result: @escaping FlutterResult) {
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

  private func handlePermissions(result: @escaping FlutterResult) {
    let axState = AXIsProcessTrusted() ? "granted" : "denied"

    let bundles = [
      "com.spotify.client",
      "com.apple.Music",
      "com.apple.systemevents",
    ]
    var automationMap: [String: String] = [:]
    for bundle in bundles {
      automationMap[bundle] = checkAutomationPermission(bundleId: bundle, prompt: false)
    }

    let notifState = queryNotificationPermissionState()

    replySuccess(result, [
      "accessibility": axState,
      "automation": automationMap,
      "notifications": notifState,
    ])
  }

  private func handleRequestPermission(args: [String: Any], result: @escaping FlutterResult) {
    let kind = args["kind"] as? String ?? ""

    if kind == "accessibility" {
      let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
      let trusted = AXIsProcessTrustedWithOptions(options)
      if !trusted,
         let prefUrl = URL(
           string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
         )
      {
        NSWorkspace.shared.open(prefUrl)
      }
      replySuccess(result, ["state": trusted ? "granted" : "denied"])
      return
    }

    if kind.hasPrefix("automation") {
      let parts = kind.split(separator: ":", maxSplits: 1)
      let bundleId = parts.count == 2 ? String(parts[1]) : "com.apple.Music"
      let state = checkAutomationPermission(bundleId: bundleId, prompt: true)
      if state != "granted",
         let prefUrl = URL(
           string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
         )
      {
        NSWorkspace.shared.open(prefUrl)
      }
      replySuccess(result, ["state": state])
      return
    }

    if kind == "notifications" {
      let semaphore = DispatchSemaphore(value: 0)
      var grantedState = "denied"
      UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
        grantedState = granted ? "granted" : "denied"
        semaphore.signal()
      }
      _ = semaphore.wait(timeout: .now() + .seconds(8))
      replySuccess(result, ["state": grantedState])
      return
    }

    replySuccess(result, ["state": "granted"])
  }

  private func checkAutomationPermission(bundleId: String, prompt: Bool) -> String {
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

  private func queryNotificationPermissionState() -> String {
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

  private func handleHostInfo(result: @escaping FlutterResult) {
    let ver = ProcessInfo.processInfo.operatingSystemVersion
    let osVersion = "\(ver.majorVersion).\(ver.minorVersion).\(ver.patchVersion)"
    let hostname = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    replySuccess(result, [
      "platform": "macos",
      "osVersion": osVersion,
      "hostname": hostname,
    ])
  }

  private func handleShowToast(args: [String: Any], result: @escaping FlutterResult) {
    let message = truncate(args["message"] as? String ?? "")
    if !message.isEmpty {
      let content = UNMutableNotificationContent()
      content.title = "XUNA"
      content.body = message
      let request = UNNotificationRequest(
        identifier: UUID().uuidString,
        content: content,
        trigger: nil
      )
      UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
    replySuccess(result, [:])
  }

  // MARK: - Helpers

  private func truncate(_ value: String) -> String {
    if value.count <= Self.maxMetadataChars {
      return value
    }
    return String(value.prefix(Self.maxMetadataChars))
  }

  private func replySuccess(_ result: @escaping FlutterResult, _ payload: [String: Any]) {
    DispatchQueue.main.async {
      result(payload)
    }
  }

  private func replyError(
    _ result: @escaping FlutterResult,
    code: String,
    message: String
  ) {
    DispatchQueue.main.async {
      result(FlutterError(code: code, message: message, details: nil))
    }
  }
}
