//
//  Logging.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-03.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - Logging

/// The run's correlation and per-concern log files, mirroring the go engine.
///
/// The first swift-mk process of a run mints the trace, prints the one-line
/// header, and exports the traceparent so child processes it spawns join the
/// same trace and stay quiet. Every diagnostic record is also written to a
/// per-concern JSONL file under `.make/logs`, carrying the run's trace and span
/// ids, so a failure is traceable from the printed header. Auxiliary subcommands
/// that run as make prerequisites, such as `notice`, never print the header.
public enum Logging {
  /// The per-concern JSONL directory every run writes under.
  public static let logDirectory = ".make/logs"
  public static let traceparentPath = ".make/logs/.traceparent"

  private static let sentinelPath = ".make/logs/.run"
  private static let fallbackConcern = "swift-mk"
  private static let headerlessCommands: Set<String> = [
    "notice", "signing-xcconfig", "signing-identity",
  ]

  nonisolated(unsafe) private static var started = false
  nonisolated(unsafe) private static var recording = false
  nonisolated(unsafe) private static var correlationValue = Correlation.new()
  nonisolated(unsafe) private static var logDirectoryOverride: String?
  private static let stateLock = NSRecursiveLock()

  nonisolated(unsafe) private static let timestampFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  /// The run's correlation, resolving it on first use.
  public static var correlation: Correlation {
    withStateLock {
      ensureStartedLocked()
      return correlationValue
    }
  }

  /// Begin a top-level make run before any shell build output can appear.
  public static func beginRun(makeLevel: String? = nil) {
    withStateLock {
      if isNestedMakeLevel(makeLevel ?? Env.get("MAKELEVEL")) {
        ensureStartedLocked()
        return
      }
      let adopted = Correlation.fromEnvironment()
      let current = adopted ?? Correlation.new()
      started = true
      correlationValue = current
      exportCorrelation(current)
      writeTraceparent(current)
      // The make recipe redirects stderr to hide stale-binary errors.
      printHeaderOnce(current, to: .standardOutput)
      startExport(current)
    }
  }

  /// Resolve the run's trace once: adopt an inherited traceparent, adopt the
  /// persisted trace from the latest make run, or mint a new one, then print the
  /// header unless this is an auxiliary subcommand.
  public static func ensureStarted() {
    withStateLock {
      ensureStartedLocked()
    }
  }

  public static func resetForTesting(logDirectory: String? = nil) {
    withStateLock {
      resetForTestingLocked(logDirectory: logDirectory)
    }
  }

  public static func withTestingState<T>(
    logDirectory: String? = nil,
    _ run: () throws -> T
  ) rethrows -> T {
    try withStateLock {
      let previousStarted = started
      let previousRecording = recording
      let previousCorrelationValue = correlationValue
      let previousLogDirectoryOverride = logDirectoryOverride
      resetForTestingLocked(logDirectory: logDirectory)
      defer {
        started = previousStarted
        recording = previousRecording
        correlationValue = previousCorrelationValue
        logDirectoryOverride = previousLogDirectoryOverride
      }
      return try run()
    }
  }

  private static func ensureStartedLocked() {
    if started {
      return
    }
    started = true
    correlationValue = resolveCorrelation()
    if !isHeaderless() {
      printHeaderOnce(correlationValue)
    }
    startExport(correlationValue)
  }

  private static func resetForTestingLocked(logDirectory: String? = nil) {
    started = false
    recording = false
    correlationValue = Correlation.new()
    logDirectoryOverride = logDirectory
  }

  private static func withStateLock<T>(_ run: () throws -> T) rethrows -> T {
    stateLock.lock()
    defer { stateLock.unlock() }
    return try run()
  }

  static func isNestedMakeLevel(_ value: String) -> Bool {
    guard !value.isEmpty else {
      return false
    }
    guard let level = Int(value) else {
      return value != "0"
    }
    // GNU make increments MAKELEVEL before recipe commands run.
    return level > 1
  }

  public static var traceparentPathForTesting: String {
    activeTraceparentPath
  }

  public static var sentinelPathForTesting: String {
    activeSentinelPath
  }

  private static var activeLogDirectory: String {
    logDirectoryOverride ?? logDirectory
  }

  private static var activeTraceparentPath: String {
    if let logDirectoryOverride {
      return (logDirectoryOverride as NSString).appendingPathComponent(".traceparent")
    }
    return traceparentPath
  }

  private static var activeSentinelPath: String {
    if let logDirectoryOverride {
      return (logDirectoryOverride as NSString).appendingPathComponent(".run")
    }
    return sentinelPath
  }

  private static func resolveCorrelation() -> Correlation {
    if let adopted = Correlation.fromEnvironment() {
      exportCorrelation(adopted)
      return adopted
    }
    if let adopted = traceparentFileCorrelation() {
      exportCorrelation(adopted)
      return adopted
    }
    let minted = Correlation.new()
    exportCorrelation(minted)
    writeTraceparent(minted)
    return minted
  }

  private static func exportCorrelation(_ correlation: Correlation) {
    setenv("TRACEPARENT", correlation.traceparent, 1)
    setenv("TRACE_ID", correlation.traceID, 1)
    setenv("SPAN_ID", correlation.spanID, 1)
    setenv("SWIFT_MK_TRACE_ID", correlation.traceID, 1)
    setenv("SWIFT_MK_SPAN_ID", correlation.spanID, 1)
  }

  private static func writeTraceparent(_ correlation: Correlation) {
    ensureLogDirectory()
    do {
      try correlation.traceparent.write(
        toFile: activeTraceparentPath, atomically: true, encoding: .utf8)
    } catch {
      Output.error("swift-mk logging: write traceparent: \(error)")
    }
  }

  private static func traceparentFileCorrelation() -> Correlation? {
    guard FileManager.default.fileExists(atPath: activeTraceparentPath) else {
      return nil
    }
    do {
      let value = try String(contentsOfFile: activeTraceparentPath, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      // Direct CLI calls outside make intentionally join the last run's file trace
      // until a new top-level `make` run refreshes it through `trace begin`.
      return Correlation.fromTraceparent(value)
    } catch {
      Output.error("swift-mk logging: read traceparent: \(error)")
      return nil
    }
  }

  private static func startExport(_ correlation: Correlation) {
    // Export the run's span when a collector endpoint is set. The exporter
    // adopts the run's trace id, so a collector sees the same trace id the
    // header prints. The flush runs at process exit through atexit, which
    // fires even though the CLI subcommands return rather than call exit.
    OTelExport.start(correlation)
    atexit { OTelExport.shutdown() }
  }

  /// Append one diagnostic record to its per-concern JSONL file. The concern is
  /// the first dot-segment of the message, mirroring the go router. The recording
  /// guard drops a re-entrant call, so a write failure that reports through
  /// Output cannot recurse back into a record.
  public static func record(_ message: String, level: String) {
    withStateLock {
      ensureStartedLocked()
      if recording {
        return
      }
      recording = true
      defer { recording = false }
      let current = correlationValue
      let payload: [String: String] = [
        "time": timestampFormatter.string(from: Date()),
        "level": level,
        "msg": message,
        "trace_id": current.traceID,
        "span_id": current.spanID,
      ]
      let data: Data
      do {
        data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
      } catch {
        Output.error("swift-mk logging: encode record: \(error)")
        return
      }
      guard let line = String(data: data, encoding: .utf8) else {
        return
      }
      appendLine(line, toConcern: concern(of: message))
    }
  }

  private static func isHeaderless() -> Bool {
    for argument in CommandLine.arguments.dropFirst() {
      if argument.hasPrefix("-") {
        continue
      }
      return headerlessCommands.contains(argument)
    }
    return false
  }

  private static func printHeaderOnce(
    _ correlation: Correlation,
    to handle: FileHandle = .standardError
  ) {
    if alreadyPrinted(correlation.traceID) {
      return
    }
    ensureLogDirectory()
    do {
      try correlation.traceID.write(toFile: activeSentinelPath, atomically: true, encoding: .utf8)
    } catch {
      Output.error("swift-mk logging: write run sentinel: \(error)")
    }
    let ids = "trace_id=\(correlation.traceID) span_id=\(correlation.spanID)"
    let header = "🔎 logs=\(activeLogDirectory) \(ids)\n"
    handle.write(Data(header.utf8))
  }

  private static func alreadyPrinted(_ traceID: String) -> Bool {
    guard FileManager.default.fileExists(atPath: activeSentinelPath) else {
      return false
    }
    do {
      let previous = try String(contentsOfFile: activeSentinelPath, encoding: .utf8)
      return previous.trimmingCharacters(in: .whitespacesAndNewlines) == traceID
    } catch {
      Output.error("swift-mk logging: read run sentinel: \(error)")
      return false
    }
  }

  private static func concern(of message: String) -> String {
    // swift-mk diagnostics use a "<concern>: detail" or "<concern> detail"
    // form, so the concern is the leading token up to the first colon or
    // space. That splits records into per-concern files such as lint.jsonl
    // and audit.jsonl, mirroring the go router.
    let boundary = message.firstIndex { $0 == ":" || $0 == " " }
    if let boundary, boundary != message.startIndex {
      return String(message[message.startIndex..<boundary])
    }
    return fallbackConcern
  }

  private static func appendLine(_ line: String, toConcern concern: String) {
    ensureLogDirectory()
    let path = "\(activeLogDirectory)/\(concern).jsonl"
    let data = Data((line + "\n").utf8)
    guard let handle = FileHandle(forWritingAtPath: path) else {
      FileManager.default.createFile(atPath: path, contents: data)
      return
    }
    handle.seekToEndOfFile()
    handle.write(data)
    do {
      try handle.close()
    } catch {
      Output.error("swift-mk logging: close log file: \(error)")
    }
  }

  private static func ensureLogDirectory() {
    do {
      try FileManager.default.createDirectory(
        atPath: activeLogDirectory, withIntermediateDirectories: true)
    } catch {
      Output.error("swift-mk logging: create log directory: \(error)")
    }
  }
}
