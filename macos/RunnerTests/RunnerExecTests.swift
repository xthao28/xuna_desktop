import Darwin
import FlutterMacOS
import XCTest
@testable import xuna_desktop

/// Real-process tests for `XunaExecProcess` (`ADR-0018`, Wave 3 W3-M3):
/// process-group kill leaves 0 survivors, the environment is exactly what was
/// passed, PTY mode gives a terminal, and exit codes propagate.
class RunnerExecTests: XCTestCase {
  private let baseEnv = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory()]

  private func drain(_ process: XunaExecProcess, until deadline: Date, stopWhen: (String, [String: Any]) -> Bool) -> (String, [String: Any]) {
    var text = ""
    var last: [String: Any] = [:]
    while Date() < deadline {
      last = process.poll()
      if let typed = last["data"] as? FlutterStandardTypedData {
        text += String(decoding: typed.data, as: UTF8.self)
      }
      if stopWhen(text, last) { break }
      usleep(50_000)
    }
    return (text, last)
  }

  private func isAlive(_ pid: pid_t) -> Bool {
    return kill(pid, 0) == 0 || errno == EPERM
  }

  func testExitCodeAndOutputPropagate() throws {
    let process = try XunaExecProcess.spawn(
      command: "echo hello; exit 3",
      cwd: NSTemporaryDirectory(),
      environment: baseEnv,
      pty: false
    )
    defer { process.release() }
    let (text, last) = drain(process, until: Date().addingTimeInterval(10)) { _, p in
      (p["exited"] as? Bool) == true && (p["outputClosed"] as? Bool) == true
    }
    XCTAssertTrue(text.contains("hello"))
    XCTAssertEqual(last["exitCode"] as? Int, 3)
  }

  func testEnvironmentIsNotInherited() throws {
    setenv("GEMINI_API_KEY", "should-not-leak", 1)
    defer { unsetenv("GEMINI_API_KEY") }
    let process = try XunaExecProcess.spawn(
      command: "printf '[%s]' \"$GEMINI_API_KEY\"",
      cwd: NSTemporaryDirectory(),
      environment: baseEnv,
      pty: false
    )
    defer { process.release() }
    let (text, _) = drain(process, until: Date().addingTimeInterval(10)) { _, p in
      (p["exited"] as? Bool) == true && (p["outputClosed"] as? Bool) == true
    }
    XCTAssertEqual(text, "[]")
  }

  func testCwdIsApplied() throws {
    // `pwd -P` prints the physical path (`/private/var/...`); Darwin `realpath`
    // keeps that prefix, unlike `NSString.resolvingSymlinksInPath`.
    guard let resolved = realpath(NSTemporaryDirectory(), nil) else {
      return XCTFail("realpath failed")
    }
    let dir = String(cString: resolved)
    free(resolved)
    let process = try XunaExecProcess.spawn(
      command: "pwd -P",
      cwd: dir,
      environment: baseEnv,
      pty: false
    )
    defer { process.release() }
    let (text, _) = drain(process, until: Date().addingTimeInterval(10)) { _, p in
      (p["exited"] as? Bool) == true && (p["outputClosed"] as? Bool) == true
    }
    XCTAssertEqual(text.trimmingCharacters(in: .whitespacesAndNewlines), dir)
  }

  func testPtyModeProvidesATerminal() throws {
    let process = try XunaExecProcess.spawn(
      command: "if test -t 1; then echo is_tty; else echo no_tty; fi",
      cwd: NSTemporaryDirectory(),
      environment: baseEnv,
      pty: true
    )
    defer { process.release() }
    let (text, _) = drain(process, until: Date().addingTimeInterval(10)) { t, p in
      t.contains("tty") && (p["exited"] as? Bool) == true
    }
    XCTAssertTrue(text.contains("is_tty"), "output: \(text)")
  }

  func testProcessGroupKillLeavesNoSurvivors() throws {
    let process = try XunaExecProcess.spawn(
      command: "sleep 60 & echo child=$!; wait",
      cwd: NSTemporaryDirectory(),
      environment: baseEnv,
      pty: false
    )
    defer { process.release() }
    let (text, _) = drain(process, until: Date().addingTimeInterval(10)) { t, _ in
      t.contains("child=") && t.contains("\n")
    }
    guard let range = text.range(of: "child="),
          let childPid = pid_t(text[range.upperBound...].prefix { $0.isNumber })
    else {
      return XCTFail("no child pid in output: \(text)")
    }
    XCTAssertEqual(getpgid(childPid), process.pid, "child must share the group")
    XCTAssertTrue(isAlive(process.pid))
    XCTAssertTrue(isAlive(childPid))

    XCTAssertTrue(process.signalGroup(SIGTERM))
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline && isAlive(childPid) {
      usleep(20_000)
    }
    if isAlive(childPid) {
      _ = process.signalGroup(SIGKILL)
      usleep(200_000)
    }
    // The parent is reaped by the waiter thread; the orphaned child is reaped by
    // launchd, so poll until both are gone.
    let reapDeadline = Date().addingTimeInterval(3)
    while Date() < reapDeadline && (isAlive(childPid) || isAlive(process.pid)) {
      usleep(20_000)
    }
    XCTAssertFalse(isAlive(childPid), "child survived the group kill")
    XCTAssertFalse(isAlive(process.pid), "shell survived the group kill")
    let (_, last) = drain(process, until: Date().addingTimeInterval(3)) { _, p in
      (p["exited"] as? Bool) == true
    }
    XCTAssertEqual(last["exited"] as? Bool, true)
  }

  func testZshHardeningDisablesGlobQualifiersAndEqualsExpansion() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "xuna_zsh_hardening_\(UUID().uuidString)"
    )
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let seed = dir.appendingPathComponent("a.txt")
    try "ok\n".write(to: seed, atomically: true, encoding: .utf8)
    let pwned = dir.appendingPathComponent("pwned")

    // Bare glob qualifier `(e:'...':)` must NOT execute.
    let globProc = try XunaExecProcess.spawn(
      command: "echo a.txt(e:'touch pwned':)",
      cwd: dir.path,
      environment: baseEnv,
      pty: false
    )
    defer { globProc.release() }
    let (_, globLast) = drain(globProc, until: Date().addingTimeInterval(10)) { _, p in
      (p["exited"] as? Bool) == true && (p["outputClosed"] as? Bool) == true
    }
    XCTAssertNotEqual(globLast["exitCode"] as? Int, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: pwned.path))

    // `=env` equals expansion must NOT resolve to `/usr/bin/env`.
    let eqProc = try XunaExecProcess.spawn(
      command: "=env",
      cwd: dir.path,
      environment: baseEnv,
      pty: false
    )
    defer { eqProc.release() }
    let (_, eqLast) = drain(eqProc, until: Date().addingTimeInterval(10)) { _, p in
      (p["exited"] as? Bool) == true && (p["outputClosed"] as? Bool) == true
    }
    XCTAssertNotEqual(eqLast["exitCode"] as? Int, 0)

    // Standard quoting and globbing must keep working cleanly.
    let okProc = try XunaExecProcess.spawn(
      command: "echo \"hello \\\"world\\\"\" && ls *.txt",
      cwd: dir.path,
      environment: baseEnv,
      pty: false
    )
    defer { okProc.release() }
    let (okText, okLast) = drain(okProc, until: Date().addingTimeInterval(10)) { _, p in
      (p["exited"] as? Bool) == true && (p["outputClosed"] as? Bool) == true
    }
    XCTAssertEqual(okLast["exitCode"] as? Int, 0)
    XCTAssertTrue(okText.contains("hello \"world\""))
    XCTAssertTrue(okText.contains("a.txt"))
  }
}
