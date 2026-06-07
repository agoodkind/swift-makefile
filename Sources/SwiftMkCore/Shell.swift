//
//  Shell.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-25.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - Shell

/// Run external programs and capture their output.
public enum Shell {
  /// Exit status used when a program cannot be launched, matching the shell
  /// convention for "command not found".
  private static let launchFailureStatus: Int32 = 127

  public struct Result: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    /// stdout followed by stderr, matching `swift_mk_run_capture`.
    public var combined: String { stdout + stderr }
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
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [executable] + arguments
    if !environment.isEmpty {
      var merged = ProcessInfo.processInfo.environment
      for (key, value) in environment { merged[key] = value }
      process.environment = merged
    }
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    do {
      try process.run()
    } catch {
      return Result(status: launchFailureStatus, stdout: "", stderr: "\(error)\n")
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
    let buffer = LockedData()
    group.enter()
    handle.readabilityHandler = { source in
      let chunk = source.availableData
      if chunk.isEmpty {
        source.readabilityHandler = nil
        group.leave()
      } else {
        buffer.append(chunk)
      }
    }
    return buffer
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
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [executable] + arguments
    if !environment.isEmpty {
      var merged = ProcessInfo.processInfo.environment
      for (key, value) in environment { merged[key] = value }
      process.environment = merged
    }
    do {
      try process.run()
    } catch {
      FileHandle.standardError.write(Data("Shell.runForwardingOutput: \(error)\n".utf8))
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
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [executable] + arguments
    if !environment.isEmpty {
      var merged = ProcessInfo.processInfo.environment
      for (key, value) in environment { merged[key] = value }
      process.environment = merged
    }
    process.standardOutput = outputFile
    process.standardError = outputFile
    do {
      try process.run()
    } catch {
      FileHandle.standardError.write(Data("Shell.runWritingOutput: \(error)\n".utf8))
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
