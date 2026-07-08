//
//  LoggingTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-09.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - LoggingTests

@Suite(.serialized)
enum LoggingTests {
  private static let environmentKeys = Correlation.environmentKeys
  private static let traceID = "11111111111111111111111111111111"
  private static let spanID = "2222222222222222"
  private static let traceparent = "00-\(traceID)-\(spanID)-01"

  @Test
  static func beginRunWritesTraceparentAndEnsureStartedAdoptsIt() throws {
    try withTemporaryLogDirectory { logDirectory in
      clearLoggingEnvironment()

      Logging.beginRun(makeLevel: "")

      let persistedTraceparent = try readTrimmed(Logging.traceparentPathForTesting)
      let persisted = try #require(Correlation.fromTraceparent(persistedTraceparent))
      let sentinel = try readTrimmed(Logging.sentinelPathForTesting)
      #expect(sentinel == persisted.traceID)

      // Clear the env pair so ensureStarted adopts from the persisted file.
      clearLoggingEnvironment()
      Logging.resetForTesting(logDirectory: logDirectory)
      Logging.ensureStarted()

      #expect(Logging.correlation.traceID == persisted.traceID)
    }
  }

  @Test
  static func beginRunAdoptsTraceparentFromEnvironment() throws {
    try withTemporaryLogDirectory { _ in
      clearLoggingEnvironment()
      setenv("TRACEPARENT", traceparent, 1)

      Logging.beginRun(makeLevel: "")

      let persistedTraceparent = try readTrimmed(Logging.traceparentPathForTesting)
      #expect(Logging.correlation.traceID == traceID)
      #expect(Logging.correlation.spanID == spanID)
      #expect(persistedTraceparent == traceparent)
      #expect(Env.get("TRACEPARENT") == traceparent)
      #expect(Env.get("TRACE_ID") == traceID)
      #expect(Env.get("SPAN_ID") == spanID)
      #expect(Env.get("SWIFT_MK_TRACE_ID") == traceID)
      #expect(Env.get("SWIFT_MK_SPAN_ID") == spanID)
    }
  }

  @Test
  static func logRecordsUseAdoptedRunSpan() throws {
    try withTemporaryLogDirectory { logDirectory in
      clearLoggingEnvironment()
      setenv("TRACEPARENT", traceparent, 1)

      Logging.beginRun(makeLevel: "")
      Logging.record("trace: record", level: "info")

      let recordPath = (logDirectory as NSString).appendingPathComponent("trace.jsonl")
      let record = try decodeLogRecord(readTrimmed(recordPath))
      #expect(record.traceID == traceID)
      #expect(record.spanID == spanID)
    }
  }

  @Test
  static func beginRunUnderNestedMakeLevelDoesNotOverwriteTraceparentFile() throws {
    try withTemporaryLogDirectory { _ in
      clearLoggingEnvironment()
      let existing = Correlation.new()
      try existing.traceparent.write(
        toFile: Logging.traceparentPathForTesting, atomically: true, encoding: .utf8)
      try existing.traceID.write(
        toFile: Logging.sentinelPathForTesting, atomically: true, encoding: .utf8)

      Logging.beginRun(makeLevel: "2")

      #expect(try readTrimmed(Logging.traceparentPathForTesting) == existing.traceparent)
      #expect(Logging.correlation.traceID == existing.traceID)
    }
  }

  @Test
  static func makeLevelOneIsTheTopLevelRecipeProcess() {
    #expect(!Logging.isNestedMakeLevel(""))
    #expect(!Logging.isNestedMakeLevel("0"))
    #expect(!Logging.isNestedMakeLevel("1"))
    #expect(Logging.isNestedMakeLevel("2"))
  }

  private static func withTemporaryLogDirectory(_ run: (String) throws -> Void) throws {
    let fileManager = FileManager.default
    let originalEnvironment = savedEnvironment()
    let directory = fileManager.temporaryDirectory.appendingPathComponent(
      "swift-mk-logging-\(UUID().uuidString)",
      isDirectory: true
    )
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

    defer {
      restoreEnvironment(originalEnvironment)
      do {
        try fileManager.removeItem(at: directory)
      } catch {
        Output.warning("logging tests cleanup failed: \(error.localizedDescription)")
      }
    }

    try Logging.withTestingState(logDirectory: directory.path) {
      try run(directory.path)
    }
  }

  private static func readTrimmed(_ path: String) throws -> String {
    try String(contentsOfFile: path, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func savedEnvironment() -> [String: String?] {
    var saved: [String: String?] = [:]
    for key in environmentKeys {
      saved[key] = getenv(key).map { String(cString: $0) }
    }
    return saved
  }

  private static func restoreEnvironment(_ saved: [String: String?]) {
    for key in environmentKeys {
      guard let savedValue = saved[key] else {
        unsetenv(key)
        continue
      }
      guard let value = savedValue else {
        unsetenv(key)
        continue
      }
      setenv(key, value, 1)
    }
  }

  private static func clearLoggingEnvironment() {
    for key in environmentKeys {
      unsetenv(key)
    }
  }

  private static func decodeLogRecord(_ line: String) throws -> LogRecord {
    let data = Data(line.utf8)
    return try JSONDecoder().decode(LogRecord.self, from: data)
  }

  private struct LogRecord: Decodable {
    let traceID: String
    let spanID: String

    enum CodingKeys: String, CodingKey {
      case traceID = "trace_id"
      case spanID = "span_id"
    }
  }
}
