import Cocoa
import CoreText
import FlutterMacOS
import ImageIO
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

}
