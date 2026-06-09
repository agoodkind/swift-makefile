//
//  StructuredGateTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-08.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - StructuredGateTests

@Suite(.serialized)
enum StructuredGateTests {
  @Test
  static func runPassesWhenCurrentKeysAndCountsAreWithinBaseline() throws {
    try withTemporaryWorkingDirectory { directoryPath in
      let firstFinding = makeSwiftlintFinding(
        ruleId: "identifier_name",
        file: "Sources/App.swift",
        line: 12,
        column: 5,
        message: "Identifier name should be between 3 and 40 characters long"
      )
      let secondFinding = makeSwiftlintFinding(
        ruleId: "identifier_name",
        file: "Sources/App.swift",
        line: 20,
        column: 9,
        message: "Identifier name should be between 3 and 40 characters long"
      )
      let baselinePath = baselinePath(in: directoryPath)
      try BaselineStore.write(
        [
          makeRecord(from: firstFinding),
          makeRecord(from: secondFinding),
        ],
        to: baselinePath
      )

      let passed = StructuredGate.run(
        gateName: "swiftlint",
        findings: [firstFinding, secondFinding],
        baselinePath: baselinePath,
        remediation: "Run make baseline-update"
      )

      #expect(passed)
    }
  }

  @Test
  static func runFailsWhenCurrentFindingHasBrandNewKey() throws {
    try withTemporaryWorkingDirectory { directoryPath in
      let baselineFinding = makeSwiftlintFinding(
        ruleId: "identifier_name",
        file: "Sources/App.swift",
        line: 12,
        column: 5,
        message: "Identifier name should be between 3 and 40 characters long"
      )
      let currentFinding = makeSwiftlintFinding(
        ruleId: "function_body_length",
        file: "Sources/NewFile.swift",
        line: 42,
        column: 1,
        message: "Function body should span 40 lines or less"
      )
      let baselinePath = baselinePath(in: directoryPath)
      try BaselineStore.write([makeRecord(from: baselineFinding)], to: baselinePath)

      let passed = StructuredGate.run(
        gateName: "swiftlint",
        findings: [currentFinding],
        baselinePath: baselinePath,
        remediation: "Run make baseline-update"
      )

      #expect(!passed)
    }
  }

  @Test
  static func runPassesWhenSwiftlintLocationAndMessageDrift() throws {
    try withTemporaryWorkingDirectory { directoryPath in
      let baselineFinding = makeSwiftlintFinding(
        ruleId: "function_body_length",
        file: "Sources/App.swift",
        line: 42,
        column: 1,
        message: "Function body should span 40 lines or less: currently spans 45 lines"
      )
      let currentFinding = makeSwiftlintFinding(
        ruleId: "function_body_length",
        file: "Sources/App.swift",
        line: 48,
        column: 7,
        message: "Function body should span 40 lines or less: currently spans 47 lines"
      )
      let baselinePath = baselinePath(in: directoryPath)
      try BaselineStore.write([makeRecord(from: baselineFinding)], to: baselinePath)

      let passed = StructuredGate.run(
        gateName: "swiftlint",
        findings: [currentFinding],
        baselinePath: baselinePath,
        remediation: "Run make baseline-update"
      )

      #expect(passed)
    }
  }

  @Test
  static func runFailsWhenBaselineFileIsAbsentAndCurrentFindingsExist() throws {
    try withTemporaryWorkingDirectory { directoryPath in
      let currentFinding = makeSwiftlintFinding(
        ruleId: "identifier_name",
        file: "Sources/App.swift",
        line: 12,
        column: 5,
        message: "Identifier name should be between 3 and 40 characters long"
      )
      let baselinePath = baselinePath(in: directoryPath)

      let passed = StructuredGate.run(
        gateName: "swiftlint",
        findings: [currentFinding],
        baselinePath: baselinePath,
        remediation: "Run make baseline-update"
      )

      #expect(!passed)
    }
  }

  private static func makeSwiftlintFinding(
    ruleId: String,
    file: String,
    line: Int,
    column: Int,
    message: String
  ) -> Finding {
    Finding(
      tool: "swiftlint",
      ruleId: ruleId,
      file: file,
      line: line,
      column: column,
      severity: .warning,
      message: message
    )
  }

  private static func makeRecord(from finding: Finding) -> BaselineRecord {
    BaselineRecord.from(
      finding,
      firstAdded: "2026-06-08T10:00:00Z",
      lastSeen: "2026-06-08T11:00:00Z"
    )
  }

  private static func baselinePath(in directoryPath: String) -> String {
    "\(directoryPath)/baseline-\(UUID().uuidString).jsonl"
  }

  private static func withTemporaryWorkingDirectory(_ run: (String) throws -> Void) throws {
    let fileManager = FileManager.default
    let originalPath = fileManager.currentDirectoryPath
    let directory = fileManager.temporaryDirectory.appendingPathComponent(
      "swift-mk-structured-gate-\(UUID().uuidString)",
      isDirectory: true
    )
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

    var didChangeDirectory = false
    defer {
      if didChangeDirectory {
        _ = fileManager.changeCurrentDirectoryPath(originalPath)
      }
      try? fileManager.removeItem(at: directory)
    }

    didChangeDirectory = fileManager.changeCurrentDirectoryPath(directory.path)
    try #require(didChangeDirectory)
    try run(directory.path)
  }
}
