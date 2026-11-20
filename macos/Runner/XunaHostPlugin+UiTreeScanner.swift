import ApplicationServices
import Cocoa
import CoreText
import FlutterMacOS
import ImageIO

struct ScanBudget {
  let maxIpcCalls: Int
  let deadline: Date
  var ipcCalls: Int

  init(
    maxIpcCalls: Int = 600,
    timeoutSeconds: TimeInterval = 0.35,
    now: Date = Date()
  ) {
    self.maxIpcCalls = max(1, maxIpcCalls)
    self.deadline = now.addingTimeInterval(max(0.01, timeoutSeconds))
    self.ipcCalls = 0
  }

  init(maxIpcCalls: Int = 600, deadline: Date) {
    self.maxIpcCalls = max(1, maxIpcCalls)
    self.deadline = deadline
    self.ipcCalls = 0
  }

  var isExhausted: Bool {
    isExhausted(now: Date())
  }

  func isExhausted(now: Date) -> Bool {
    ipcCalls >= maxIpcCalls || now >= deadline
  }

  func canContinue(now: Date = Date()) -> Bool {
    !isExhausted(now: now)
  }

  func remainingTime(now: Date = Date()) -> TimeInterval {
    deadline.timeIntervalSince(now)
  }

  @discardableResult
  mutating func recordIpc(_ count: Int = 1, now: Date = Date()) -> Bool {
    ipcCalls += max(0, count)
    return canContinue(now: now)
  }
}

struct SoMMark: Equatable {
  let index: Int
  let x0: Double
  let y0: Double
  let x1: Double
  let y1: Double
  let role: String?
}

enum SoMRenderingHelper {
  static let maxRenderedMarks = 300
  static let maxRawItemsScanned = 2000
  static let gridFractions: [Double] = [0.2, 0.4, 0.6, 0.8]

  private static let srgbSpace: CGColorSpace =
    CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

  static func srgbColor(
    _ r: CGFloat,
    _ g: CGFloat,
    _ b: CGFloat,
    _ a: CGFloat
  ) -> CGColor {
    return CGColor(colorSpace: srgbSpace, components: [r, g, b, a])!
  }

  private static func isBooleanValue(_ value: Any) -> Bool {
    if let num = value as? NSNumber {
      return CFGetTypeID(num) == CFBooleanGetTypeID()
    }
    return value is Bool
  }

  static func shouldAnnotateGrid(explicitArg: Any?, parsedMarks: [SoMMark]) -> Bool {
    if let explicit = explicitArg, isBooleanValue(explicit), let flag = explicit as? Bool {
      return flag
    }
    return !parsedMarks.isEmpty
  }

  static func parseMarks(_ rawList: Any?) -> [SoMMark] {
    guard let items = rawList as? [Any] else { return [] }
    var parsed: [SoMMark] = []
    let scanLimit = min(items.count, maxRawItemsScanned)
    for i in 0..<scanLimit {
      if parsed.count >= maxRenderedMarks { break }
      guard let dict = items[i] as? [String: Any] else { continue }
      guard let rawIdx = dict["index"], !isBooleanValue(rawIdx),
            let idxNum = rawIdx as? NSNumber,
            idxNum.doubleValue.isFinite
      else { continue }
      let idx = idxNum.intValue
      guard idx > 0 else { continue }
      guard let rawBounds = dict["bounds"] as? [Any], rawBounds.count == 4 else {
        continue
      }
      var coords: [Double] = []
      coords.reserveCapacity(4)
      var validCoords = true
      for rawCoord in rawBounds {
        if isBooleanValue(rawCoord) {
          validCoords = false
          break
        }
        guard let num = rawCoord as? NSNumber else {
          validCoords = false
          break
        }
        let d = num.doubleValue
        if !d.isFinite {
          validCoords = false
          break
        }
        coords.append(d)
      }
      guard validCoords, coords.count == 4 else { continue }
      let rawX0 = coords[0]
      let rawY0 = coords[1]
      let rawX1 = coords[2]
      let rawY1 = coords[3]
      guard rawX1 > rawX0, rawY1 > rawY0 else { continue }

      let cx0 = min(max(rawX0, 0.0), 1.0)
      let cy0 = min(max(rawY0, 0.0), 1.0)
      let cx1 = min(max(rawX1, 0.0), 1.0)
      let cy1 = min(max(rawY1, 0.0), 1.0)
      guard cx1 > cx0, cy1 > cy0 else { continue }

      let trimmedRole = (dict["role"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let role = (trimmedRole?.isEmpty == false) ? trimmedRole : nil
      parsed.append(
        SoMMark(index: idx, x0: cx0, y0: cy0, x1: cx1, y1: cy1, role: role)
      )
    }
    return parsed
  }

  static func cgBoxRect(
    for mark: SoMMark,
    canvasWidth: CGFloat,
    canvasHeight: CGFloat
  ) -> CGRect? {
    guard canvasWidth > 0, canvasHeight > 0 else { return nil }
    let px0 = CGFloat(mark.x0) * canvasWidth
    let px1 = CGFloat(mark.x1) * canvasWidth
    let pyTop = (1.0 - CGFloat(mark.y0)) * canvasHeight
    let pyBottom = (1.0 - CGFloat(mark.y1)) * canvasHeight
    let rect = CGRect(
      x: px0,
      y: pyBottom,
      width: px1 - px0,
      height: pyTop - pyBottom
    )
    guard rect.width >= 1.0, rect.height >= 1.0 else { return nil }
    return rect
  }

  static func clampedBadgeRect(
    forBox boxRect: CGRect,
    badgeSize: CGSize,
    canvasWidth: CGFloat,
    canvasHeight: CGFloat,
    margin: CGFloat = 1.0
  ) -> CGRect {
    let clampedW = min(max(1.0, badgeSize.width), max(1.0, canvasWidth))
    let clampedH = min(max(1.0, badgeSize.height), max(1.0, canvasHeight))
    let effectiveMarginX = min(margin, max(0.0, (canvasWidth - clampedW) * 0.5))
    let effectiveMarginY = min(margin, max(0.0, (canvasHeight - clampedH) * 0.5))

    let preferredX = boxRect.minX
    let preferredY: CGFloat
    if boxRect.maxY + clampedH + effectiveMarginY <= canvasHeight {
      preferredY = boxRect.maxY + 1.0
    } else {
      preferredY = boxRect.maxY - clampedH - 1.0
    }

    let minAllowedX = effectiveMarginX
    let maxAllowedX = max(minAllowedX, canvasWidth - clampedW - effectiveMarginX)
    let minAllowedY = effectiveMarginY
    let maxAllowedY = max(minAllowedY, canvasHeight - clampedH - effectiveMarginY)

    let finalX = min(max(preferredX, minAllowedX), maxAllowedX)
    let finalY = min(max(preferredY, minAllowedY), maxAllowedY)
    return CGRect(x: finalX, y: finalY, width: clampedW, height: clampedH)
  }

  private static func boxColorComponents(
    for mark: SoMMark
  ) -> (CGFloat, CGFloat, CGFloat) {
    let normalizedRole = mark.role?.lowercased() ?? ""
    if normalizedRole == "textfield"
      || normalizedRole == "searchfield"
      || normalizedRole == "textarea"
      || normalizedRole == "combobox"
    {
      return (0.0, 0.48, 1.0)
    }
    switch (mark.index - 1) % 5 {
    case 0:
      return (1.0, 0.23, 0.19)
    case 1:
      return (1.0, 0.58, 0.0)
    case 2:
      return (0.0, 0.78, 0.75)
    case 3:
      return (0.20, 0.78, 0.35)
    default:
      return (0.69, 0.32, 0.87)
    }
  }

  private static func drawPillText(
    _ text: String,
    fontSize: CGFloat,
    textColor: CGColor,
    bgColor: CGColor,
    borderColor: CGColor?,
    originForSize: (CGSize) -> CGRect,
    in ctx: CGContext
  ) {
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
    let attrs: [CFString: Any] = [
      kCTFontAttributeName: font,
      kCTForegroundColorAttributeName: textColor,
    ]
    guard let attrStr = CFAttributedStringCreate(
      kCFAllocatorDefault,
      text as CFString,
      attrs as CFDictionary
    ) else { return }
    let line = CTLineCreateWithAttributedString(attrStr)
    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    var leading: CGFloat = 0
    let textWidth = CGFloat(
      CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
    )
    let pillSize = CGSize(
      width: ceil(textWidth) + 8.0,
      height: ceil(ascent + descent) + 4.0
    )
    let pillRect = originForSize(pillSize)

    ctx.saveGState()
    ctx.setFillColor(bgColor)
    ctx.fill(pillRect)
    if let border = borderColor {
      ctx.setStrokeColor(border)
      ctx.setLineWidth(1.0)
      ctx.stroke(pillRect.insetBy(dx: 0.5, dy: 0.5))
    }
    ctx.textMatrix = .identity
    let baselineX = pillRect.midX - textWidth * 0.5
    let baselineY = pillRect.midY - (ascent - descent) * 0.5
    ctx.textPosition = CGPoint(x: baselineX, y: baselineY)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
  }

  private static func drawGridOverlay(
    in ctx: CGContext,
    width: CGFloat,
    height: CGFloat
  ) {
    let darkBacking = srgbColor(0.0, 0.0, 0.0, 0.35)
    let gridColor = srgbColor(0.0, 0.82, 1.0, 0.45)
    let pillBg = srgbColor(0.07, 0.09, 0.15, 0.78)
    let pillText = srgbColor(0.82, 0.96, 1.0, 0.95)
    let drawTickLabels = width >= 160.0 && height >= 120.0

    for t in gridFractions {
      let x = CGFloat(t) * width
      let y = (1.0 - CGFloat(t)) * height

      ctx.saveGState()
      ctx.setStrokeColor(darkBacking)
      ctx.setLineWidth(1.5)
      ctx.move(to: CGPoint(x: x, y: 0))
      ctx.addLine(to: CGPoint(x: x, y: height))
      ctx.move(to: CGPoint(x: 0, y: y))
      ctx.addLine(to: CGPoint(x: width, y: y))
      ctx.strokePath()

      ctx.setStrokeColor(gridColor)
      ctx.setLineWidth(0.75)
      ctx.move(to: CGPoint(x: x, y: 0))
      ctx.addLine(to: CGPoint(x: x, y: height))
      ctx.move(to: CGPoint(x: 0, y: y))
      ctx.addLine(to: CGPoint(x: width, y: y))
      ctx.strokePath()
      ctx.restoreGState()

      if drawTickLabels {
        let label = String(format: "%.1f", t)
        drawPillText(
          label,
          fontSize: 9.0,
          textColor: pillText,
          bgColor: pillBg,
          borderColor: nil,
          originForSize: { size in
            let px = min(max(2.0, x - size.width * 0.5), width - size.width - 2.0)
            let py = max(2.0, height - size.height - 2.0)
            return CGRect(origin: CGPoint(x: px, y: py), size: size)
          },
          in: ctx
        )
        drawPillText(
          label,
          fontSize: 9.0,
          textColor: pillText,
          bgColor: pillBg,
          borderColor: nil,
          originForSize: { size in
            let px: CGFloat = 2.0
            let py = min(max(2.0, y - size.height * 0.5), height - size.height - 2.0)
            return CGRect(origin: CGPoint(x: px, y: py), size: size)
          },
          in: ctx
        )
      }
    }
  }

  /// Renders scaled base image + optional normalized coordinate grid + optional
  /// Set-of-Marks boxes & `[N]` badges strictly in RAM (zero disk writes).
  static func render(
    image: CGImage,
    targetWidth: Int,
    targetHeight: Int,
    marks: [SoMMark],
    annotateGrid: Bool
  ) -> CGImage? {
    guard targetWidth > 0, targetHeight > 0 else { return nil }
    guard let ctx = CGContext(
      data: nil,
      width: targetWidth,
      height: targetHeight,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: srgbSpace,
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else {
      return nil
    }

    let w = CGFloat(targetWidth)
    let h = CGFloat(targetHeight)
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

    if annotateGrid {
      drawGridOverlay(in: ctx, width: w, height: h)
    }

    let badgeBg = srgbColor(0.07, 0.09, 0.15, 0.90)
    let badgeText = srgbColor(1.0, 1.0, 1.0, 1.0)
    let boxBacking = srgbColor(0.0, 0.0, 0.0, 0.45)

    for mark in marks.prefix(maxRenderedMarks) {
      guard let boxRect = cgBoxRect(for: mark, canvasWidth: w, canvasHeight: h)
      else { continue }
      let (r, g, b) = boxColorComponents(for: mark)
      let strokeColor = srgbColor(r, g, b, 0.95)
      let drawRect =
        (boxRect.width >= 4.0 && boxRect.height >= 4.0)
        ? boxRect.insetBy(dx: 0.75, dy: 0.75)
        : boxRect

      ctx.saveGState()
      ctx.setStrokeColor(boxBacking)
      ctx.setLineWidth(3.0)
      ctx.stroke(drawRect)
      ctx.setStrokeColor(strokeColor)
      ctx.setLineWidth(1.75)
      ctx.stroke(drawRect)
      ctx.restoreGState()

      let fontSize: CGFloat = min(11.0, max(7.0, h * 0.04))
      let labelText = "[\(mark.index)]"
      drawPillText(
        labelText,
        fontSize: fontSize,
        textColor: badgeText,
        bgColor: badgeBg,
        borderColor: strokeColor,
        originForSize: { size in
          clampedBadgeRect(
            forBox: boxRect,
            badgeSize: size,
            canvasWidth: w,
            canvasHeight: h
          )
        },
        in: ctx
      )
    }

    return ctx.makeImage()
  }
}

/// Application discovery, AXUIElement tree scanner, and pointer/scroll CGEvent primitives
/// for `XunaHostPlugin`.
extension XunaHostPlugin {
  static let interactiveAxRoles: Set<String> = [
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
    "AXTab",
    "AXLink",
    "AXRow",
    "AXListItem",
    "AXOutlineRow",
    "AXCell",
    "AXSlider",
  ]

  static let pressOnlyAxRoles: Set<String> = [
    "AXImage",
    "AXHeading",
    "AXStaticText",
  ]

  static let textInputAxRoles: Set<String> = [
    "AXTextField",
    "AXTextArea",
    "AXSearchField",
    "AXComboBox",
  ]

  static func isSecureAxControl(role: String, subrole: String) -> Bool {
    role.lowercased().contains("secure") || subrole.lowercased().contains("secure")
  }

  static func isCompositeRowAxControl(role: String, subrole: String) -> Bool {
    role == "AXRow"
      || role == "AXListItem"
      || role == "AXOutlineRow"
      || subrole == "AXOutlineRow"
  }

  static func shouldInspectAxAttributes(role: String, subrole: String) -> Bool {
    if isSecureAxControl(role: role, subrole: subrole) {
      return true
    }
    return interactiveAxRoles.contains(role)
      || pressOnlyAxRoles.contains(role)
      || textInputAxRoles.contains(role)
      || subrole == "AXOutlineRow"
  }
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
      return onMainThread { NSWorkspace.shared.frontmostApplication }
    }

    let lower = trimmed.lowercased()
    let queryTokens = lower
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }

    func findRunning() -> NSRunningApplication? {
      let running = onMainThread {
        NSWorkspace.shared.runningApplications.filter {
          $0.activationPolicy == .regular && !$0.isTerminated
        }
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
      onMainThread {
        if #available(macOS 14.0, *) {
          _ = app.activate()
        } else {
          _ = app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        }
      }
      Thread.sleep(forTimeInterval: 0.2)
    }
    return targetApp ?? onMainThread { NSWorkspace.shared.frontmostApplication }
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

  func extractAxString(_ element: AXUIElement, _ attr: String, budget: inout ScanBudget) -> String? {
    guard budget.canContinue() else { return nil }
    var ref: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(element, attr as CFString, &ref)
    budget.recordIpc(1)
    guard err == .success,
          let val = ref as? String
    else {
      return nil
    }
    let clean = val.trimmingCharacters(in: .whitespacesAndNewlines)
    return clean.isEmpty ? nil : clean
  }

  func extractAxRect(_ element: AXUIElement) -> CGRect? {
    var posRef: CFTypeRef?
    var sizeRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
          AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
          let posVal = posRef,
          let sizeVal = sizeRef,
          CFGetTypeID(posVal) == AXValueGetTypeID(),
          CFGetTypeID(sizeVal) == AXValueGetTypeID()
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
    return CGRect(origin: pt, size: sz)
  }

  func extractAxRect(_ element: AXUIElement, budget: inout ScanBudget) -> CGRect? {
    guard budget.canContinue() else { return nil }
    var posRef: CFTypeRef?
    let posErr = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef)
    budget.recordIpc(1)
    guard posErr == .success,
          let posVal = posRef,
          CFGetTypeID(posVal) == AXValueGetTypeID()
    else {
      return nil
    }
    guard budget.canContinue() else { return nil }
    var sizeRef: CFTypeRef?
    let sizeErr = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef)
    budget.recordIpc(1)
    guard sizeErr == .success,
          let sizeVal = sizeRef,
          CFGetTypeID(sizeVal) == AXValueGetTypeID()
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
    return CGRect(origin: pt, size: sz)
  }

  func extractAxCenterPoint(_ element: AXUIElement) -> CGPoint? {
    guard let rect = extractAxRect(element) else { return nil }
    return CGPoint(x: rect.midX, y: rect.midY)
  }

  func findOnScreenWindowInfo(for pid: pid_t) -> (windowId: CGWindowID, bounds: CGRect)? {
    guard let infoList = CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements],
      kCGNullWindowID
    ) as? [[String: Any]] else {
      return nil
    }
    for entry in infoList {
      guard let ownerPid = entry[kCGWindowOwnerPID as String] as? pid_t,
            ownerPid == pid,
            let layer = entry[kCGWindowLayer as String] as? Int,
            layer == 0,
            let winNum = entry[kCGWindowNumber as String] as? UInt32,
            let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
            let rect = CGRect(dictionaryRepresentation: boundsDict),
            rect.width >= 80,
            rect.height >= 60
      else {
        continue
      }
      return (CGWindowID(winNum), rect)
    }
    return nil
  }

  /// Resolves the Retina backing scale factor using thread-safe CoreGraphics display APIs.
  /// Never touches AppKit `NSScreen` on `workQueue` (which asserts `com.apple.main-thread`).
  func backingScaleFactor(for quartzRect: CGRect) -> Double {
    var displayCount: UInt32 = 0
    var matchedDisplays = [CGDirectDisplayID](repeating: 0, count: 4)
    let midRect = CGRect(x: quartzRect.midX, y: quartzRect.midY, width: 1, height: 1)
    let displayId: CGDirectDisplayID
    if CGGetDisplaysWithRect(
      midRect,
      UInt32(matchedDisplays.count),
      &matchedDisplays,
      &displayCount
    ) == .success, displayCount > 0 {
      displayId = matchedDisplays[0]
    } else {
      displayId = CGMainDisplayID()
    }
    if let mode = CGDisplayCopyDisplayMode(displayId), mode.width > 0 {
      let scale = Double(mode.pixelWidth) / Double(mode.width)
      if scale >= 1.0 {
        return scale
      }
    }
    return 1.0
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
  func axSupportsPress(_ element: AXUIElement, budget: inout ScanBudget) -> Bool {
    guard budget.canContinue() else { return false }
    var namesRef: CFArray?
    let err = AXUIElementCopyActionNames(element, &namesRef)
    budget.recordIpc(1)
    guard err == .success,
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
  func enableAssistiveAccessibility(
    app: NSRunningApplication,
    axApp: AXUIElement,
    budget: inout ScanBudget
  ) -> Bool {
    guard budget.canContinue() else { return false }
    var current: CFTypeRef?
    let curErr = AXUIElementCopyAttributeValue(axApp, "AXManualAccessibility" as CFString, &current)
    budget.recordIpc(1)
    if curErr == .success, (current as? Bool) == true {
      return false
    }
    guard budget.canContinue() else { return false }
    let manualErr = AXUIElementSetAttributeValue(
      axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    budget.recordIpc(1)
    var flipped = manualErr == .success
    if isChromiumShellApp(app) && budget.canContinue() {
      // CEF shells honour this one instead; it is limited to Chromium bundles because
      // it can change window-animation behaviour in native apps.
      let enhancedErr = AXUIElementSetAttributeValue(
        axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
      budget.recordIpc(1)
      flipped = flipped || enhancedErr == .success
    }
    return flipped
  }

  static let windowChromeSubroles: Set<String> = [
    "AXCloseButton",
    "AXMinimizeButton",
    "AXZoomButton",
    "AXFullScreenButton",
  ]

  static func reorderWindowNodes(
    nodes: [[String: Any]],
    chromeRefs: Set<String>,
    windowWidth: CGFloat,
    maxNodes: Int,
    elementMap: [String: AXUIElement],
    centerMap: [String: CGPoint],
    descriptorMap: [String: (role: String, label: String)]
  ) -> (
    nodes: [[String: Any]],
    elementMap: [String: AXUIElement],
    centerMap: [String: CGPoint],
    descriptorMap: [String: (role: String, label: String)]
  ) {
    let sidebarCutoffX = Int((windowWidth * 0.20).rounded())
    var tier1Inputs: [[String: Any]] = []
    var tier2MainContent: [[String: Any]] = []
    var tier3ChromeAndSidebar: [[String: Any]] = []
    for item in nodes {
      let refId = (item["refId"] as? String) ?? ""
      let isEditable = (item["editable"] as? Bool) == true
      let b = item["bounds"] as? [String: Int]
      let bx = b?["x"] ?? sidebarCutoffX
      let by = b?["y"] ?? 60
      let isChrome = chromeRefs.contains(refId) || by < 36
      if isEditable && !isChrome {
        tier1Inputs.append(item)
      } else if !isChrome && bx >= sidebarCutoffX {
        tier2MainContent.append(item)
      } else {
        tier3ChromeAndSidebar.append(item)
      }
    }
    let ordered = Array((tier1Inputs + tier2MainContent + tier3ChromeAndSidebar).prefix(maxNodes))
    var reindexedNodes: [[String: Any]] = []
    var newElements: [String: AXUIElement] = [:]
    var newCenters: [String: CGPoint] = [:]
    var newDescriptors: [String: (role: String, label: String)] = [:]
    for (i, var item) in ordered.enumerated() {
      let oldRef = (item["refId"] as? String) ?? ""
      let newRef = "ui_\(i + 1)"
      item["refId"] = newRef
      reindexedNodes.append(item)
      if let el = elementMap[oldRef] {
        newElements[newRef] = el
      }
      if let ct = centerMap[oldRef] {
        newCenters[newRef] = ct
      }
      if let desc = descriptorMap[oldRef] {
        newDescriptors[newRef] = desc
      }
    }
    return (reindexedNodes, newElements, newCenters, newDescriptors)
  }

  /// Synthesizes a concise human-readable label from shallow descendant text nodes
  /// (`AXStaticText`, `AXLink`) strictly for composite rows/list items (`AXRow`,
  /// `AXListItem`, `AXOutlineRow`) whose `AXTitle`/`AXDescription` are empty.
  func extractCompositeRowLabel(_ root: AXUIElement, budget: inout ScanBudget) -> String {
    if budget.ipcCalls > (budget.maxIpcCalls * 6) / 10 || !budget.canContinue() {
      return ""
    }
    var parts: [String] = []
    var queue: [(el: AXUIElement, depth: Int)] = [(root, 0)]
    var head = 0
    var visited = 0
    while head < queue.count && visited < 6 && parts.count < 4 && budget.canContinue() {
      let (cur, depth) = queue[head]
      head += 1
      visited += 1
      if depth > 0 {
        let r = extractAxString(cur, kAXRoleAttribute as String, budget: &budget) ?? ""
        if r == "AXStaticText" || r == "AXLink" {
          let txt = (
            extractAxString(cur, kAXValueAttribute as String, budget: &budget)
            ?? extractAxString(cur, kAXTitleAttribute as String, budget: &budget)
            ?? extractAxString(cur, kAXDescriptionAttribute as String, budget: &budget)
            ?? ""
          ).replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
          if !txt.isEmpty && !parts.contains(txt) {
            parts.append(String(txt.prefix(50)))
          }
        }
      }
      if depth < 1 && parts.count < 4 && budget.canContinue() {
        var childRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(cur, kAXChildrenAttribute as CFString, &childRef)
        budget.recordIpc(1)
        if err == .success, let children = childRef as? [AXUIElement] {
          for ch in children.prefix(4) {
            queue.append((ch, depth + 1))
          }
        }
      }
    }
    return parts.joined(separator: " · ")
  }

  func collectInteractiveAxNodes(
    from root: AXUIElement,
    maxNodes: Int,
    windowOrigin: CGPoint = .zero,
    priorityElement: AXUIElement? = nil,
    budget: inout ScanBudget,
    into nodes: inout [[String: Any]],
    elementMap: inout [String: AXUIElement],
    centerMap: inout [String: CGPoint],
    descriptorMap: inout [String: (role: String, label: String)],
    chromeRefs: inout Set<String>,
    redactedCount: inout Int
  ) {
    var seenElements: [AXUIElement] = []
    func alreadyRecorded(_ candidate: AXUIElement) -> Bool {
      for existing in seenElements {
        if CFEqual(existing, candidate) { return true }
      }
      return false
    }

    var queue: [(element: AXUIElement, depth: Int)] = []
    if let prio = priorityElement {
      queue.append((prio, 0))
    }
    queue.append((root, 0))
    var queueHead = 0
    var visited = 0
    let maxVisited = 4500
    let maxDepth = 45

    while queueHead < queue.count && nodes.count < maxNodes && visited < maxVisited
      && budget.canContinue()
    {
      let (current, depth) = queue[queueHead]
      queueHead += 1
      if depth > maxDepth || alreadyRecorded(current) {
        continue
      }
      visited += 1

      let role = extractAxString(current, kAXRoleAttribute as String, budget: &budget) ?? "AXElement"
      let needsSubrole =
        role == "AXGroup"
        || role == "AXTextField"
        || role == "AXButton"
        || role == "AXRow"
        || role == "AXUnknown"
        || role == "AXElement"
        || role.lowercased().contains("secure")
      let subrole = needsSubrole
        ? (extractAxString(current, kAXSubroleAttribute as String, budget: &budget) ?? "")
        : ""

      if !Self.shouldInspectAxAttributes(role: role, subrole: subrole) {
        if depth < maxDepth && budget.canContinue() {
          var childrenRef: CFTypeRef?
          let err = AXUIElementCopyAttributeValue(current, kAXChildrenAttribute as CFString, &childrenRef)
          budget.recordIpc(1)
          if err == .success, let children = childrenRef as? [AXUIElement] {
            for child in children.prefix(80) {
              queue.append((child, depth + 1))
            }
          }
        }
        continue
      }

      let isSecure = Self.isSecureAxControl(role: role, subrole: subrole)
      let isTextInput = Self.textInputAxRoles.contains(role)

      var title: String?
      var desc: String?
      var placeholder: String?
      var help: String?
      var value: String?
      var identifier: String?
      var cmdChar: String?

      let isCompositeRow = Self.isCompositeRowAxControl(role: role, subrole: subrole)
      if !isSecure {
        title = extractAxString(current, kAXTitleAttribute as String, budget: &budget)
        if title == nil {
          desc = extractAxString(current, kAXDescriptionAttribute as String, budget: &budget)
        }
        if isTextInput {
          placeholder = extractAxString(current, "AXPlaceholderValue", budget: &budget)
        }
        if !isCompositeRow && title == nil && desc == nil && placeholder == nil {
          help = extractAxString(current, kAXHelpAttribute as String, budget: &budget)
        }
        let needsValueAttr =
          isTextInput
          || role == "AXStaticText"
          || role == "AXCheckBox"
          || role == "AXRadioButton"
          || role == "AXPopUpButton"
          || role == "AXSlider"
          || (!isCompositeRow && title == nil && desc == nil && placeholder == nil && help == nil)
        if needsValueAttr {
          value = extractAxString(current, kAXValueAttribute as String, budget: &budget)
        }
        if !isCompositeRow && title == nil && desc == nil && placeholder == nil && help == nil && value == nil {
          identifier = extractAxString(current, kAXIdentifierAttribute as String, budget: &budget)
        }
        if role == "AXMenuItem" {
          cmdChar = extractAxString(current, kAXMenuItemCmdCharAttribute as String, budget: &budget)
        }
      }

      var rawLabel = title ?? desc ?? placeholder ?? help ?? value ?? identifier ?? ""
      if rawLabel.isEmpty && !isSecure && Self.isCompositeRowAxControl(role: role, subrole: subrole) {
        rawLabel = extractCompositeRowLabel(current, budget: &budget)
      }
      if let keyChar = cmdChar, !keyChar.isEmpty, !rawLabel.isEmpty {
        rawLabel = "\(rawLabel) [⌘\(keyChar.uppercased())]"
      }
      var isTextEditable = false
      if isTextInput && !isSecure && budget.canContinue() {
        var settable = DarwinBoolean(false)
        _ = AXUIElementIsAttributeSettable(current, kAXValueAttribute as CFString, &settable)
        budget.recordIpc(1)
        var hasSel = false
        if !settable.boolValue && budget.canContinue() {
          var selRef: CFTypeRef?
          hasSel = AXUIElementCopyAttributeValue(
            current,
            kAXSelectedTextRangeAttribute as CFString,
            &selRef
          ) == .success
          budget.recordIpc(1)
        }
        isTextEditable = settable.boolValue || hasSel || placeholder != nil || subrole == "AXSearchField"
      }
      let effectiveRole: String
      if subrole == "AXSearchField" || (role == "AXComboBox" && isTextEditable) {
        effectiveRole = "AXSearchField"
      } else {
        effectiveRole = role
      }

      let isLabelledInteractive = !rawLabel.isEmpty && Self.interactiveAxRoles.contains(role)
      let isPressableGeneric =
        !rawLabel.isEmpty && Self.pressOnlyAxRoles.contains(role) && axSupportsPress(current, budget: &budget)
      if isSecure || isLabelledInteractive || isTextInput || isPressableGeneric {
        seenElements.append(current)
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
          "role": effectiveRole,
          "label": cleanLabel,
          "editable": isTextInput ? isTextEditable : false,
          "isPassword": isSecure,
          "pattern": (effectiveRole.contains("Text") || effectiveRole.contains("Search") || effectiveRole.contains("Combo"))
            ? "AXValue / Keyboard"
            : "AXPress",
          "status": "ready",
        ]
        if cleanLabel.isEmpty {
          nodeDict["unlabeled"] = true
        }
        if let val = value, !val.isEmpty, val != cleanLabel {
          nodeDict["value"] = String(val.prefix(80))
        }
        let elRect = extractAxRect(current, budget: &budget)
        if let rect = elRect {
          nodeDict["bounds"] = [
            "x": Int((rect.origin.x - windowOrigin.x).rounded()),
            "y": Int((rect.origin.y - windowOrigin.y).rounded()),
            "width": Int(rect.size.width.rounded()),
            "height": Int(rect.size.height.rounded()),
          ]
        }
        nodes.append(nodeDict)
        if Self.windowChromeSubroles.contains(subrole) {
          chromeRefs.insert(refId)
        }
        if !isSecure {
          elementMap[refId] = current
          descriptorMap[refId] = (role: effectiveRole, label: cleanLabel)
          if let rect = elRect {
            centerMap[refId] = CGPoint(x: rect.midX, y: rect.midY)
          }
        }
      }

      if depth < maxDepth && budget.canContinue() {
        var childrenRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(current, kAXChildrenAttribute as CFString, &childrenRef)
        budget.recordIpc(1)
        if err == .success, let children = childrenRef as? [AXUIElement] {
          let childCap = (role == "AXTable" || role == "AXOutline" || role == "AXList") ? 12 : 80
          for child in children.prefix(childCap) {
            queue.append((child, depth + 1))
          }
        }
      }
    }
  }

  func scanApplicationUiTree(
    app: NSRunningApplication,
    maxNodes: Int
  ) -> (
    windowTitle: String,
    nodes: [[String: Any]],
    redactedCount: Int,
    windowRect: CGRect,
    devicePixelRatio: Double
  ) {
    let maxIpc = maxNodes >= 100 ? 1150 : 850
    let timeoutSec: TimeInterval = maxNodes >= 100 ? 0.14 : 0.095
    var budget = ScanBudget(maxIpcCalls: maxIpc, timeoutSeconds: timeoutSec)
    let appName = app.localizedName ?? "macOS Window"
    var winTitle = appName
    var nodes: [[String: Any]] = []
    var elementMap: [String: AXUIElement] = [:]
    var centerMap: [String: CGPoint] = [:]
    var descriptorMap: [String: (role: String, label: String)] = [:]
    var chromeRefs: Set<String> = []
    var redactedCount = 0
    var winRect = findOnScreenWindowInfo(for: app.processIdentifier)?.bounds
      ?? CGRect(x: 0, y: 0, width: 1280, height: 720)

    // Set short per-IPC timeout globally on the system-wide AX object AND axApp so child
    // AXUIElements never fall back to the ~6s default messaging timeout.
    let systemWide = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(systemWide, 0.05)
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(axApp, 0.05)
    let justEnabledAx = enableAssistiveAccessibility(app: app, axApp: axApp, budget: &budget)

    var focusElemRef: CFTypeRef?
    var focusedPriority: AXUIElement?
    if budget.canContinue() {
      let focusErr = AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusElemRef)
      budget.recordIpc(1)
      if focusErr == .success, let focusVal = focusElemRef, CFGetTypeID(focusVal) == AXUIElementGetTypeID() {
        let candidate = (focusVal as! AXUIElement)
        let focusRole = extractAxString(candidate, kAXRoleAttribute as String, budget: &budget) ?? ""
        let focusSubrole = extractAxString(candidate, kAXSubroleAttribute as String, budget: &budget) ?? ""
        if Self.shouldInspectAxAttributes(role: focusRole, subrole: focusSubrole)
          && !Self.isCompositeRowAxControl(role: focusRole, subrole: focusSubrole)
        {
          focusedPriority = candidate
        }
      }
    }

    var targetWindow: AXUIElement?
    if budget.canContinue() {
      var winRef: CFTypeRef?
      let focusedWinErr = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &winRef)
      budget.recordIpc(1)
      if focusedWinErr == .success, let winElem = winRef, CFGetTypeID(winElem) == AXUIElementGetTypeID() {
        targetWindow = (winElem as! AXUIElement)
      } else if budget.canContinue() {
        var mainRef: CFTypeRef?
        let mainWinErr = AXUIElementCopyAttributeValue(axApp, kAXMainWindowAttribute as CFString, &mainRef)
        budget.recordIpc(1)
        if mainWinErr == .success, let winElem = mainRef, CFGetTypeID(winElem) == AXUIElementGetTypeID() {
          targetWindow = (winElem as! AXUIElement)
        } else if budget.canContinue() {
          var winsRef: CFTypeRef?
          let winsErr = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winsRef)
          budget.recordIpc(1)
          if winsErr == .success, let winList = winsRef as? [AXUIElement], let firstWin = winList.first {
            targetWindow = firstWin
          }
        }
      }
    }

    let collectLimit = min(max(maxNodes + 15, 75), 130)
    if let win = targetWindow {
      if let actualTitle = extractAxString(win, kAXTitleAttribute as String, budget: &budget) {
        winTitle = "\(appName) — \(actualTitle)"
      }
      if let axWinRect = extractAxRect(win, budget: &budget) {
        winRect = axWinRect
      }
      collectInteractiveAxNodes(
        from: win,
        maxNodes: collectLimit,
        windowOrigin: winRect.origin,
        priorityElement: focusedPriority,
        budget: &budget,
        into: &nodes,
        elementMap: &elementMap,
        centerMap: &centerMap,
        descriptorMap: &descriptorMap,
        chromeRefs: &chromeRefs,
        redactedCount: &redactedCount
      )
      let isChromium = isChromiumShellApp(app)
      let minWaitBudget: TimeInterval = isChromium ? 0.22 : 0.12
      if justEnabledAx && nodes.count < 3 && budget.canContinue() && budget.remainingTime() >= minWaitBudget {
        let maxWait: TimeInterval = isChromium ? 0.15 : 0.05
        let sleepSec = min(maxWait, max(0.0, budget.remainingTime() - 0.07))
        if sleepSec > 0.005 {
          Thread.sleep(forTimeInterval: sleepSec)
        }
        if budget.canContinue() {
          nodes.removeAll()
          elementMap.removeAll()
          centerMap.removeAll()
          descriptorMap.removeAll()
          chromeRefs.removeAll()
          redactedCount = 0
          collectInteractiveAxNodes(
            from: win,
            maxNodes: collectLimit,
            windowOrigin: winRect.origin,
            priorityElement: focusedPriority,
            budget: &budget,
            into: &nodes,
            elementMap: &elementMap,
            centerMap: &centerMap,
            descriptorMap: &descriptorMap,
            chromeRefs: &chromeRefs,
            redactedCount: &redactedCount
          )
        }
      }
      // Prioritize focused/editable inputs + main content canvas (`x >= 20% width`) ahead of
      // macOS window-chrome controls (`AXCloseButton`, `AXZoomButton`, `y < 36`) and sidebars.
      if nodes.count > 1 {
        let reordered = Self.reorderWindowNodes(
          nodes: nodes,
          chromeRefs: chromeRefs,
          windowWidth: winRect.size.width,
          maxNodes: maxNodes,
          elementMap: elementMap,
          centerMap: centerMap,
          descriptorMap: descriptorMap
        )
        nodes = reordered.nodes
        elementMap = reordered.elementMap
        centerMap = reordered.centerMap
        descriptorMap = reordered.descriptorMap
      }
    }

    if nodes.count < maxNodes && budget.canContinue() {
      var menuRef: CFTypeRef?
      let menuErr = AXUIElementCopyAttributeValue(axApp, kAXMenuBarAttribute as CFString, &menuRef)
      budget.recordIpc(1)
      if menuErr == .success,
         let menuElem = menuRef,
         CFGetTypeID(menuElem) == AXUIElementGetTypeID()
      {
        collectInteractiveAxNodes(
          from: menuElem as! AXUIElement,
          maxNodes: min(maxNodes, nodes.count + 6),
          windowOrigin: winRect.origin,
          budget: &budget,
          into: &nodes,
          elementMap: &elementMap,
          centerMap: &centerMap,
          descriptorMap: &descriptorMap,
          chromeRefs: &chromeRefs,
          redactedCount: &redactedCount
        )
      }
    }

    uiCacheLock.lock()
    cachedUiPid = app.processIdentifier
    cachedUiElements = elementMap
    cachedUiCenters = centerMap
    cachedUiDescriptors = descriptorMap
    uiCacheLock.unlock()

    let dpr = backingScaleFactor(for: winRect)
    return (winTitle, nodes, redactedCount, winRect, dpr)
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
    if !onMainThread({ AXIsProcessTrusted() }) {
      replyError(
        result,
        code: "accessibility",
        message: "Accessibility permission is required on macOS to inspect application UI."
      )
      return
    }
    let rawMax = args["maxNodes"] as? Int ?? 35
    let maxNodes = min(max(rawMax, 1), 120)
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
      "windowX": Int(snapshot.windowRect.origin.x.rounded()),
      "windowY": Int(snapshot.windowRect.origin.y.rounded()),
      "windowWidth": Int(snapshot.windowRect.size.width.rounded()),
      "windowHeight": Int(snapshot.windowRect.size.height.rounded()),
      "devicePixelRatio": snapshot.devicePixelRatio,
      "screenshotBytesUsed": 0,
    ])
  }

  /// Captures an in-memory JPEG screenshot of the active window or full display (`UDC-18` Wave C).
  /// Zero-Retention (Consent U5): encoded strictly in memory, never touches disk.
  func handleCaptureScreen(args: [String: Any], result: @escaping FlutterResult) {
    let hasScreenAccess = onMainThread { () -> Bool in
      if #available(macOS 10.15, *) {
        return CGPreflightScreenCaptureAccess()
      }
      return true
    }
    if !hasScreenAccess {
      replyError(
        result,
        code: "screen_recording",
        message: "Screen recording permission is required for visual observation."
      )
      return
    }

    let scope = (args["scope"] as? String ?? "active_window").lowercased()
    let rawMaxEdge = args["maxEdge"] as? Int ?? 1280
    let maxEdge = min(max(rawMaxEdge, 320), 1280)
    let rawSomMarks = args["somMarks"]
    let somMarks = SoMRenderingHelper.parseMarks(rawSomMarks)
    let annotateGrid = SoMRenderingHelper.shouldAnnotateGrid(
      explicitArg: args["annotateGrid"],
      parsedMarks: somMarks
    )
    let shouldRenderOverlay = annotateGrid || !somMarks.isEmpty

    let frontApp = onMainThread { NSWorkspace.shared.frontmostApplication }
    if let app = frontApp,
       Self.isHardDeniedApp(app.localizedName ?? "", bundleId: app.bundleIdentifier)
    {
      replyError(
        result,
        code: "hard_denied_window",
        message: "Refused to capture a hard-denied security or terminal window."
      )
      return
    }

    let captured: CGImage?
    if scope == "screen" || scope == "full_screen" {
      captured = CGWindowListCreateImage(
        CGRect.infinite,
        .optionOnScreenOnly,
        kCGNullWindowID,
        [.nominalResolution]
      )
    } else if let app = frontApp,
              let info = findOnScreenWindowInfo(for: app.processIdentifier)
    {
      if let winImg = CGWindowListCreateImage(
        .null,
        .optionIncludingWindow,
        info.windowId,
        [.boundsIgnoreFraming, .nominalResolution]
      ) {
        captured = winImg
      } else {
        captured = CGWindowListCreateImage(
          info.bounds,
          .optionOnScreenOnly,
          kCGNullWindowID,
          [.nominalResolution]
        )
      }
    } else {
      captured = CGWindowListCreateImage(
        CGRect.infinite,
        .optionOnScreenOnly,
        kCGNullWindowID,
        [.nominalResolution]
      )
    }

    guard let cgImg = captured, cgImg.width > 1, cgImg.height > 1 else {
      replyError(
        result,
        code: "capture_failed",
        message: "Screen capture returned no window image."
      )
      return
    }

    let srcW = cgImg.width
    let srcH = cgImg.height
    let longest = max(srcW, srcH)
    let scale = longest > maxEdge ? (Double(maxEdge) / Double(longest)) : 1.0
    let dstW = max(1, Int((Double(srcW) * scale).rounded()))
    let dstH = max(1, Int((Double(srcH) * scale).rounded()))

    let scaledImage: CGImage
    if !shouldRenderOverlay && dstW == srcW && dstH == srcH {
      scaledImage = cgImg
    } else if let rendered = SoMRenderingHelper.render(
      image: cgImg,
      targetWidth: dstW,
      targetHeight: dstH,
      marks: somMarks,
      annotateGrid: annotateGrid
    ) {
      scaledImage = rendered
    } else {
      scaledImage = cgImg
    }

    guard let encoded = Self.encodeCompactJpeg(scaledImage, maxBytes: 85_000) else {
      replyError(
        result,
        code: "capture_failed",
        message: "Failed to encode screenshot as JPEG."
      )
      return
    }

    replySuccess(result, [
      "mimeType": "image/jpeg",
      "width": encoded.width,
      "height": encoded.height,
      "dataBase64": encoded.data.base64EncodedString(),
    ])
  }

  static func encodeJpeg(_ image: CGImage, quality: Double) -> Data? {
    let jpegMutableData = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(
      jpegMutableData as CFMutableData,
      "public.jpeg" as CFString,
      1,
      nil
    ) else {
      return nil
    }
    let encodeOptions: [CFString: Any] = [
      kCGImageDestinationLossyCompressionQuality: quality,
    ]
    CGImageDestinationAddImage(dest, image, encodeOptions as CFDictionary)
    guard CGImageDestinationFinalize(dest), jpegMutableData.length > 0 else {
      return nil
    }
    return jpegMutableData as Data
  }

  static func encodeCompactJpeg(
    _ image: CGImage,
    maxBytes: Int = 220_000
  ) -> (data: Data, width: Int, height: Int)? {
    let qualities: [Double] = [0.35, 0.25, 0.18]
    var bestData: Data?
    var bestW = image.width
    var bestH = image.height

    for q in qualities {
      if let data = encodeJpeg(image, quality: q) {
        bestData = data
        if data.count <= maxBytes {
          return (data, image.width, image.height)
        }
      }
    }

    var curImage = image
    for _ in 0..<2 {
      guard let prevData = bestData, prevData.count > maxBytes else { break }
      let ratio = max(0.45, min(0.80, sqrt(Double(maxBytes) / Double(prevData.count)) * 0.92))
      let newW = max(1, Int((Double(curImage.width) * ratio).rounded()))
      let newH = max(1, Int((Double(curImage.height) * ratio).rounded()))
      if newW == curImage.width && newH == curImage.height {
        break
      }
      guard let resized = SoMRenderingHelper.render(
        image: curImage,
        targetWidth: newW,
        targetHeight: newH,
        marks: [],
        annotateGrid: false
      ) else {
        break
      }
      curImage = resized
      bestW = resized.width
      bestH = resized.height
      for q in [0.55, 0.40, 0.30] {
        if let data = encodeJpeg(curImage, quality: q) {
          bestData = data
          if data.count <= maxBytes {
            return (data, bestW, bestH)
          }
        }
      }
    }

    if let data = bestData {
      return (data, bestW, bestH)
    }
    return nil
  }
}
