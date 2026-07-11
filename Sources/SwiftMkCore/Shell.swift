//
//  Shell.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-25.
//  Copyright © 2026, all rights reserved.
//

import Darwin
import Foundation

// MARK: - Shell

/// Run external programs and capture their output.
public enum Shell {
  /// Exit status used when a program cannot be launched, matching the shell
  /// convention for "command not found".
  private static let launchFailureStatus: Int32 = 127

  /// Number of launch attempts before a spawn failure is treated as terminal.
  private static let maxLaunchAttempts = 5
  private static let timeoutTerminationGraceSeconds = 2.0
  private static let timeoutPollIntervalMicroseconds: useconds_t = 10_000
  /// The live trace/span keys re-applied over a child's environment overrides so a
  /// subprocess joins the run trace, driven from the one Correlation.environmentKeys
  /// list the test suites also share.
  private static let traceEnvironmentKeys = Correlation.environmentKeys

  /// Build and start a process, retrying a spurious launch failure with a fresh
  /// `Process` each attempt. An `NSTask` cannot be relaunched (a second `run()`
  /// raises an uncaught `NSException`), so each retry builds a new instance through
  /// `makeProcess`. Foundation occasionally fails `run()` with a transient POSIX
  /// error (ENOTDIR, EFAULT, or EAGAIN) when many launches race, which a parallel
  /// test suite reproduces by issuing dozens of concurrent `Process.run()` calls at
  /// once. Every executable here is a valid absolute path (`/usr/bin/env` or
  /// `/bin/sh`), so a throw is never a wrong path, only a transient spawn-layer
  /// race; a bounded retry clears it without masking a real failure. Returns the
  /// started process, or nil with `launchError` set when every attempt failed.
  private static func startWithRetry(
    _ makeProcess: () -> Process, launchError: inout Error?
  ) -> Process? {
    for attempt in 1...maxLaunchAttempts {
      let process = makeProcess()
      do {
        try process.run()
        return process
      } catch {
        launchError = error
        Output.debug(
          "Shell: launch attempt \(attempt)/\(maxLaunchAttempts) failed, retrying: \(error)")
        continue
      }
    }
    return nil
  }

  /// The child environment for a spawned process: nil to inherit the parent
  /// environment unchanged, or the parent merged with `overrides`.
  private static func childEnvironment(_ overrides: [String: String]) -> [String: String]? {
    guard !overrides.isEmpty else {
      return nil
    }
    var merged = ProcessInfo.processInfo.environment
    for (key, value) in overrides {
      merged[key] = value
    }
    for key in traceEnvironmentKeys {
      let value = Env.get(key)
      if !value.isEmpty {
        merged[key] = value
      }
    }
    return merged
  }

  public struct Result: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    /// stdout followed by stderr, matching `swift_mk_run_capture`.
    public var combined: String { stdout + stderr }
  }

  public struct StreamingResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let timedOut: Bool
  }

  /// Run a program found on PATH (or an absolute path) with arguments. An
  /// empty `environment` inherits the current process environment unchanged.
  @discardableResult
  public static func run(
    _ executable: String,
    _ arguments: [String] = [],
    environment: [String: String] = [:]
  ) -> Result {
    Output.debug("Shell.run \(executable) \(arguments.joined(separator: " "))")
    var launchError: Error?
    let started = startWithRetry(
      {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        if let childEnv = childEnvironment(environment) {
          process.environment = childEnv
        }
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        return process
      }, launchError: &launchError)
    guard let process = started,
      let outPipe = process.standardOutput as? Pipe,
      let errPipe = process.standardError as? Pipe
    else {
      let message = launchError.map { "\($0)" } ?? "Shell.run: launch failed"
      return Result(status: launchFailureStatus, stdout: "", stderr: "\(message)\n")
    }
    // Drain stdout and stderr concurrently. A pipe's kernel buffer is bounded
    // (about 64 KB on macOS), so reading one stream to EOF before the other
    // deadlocks when the child fills the unread pipe before it closes the one
    // being read: the child blocks in write() while this process blocks in
    // read(). Reading both as bytes arrive keeps either stream from blocking.
    let group = DispatchGroup()
    let outBuffer = drainAsync(outPipe.fileHandleForReading, into: group)
    let errBuffer = drainAsync(errPipe.fileHandleForReading, into: group)
    group.wait()
    process.waitUntilExit()
    return Result(
      status: process.terminationStatus,
      stdout: String(bytes: outBuffer.snapshot(), encoding: .utf8) ?? "",
      stderr: String(bytes: errBuffer.snapshot(), encoding: .utf8) ?? ""
    )
  }

  /// Accumulate a file handle's bytes off the calling thread until the stream
  /// closes, holding `group` until EOF so the buffer is complete once
  /// `group.wait()` returns. Reading both of a process's streams this way keeps a
  /// child that floods one pipe from blocking against a serial reader of the other.
  private static func drainAsync(_ handle: FileHandle, into group: DispatchGroup) -> LockedData {
    drainAsync(handle, into: group, onChunk: nil)
  }

  private static func drainAsync(
    _ handle: FileHandle,
    into group: DispatchGroup,
    onChunk: (@Sendable (Data) -> Void)?
  ) -> LockedData {
    let buffer = LockedData()
    group.enter()
    handle.readabilityHandler = { source in
      let chunk = source.availableData
      if chunk.isEmpty {
        source.readabilityHandler = nil
        group.leave()
      } else {
        buffer.append(chunk)
        onChunk?(chunk)
      }
    }
    return buffer
  }

  private struct SpawnedStreamingProcess {
    let processIdentifier: pid_t
    let standardOutput: Pipe
    let standardError: Pipe
  }

  private static func spawnStreamingProcessGroup(
    _ executable: String,
    _ arguments: [String],
    environment: [String: String]
  ) -> SpawnedStreamingProcess? {
    let standardOutput = Pipe()
    let standardError = Pipe()
    let outputReadDescriptor = standardOutput.fileHandleForReading.fileDescriptor
    let outputWriteDescriptor = standardOutput.fileHandleForWriting.fileDescriptor
    let errorReadDescriptor = standardError.fileHandleForReading.fileDescriptor
    let errorWriteDescriptor = standardError.fileHandleForWriting.fileDescriptor

    var attributes: posix_spawnattr_t?
    guard posix_spawnattr_init(&attributes) == 0 else {
      return nil
    }
    defer { posix_spawnattr_destroy(&attributes) }

    var fileActions: posix_spawn_file_actions_t?
    guard posix_spawn_file_actions_init(&fileActions) == 0 else {
      return nil
    }
    defer { posix_spawn_file_actions_destroy(&fileActions) }

    let spawnFlags = Int16(POSIX_SPAWN_SETPGROUP)
    guard posix_spawnattr_setflags(&attributes, spawnFlags) == 0,
      posix_spawnattr_setpgroup(&attributes, 0) == 0,
      posix_spawn_file_actions_adddup2(
        &fileActions, outputWriteDescriptor, STDOUT_FILENO) == 0,
      posix_spawn_file_actions_adddup2(
        &fileActions, errorWriteDescriptor, STDERR_FILENO) == 0,
      posix_spawn_file_actions_addclose(&fileActions, outputReadDescriptor) == 0,
      posix_spawn_file_actions_addclose(&fileActions, errorReadDescriptor) == 0,
      posix_spawn_file_actions_addclose(&fileActions, outputWriteDescriptor) == 0,
      posix_spawn_file_actions_addclose(&fileActions, errorWriteDescriptor) == 0
    else {
      return nil
    }

    let argv = ["/usr/bin/env", executable] + arguments
    let envpStrings = childEnvironment(environment).map { merged in
      merged.map { "\($0.key)=\($0.value)" }
    }
    var processIdentifier: pid_t = -1
    let spawnStatus = withCStringArray(argv) { argvPointer -> Int32 in
      if let envpStrings {
        return withCStringArray(envpStrings) { envpPointer in
          posix_spawn(
            &processIdentifier, "/usr/bin/env", &fileActions, &attributes, argvPointer,
            envpPointer)
        } ?? ENOMEM
      }
      return posix_spawn(
        &processIdentifier, "/usr/bin/env", &fileActions, &attributes, argvPointer, environ)
    }
    guard let spawnStatus, spawnStatus == 0 else {
      return nil
    }
    // The parent must drop its copies of the write ends so the read ends reach
    // EOF once the whole child group exits; only the child holds them as fd 1/2.
    standardOutput.fileHandleForWriting.closeFile()
    standardError.fileHandleForWriting.closeFile()
    return SpawnedStreamingProcess(
      processIdentifier: processIdentifier,
      standardOutput: standardOutput,
      standardError: standardError)
  }

  /// Decode a `waitpid` status into a shell-style exit code: the exit status for
  /// a normal exit, or 128 plus the signal number for a signalled child.
  private static func decodeWaitStatus(_ status: Int32) -> Int32 {
    if status & 0x7f == 0 {
      return (status >> 8) & 0xff
    }
    let terminatingSignal = status & 0x7f
    if terminatingSignal != 0x7f {
      return 128 + terminatingSignal
    }
    return (status >> 8) & 0xff
  }

  private static func reapProcessBlocking(_ processIdentifier: pid_t) -> Int32 {
    var status: Int32 = 0
    while true {
      let reaped = waitpid(processIdentifier, &status, 0)
      if reaped == processIdentifier {
        return decodeWaitStatus(status)
      }
      if reaped == -1, errno != EINTR {
        return launchFailureStatus
      }
    }
  }

  /// Kill a timed-out child's whole process group and reap it. Send SIGTERM to the
  /// group, give it a bounded grace to exit, then SIGKILL the group and reap. The
  /// SIGKILL goes out while the leader is still unreaped, so its PID cannot be
  /// recycled into an unrelated group before the signal lands, and it clears any
  /// grandchild that ignores SIGTERM so nothing outlives the wrapper and reparents
  /// to launchd as a runaway. Every wait here is bounded, including the drain.
  private static func terminateProcessGroupAndReap(
    _ process: SpawnedStreamingProcess, drainGroup: DispatchGroup
  ) -> Int32 {
    let processIdentifier = process.processIdentifier
    _ = kill(-processIdentifier, SIGTERM)
    // Wait for the group leader to exit WITHOUT reaping it (WNOWAIT), so its PID
    // stays reserved while the group SIGKILL below is delivered.
    let deadline = Date().addingTimeInterval(timeoutTerminationGraceSeconds)
    while Date() < deadline {
      var status: Int32 = 0
      if waitpid(processIdentifier, &status, WNOHANG | WNOWAIT) == processIdentifier {
        break
      }
      usleep(timeoutPollIntervalMicroseconds)
    }
    _ = kill(-processIdentifier, SIGKILL)
    let status = reapProcessBlocking(processIdentifier)
    drainAndRelease(process, drainGroup: drainGroup)
    return status
  }

  /// Wait for the drain handlers to finish, bounded so a descendant that escaped
  /// the process group and kept a pipe write end open cannot hang the wrapper. On
  /// timeout, detach the readers and close the read ends; the captured stdout is
  /// whatever arrived before then.
  private static func drainAndRelease(
    _ process: SpawnedStreamingProcess, drainGroup: DispatchGroup
  ) {
    if drainGroup.wait(timeout: .now() + timeoutTerminationGraceSeconds) == .timedOut {
      for handle in [
        process.standardOutput.fileHandleForReading,
        process.standardError.fileHandleForReading,
      ] {
        handle.readabilityHandler = nil
        try? handle.close()
      }
    }
  }

  private static func withCStringArray<Value>(
    _ strings: [String],
    _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Value
  ) -> Value? {
    var pointers: [UnsafeMutablePointer<CChar>?] = []
    for string in strings {
      guard let pointer = strdup(string) else {
        for pointer in pointers {
          free(pointer)
        }
        return nil
      }
      pointers.append(pointer)
    }
    pointers.append(nil)
    defer {
      for pointer in pointers {
        free(pointer)
      }
    }
    return pointers.withUnsafeMutableBufferPointer { buffer in
      body(buffer.baseAddress!)
    }
  }

  /// Run a program, capturing stdout in full while forwarding stderr live.
  @discardableResult
  public static func runStreamingStderr(
    _ executable: String,
    _ arguments: [String] = [],
    environment: [String: String] = [:],
    timeoutSeconds: Double = 0
  ) -> StreamingResult {
    Output.debug("Shell.runStreamingStderr \(executable) \(arguments.joined(separator: " "))")
    // Spawn the child in its OWN process group (see spawnStreamingProcessGroup)
    // so a timeout can kill the whole tree with kill(-pid, ...) instead of only
    // the direct child. A single SIGTERM to the child left grandchildren, or a
    // child that ignored SIGTERM, running until an outer force-kill orphaned
    // them to launchd as runaways.
    var spawned: SpawnedStreamingProcess?
    for attempt in 1...maxLaunchAttempts {
      if let candidate = spawnStreamingProcessGroup(executable, arguments, environment: environment)
      {
        spawned = candidate
        break
      }
      Output.debug(
        "Shell.runStreamingStderr: spawn attempt \(attempt)/\(maxLaunchAttempts) failed, retrying")
    }
    guard let spawned else {
      return StreamingResult(status: launchFailureStatus, stdout: "", timedOut: false)
    }

    let group = DispatchGroup()
    let outBuffer = drainAsync(spawned.standardOutput.fileHandleForReading, into: group)
    _ = drainAsync(spawned.standardError.fileHandleForReading, into: group) { chunk in
      FileHandle.standardError.write(chunk)
    }
    var timedOut = false
    let status: Int32
    if timeoutSeconds > 0, group.wait(timeout: .now() + timeoutSeconds) == .timedOut {
      timedOut = true
      status = terminateProcessGroupAndReap(spawned, drainGroup: group)
    } else {
      group.wait()
      status = reapProcessBlocking(spawned.processIdentifier)
    }
    return StreamingResult(
      status: status,
      stdout: String(bytes: outBuffer.snapshot(), encoding: .utf8) ?? "",
      timedOut: timedOut
    )
  }

  /// Run a command string through `/bin/sh -c`. An empty `environment` inherits the
  /// current process environment unchanged; a non-empty one is merged over it.
  @discardableResult
  public static func sh(_ command: String, environment: [String: String] = [:]) -> Result {
    run("/bin/sh", ["-c", command], environment: environment)
  }

  /// Run a program and forward its stdout and stderr to this process's streams,
  /// returning only the exit status. Use this for long, streaming subprocesses
  /// such as a build or test run, where the child's output must reach the user
  /// live rather than being captured and discarded.
  @discardableResult
  public static func runForwardingOutput(
    _ executable: String,
    _ arguments: [String] = [],
    environment: [String: String] = [:]
  ) -> Int32 {
    Output.debug("Shell.runForwardingOutput \(executable) \(arguments.joined(separator: " "))")
    var launchError: Error?
    let started = startWithRetry(
      {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        if let childEnv = childEnvironment(environment) {
          process.environment = childEnv
        }
        return process
      }, launchError: &launchError)
    guard let process = started else {
      let message = launchError.map { "\($0)" } ?? "launch failed"
      FileHandle.standardError.write(Data("Shell.runForwardingOutput: \(message)\n".utf8))
      return launchFailureStatus
    }
    process.waitUntilExit()
    return process.terminationStatus
  }

  /// Run a program writing its combined stdout and stderr to a file, returning the
  /// exit status. Use when a later step reads the full output from disk, such as the
  /// swiftlint analyze compiler-log build that feeds `swiftlint analyze`. An empty
  /// `environment` inherits the current process environment unchanged; a non-empty
  /// one is merged over it.
  @discardableResult
  public static func runWritingOutput(
    _ executable: String,
    _ arguments: [String],
    toFile path: String,
    environment: [String: String] = [:]
  ) -> Int32 {
    Output.debug("Shell.runWritingOutput \(executable) \(arguments.joined(separator: " "))")
    guard FileManager.default.createFile(atPath: path, contents: nil) else {
      FileHandle.standardError.write(
        Data("Shell.runWritingOutput: cannot create \(path)\n".utf8))
      return launchFailureStatus
    }
    let outputFile: FileHandle
    do {
      outputFile = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
    } catch {
      FileHandle.standardError.write(Data("Shell.runWritingOutput: \(error)\n".utf8))
      return launchFailureStatus
    }
    defer {
      do {
        try outputFile.close()
      } catch {
        Output.error("Shell.runWritingOutput: failed closing \(path): \(error)")
      }
    }
    var launchError: Error?
    let started = startWithRetry(
      {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        if let childEnv = childEnvironment(environment) {
          process.environment = childEnv
        }
        process.standardOutput = outputFile
        process.standardError = outputFile
        return process
      }, launchError: &launchError)
    guard let process = started else {
      let message = launchError.map { "\($0)" } ?? "launch failed"
      FileHandle.standardError.write(Data("Shell.runWritingOutput: \(message)\n".utf8))
      return launchFailureStatus
    }
    process.waitUntilExit()
    return process.terminationStatus
  }
}

// MARK: - LockedData

/// A growable byte buffer one `readabilityHandler` appends to off the calling
/// thread while `Shell.run` reads it back after the stream closes. A reference
/// type so the handler and the caller share one buffer; an `NSLock` guards every
/// access, which is why the unchecked `Sendable` conformance is sound.
private final class LockedData: @unchecked Sendable {
  private let lock = NSLock()
  private var data = Data()

  func append(_ chunk: Data) {
    lock.lock()
    defer { lock.unlock() }
    data.append(chunk)
  }

  func snapshot() -> Data {
    lock.lock()
    defer { lock.unlock() }
    return data
  }
}
