import Cocoa
import Darwin
import FlutterMacOS

/// One `exec.run` child started in its own process group (`ADR-0018`).
///
/// The child is `/bin/zsh -f` (no start-up files, so `.zshenv` cannot inject
/// secrets back into the sanitized environment) started with `posix_spawn`
/// and `POSIX_SPAWN_SETPGROUP` (pgid == pid), so `kill(-pgid, …)` reaches every
/// descendant that stayed in the group. With `pty: true` stdin/stdout/stderr
/// are a pseudo-terminal from `posix_openpt` (isatty() is true; the child has
/// no controlling terminal). Output is buffered in RAM only.
final class XunaExecProcess {
  static let maxPendingBytes = 256 * 1024

  let pid: pid_t
  private let readFd: Int32
  private var writeFd: Int32
  private let lock = NSLock()
  private var pending = Data()
  private var dropped = false
  private var exited = false
  private var exitCode: Int32 = 0
  private var termSignal: Int32 = 0
  private var readerDone = false

  private init(pid: pid_t, readFd: Int32, writeFd: Int32) {
    self.pid = pid
    self.readFd = readFd
    self.writeFd = writeFd
  }

  enum SpawnError: Error {
    case pipe
    case pty
    case spawn(Int32)
  }

  /// Starts `command` in `cwd` with exactly `environment` (no inheritance).
  static func spawn(
    command: String,
    cwd: String,
    environment: [String: String],
    pty: Bool
  ) throws -> XunaExecProcess {
    var parentRead: Int32 = -1
    var parentWrite: Int32 = -1
    var childIn: Int32 = -1
    var childOut: Int32 = -1
    if pty {
      let master = posix_openpt(O_RDWR | O_NOCTTY)
      guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0,
            let namePtr = ptsname(master)
      else {
        throw SpawnError.pty
      }
      let slave = open(String(cString: namePtr), O_RDWR | O_NOCTTY)
      guard slave >= 0 else {
        close(master)
        throw SpawnError.pty
      }
      parentRead = master
      parentWrite = master
      childIn = slave
      childOut = slave
    } else {
      var outPipe: [Int32] = [-1, -1]
      var inPipe: [Int32] = [-1, -1]
      guard pipe(&outPipe) == 0 else { throw SpawnError.pipe }
      guard pipe(&inPipe) == 0 else {
        close(outPipe[0])
        close(outPipe[1])
        throw SpawnError.pipe
      }
      parentRead = outPipe[0]
      childOut = outPipe[1]
      childIn = inPipe[0]
      parentWrite = inPipe[1]
    }

    var fileActions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&fileActions)
    defer { posix_spawn_file_actions_destroy(&fileActions) }
    posix_spawn_file_actions_adddup2(&fileActions, childIn, 0)
    posix_spawn_file_actions_adddup2(&fileActions, childOut, 1)
    posix_spawn_file_actions_adddup2(&fileActions, childOut, 2)

    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    // New process group (pgid == pid); close every descriptor not set above;
    // reset blocked/ignored signals so SIGTERM/SIGPIPE behave normally.
    let flags = Int16(
      POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
        | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
    )
    posix_spawnattr_setflags(&attr, flags)
    posix_spawnattr_setpgroup(&attr, 0)
    var emptyMask: sigset_t = 0
    posix_spawnattr_setsigmask(&attr, &emptyMask)
    var defaults: sigset_t = 0
    for sig in [SIGPIPE, SIGTERM, SIGINT, SIGHUP, SIGQUIT] {
      defaults |= sigset_t(1) << sigset_t(sig - 1)
    }
    posix_spawnattr_setsigdefault(&attr, &defaults)

    // `cd` runs inside the child shell (posix_spawn chdir needs macOS 10.15).
    // Disable zsh-only bare glob qualifiers (`*(e:'...':)`) and `=cmd` equals
    // expansion so the shell matches the POSIX lexer strictly.
    let script = "cd -- \"$1\" || exit 97; exec /bin/zsh -f -o NO_BARE_GLOB_QUAL -o NO_EQUALS -c \"$2\""
    let argv = ["/bin/zsh", "-f", "-c", script, "xuna-exec", cwd, command]
    let cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
    let cEnv: [UnsafeMutablePointer<CChar>?] =
      environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer {
      cArgs.forEach { free($0) }
      cEnv.forEach { free($0) }
    }
    var pid: pid_t = 0
    let rc = posix_spawn(&pid, "/bin/zsh", &fileActions, &attr, cArgs, cEnv)
    if pty {
      close(childIn)
    } else {
      close(childIn)
      close(childOut)
    }
    guard rc == 0 else {
      close(parentRead)
      if parentWrite != parentRead { close(parentWrite) }
      throw SpawnError.spawn(rc)
    }
    let process = XunaExecProcess(pid: pid, readFd: parentRead, writeFd: parentWrite)
    process.startThreads()
    return process
  }

  private func startThreads() {
    let fd = readFd
    Thread.detachNewThread { [weak self] in
      var buffer = [UInt8](repeating: 0, count: 8192)
      while true {
        let n = read(fd, &buffer, buffer.count)
        if n > 0 {
          self?.append(Data(buffer[0..<n]))
        } else if n < 0 && errno == EINTR {
          continue
        } else {
          break
        }
      }
      self?.markReaderDone()
    }
    let childPid = pid
    Thread.detachNewThread { [weak self] in
      var status: Int32 = 0
      var r: pid_t = -1
      repeat {
        r = waitpid(childPid, &status, 0)
      } while r == -1 && errno == EINTR
      self?.markExited(status: r == childPid ? status : -1)
    }
  }

  private func append(_ data: Data) {
    lock.lock()
    pending.append(data)
    if pending.count > Self.maxPendingBytes {
      pending = pending.suffix(Self.maxPendingBytes)
      dropped = true
    }
    lock.unlock()
  }

  private func markReaderDone() {
    lock.lock()
    readerDone = true
    lock.unlock()
  }

  private func markExited(status: Int32) {
    lock.lock()
    if status < 0 {
      exitCode = -1
    } else {
      let sig = status & 0x7f
      if sig == 0 {
        exitCode = (status >> 8) & 0xff
      } else {
        termSignal = sig
        exitCode = 128 + sig
      }
    }
    exited = true
    lock.unlock()
  }

  /// Drains buffered output. `exited` is reported only once the process has
  /// been reaped AND its output pipe reached EOF (or a short grace passed).
  func poll() -> [String: Any] {
    lock.lock()
    defer { lock.unlock() }
    let data = pending
    pending = Data()
    let wasDropped = dropped
    dropped = false
    var out: [String: Any] = [
      "data": FlutterStandardTypedData(bytes: data),
      "dropped": wasDropped,
      "exited": exited,
      "outputClosed": readerDone,
    ]
    if exited {
      out["exitCode"] = Int(exitCode)
      if termSignal != 0 { out["signal"] = Int(termSignal) }
    }
    return out
  }

  func write(_ data: Data, eof: Bool) -> Int {
    lock.lock()
    let fd = writeFd
    lock.unlock()
    guard fd >= 0 else { return -1 }
    var written = 0
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      guard let base = raw.baseAddress else { return }
      while written < raw.count {
        let n = Darwin.write(fd, base + written, raw.count - written)
        if n > 0 {
          written += n
        } else if n < 0 && errno == EINTR {
          continue
        } else {
          break
        }
      }
    }
    if eof {
      lock.lock()
      if writeFd >= 0 && writeFd != readFd {
        close(writeFd)
        writeFd = -1
      } else if writeFd == readFd {
        // PTY: send the terminal EOF character instead of closing the master.
        var eot: UInt8 = 4
        _ = Darwin.write(writeFd, &eot, 1)
      }
      lock.unlock()
    }
    return written
  }

  /// Sends `signal` to the whole process group. Returns false when the group
  /// no longer exists.
  func signalGroup(_ signal: Int32) -> Bool {
    return kill(-pid, signal) == 0
  }

  func release() {
    lock.lock()
    if writeFd >= 0 && writeFd != readFd { close(writeFd) }
    writeFd = -1
    lock.unlock()
    close(readFd)
  }
}

private let xunaExecQueue = DispatchQueue(label: "ai.xuna.desktop.host.exec", qos: .userInitiated)
private let xunaExecLock = NSLock()
private var xunaExecProcesses: [Int: XunaExecProcess] = [:]
private var xunaExecNextHandle = 1

extension XunaHostPlugin {
  /// Routes `execSpawn` / `execPoll` / `execWrite` / `execSignal` /
  /// `execRelease`. Returns false for any other method.
  func routeExecMethod(_ method: String, args: [String: Any], result: @escaping FlutterResult) -> Bool {
    switch method {
    case "execSpawn", "execPoll", "execWrite", "execSignal", "execRelease":
      xunaExecQueue.async { self.handleExec(method, args: args, result: result) }
      return true
    default:
      return false
    }
  }

  private func replyExec(_ result: @escaping FlutterResult, _ value: Any?) {
    DispatchQueue.main.async { result(value) }
  }

  private func handleExec(_ method: String, args: [String: Any], result: @escaping FlutterResult) {
    if method == "execSpawn" {
      guard let command = args["command"] as? String, !command.isEmpty,
            let cwd = args["cwd"] as? String, cwd.hasPrefix("/"),
            let env = args["environment"] as? [String: String]
      else {
        replyError(result, code: "invalid_args", message: "Missing exec spawn arguments", errorCode: "schema_mismatch")
        return
      }
      do {
        let process = try XunaExecProcess.spawn(
          command: command,
          cwd: cwd,
          environment: env,
          pty: (args["pty"] as? Bool) ?? false
        )
        xunaExecLock.lock()
        let handle = xunaExecNextHandle
        xunaExecNextHandle += 1
        xunaExecProcesses[handle] = process
        xunaExecLock.unlock()
        replyExec(result, ["handle": handle, "pid": Int(process.pid)])
      } catch {
        replyError(result, code: "failed", message: "Command could not be started", errorCode: "exec_spawn_failed")
      }
      return
    }
    guard let handle = args["handle"] as? Int else {
      replyError(result, code: "invalid_args", message: "Missing exec handle", errorCode: "schema_mismatch")
      return
    }
    xunaExecLock.lock()
    let process = xunaExecProcesses[handle]
    if method == "execRelease" { xunaExecProcesses.removeValue(forKey: handle) }
    xunaExecLock.unlock()
    guard let process = process else {
      replyError(result, code: "failed", message: "Unknown exec handle", errorCode: "exec_task_not_found")
      return
    }
    switch method {
    case "execPoll":
      replyExec(result, process.poll())
    case "execWrite":
      let typed = args["data"] as? FlutterStandardTypedData
      let written = process.write(typed?.data ?? Data(), eof: (args["eof"] as? Bool) ?? false)
      replyExec(result, ["written": written])
    case "execSignal":
      let sig: Int32 = (args["signal"] as? String) == "kill" ? SIGKILL : SIGTERM
      replyExec(result, ["sent": process.signalGroup(sig)])
    default:
      process.release()
      replyExec(result, ["released": true])
    }
  }
}
