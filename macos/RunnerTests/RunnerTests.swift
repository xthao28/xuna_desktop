import Cocoa
import CoreText
import FlutterMacOS
import ImageIO
import IOKit.ps
import XCTest
@testable import xuna_desktop

class RunnerTests: XCTestCase {

  func testScanBudgetStopsAtMaxIpcCalls() {
    let start = Date(timeIntervalSince1970: 1_000.0)
    var budget = ScanBudget(maxIpcCalls: 600, timeoutSeconds: 0.35, now: start)

    XCTAssertTrue(budget.canContinue(now: start))
    XCTAssertFalse(budget.isExhausted(now: start))

    for idx in 0..<599 {
      let stillOk = budget.recordIpc(1, now: start)
      XCTAssertTrue(stillOk, "Expected budget to remain open at IPC call \(idx + 1)")
    }
    XCTAssertEqual(budget.ipcCalls, 599)
    XCTAssertTrue(budget.canContinue(now: start))

    let after600 = budget.recordIpc(1, now: start)
    XCTAssertFalse(after600)
    XCTAssertEqual(budget.ipcCalls, 600)
    XCTAssertTrue(budget.isExhausted(now: start))
    XCTAssertFalse(budget.canContinue(now: start))
  }

  func testScanBudgetStopsAtDeadline() {
    let start = Date(timeIntervalSince1970: 2_000.0)
    let budget = ScanBudget(maxIpcCalls: 600, timeoutSeconds: 0.35, now: start)

    let beforeDeadline = start.addingTimeInterval(0.349)
    XCTAssertTrue(budget.canContinue(now: beforeDeadline))
    XCTAssertFalse(budget.isExhausted(now: beforeDeadline))

    let atDeadline = start.addingTimeInterval(0.35)
    XCTAssertFalse(budget.canContinue(now: atDeadline))
    XCTAssertTrue(budget.isExhausted(now: atDeadline))

    let pastDeadline = start.addingTimeInterval(0.50)
    XCTAssertFalse(budget.canContinue(now: pastDeadline))
    XCTAssertTrue(budget.isExhausted(now: pastDeadline))
  }

  func testScanBudgetRecordMultiCountAndRemainingTime() {
    let start = Date(timeIntervalSince1970: 3_000.0)
    var budget = ScanBudget(maxIpcCalls: 5, timeoutSeconds: 0.35, now: start)

    XCTAssertEqual(budget.remainingTime(now: start.addingTimeInterval(0.10)), 0.25, accuracy: 0.0001)
    XCTAssertTrue(budget.recordIpc(2, now: start))
    XCTAssertEqual(budget.ipcCalls, 2)
    XCTAssertFalse(budget.recordIpc(3, now: start))
    XCTAssertTrue(budget.isExhausted(now: start))
  }

  func testAxRolePruningExcludesGenericAxGroupFromAttributeInspection() {
    XCTAssertFalse(XunaHostPlugin.shouldInspectAxAttributes(role: "AXGroup", subrole: ""))
    XCTAssertFalse(XunaHostPlugin.shouldInspectAxAttributes(role: "AXGroup", subrole: "AXApplicationGroup"))
    XCTAssertFalse(XunaHostPlugin.shouldInspectAxAttributes(role: "AXScrollArea", subrole: ""))
    XCTAssertFalse(XunaHostPlugin.shouldInspectAxAttributes(role: "AXWebArea", subrole: ""))
    XCTAssertFalse(XunaHostPlugin.shouldInspectAxAttributes(role: "AXSplitGroup", subrole: ""))
    XCTAssertFalse(XunaHostPlugin.pressOnlyAxRoles.contains("AXGroup"))
    XCTAssertFalse(XunaHostPlugin.isCompositeRowAxControl(role: "AXGroup", subrole: ""))
  }

  func testAxRoleClassificationPreservesInteractiveAndCompositeRowRoles() {
    let expectedInspectedRoles = [
      "AXButton",
      "AXLink",
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
      "AXSlider",
      "AXRow",
      "AXListItem",
      "AXOutlineRow",
      "AXCell",
      "AXImage",
      "AXHeading",
      "AXStaticText",
    ]
    for role in expectedInspectedRoles {
      XCTAssertTrue(
        XunaHostPlugin.shouldInspectAxAttributes(role: role, subrole: ""),
        "Expected role \(role) to remain inspected"
      )
    }

    XCTAssertTrue(XunaHostPlugin.isCompositeRowAxControl(role: "AXRow", subrole: ""))
    XCTAssertTrue(XunaHostPlugin.isCompositeRowAxControl(role: "AXListItem", subrole: ""))
    XCTAssertTrue(XunaHostPlugin.isCompositeRowAxControl(role: "AXOutlineRow", subrole: ""))
    XCTAssertTrue(XunaHostPlugin.isCompositeRowAxControl(role: "AXGroup", subrole: "AXOutlineRow"))
  }

  func testSecureControlDetection() {
    XCTAssertTrue(XunaHostPlugin.isSecureAxControl(role: "AXSecureTextField", subrole: ""))
    XCTAssertTrue(XunaHostPlugin.isSecureAxControl(role: "AXTextField", subrole: "AXSecureTextField"))
    XCTAssertTrue(XunaHostPlugin.isSecureAxControl(role: "AXGroup", subrole: "AXSecureTextField"))
    XCTAssertTrue(XunaHostPlugin.shouldInspectAxAttributes(role: "AXGroup", subrole: "AXSecureTextField"))
    XCTAssertFalse(XunaHostPlugin.isSecureAxControl(role: "AXTextField", subrole: "AXSearchField"))
  }

  func testQueueSplitAndLockIsolation() {
    let plugin = XunaHostPlugin()
    XCTAssertNotEqual(plugin.fastContextQueue.label, plugin.uiActionQueue.label)
    XCTAssertNotEqual(plugin.captureQueue.label, plugin.uiActionQueue.label)
    XCTAssertEqual(plugin.fastContextQueue.label, "ai.xuna.desktop.host.fast-context")
    XCTAssertEqual(plugin.uiActionQueue.label, "ai.xuna.desktop.host.ui-action")
    XCTAssertEqual(plugin.captureQueue.label, "ai.xuna.desktop.host.capture")

    plugin.uiCacheLock.lock()
    plugin.cachedUiPid = 1234
    plugin.uiCacheLock.unlock()
    XCTAssertEqual(plugin.cachedUiPid, 1234)

    plugin.keyCacheLock.lock()
    plugin.keyCacheLock.unlock()
  }

  private func makeSolidBlackImage(width: Int, height: Int) -> CGImage? {
    let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: space,
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else {
      return nil
    }
    ctx.setFillColor(SoMRenderingHelper.srgbColor(0.0, 0.0, 0.0, 1.0))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()
  }

  private func readRgbaBytes(from image: CGImage) -> [UInt8]? {
    let width = image.width
    let height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    let drawn: Bool = bytes.withUnsafeMutableBytes { rawBuf in
      guard let basePtr = rawBuf.baseAddress,
            let ctx = CGContext(
              data: basePtr,
              width: width,
              height: height,
              bitsPerComponent: 8,
              bytesPerRow: width * 4,
              space: space,
              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
      else {
        return false
      }
      ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    return drawn ? bytes : nil
  }

  private func hasNonBlackPixel(
    in bytes: [UInt8],
    width: Int,
    rowRange: Range<Int>,
    colRange: Range<Int>
  ) -> Bool {
    for row in rowRange {
      for col in colRange {
        let offset = (row * width + col) * 4
        if bytes[offset] > 10 || bytes[offset + 1] > 10 || bytes[offset + 2] > 10 {
          return true
        }
      }
    }
    return false
  }

  func testParseMarksFiltersInvalidAndCapsHugeArrays() {
    let raw: [Any] = [
      // Valid mark with role and edge overhang
      ["index": 1, "bounds": [-0.05, 0.1, 0.25, 0.4], "role": "button"],
      // Bool disguised as NSNumber must be rejected
      ["index": true, "bounds": [0.1, 0.1, 0.5, 0.5]],
      ["index": 2, "bounds": [true, 0.1, 0.5, 0.5]],
      // Non-positive index rejected
      ["index": 0, "bounds": [0.1, 0.1, 0.5, 0.5]],
      ["index": -3, "bounds": [0.1, 0.1, 0.5, 0.5]],
      // Non-finite coords rejected
      ["index": 3, "bounds": [0.1, Double.nan, 0.5, 0.5]],
      ["index": 4, "bounds": [0.1, 0.2, Double.infinity, 0.5]],
      // Wrong bounds length or inverted coords rejected
      ["index": 5, "bounds": [0.1, 0.2, 0.5]],
      ["index": 6, "bounds": [0.5, 0.2, 0.3, 0.4]],
      ["index": 7, "bounds": [0.1, 0.6, 0.5, 0.4]],
      // Completely offscreen rejected
      ["index": 8, "bounds": [-0.5, 0.1, -0.1, 0.3]],
      ["index": 9, "bounds": [1.2, 0.1, 1.5, 0.3]],
    ]

    let parsed = SoMRenderingHelper.parseMarks(raw)
    XCTAssertEqual(parsed.count, 1)
    XCTAssertEqual(parsed[0].index, 1)
    XCTAssertEqual(parsed[0].x0, 0.0, accuracy: 0.0001)
    XCTAssertEqual(parsed[0].y0, 0.1, accuracy: 0.0001)
    XCTAssertEqual(parsed[0].x1, 0.25, accuracy: 0.0001)
    XCTAssertEqual(parsed[0].y1, 0.4, accuracy: 0.0001)
    XCTAssertEqual(parsed[0].role, "button")

    // Huge array capped at maxRenderedMarks (300)
    let huge = (1...1000).map { idx -> [String: Any] in
      ["index": idx, "bounds": [0.1, 0.1, 0.2, 0.2]]
    }
    let capped = SoMRenderingHelper.parseMarks(huge)
    XCTAssertEqual(capped.count, SoMRenderingHelper.maxRenderedMarks)
    XCTAssertEqual(capped.first?.index, 1)
    XCTAssertEqual(capped.last?.index, 300)
  }

  func testCgBoxRectYFlipMapsTopLeftNormalizedToBottomLeftCG() {
    let topLeft = SoMMark(index: 1, x0: 0.0, y0: 0.0, x1: 0.2, y1: 0.1, role: nil)
    let topLeftCg = SoMRenderingHelper.cgBoxRect(
      for: topLeft,
      canvasWidth: 1000,
      canvasHeight: 800
    )
    XCTAssertNotNil(topLeftCg)
    XCTAssertEqual(topLeftCg!.minX, 0.0, accuracy: 0.01)
    XCTAssertEqual(topLeftCg!.minY, 720.0, accuracy: 0.01)
    XCTAssertEqual(topLeftCg!.maxY, 800.0, accuracy: 0.01)
    XCTAssertEqual(topLeftCg!.width, 200.0, accuracy: 0.01)
    XCTAssertEqual(topLeftCg!.height, 80.0, accuracy: 0.01)

    let bottomRight = SoMMark(index: 2, x0: 0.8, y0: 0.9, x1: 1.0, y1: 1.0, role: nil)
    let bottomRightCg = SoMRenderingHelper.cgBoxRect(
      for: bottomRight,
      canvasWidth: 1000,
      canvasHeight: 800
    )
    XCTAssertNotNil(bottomRightCg)
    XCTAssertEqual(bottomRightCg!.minX, 800.0, accuracy: 0.01)
    XCTAssertEqual(bottomRightCg!.minY, 0.0, accuracy: 0.01)
    XCTAssertEqual(bottomRightCg!.width, 200.0, accuracy: 0.01)
    XCTAssertEqual(bottomRightCg!.height, 80.0, accuracy: 0.01)
  }

  func testClampedBadgeRectStaysInsideAllFourCanvasEdges() {
    let badgeSize = CGSize(width: 28, height: 16)
    let cases: [(CGRect, CGFloat, CGFloat)] = [
      (CGRect(x: 0, y: 740, width: 60, height: 60), 1000, 800), // top-left
      (CGRect(x: 960, y: 0, width: 40, height: 40), 1000, 800), // bottom-right
      (CGRect(x: 980, y: 780, width: 20, height: 20), 1000, 800), // top-right
      (CGRect(x: 0, y: 0, width: 20, height: 20), 40, 40), // tiny canvas
    ]
    for (box, w, h) in cases {
      let badge = SoMRenderingHelper.clampedBadgeRect(
        forBox: box,
        badgeSize: badgeSize,
        canvasWidth: w,
        canvasHeight: h
      )
      XCTAssertGreaterThanOrEqual(badge.minX, 0.0)
      XCTAssertGreaterThanOrEqual(badge.minY, 0.0)
      XCTAssertLessThanOrEqual(badge.maxX, w)
      XCTAssertLessThanOrEqual(badge.maxY, h)
    }
  }

  func testRenderSoMDrawsPixelsInExpectedTopLeftAndBottomRightQuadrants() throws {
    let base = try XCTUnwrap(makeSolidBlackImage(width: 400, height: 300))
    let mark = SoMMark(index: 1, x0: 0.0, y0: 0.0, x1: 0.25, y1: 0.25, role: "button")
    // Exercises dstW == srcW && dstH == srcH path with overlay rendering
    let rendered = try XCTUnwrap(
      SoMRenderingHelper.render(
        image: base,
        targetWidth: 400,
        targetHeight: 300,
        marks: [mark],
        annotateGrid: false
      )
    )
    XCTAssertEqual(rendered.width, 400)
    XCTAssertEqual(rendered.height, 300)

    let bytes = try XCTUnwrap(readRgbaBytes(from: rendered))
    // Top-left quadrant (rows 0..<90, cols 0..<120) must contain drawn overlay pixels
    XCTAssertTrue(hasNonBlackPixel(in: bytes, width: 400, rowRange: 0..<90, colRange: 0..<120))
    // Bottom-right quadrant (rows 200..<300, cols 280..<400) must remain pure black
    XCTAssertFalse(hasNonBlackPixel(in: bytes, width: 400, rowRange: 200..<300, colRange: 280..<400))
  }

  func testRenderGridTicksDrawsHorizontalAndVerticalLinesAndEncodesValidInMemoryJpeg() throws {
    let base = try XCTUnwrap(makeSolidBlackImage(width: 400, height: 300))
    let rendered = try XCTUnwrap(
      SoMRenderingHelper.render(
        image: base,
        targetWidth: 400,
        targetHeight: 300,
        marks: [],
        annotateGrid: true
      )
    )
    let bytes = try XCTUnwrap(readRgbaBytes(from: rendered))
    // Vertical line at 0.2 * 400 = 80 (check middle row 150)
    XCTAssertTrue(hasNonBlackPixel(in: bytes, width: 400, rowRange: 148..<152, colRange: 78..<82))
    // Horizontal line at top-down 0.2 * 300 = row 60 (check middle col 200)
    XCTAssertTrue(hasNonBlackPixel(in: bytes, width: 400, rowRange: 58..<62, colRange: 198..<202))

    // Verify in-memory JPEG encoding produces valid JPEG magic bytes 0xFF 0xD8 with zero disk writes
    let jpegData = NSMutableData()
    let dest = try XCTUnwrap(
      CGImageDestinationCreateWithData(
        jpegData as CFMutableData,
        "public.jpeg" as CFString,
        1,
        nil
      )
    )
    CGImageDestinationAddImage(dest, rendered, [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(dest))
    let rawData = jpegData as Data
    XCTAssertGreaterThan(rawData.count, 100)
    XCTAssertEqual(rawData[0], 0xFF)
    XCTAssertEqual(rawData[1], 0xD8)
  }

  func testRenderPlainScreenCaptureWithoutSoMLeavesSolidImageUnmodified() throws {
    let base = try XCTUnwrap(makeSolidBlackImage(width: 200, height: 150))
    let rendered = try XCTUnwrap(
      SoMRenderingHelper.render(
        image: base,
        targetWidth: 200,
        targetHeight: 150,
        marks: [],
        annotateGrid: false
      )
    )
    let bytes = try XCTUnwrap(readRgbaBytes(from: rendered))
    XCTAssertFalse(hasNonBlackPixel(in: bytes, width: 200, rowRange: 0..<150, colRange: 0..<200))
  }

  func testParseMarksHandlesObjectiveCNSNumberAndFlutterStandardMethodCodecRoundtrip() throws {
    let cfTrue: Any = kCFBooleanTrue as Any
    let cfFalse: Any = kCFBooleanFalse as Any
    let directCases: [Any] = [
      ["index": NSNumber(value: Int64(1)), "bounds": [NSNumber(value: 0.0), NSNumber(value: 0.2), NSNumber(value: 1.0), NSNumber(value: 0.8)]],
      ["index": NSNumber(value: true), "bounds": [NSNumber(value: 0.1), NSNumber(value: 0.1), NSNumber(value: 0.5), NSNumber(value: 0.5)]],
      ["index": NSNumber(value: false), "bounds": [NSNumber(value: 0.1), NSNumber(value: 0.1), NSNumber(value: 0.5), NSNumber(value: 0.5)]],
      ["index": cfTrue, "bounds": [NSNumber(value: 0.1), NSNumber(value: 0.1), NSNumber(value: 0.5), NSNumber(value: 0.5)]],
      ["index": 2, "bounds": [cfFalse, NSNumber(value: 0.1), NSNumber(value: 0.5), NSNumber(value: 0.5)]],
      ["index": 3, "bounds": [NSNumber(value: 1.0), NSNumber(value: 0.1), NSNumber(value: 0.5), NSNumber(value: 0.5)]],
      ["index": 4, "bounds": [NSNumber(value: 0.1), NSNumber(value: 0.0), NSNumber(value: 0.5), NSNumber(value: 1.0)]],
    ]
    let directParsed = SoMRenderingHelper.parseMarks(directCases)
    XCTAssertEqual(directParsed.map(\.index), [1, 4])
    XCTAssertEqual(directParsed[0].x0, 0.0, accuracy: 0.0001)
    XCTAssertEqual(directParsed[0].x1, 1.0, accuracy: 0.0001)
    XCTAssertEqual(directParsed[1].y0, 0.0, accuracy: 0.0001)
    XCTAssertEqual(directParsed[1].y1, 1.0, accuracy: 0.0001)

    let codec = FlutterStandardMethodCodec.sharedInstance()
    let call = FlutterMethodCall(
      methodName: "captureScreen",
      arguments: [
        "scope": "active_window",
        "maxEdge": 1280,
        "somMarks": [
          ["index": 1, "bounds": [0.2, 0.2, 0.5, 0.4], "role": "button"],
          ["index": 2, "bounds": [0.0, 0.2, 0.5, 0.4]],
          ["index": 3, "bounds": [0.2, 0.2, 1.0, 0.4]],
          ["index": 4, "bounds": [0.2, 0.0, 0.5, 0.4]],
          ["index": 5, "bounds": [0.2, 0.2, 0.5, 1.0]],
          ["index": 6, "bounds": [0.2, 0.2, 0.8, 0.4]],
          ["index": true, "bounds": [0.1, 0.1, 0.4, 0.4]],
          ["index": 7, "bounds": [false, 0.1, 0.4, 0.4]],
        ],
      ]
    )
    let encoded = codec.encode(call)
    let decoded = codec.decodeMethodCall(encoded)
    let decodedArgs = try XCTUnwrap(decoded.arguments as? [String: Any])
    let roundtripMarks = SoMRenderingHelper.parseMarks(decodedArgs["somMarks"])
    XCTAssertEqual(roundtripMarks.map(\.index), [1, 2, 3, 4, 5, 6])
    XCTAssertEqual(roundtripMarks[1].x0, 0.0, accuracy: 0.0001)
    XCTAssertEqual(roundtripMarks[2].x1, 1.0, accuracy: 0.0001)
    XCTAssertEqual(roundtripMarks[3].y0, 0.0, accuracy: 0.0001)
    XCTAssertEqual(roundtripMarks[4].y1, 1.0, accuracy: 0.0001)
    XCTAssertTrue(
      SoMRenderingHelper.shouldAnnotateGrid(
        explicitArg: decodedArgs["annotateGrid"],
        parsedMarks: roundtripMarks
      )
    )
  }

  func testAnnotateGridDefaultsFalseForNSNullOrEmptySomMarks() throws {
    let codec = FlutterStandardMethodCodec.sharedInstance()

    for rawMarks in [NSNull(), []] as [Any] {
      let call = FlutterMethodCall(
        methodName: "captureScreen",
        arguments: ["scope": "active_window", "maxEdge": 1280, "somMarks": rawMarks]
      )
      let decoded = codec.decodeMethodCall(codec.encode(call))
      let args = try XCTUnwrap(decoded.arguments as? [String: Any])
      let parsed = SoMRenderingHelper.parseMarks(args["somMarks"])
      XCTAssertTrue(parsed.isEmpty)
      XCTAssertFalse(
        SoMRenderingHelper.shouldAnnotateGrid(
          explicitArg: args["annotateGrid"],
          parsedMarks: parsed
        )
      )
    }

    XCTAssertTrue(
      SoMRenderingHelper.shouldAnnotateGrid(
        explicitArg: NSNumber(value: true),
        parsedMarks: []
      )
    )
    XCTAssertFalse(
      SoMRenderingHelper.shouldAnnotateGrid(
        explicitArg: NSNumber(value: false),
        parsedMarks: [SoMMark(index: 1, x0: 0.1, y0: 0.1, x1: 0.5, y1: 0.5, role: nil)]
      )
    )
    XCTAssertFalse(
      SoMRenderingHelper.shouldAnnotateGrid(
        explicitArg: NSNumber(value: 1),
        parsedMarks: []
      )
    )
  }

  func testReorderWindowNodesDemotesWindowChromeAndTitlebarControls() {
    let nodes: [[String: Any]] = [
      [
        "refId": "ui_1",
        "role": "AXButton",
        "label": "this button also has an action to zoom the window",
        "editable": false,
        "bounds": ["x": 59, "y": 18, "width": 14, "height": 16],
      ],
      [
        "refId": "ui_2",
        "role": "AXButton",
        "label": "Sidebar Folder",
        "editable": false,
        "bounds": ["x": 20, "y": 100, "width": 120, "height": 24],
      ],
      [
        "refId": "ui_3",
        "role": "AXButton",
        "label": "New Note",
        "editable": false,
        "bounds": ["x": 300, "y": 48, "width": 80, "height": 30],
      ],
      [
        "refId": "ui_4",
        "role": "AXTextField",
        "label": "Search",
        "editable": true,
        "bounds": ["x": 400, "y": 48, "width": 200, "height": 30],
      ],
    ]
    let reordered = XunaHostPlugin.reorderWindowNodes(
      nodes: nodes,
      chromeRefs: ["ui_1"],
      windowWidth: 1000,
      maxNodes: 20,
      elementMap: [:],
      centerMap: [:],
      descriptorMap: [:]
    )
    XCTAssertEqual(reordered.nodes.count, 4)
    // Editable search field first (ui_1), main canvas button second (ui_2), chrome/sidebar last
    XCTAssertEqual(reordered.nodes[0]["label"] as? String, "Search")
    XCTAssertEqual(reordered.nodes[0]["refId"] as? String, "ui_1")
    XCTAssertEqual(reordered.nodes[1]["label"] as? String, "New Note")
    XCTAssertEqual(reordered.nodes[1]["refId"] as? String, "ui_2")
    XCTAssertEqual(reordered.nodes[2]["label"] as? String, "this button also has an action to zoom the window")
    XCTAssertEqual(reordered.nodes[3]["label"] as? String, "Sidebar Folder")
  }

  func testEncodeCompactJpegStaysWithinByteBudget() throws {
    let base = try XCTUnwrap(makeSolidBlackImage(width: 1280, height: 800))
    let encoded = try XCTUnwrap(XunaHostPlugin.encodeCompactJpeg(base, maxBytes: 220_000))
    XCTAssertGreaterThan(encoded.data.count, 100)
    XCTAssertLessThanOrEqual(encoded.data.count, 220_000)
    XCTAssertEqual(encoded.data[0], 0xFF)
    XCTAssertEqual(encoded.data[1], 0xD8)
  }

  func testPresenceParseIdleSecondsRejectsInvalidAndTruncatesValid() {
    XCTAssertNil(XunaHostPlugin.parseIdleSeconds(-0.1))
    XCTAssertNil(XunaHostPlugin.parseIdleSeconds(Double.nan))
    XCTAssertNil(XunaHostPlugin.parseIdleSeconds(Double.infinity))
    XCTAssertNil(XunaHostPlugin.parseIdleSeconds(-Double.infinity))
    XCTAssertNil(XunaHostPlugin.parseIdleSeconds(Double(Int.max)))
    XCTAssertNil(XunaHostPlugin.parseIdleSeconds(Double(Int.max) * 2.0))
    XCTAssertEqual(XunaHostPlugin.parseIdleSeconds(0.0), 0)
    XCTAssertEqual(XunaHostPlugin.parseIdleSeconds(12.9), 12)
  }

  func testPresenceParseScreenLockedHandlesNilAbsentBoolAndOffConsole() {
    XCTAssertNil(XunaHostPlugin.parseScreenLocked(fromSessionDict: nil))
    XCTAssertEqual(XunaHostPlugin.parseScreenLocked(fromSessionDict: [:]), false)
    XCTAssertEqual(
      XunaHostPlugin.parseScreenLocked(fromSessionDict: [
        "CGSSessionScreenIsLocked": false,
        kCGSessionOnConsoleKey as String: true,
      ]),
      false
    )
    XCTAssertEqual(
      XunaHostPlugin.parseScreenLocked(fromSessionDict: ["CGSSessionScreenIsLocked": true]),
      true
    )
    XCTAssertEqual(
      XunaHostPlugin.parseScreenLocked(fromSessionDict: [
        "CGSSessionScreenIsLocked": NSNumber(value: 1),
      ]),
      true
    )
    XCTAssertEqual(
      XunaHostPlugin.parseScreenLocked(fromSessionDict: [
        kCGSessionOnConsoleKey as String: false,
      ]),
      true
    )
  }

  func testPresenceParseInternalBatteryOmitsDesktopAndHandlesFullAcCharge() throws {
    // Desktop Mac (Mac mini / Studio / iMac) with no internal battery -> nil.
    XCTAssertNil(XunaHostPlugin.parseInternalBattery(fromPowerSources: []))
    XCTAssertNil(
      XunaHostPlugin.parseInternalBattery(fromPowerSources: [
        [
          kIOPSTypeKey as String: kIOPSUPSType,
          kIOPSCurrentCapacityKey as String: 100,
          kIOPSMaxCapacityKey as String: 100,
        ],
      ])
    )
    // Absent internal battery flag -> nil.
    XCTAssertNil(
      XunaHostPlugin.parseInternalBattery(fromPowerSources: [
        [
          kIOPSTypeKey as String: kIOPSInternalBatteryType,
          kIOPSIsPresentKey as String: false,
          kIOPSCurrentCapacityKey as String: 50,
          kIOPSMaxCapacityKey as String: 100,
        ],
      ])
    )
    // Zero max capacity -> nil (fail closed).
    XCTAssertNil(
      XunaHostPlugin.parseInternalBattery(fromPowerSources: [
        [
          kIOPSTypeKey as String: kIOPSInternalBatteryType,
          kIOPSIsPresentKey as String: true,
          kIOPSCurrentCapacityKey as String: 50,
          kIOPSMaxCapacityKey as String: 0,
        ],
      ])
    )

    // Discharging laptop battery -> (42, false).
    let discharging = try XCTUnwrap(
      XunaHostPlugin.parseInternalBattery(fromPowerSources: [
        [
          kIOPSTypeKey as String: kIOPSInternalBatteryType,
          kIOPSIsPresentKey as String: true,
          kIOPSCurrentCapacityKey as String: 42,
          kIOPSMaxCapacityKey as String: 100,
          kIOPSIsChargingKey as String: false,
          kIOPSPowerSourceStateKey as String: kIOPSBatteryPowerValue,
        ],
      ])
    )
    XCTAssertEqual(discharging.percent, 42)
    XCTAssertFalse(discharging.isCharging)

    // 100%-charged AC-plugged MacBook reports isCharging == false in IOKit but AC Power state -> (100, true).
    let fullAc = try XCTUnwrap(
      XunaHostPlugin.parseInternalBattery(fromPowerSources: [
        [
          kIOPSTypeKey as String: kIOPSInternalBatteryType,
          kIOPSIsPresentKey as String: true,
          kIOPSCurrentCapacityKey as String: 100,
          kIOPSMaxCapacityKey as String: 100,
          kIOPSIsChargingKey as String: false,
          kIOPSPowerSourceStateKey as String: kIOPSACPowerValue,
        ],
      ])
    )
    XCTAssertEqual(fullAc.percent, 100)
    XCTAssertTrue(fullAc.isCharging)
  }

  func testPresenceNormalizeForegroundAppIdMatchesAutoAppScanner() {
    XCTAssertEqual(
      XunaHostPlugin.normalizeForegroundAppId("Visual Studio Code"),
      "visual_studio_code"
    )
    XCTAssertEqual(
      XunaHostPlugin.normalizeForegroundAppId("Google Chrome.app"),
      "google_chrome"
    )
    XCTAssertEqual(
      XunaHostPlugin.normalizeForegroundAppId("  Code.exe  "),
      "code"
    )
    XCTAssertNil(XunaHostPlugin.normalizeForegroundAppId(nil))
    XCTAssertNil(XunaHostPlugin.normalizeForegroundAppId("   "))
    XCTAssertNil(XunaHostPlugin.normalizeForegroundAppId("!!!"))

    let overlong = String(repeating: "a", count: 80)
    let normalized = XunaHostPlugin.normalizeForegroundAppId(overlong)
    XCTAssertEqual(normalized?.count, 64)
  }

  func testPresenceProbeLiveSmokeCompletesFastWhenWindowServerAvailable() throws {
    try XCTSkipIf(
      CGSessionCopyCurrentDictionary() == nil,
      "WindowServer session dictionary unavailable in headless environment"
    )
    let plugin = XunaHostPlugin()
    // Warm up MediaRemote XPC once outside the steady-state latency assertion.
    _ = XunaHostPlugin.queryMediaPlayingFast()

    let start = CFAbsoluteTimeGetCurrent()
    let res = plugin.buildPresenceProbePayload()
    let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0

    switch res {
    case .success(let payload):
      let idle = try XCTUnwrap(payload["idleSeconds"] as? Int)
      XCTAssertGreaterThanOrEqual(idle, 0)
      XCTAssertTrue(payload["screenLocked"] is Bool)
      XCTAssertTrue(payload["mediaPlaying"] is Bool)
      if let bat = payload["batteryPercent"] as? Int {
        XCTAssertTrue((0...100).contains(bat))
        XCTAssertTrue(payload["isCharging"] is Bool)
      }
      if let fg = payload["foregroundAppId"] as? String {
        XCTAssertFalse(fg.isEmpty)
        XCTAssertLessThanOrEqual(fg.count, 64)
      }
      XCTAssertLessThan(
        elapsedMs,
        50.0,
        "Expected non-blocking presenceProbe; took \(elapsedMs) ms"
      )
    case .failure(let error):
      XCTFail("presenceProbe failed unexpectedly with WindowServer present: \(error.message)")
    }
  }

  func testBuildPresenceProbePayloadAndHardDeniedAppFilter() {
    let plugin = XunaHostPlugin()
    let payloadResult = plugin.buildPresenceProbePayload()
    switch payloadResult {
    case .success(let payload):
      XCTAssertNotNil(payload["idleSeconds"] as? Int)
      XCTAssertNotNil(payload["screenLocked"] as? Bool)
      XCTAssertNotNil(payload["mediaPlaying"] as? Bool)
      if let fg = payload["foregroundAppId"] as? String {
        XCTAssertFalse(XunaHostPlugin.isHardDeniedApp(fg, bundleId: nil))
      }
    case .failure(let error):
      // Headless environments without WindowServer fail closed cleanly without crashing.
      XCTAssertFalse(error.message.isEmpty)
    }
  }

  func testResolveBrowserCandidateSupportsEdgeChromeSafariFrontmostAndAmbiguityRefusal() {
    let allRunning: Set<String> = [
      "com.apple.Safari",
      "com.google.Chrome",
      "com.microsoft.edgemac",
    ]

    // Explicit Edge selection resolves com.microsoft.edgemac.
    switch XunaHostPlugin.resolveBrowserCandidate(
      requested: "edge",
      frontmostBundleId: "com.apple.Safari",
      runningBundleIds: allRunning
    ) {
    case .resolved(let candidate):
      XCTAssertEqual(candidate.id, "edge")
      XCTAssertEqual(candidate.bundleId, "com.microsoft.edgemac")
    case .error(let code, let ec, let msg):
      XCTFail("Expected Edge candidate, got error \(code)/\(ec): \(msg)")
    }

    // Auto mode prefers frontmost running browser (Chrome over Safari/Edge).
    switch XunaHostPlugin.resolveBrowserCandidate(
      requested: "auto",
      frontmostBundleId: "com.google.Chrome",
      runningBundleIds: allRunning
    ) {
    case .resolved(let candidate):
      XCTAssertEqual(candidate.id, "chrome")
    case .error(let code, let ec, let msg):
      XCTFail("Expected frontmost Chrome, got \(code)/\(ec): \(msg)")
    }

    // Auto mode with non-browser frontmost and single running browser (Edge) selects Edge.
    switch XunaHostPlugin.resolveBrowserCandidate(
      requested: "auto",
      frontmostBundleId: "com.microsoft.VSCode",
      runningBundleIds: ["com.microsoft.edgemac"]
    ) {
    case .resolved(let candidate):
      XCTAssertEqual(candidate.id, "edge")
    case .error(let code, let ec, let msg):
      XCTFail("Expected single running Edge, got \(code)/\(ec): \(msg)")
    }

    // Auto mode with multiple running browsers and non-browser frontmost fails closed (browser_ambiguous).
    switch XunaHostPlugin.resolveBrowserCandidate(
      requested: "auto",
      frontmostBundleId: "com.microsoft.VSCode",
      runningBundleIds: ["com.google.Chrome", "com.microsoft.edgemac"]
    ) {
    case .resolved(let candidate):
      XCTFail("Expected browser_ambiguous error, resolved \(candidate.id)")
    case .error(let code, let ec, _):
      XCTAssertEqual(code, "invalid_args")
      XCTAssertEqual(ec, "browser_ambiguous")
    }

    // Unknown browser fails closed.
    switch XunaHostPlugin.resolveBrowserCandidate(
      requested: "firefox",
      frontmostBundleId: nil,
      runningBundleIds: allRunning
    ) {
    case .resolved(let candidate):
      XCTFail("Expected unsupported_browser error, resolved \(candidate.id)")
    case .error(let code, let ec, _):
      XCTAssertEqual(code, "invalid_args")
      XCTAssertEqual(ec, "unsupported_browser")
    }

    // Requested browser not running fails closed.
    switch XunaHostPlugin.resolveBrowserCandidate(
      requested: "safari",
      frontmostBundleId: nil,
      runningBundleIds: ["com.microsoft.edgemac"]
    ) {
    case .resolved(let candidate):
      XCTFail("Expected browser_not_running error, resolved \(candidate.id)")
    case .error(let code, let ec, _):
      XCTAssertEqual(code, "failed")
      XCTAssertEqual(ec, "browser_not_running")
    }
  }

  func testIsValidPublicHttpsTabUrlRejectsUnsafeUrls() {
    XCTAssertTrue(XunaHostPlugin.isValidPublicHttpsTabUrl("https://github.com/xthao28/xuna_pet"))
    XCTAssertTrue(XunaHostPlugin.isValidPublicHttpsTabUrl("HTTPS://docs.example.com/a?b=1"))

    XCTAssertFalse(XunaHostPlugin.isValidPublicHttpsTabUrl("http://github.com/xthao28"))
    XCTAssertFalse(XunaHostPlugin.isValidPublicHttpsTabUrl("file:///etc/passwd"))
    XCTAssertFalse(XunaHostPlugin.isValidPublicHttpsTabUrl("https://user:pass@github.com/"))
    XCTAssertFalse(XunaHostPlugin.isValidPublicHttpsTabUrl("https:///missing-host"))
    XCTAssertFalse(
      XunaHostPlugin.isValidPublicHttpsTabUrl("https://github.com/" + String(repeating: "a", count: 2040))
    )
  }

  func testClipboardReadAndWriteValidationAndPasteboardRoundTrip() {
    // Binary pasteboard (no string, items present) fails closed.
    switch XunaHostPlugin.validateClipboardReadPayload(stringValue: nil, hasPasteboardItems: true) {
    case .valid:
      XCTFail("Expected binary pasteboard rejection")
    case .error(let code, let ec, _):
      XCTAssertEqual(code, "invalid_args")
      XCTAssertEqual(ec, "clipboard_binary")
    }

    // Control byte in clipboard read fails closed.
    switch XunaHostPlugin.validateClipboardReadPayload(
      stringValue: "hello\u{0000}world",
      hasPasteboardItems: true
    ) {
    case .valid:
      XCTFail("Expected NUL byte rejection")
    case .error(let code, let ec, _):
      XCTAssertEqual(code, "invalid_args")
      XCTAssertEqual(ec, "clipboard_binary")
    }

    // Empty pasteboard (no items) yields empty string.
    switch XunaHostPlugin.validateClipboardReadPayload(stringValue: nil, hasPasteboardItems: false) {
    case .valid(let text):
      XCTAssertEqual(text, "")
    case .error:
      XCTFail("Expected empty pasteboard to succeed with empty string")
    }

    // Write validator allows multiline + UTF-8 <= 4000 UTF-16 code units and rejects control bytes / > 4000 / empty.
    switch XunaHostPlugin.validateClipboardWritePayload("line1\n\tline2\r\nTiếng Việt") {
    case .valid(let text):
      XCTAssertTrue(text.contains("Tiếng Việt"))
    case .error:
      XCTFail("Expected valid multiline UTF-8 clipboard write")
    }
    switch XunaHostPlugin.validateClipboardWritePayload(String(repeating: "a", count: 4001)) {
    case .valid:
      XCTFail("Expected > 4000 char write rejection")
    case .error(let code, let ec, _):
      XCTAssertEqual(code, "invalid_args")
      XCTAssertEqual(ec, "schema_mismatch")
    }
    switch XunaHostPlugin.validateClipboardWritePayload(String(repeating: "👨‍👩‍👧‍👦", count: 4000)) {
    case .valid:
      XCTFail("Expected > 4000 UTF-16 code units emoji write rejection")
    case .error(let code, let ec, _):
      XCTAssertEqual(code, "invalid_args")
      XCTAssertEqual(ec, "schema_mismatch")
    }
    switch XunaHostPlugin.validateClipboardReadPayload(
      stringValue: String(repeating: "a", count: 2399) + "😀tail",
      hasPasteboardItems: true
    ) {
    case .valid(let text):
      XCTAssertEqual(text.utf16.count, 2399)
    case .error:
      XCTFail("Expected UTF-16 safe truncation for clipboardReadPayload")
    }
    switch XunaHostPlugin.validateClipboardWritePayload("bad\u{0007}bell") {
    case .valid:
      XCTFail("Expected control byte write rejection")
    case .error(let code, let ec, _):
      XCTAssertEqual(code, "invalid_args")
      XCTAssertEqual(ec, "schema_mismatch")
    }

    // Live NSPasteboard round-trip via plugin handlers.
    let plugin = XunaHostPlugin()
    let prevString = NSPasteboard.general.string(forType: .string)
    defer {
      NSPasteboard.general.clearContents()
      if let prev = prevString {
        _ = NSPasteboard.general.setString(prev, forType: .string)
      }
    }

    let writeExp = expectation(description: "clipboardWriteText")
    let sample = "XUNA Phase 3 Clipboard\nDòng 2"
    plugin.handleClipboardWriteText(args: ["text": sample]) { res in
      if let err = res as? FlutterError {
        XCTFail("clipboardWriteText failed: \(err.code) \(err.message ?? "")")
      } else if let map = res as? [String: Any] {
        XCTAssertEqual(map["written"] as? Bool, true)
      } else {
        XCTFail("Unexpected clipboardWriteText result")
      }
      writeExp.fulfill()
    }
    wait(for: [writeExp], timeout: 2.0)

    let readExp = expectation(description: "clipboardReadText")
    plugin.handleClipboardReadText { res in
      if let map = res as? [String: Any] {
        XCTAssertEqual(map["text"] as? String, sample)
      } else {
        XCTFail("Unexpected clipboardReadText result")
      }
      readExp.fulfill()
    }
    wait(for: [readExp], timeout: 2.0)
  }

  func testHardDeniedAppLaunchBlocked() throws {
    XCTAssertTrue(XunaHostPlugin.isHardDeniedApp("Terminal", bundleId: "com.apple.Terminal"))
    XCTAssertTrue(XunaHostPlugin.isHardDeniedApp("1Password", bundleId: "com.1password.1password"))
    XCTAssertTrue(XunaHostPlugin.isHardDeniedApp("CleanMyMac", bundleId: "com.macpaw.CleanMyMac4"))
    XCTAssertTrue(XunaHostPlugin.isHardDeniedApp("cleanmymac", bundleId: nil))
    XCTAssertTrue(XunaHostPlugin.isHardDeniedApp("System Settings", bundleId: "com.apple.systempreferences"))
    XCTAssertTrue(XunaHostPlugin.isHardDeniedApp("SystemPreferences", bundleId: nil))
    XCTAssertTrue(XunaHostPlugin.isHardDeniedApp("Hyper", bundleId: nil))
    XCTAssertTrue(XunaHostPlugin.isHardDeniedApp("App", bundleId: "co.zeit.hyper"))
    XCTAssertFalse(XunaHostPlugin.isHardDeniedApp("Hyperlink Reader", bundleId: "com.example.reader"))
    XCTAssertFalse(XunaHostPlugin.isHardDeniedApp("Visual Studio Code", bundleId: "com.microsoft.VSCode"))

    let plugin = XunaHostPlugin()
    let exp = expectation(description: "appLaunch hard deny bundle")
    plugin.handleAppLaunch(args: ["kind": "bundle", "target": "com.apple.Terminal"]) { res in
      guard let err = res as? FlutterError else {
        XCTFail("Expected FlutterError for hard-denied app launch")
        exp.fulfill()
        return
      }
      XCTAssertEqual(err.code, "denied")
      let details = err.details as? [String: Any]
      XCTAssertEqual(details?["errorCode"] as? String, "denylisted_target_forbidden")
      exp.fulfill()
    }
    wait(for: [exp], timeout: 2.0)

    let terminalExe = "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"
    let exeExp = expectation(description: "appLaunch hard deny exe")
    plugin.handleAppLaunch(args: ["kind": "exe", "target": terminalExe]) { res in
      guard let err = res as? FlutterError else {
        XCTFail("Expected FlutterError for hard-denied terminal binary exe launch")
        exeExp.fulfill()
        return
      }
      XCTAssertEqual(err.code, "denied")
      let details = err.details as? [String: Any]
      XCTAssertEqual(details?["errorCode"] as? String, "denylisted_target_forbidden")
      exeExp.fulfill()
    }
    wait(for: [exeExp], timeout: 2.0)

    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("xuna_deny_sym_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }
    let symBin = tmpDir.appendingPathComponent("InnocentHelper")
    try FileManager.default.createSymbolicLink(atPath: symBin.path, withDestinationPath: terminalExe)

    let symExp = expectation(description: "appLaunch hard deny symlink exe")
    plugin.handleAppLaunch(args: ["kind": "exe", "target": symBin.path]) { res in
      guard let err = res as? FlutterError else {
        XCTFail("Expected FlutterError for symlinked terminal binary launch")
        symExp.fulfill()
        return
      }
      XCTAssertEqual(err.code, "denied")
      let details = err.details as? [String: Any]
      XCTAssertEqual(details?["errorCode"] as? String, "denylisted_target_forbidden")
      symExp.fulfill()
    }
    wait(for: [symExp], timeout: 2.0)
  }

  func testUnstandardizedPathsTerminateAndBundleModeRejectsShellBinaries() throws {
    // 1. Unstandardized paths (//, /./, /../, $TMPDIR with //) must terminate immediately.
    let start = CFAbsoluteTimeGetCurrent()
    XCTAssertFalse(
      XunaHostPlugin.isHardDeniedResolvedTarget(
        url: URL(fileURLWithPath: "/Applications//Safari.app"),
        kind: "bundle"
      )
    )
    XCTAssertFalse(
      XunaHostPlugin.isHardDeniedResolvedTarget(
        url: URL(fileURLWithPath: "/Applications/./Safari.app"),
        kind: "bundle"
      )
    )
    XCTAssertFalse(
      XunaHostPlugin.isHardDeniedResolvedTarget(
        url: URL(fileURLWithPath: "/tmp/../Applications/Safari.app"),
        kind: "bundle"
      )
    )
    XCTAssertTrue(
      XunaHostPlugin.isHardDeniedResolvedTarget(
        url: URL(fileURLWithPath: "/System/Applications/Utilities//Terminal.app"),
        kind: "bundle"
      )
    )
    XCTAssertTrue(
      XunaHostPlugin.isHardDeniedResolvedTarget(
        url: URL(fileURLWithPath: "/System/Applications/Utilities/./Terminal.app/Contents/MacOS/Terminal"),
        kind: "exe"
      )
    )

    let tmpDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("xuna_unstd_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let terminalExe = "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"
    let symTerm = tmpDir.appendingPathComponent("TermViaSlash")
    try FileManager.default.createSymbolicLink(atPath: symTerm.path, withDestinationPath: terminalExe)

    let benignFile = tmpDir.appendingPathComponent("BenignTool")
    FileManager.default.createFile(atPath: benignFile.path, contents: Data("ok".utf8))

    let doubleSlashTermUrl = URL(fileURLWithPath: "\(tmpDir.path)//TermViaSlash")
    let doubleSlashBenignUrl = URL(fileURLWithPath: "\(tmpDir.path)//BenignTool")
    XCTAssertTrue(XunaHostPlugin.isHardDeniedResolvedTarget(url: doubleSlashTermUrl, kind: "exe"))
    XCTAssertFalse(XunaHostPlugin.isHardDeniedResolvedTarget(url: doubleSlashBenignUrl, kind: "exe"))

    let elapsed = CFAbsoluteTimeGetCurrent() - start
    XCTAssertLessThan(elapsed, 0.5, "Unstandardized ancestor walk took too long: \(elapsed)s")

    // 2. kind == "bundle" must block bare shell/terminal binaries and symlinks to them.
    let symZsh = tmpDir.appendingPathComponent("InnocentBundle")
    try FileManager.default.createSymbolicLink(atPath: symZsh.path, withDestinationPath: "/bin/zsh")

    XCTAssertTrue(
      XunaHostPlugin.isHardDeniedResolvedTarget(
        url: URL(fileURLWithPath: "/bin/zsh"),
        kind: "bundle"
      )
    )
    XCTAssertTrue(
      XunaHostPlugin.isHardDeniedResolvedTarget(
        url: symZsh,
        kind: "bundle"
      )
    )

    let plugin = XunaHostPlugin()
    for (label, target) in [("direct zsh", "/bin/zsh"), ("symlink zsh", symZsh.path)] {
      let exp = expectation(description: "bundle denies \(label)")
      plugin.handleAppLaunch(args: ["kind": "bundle", "target": target]) { res in
        guard let err = res as? FlutterError else {
          XCTFail("Expected FlutterError when launching \(label) as kind=bundle")
          exp.fulfill()
          return
        }
        XCTAssertEqual(err.code, "denied")
        let details = err.details as? [String: Any]
        XCTAssertEqual(details?["errorCode"] as? String, "denylisted_target_forbidden")
        exp.fulfill()
      }
      wait(for: [exp], timeout: 2.0)
    }

    // Non-.app binary must also be rejected when kind == "bundle".
    let nonAppBin = tmpDir.appendingPathComponent("plain_binary")
    FileManager.default.createFile(atPath: nonAppBin.path, contents: Data("bin".utf8))
    let nonAppExp = expectation(description: "bundle rejects non-.app binary")
    plugin.handleAppLaunch(args: ["kind": "bundle", "target": nonAppBin.path]) { res in
      guard let err = res as? FlutterError else {
        XCTFail("Expected FlutterError when launching non-.app binary as kind=bundle")
        nonAppExp.fulfill()
        return
      }
      XCTAssertEqual(err.code, "invalid_args")
      let details = err.details as? [String: Any]
      XCTAssertEqual(details?["errorCode"] as? String, "invalid_bundle_target")
      nonAppExp.fulfill()
    }
    wait(for: [nonAppExp], timeout: 2.0)
  }

  func testMediaPlayPauseResultStateCompliesWithSchemaEnum() {
    let allowed: Set<String> = ["playing", "paused", "unknown"]
    for raw in [nil, "", "toggled", "playing", "paused", "stopped", "unexpected"] {
      let normalized = XunaHostPlugin.normalizeMediaResultState(cmd: "play_pause", reportedState: raw)
      XCTAssertTrue(allowed.contains(normalized), "Invalid state: \(normalized)")
      XCTAssertNotEqual(normalized, "toggled")
    }
    XCTAssertEqual(
      XunaHostPlugin.normalizeMediaResultState(cmd: "play_pause", reportedState: "paused"),
      "paused"
    )
    XCTAssertEqual(
      XunaHostPlugin.normalizeMediaResultState(cmd: "play_pause", reportedState: nil),
      "unknown"
    )

    let plugin = XunaHostPlugin()
    let exp = expectation(description: "media unsupported fails closed")
    plugin.handleMedia(args: ["cmd": "rewind_invalid"]) { res in
      guard let err = res as? FlutterError else {
        XCTFail("Expected FlutterError for unsupported media command")
        exp.fulfill()
        return
      }
      XCTAssertEqual(err.code, "unsupported")
      let details = err.details as? [String: Any]
      XCTAssertEqual(details?["errorCode"] as? String, "platform_unsupported")
      exp.fulfill()
    }
    wait(for: [exp], timeout: 2.0)
  }

  func testMatchRunningAppCandidatePreventsShortTokenBundleFalsePositives() {
    let candidates: [XunaHostPlugin.RunningAppMatchCandidate] = [
      XunaHostPlugin.RunningAppMatchCandidate(
        pid: 101,
        localizedName: "Antigravity IDE",
        bundleId: "com.google.antigravity-ide",
        bundleStem: "Antigravity IDE",
        windowTitles: [
          "xuna_pet — mvp_devops_catalog.dart",
          "physical-ai-venture — index.html — Untracked",
        ]
      ),
      XunaHostPlugin.RunningAppMatchCandidate(
        pid: 202,
        localizedName: "PyCharm",
        bundleId: "com.jetbrains.pycharm",
        bundleStem: "PyCharm",
        windowTitles: ["Welcome to PyCharm"]
      ),
      XunaHostPlugin.RunningAppMatchCandidate(
        pid: 303,
        localizedName: "Finder",
        bundleId: "com.apple.finder",
        bundleStem: "Finder",
        windowTitles: ["Projects"]
      ),
    ]

    // Raw workspace window title matches the live Antigravity IDE window, not PyCharm.
    XCTAssertEqual(
      XunaHostPlugin.matchRunningAppCandidate(
        query: "physical-ai-venture — index.html — Untracked",
        candidates: candidates
      ),
      101
    )

    // Without Antigravity IDE running, `"ai"` inside `"physical-ai-venture"` must NEVER
    // false-match `"com.jetbrains.pycharm"`.
    let withoutIde = candidates.filter { $0.pid != 101 }
    XCTAssertNil(
      XunaHostPlugin.matchRunningAppCandidate(
        query: "physical-ai-venture — index.html — Untracked",
        candidates: withoutIde
      )
    )

    // Explicit app name & prefixed window title still resolve deterministically.
    XCTAssertEqual(
      XunaHostPlugin.matchRunningAppCandidate(
        query: "Antigravity IDE — physical-ai-venture",
        candidates: candidates
      ),
      101
    )
    XCTAssertEqual(
      XunaHostPlugin.matchRunningAppCandidate(
        query: "PyCharm",
        candidates: candidates
      ),
      202
    )
  }

}
