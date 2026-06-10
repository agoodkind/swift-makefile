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
  private static let environmentKeys = ["TRACEPARENT"]

  @Test
  static func beginRunWritesTraceparentAndEnsureStartedAdoptsIt() throws {
    try withTemporaryLogDirectory { logDirectory in
      clearLoggingEnvironment()

      Logging.beginRun(makeLevel: "")

      let traceparent = try readTrimmed(Logging.traceparentPathForTesting)
      let persisted = try #require(Correlation.fromTraceparent(traceparent))
      let sentinel = try readTrimmed(Logging.sentinelPathForTesting)
      #expect(sentinel == persisted.traceID)

      unsetenv("TRACEPARENT")
      Logging.resetForTesting(logDirectory: logDirectory)
      Logging.ensureStarted()

      #expect(Logging.correlation.traceID == persisted.traceID)
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
    let environment = ProcessInfo.processInfo.environment
    for key in environmentKeys {
      saved[key] = environment[key]
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
}
