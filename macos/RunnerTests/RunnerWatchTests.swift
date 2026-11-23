import ApplicationServices
import Cocoa
import Darwin
import FlutterMacOS
import XCTest
@testable import xuna_desktop

class RunnerWatchTests: XCTestCase {

  func testAxStructuralDigestDeterministicAndContentFree() {
    let base = [
      (depth: 0, role: "AXWindow", labelLen: 12, valueLen: 0, childCount: 2),
      (depth: 1, role: "AXTextField", labelLen: 5, valueLen: 18, childCount: 0),
      (depth: 1, role: "AXButton", labelLen: 6, valueLen: 0, childCount: 0),
    ]
    let d1 = XunaHostPlugin.computeAxDigestHex(tuples: base)
    let d2 = XunaHostPlugin.computeAxDigestHex(tuples: base)
    XCTAssertEqual(d1.count, 64)
    XCTAssertEqual(d1, d2)

    // Same lengths with completely different string contents yield identical hash (content-free).
    let textA = "SecretPassword1234"
    let textB = "PublicButtonText99"
    XCTAssertEqual(textA.utf8.count, textB.utf8.count)
    let dTextA = XunaHostPlugin.computeAxDigestHex(tuples: [
      (depth: 0, role: "AXTextField", labelLen: 4, valueLen: textA.utf8.count, childCount: 0),
    ])
    let dTextB = XunaHostPlugin.computeAxDigestHex(tuples: [
      (depth: 0, role: "AXTextField", labelLen: 4, valueLen: textB.utf8.count, childCount: 0),
    ])
    XCTAssertEqual(dTextA, dTextB)

    // Structural change (valueLen or childCount) changes the digest.
    let changed = [
      (depth: 0, role: "AXWindow", labelLen: 12, valueLen: 0, childCount: 2),
      (depth: 1, role: "AXTextField", labelLen: 5, valueLen: 24, childCount: 0),
      (depth: 1, role: "AXButton", labelLen: 6, valueLen: 0, childCount: 0),
    ]
    let d3 = XunaHostPlugin.computeAxDigestHex(tuples: changed)
    XCTAssertNotEqual(d1, d3)
  }

  func testWatchStartUiFailClosedWhenTargetMissingOrHardDenied() {
    let plugin = XunaHostPlugin()
    defer { plugin.stopAllWatchEntries() }

    let trusted = AXIsProcessTrusted()

    let missingExp = expectation(description: "ui_quiescence fails closed when target missing")
    plugin.handleWatchStart(args: [
      "watchId": "w-ui-missing",
      "signal": "ui_quiescence",
      "releaseFocus": true,
    ]) { res in
      guard let err = res as? FlutterError else {
        XCTFail("Expected FlutterError when target missing")
        missingExp.fulfill()
        return
      }
      let details = err.details as? [String: Any]
      let ec = details?["errorCode"] as? String
      if trusted {
        XCTAssertEqual(ec, "target_not_found")
      } else {
        XCTAssertEqual(err.code, "needs_permission")
        XCTAssertEqual(ec, "needs_permission")
      }
      missingExp.fulfill()
    }
    wait(for: [missingExp], timeout: 2.0)

    let deniedExp = expectation(description: "ui_change rejects hard-denied appId")
    plugin.handleWatchStart(args: [
      "watchId": "w-ui-denied",
      "signal": "ui_change",
      "appId": "com.apple.Terminal",
      "releaseFocus": true,
    ]) { res in
      guard let err = res as? FlutterError else {
        XCTFail("Expected FlutterError for hard-denied Terminal")
        deniedExp.fulfill()
        return
      }
      let details = err.details as? [String: Any]
      let ec = details?["errorCode"] as? String
      if trusted {
        XCTAssertEqual(err.code, "denied")
        XCTAssertEqual(ec, "policy_blocked")
      } else {
        XCTAssertEqual(err.code, "needs_permission")
        XCTAssertEqual(ec, "needs_permission")
      }
      deniedExp.fulfill()
    }
    wait(for: [deniedExp], timeout: 2.0)
  }

  func testProcessIdleSamplerDetectsRealProcessTreeAndTargetLost() throws {
    let plugin = XunaHostPlugin()
    defer { plugin.stopAllWatchEntries() }

    // 1. Non-existent PID fails closed with target_not_found.
    let missingPidExp = expectation(description: "missing pid fails closed")
    plugin.handleWatchStart(args: [
      "watchId": "w-proc-missing",
      "signal": "process_idle",
      "pid": 999_999,
      "releaseFocus": true,
    ]) { res in
      guard let err = res as? FlutterError else {
        XCTFail("Expected FlutterError for non-existent pid")
        missingPidExp.fulfill()
        return
      }
      let details = err.details as? [String: Any]
      XCTAssertEqual(details?["errorCode"] as? String, "target_not_found")
      missingPidExp.fulfill()
    }
    wait(for: [missingPidExp], timeout: 2.0)

    // 2. Hard-denied shell binary (/bin/sh) fails closed with policy_blocked.
    let deniedProc = Process()
    deniedProc.executableURL = URL(fileURLWithPath: "/bin/sh")
    deniedProc.arguments = ["-c", "sleep 2"]
    try deniedProc.run()
    defer {
      if deniedProc.isRunning { deniedProc.terminate() }
      deniedProc.waitUntilExit()
    }

    let deniedExp = expectation(description: "hard-denied shell pid blocked")
    plugin.handleWatchStart(args: [
      "watchId": "w-proc-denied",
      "signal": "process_idle",
      "pid": Int(deniedProc.processIdentifier),
      "releaseFocus": true,
    ]) { res in
      guard let err = res as? FlutterError else {
        XCTFail("Expected FlutterError for /bin/sh process")
        deniedExp.fulfill()
        return
      }
      XCTAssertEqual(err.code, "denied")
      let details = err.details as? [String: Any]
      XCTAssertEqual(details?["errorCode"] as? String, "policy_blocked")
      deniedExp.fulfill()
    }
    wait(for: [deniedExp], timeout: 2.0)

    // 3. Real benign process (/bin/sleep) starts, is tracked via libproc, and reports lost on exit.
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/sleep")
    proc.arguments = ["0.5"]
    try proc.run()
    let pid = Int(proc.processIdentifier)

    // Also verify libproc child discovery sees our spawned process as a child of the test host.
    let tree = XunaHostPlugin.collectProcessTree(rootPid: getpid())
    XCTAssertTrue(tree.contains(pid_t(pid)), "Expected libproc to find child pid \(pid)")

    let startExp = expectation(description: "process_idle start succeeds")
    plugin.handleWatchStart(args: [
      "watchId": "w-proc-live",
      "signal": "process_idle",
      "pid": pid,
      "releaseFocus": true,
    ]) { res in
      guard let map = res as? [String: Any] else {
        XCTFail("Expected success map, got \(String(describing: res))")
        startExp.fulfill()
        return
      }
      XCTAssertEqual(map["accepted"] as? Bool, true)
      XCTAssertEqual(map["watchId"] as? String, "w-proc-live")
      XCTAssertEqual(map["signal"] as? String, "process_idle")
      startExp.fulfill()
    }
    wait(for: [startExp], timeout: 2.0)

    proc.waitUntilExit()

    let pollLostExp = expectation(description: "process_idle reports lost immediately after exit")
    plugin.handleWatchPoll(args: [
      "watchId": "w-proc-live",
      "signal": "process_idle",
    ]) { res in
      guard let map = res as? [String: Any] else {
        XCTFail("Expected poll map")
        pollLostExp.fulfill()
        return
      }
      XCTAssertEqual(map["state"] as? String, "lost")
      pollLostExp.fulfill()
    }
    wait(for: [pollLostExp], timeout: 2.0)
  }

  func testProcessCpuThresholdAndHysteresisLogic() {
    XCTAssertEqual(
      XunaHostPlugin.evaluateProcessIdleState(cpuPercent: 1.5, hasBusyChild: false, wasBusy: false),
      "idle"
    )
    XCTAssertEqual(
      XunaHostPlugin.evaluateProcessIdleState(cpuPercent: 1.5, hasBusyChild: false, wasBusy: true),
      "idle"
    )
    XCTAssertEqual(
      XunaHostPlugin.evaluateProcessIdleState(cpuPercent: 12.0, hasBusyChild: false, wasBusy: false),
      "active"
    )
    XCTAssertEqual(
      XunaHostPlugin.evaluateProcessIdleState(cpuPercent: 0.5, hasBusyChild: true, wasBusy: false),
      "active"
    )
    // Hysteresis between 3.0% and 8.0% retains previous state.
    XCTAssertEqual(
      XunaHostPlugin.evaluateProcessIdleState(cpuPercent: 5.0, hasBusyChild: false, wasBusy: true),
      "active"
    )
    XCTAssertEqual(
      XunaHostPlugin.evaluateProcessIdleState(cpuPercent: 5.0, hasBusyChild: false, wasBusy: false),
      "idle"
    )
  }

  func testFsWorkspaceValidationRejectsOutsideHomeAndSensitivePaths() throws {
    let fm = FileManager.default
    let tmpBase = fm.temporaryDirectory.appendingPathComponent("xuna_watch_home_\(UUID().uuidString)")
    try fm.createDirectory(at: tmpBase, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmpBase) }

    let validProj = tmpBase.appendingPathComponent("my_project")
    try fm.createDirectory(at: validProj, withIntermediateDirectories: true)

    let sensitiveDirs = [
      tmpBase.appendingPathComponent(".ssh"),
      tmpBase.appendingPathComponent(".aws"),
      tmpBase.appendingPathComponent(".gnupg"),
      tmpBase.appendingPathComponent(".kube"),
      tmpBase.appendingPathComponent("Library"),
      tmpBase.appendingPathComponent("proj/.env.local"),
      tmpBase.appendingPathComponent("proj/.git/objects"),
    ]
    for dir in sensitiveDirs {
      try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    let escapingSymlink = tmpBase.appendingPathComponent("escape_link")
    try fm.createSymbolicLink(atPath: escapingSymlink.path, withDestinationPath: "/tmp")

    let blockedPaths = [
      "/etc",
      "/tmp",
      tmpBase.path,
      escapingSymlink.path,
    ] + sensitiveDirs.map { $0.path }

    for path in blockedPaths {
      switch XunaHostPlugin.validateWatchWorkspacePath(path, homeRoot: tmpBase.path) {
      case .success(let resolved):
        XCTFail("Expected policy_blocked for \(path), got \(resolved)")
      case .failure(let err):
        XCTAssertEqual(err.errorCode, "policy_blocked", "Path \(path) should be policy_blocked")
      }
    }

    let missingProj = tmpBase.appendingPathComponent("does_not_exist").path
    switch XunaHostPlugin.validateWatchWorkspacePath(missingProj, homeRoot: tmpBase.path) {
    case .success:
      XCTFail("Expected workspace_not_found for missing directory")
    case .failure(let err):
      XCTAssertEqual(err.errorCode, "workspace_not_found")
    }

    switch XunaHostPlugin.validateWatchWorkspacePath(validProj.path, homeRoot: tmpBase.path) {
    case .success(let resolved):
      XCTAssertTrue(resolved.hasSuffix("/my_project"))
    case .failure(let err):
      XCTFail("Expected success for valid workspace, got \(err.errorCode)")
    }
  }

  func testFsQuiescenceFSEventsDetectsFileWriteAndExcludesGitObjects() throws {
    let fm = FileManager.default
    let tmpBase = fm.temporaryDirectory.appendingPathComponent("xuna_fs_watch_\(UUID().uuidString)")
    let projDir = tmpBase.appendingPathComponent("repo")
    let gitObjectsDir = projDir.appendingPathComponent(".git/objects/ab")
    try fm.createDirectory(at: gitObjectsDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmpBase) }
    // Allow fseventsd to flush directory creation events before starting the stream.
    Thread.sleep(forTimeInterval: 0.35)

    XCTAssertTrue(XunaHostPlugin.shouldIgnoreFsEventPath(gitObjectsDir.appendingPathComponent("1234").path))
    XCTAssertTrue(XunaHostPlugin.shouldIgnoreFsEventPath(projDir.appendingPathComponent(".DS_Store").path))
    XCTAssertTrue(XunaHostPlugin.shouldIgnoreFsEventPath(projDir.appendingPathComponent(".env.local").path))
    XCTAssertFalse(XunaHostPlugin.shouldIgnoreFsEventPath(projDir.appendingPathComponent("main.dart").path))

    let plugin = XunaHostPlugin()
    plugin.watchHomeRootOverride = tmpBase.path
    defer { plugin.stopAllWatchEntries() }

    let startExp = expectation(description: "fs_quiescence starts cleanly")
    plugin.handleWatchStart(args: [
      "watchId": "w-fs-1",
      "signal": "fs_quiescence",
      "workspacePath": projDir.path,
      "releaseFocus": true,
    ]) { res in
      guard let map = res as? [String: Any] else {
        XCTFail("Expected success map for fs_quiescence, got \(String(describing: res))")
        startExp.fulfill()
        return
      }
      XCTAssertEqual(map["accepted"] as? Bool, true)
      XCTAssertEqual(map["eventDriven"] as? Bool, true)
      XCTAssertEqual(map["fallbackUsed"] as? Bool, false)
      startExp.fulfill()
    }
    wait(for: [startExp], timeout: 2.0)

    // Record baseline count (ignoring any pre-start coalesced directory flush),
    // then write only into .git/objects and verify changeCount does not advance.
    var baselineCount = -1
    let baseExp = expectation(description: "baseline poll")
    plugin.handleWatchPoll(args: [
      "watchId": "w-fs-1",
      "signal": "fs_quiescence",
    ]) { res in
      let map = res as? [String: Any]
      baselineCount = map?["changeCount"] as? Int ?? -1
      baseExp.fulfill()
    }
    wait(for: [baseExp], timeout: 2.0)
    XCTAssertGreaterThanOrEqual(baselineCount, 0)

    let gitObjFile = gitObjectsDir.appendingPathComponent("cdef")
    try Data("obj".utf8).write(to: gitObjFile)
    Thread.sleep(forTimeInterval: 0.45)

    var countAfterGitObj = -1
    let poll1Exp = expectation(description: "poll after .git/objects write")
    plugin.handleWatchPoll(args: [
      "watchId": "w-fs-1",
      "signal": "fs_quiescence",
    ]) { res in
      let map = res as? [String: Any]
      countAfterGitObj = map?["changeCount"] as? Int ?? -1
      poll1Exp.fulfill()
    }
    wait(for: [poll1Exp], timeout: 2.0)
    XCTAssertEqual(countAfterGitObj, baselineCount)

    // Write a real source file and verify FSEvents increments changeCount strictly above baseline.
    let realFile = projDir.appendingPathComponent("hello.txt")
    var observedChangeCount = countAfterGitObj
    for attempt in 0..<8 {
      if attempt == 0 {
        try Data("hello \(attempt)".utf8).write(to: realFile)
      }
      Thread.sleep(forTimeInterval: 0.35)
      let pollExp = expectation(description: "poll after real write \(attempt)")
      plugin.handleWatchPoll(args: [
        "watchId": "w-fs-1",
        "signal": "fs_quiescence",
      ]) { res in
        if let map = res as? [String: Any], let cnt = map["changeCount"] as? Int {
          observedChangeCount = cnt
        }
        pollExp.fulfill()
      }
      wait(for: [pollExp], timeout: 2.0)
      if observedChangeCount > countAfterGitObj {
        break
      }
    }
    XCTAssertGreaterThan(observedChangeCount, countAfterGitObj)

    let stopExp = expectation(description: "watchStop cleans up fs_quiescence")
    plugin.handleWatchStop(args: [
      "watchId": "w-fs-1",
    ]) { res in
      guard let map = res as? [String: Any] else {
        XCTFail("Expected stop map")
        stopExp.fulfill()
        return
      }
      XCTAssertEqual(map["stopped"] as? Bool, true)
      XCTAssertEqual(map["cancelledCount"] as? Int, 1)
      stopExp.fulfill()
    }
    wait(for: [stopExp], timeout: 2.0)
  }

  func testWatchLimitEnforcedAndStopAllClearsAll() throws {
    let plugin = XunaHostPlugin()
    defer { plugin.stopAllWatchEntries() }

    let fm = FileManager.default
    let tmpBase = fm.temporaryDirectory.appendingPathComponent("xuna_limit_\(UUID().uuidString)")
    try fm.createDirectory(at: tmpBase, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmpBase) }
    plugin.watchHomeRootOverride = tmpBase.path

    var projDirs: [URL] = []
    for i in 0..<13 {
      let dir = tmpBase.appendingPathComponent("proj_\(i)")
      try fm.createDirectory(at: dir, withIntermediateDirectories: true)
      projDirs.append(dir)
    }

    // Start 12 entries (e.g., 4 composite watchIds x 3 or 12 keys).
    for i in 0..<XunaHostPlugin.maxNativeWatchEntries {
      let watchId = "w-cap-\(i / 2)"
      let signal = "fs_quiescence"
      // Use distinct watchId per entry since fs_quiescence is 1 signal, or reuse watchId with distinct keys
      let uniqueWatchId = i < 2 ? "w-shared" : "w-cap-\(i)"
      let startExp = expectation(description: "start cap \(i)")
      plugin.handleWatchStart(args: [
        "watchId": uniqueWatchId,
        "signal": i == 1 ? "process_idle" : signal,
        "pid": i == 1 ? Int(getpid()) : nil,
        "workspacePath": i == 1 ? nil : projDirs[i].path,
        "releaseFocus": true,
      ].compactMapValues { $0 }) { res in
        guard let map = res as? [String: Any] else {
          XCTFail("Expected start success for \(i): \(String(describing: res))")
          startExp.fulfill()
          return
        }
        XCTAssertEqual(map["accepted"] as? Bool, true)
        startExp.fulfill()
      }
      wait(for: [startExp], timeout: 2.0)
      _ = watchId
    }

    // 13th distinct key fails closed with watch_limit_reached.
    let overLimitExp = expectation(description: "13th watch fails closed")
    plugin.handleWatchStart(args: [
      "watchId": "w-over-limit",
      "signal": "fs_quiescence",
      "workspacePath": projDirs[12].path,
      "releaseFocus": true,
    ]) { res in
      guard let err = res as? FlutterError else {
        XCTFail("Expected FlutterError when over native watch limit")
        overLimitExp.fulfill()
        return
      }
      let details = err.details as? [String: Any]
      XCTAssertEqual(details?["errorCode"] as? String, "watch_limit_reached")
      overLimitExp.fulfill()
    }
    wait(for: [overLimitExp], timeout: 2.0)

    // Stopping w-shared with signal == nil stops both signals (fs_quiescence + process_idle).
    let stopSharedExp = expectation(description: "stop w-shared cancels both signals")
    plugin.handleWatchStop(args: ["watchId": "w-shared"]) { res in
      guard let map = res as? [String: Any] else {
        XCTFail("Expected stop map")
        stopSharedExp.fulfill()
        return
      }
      XCTAssertEqual(map["stopped"] as? Bool, true)
      XCTAssertEqual(map["cancelledCount"] as? Int, 2)
      stopSharedExp.fulfill()
    }
    wait(for: [stopSharedExp], timeout: 2.0)

    // Now a new watch succeeds.
    let retryExp = expectation(description: "slot freed after watchStop")
    plugin.handleWatchStart(args: [
      "watchId": "w-after-free",
      "signal": "fs_quiescence",
      "workspacePath": projDirs[12].path,
      "releaseFocus": true,
    ]) { res in
      guard let map = res as? [String: Any] else {
        XCTFail("Expected success after slot freed")
        retryExp.fulfill()
        return
      }
      XCTAssertEqual(map["accepted"] as? Bool, true)
      retryExp.fulfill()
    }
    wait(for: [retryExp], timeout: 2.0)

    // Fill the remaining 12th slot (w-shared stopped 2 entries, w-after-free used 1),
    // then verify insertActiveWatchEntry rejection + stop() never touches a suspended DispatchSourceTimer,
    // and stopAllWatchEntries() on Main Thread while watchQueue dispatches onMainThread does not deadlock.
    let fill12 = NativeWatchEntry(
      watchId: "w-fill-12",
      signal: "process_idle",
      eventDriven: false,
      fallbackUsed: false,
      plugin: plugin
    )
    XCTAssertTrue(plugin.insertActiveWatchEntry(fill12))

    let extraEntry = NativeWatchEntry(
      watchId: "w-extra-overflow",
      signal: "process_idle",
      eventDriven: false,
      fallbackUsed: false,
      plugin: plugin
    )
    XCTAssertFalse(plugin.insertActiveWatchEntry(extraEntry))
    extraEntry.stop()

    let mainSyncExp = expectation(description: "watchQueue onMainThread completes without deadlock")
    plugin.watchQueue.async {
      _ = plugin.onMainThread {
        Thread.isMainThread
      }
      mainSyncExp.fulfill()
    }
    plugin.stopAllWatchEntries()
    wait(for: [mainSyncExp], timeout: 2.0)
  }
}
