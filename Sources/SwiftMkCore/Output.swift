//
//  Output.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-25.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - Output

/// The single output boundary for the engine.
///
/// User-facing gate text flows through `log`/`logError`/`emitStandardOutput`/
/// `emitStandardError`, which write verbatim to the standard streams. The
/// severity methods `debug`/`info`/`notice`/`warning`/`error` are the structured
/// diagnostic channel for runtime boundary functions (process launches, file
/// mutations, cleanup paths); they stay silent unless `SWIFT_MK_LOG_LEVEL`
/// selects them, so routine runs produce no extra noise while the boundaries
/// still have an explicit, auditable place to report.
public enum Output {
  /// Diagnostic severity, ordered from most to least verbose.
  public enum Level: Int, Sendable {
    case debug = 0
    case error = 4
    case info = 1
    case notice = 2
    case warning = 3
  }

  /// Write a line to standard output, terminated by a single newline.
  public static func log(_ message: String) {
    emit(message + "\n", to: .standardOutput)
  }

  /// Write a line to standard output and record it in the structured log, unconditionally.
  /// Use for a command whose progress must always appear in the captured step output and in
  /// the run's log file, independent of `SWIFT_MK_LOG_LEVEL`. This tees to both sinks, so a
  /// diagnostic is never only in the on-disk log where a CI reader cannot see it.
  public static func report(_ message: String) {
    Logging.record(message, level: "info")
    emit(message + "\n", to: .standardOutput)
  }

  /// Write a line to standard error, terminated by a single newline.
  public static func logError(_ message: String) {
    emit(message + "\n", to: .standardError)
  }

  /// Write text verbatim to standard output without adding a newline.
  public static func emitStandardOutput(_ text: String) {
    emit(text, to: .standardOutput)
  }

  /// Write text verbatim to standard error without adding a newline.
  public static func emitStandardError(_ text: String) {
    emit(text, to: .standardError)
  }

  public static func debug(_ message: String) {
    diagnose(message, at: .debug)
  }

  public static func info(_ message: String) {
    diagnose(message, at: .info)
  }

  public static func notice(_ message: String) {
    diagnose(message, at: .notice)
  }

  public static func warning(_ message: String) {
    diagnose(message, at: .warning)
  }

  /// Errors always surface on standard error regardless of the log level, so a
  /// failed boundary or cleanup step is never silently swallowed. The record
  /// also lands in the per-concern JSONL under the run's trace.
  public static func error(_ message: String) {
    Logging.record(message, level: "error")
    emit(message + "\n", to: .standardError)
  }

  private static let levelEnvironmentName = "SWIFT_MK_LOG_LEVEL"
  private static let captureLock = NSLock()
  nonisolated(unsafe) private static var captureBuffer = Data()
  nonisolated(unsafe) private static var capturing = false

  public static func beginCapture() {
    captureLock.lock()
    capturing = true
    captureBuffer.removeAll(keepingCapacity: true)
    captureLock.unlock()
  }

  public static func endCapture() -> String {
    captureLock.lock()
    defer { captureLock.unlock() }
    let captured = decodeCapturedUTF8(captureBuffer)
    capturing = false
    captureBuffer.removeAll(keepingCapacity: true)
    return captured
  }

  static func decodeCapturedUTF8(_ data: Data) -> String {
    let decode: (Data, UTF8.Type) -> String = String.init(decoding:as:)
    return decode(data, UTF8.self)
  }

  static func forwardStandardOutput(_ data: Data) {
    forward(data, to: .standardOutput)
  }

  static func forwardStandardError(_ data: Data) {
    forward(data, to: .standardError)
  }

  private static func thresholdLevel() -> Level? {
    let raw = Env.get(levelEnvironmentName).lowercased()
    switch raw {
    case "debug":
      return .debug
    case "info":
      return .info
    case "notice":
      return .notice
    case "warning":
      return .warning
    case "error":
      return .error
    default:
      return nil
    }
  }

  private static func diagnose(_ message: String, at level: Level) {
    // Info and above land in the per-concern JSONL on every run, carrying the
    // run's trace, so the file holds the full record even when the stderr
    // threshold keeps the stream quiet. Debug stays out of the file as noise.
    if level != .debug {
      Logging.record(message, level: levelName(level))
    }
    guard let threshold = thresholdLevel(), level.rawValue >= threshold.rawValue else {
      return
    }
    emit(message + "\n", to: .standardError)
  }

  private static func levelName(_ level: Level) -> String {
    switch level {
    case .debug:
      return "debug"
    case .info:
      return "info"
    case .notice:
      return "notice"
    case .warning:
      return "warning"
    case .error:
      return "error"
    }
  }

  private enum Stream {
    case standardError
    case standardOutput
  }

  private static func emit(_ text: String, to stream: Stream) {
    // Resolve the run's trace and print the header before the first output, so
    // the header is the first line a run produces.
    Logging.ensureStarted()
    let data = Data(text.utf8)
    if appendCaptured(data) {
      return
    }
    handle(for: stream).write(data)
  }

  private static func forward(_ data: Data, to stream: Stream) {
    Logging.ensureStarted()
    _ = appendCaptured(data)
    handle(for: stream).write(data)
  }

  private static func handle(for stream: Stream) -> FileHandle {
    switch stream {
    case .standardError:
      return FileHandle.standardError
    case .standardOutput:
      return FileHandle.standardOutput
    }
  }

  private static func appendCaptured(_ data: Data) -> Bool {
    captureLock.lock()
    defer { captureLock.unlock() }
    guard capturing else {
      return false
    }
    // Append in place so a large capture does not copy the whole buffer per write.
    captureBuffer.append(data)
    return true
  }
}
