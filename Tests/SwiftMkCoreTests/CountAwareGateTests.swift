//
//  CountAwareGateTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-08.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - CountAwareGateTests

enum CountAwareGateTests {}

@Test
func contentKeySurvivesAMoveButNotAnEdit() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "swift-mk-contentkey-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer {
    do {
      try FileManager.default.removeItem(at: directory)
    } catch {
      Output.warning("cleanup failed: \(error.localizedDescription)")
    }
  }
  let sourcePath = directory.appendingPathComponent("Worker.swift").path
  let offendingLine = "    let total = price * quantity"
  let message = "Line should be 120 or less"

  // Original tree: the violation sits on line 3, and that is the baselined state.
  let original = ["import Foundation", "", offendingLine, "", "// trailer"]
  try writeSource(original, to: sourcePath)
  let baselined = makeSwiftlintFinding(
    ruleId: "line_length", file: sourcePath, line: 3, column: 1, message: message)
  let baseline = [makeRecord(from: baselined)]

  // Move: same code, now on line 5. The key reads the line text, so it still matches.
  let moved = ["import Foundation", "", "", "", offendingLine, "// trailer"]
  try writeSource(moved, to: sourcePath)
  let movedFinding = makeSwiftlintFinding(
    ruleId: "line_length", file: sourcePath, line: 5, column: 1, message: message)
  let afterMove = CountAwareGate.evaluate(current: [movedFinding], baseline: baseline)
  #expect(afterMove.passed)
  #expect(afterMove.newFindings.isEmpty)

  // Edit: the line's tokens change, so the key changes and the finding reads new.
  let edited = ["import Foundation", "", "", "", "    let total = price * rate", "// trailer"]
  try writeSource(edited, to: sourcePath)
  let editedFinding = makeSwiftlintFinding(
    ruleId: "line_length", file: sourcePath, line: 5, column: 1, message: message)
  let afterEdit = CountAwareGate.evaluate(current: [editedFinding], baseline: baseline)
  #expect(!afterEdit.passed)
  #expect(afterEdit.newFindings == [editedFinding])
}

@Test
func contentKeyCollapsesTwoIdenticalLinesIntoOneCountedKey() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "swift-mk-contentkey-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer {
    do {
      try FileManager.default.removeItem(at: directory)
    } catch {
      Output.warning("cleanup failed: \(error.localizedDescription)")
    }
  }
  let sourcePath = directory.appendingPathComponent("Magic.swift").path
  // Two byte-identical offending lines normalize to the same text.
  try writeSource(["    print(value)", "    print(value)"], to: sourcePath)

  let firstFinding = makeSwiftlintFinding(
    ruleId: "no_magic_numbers", file: sourcePath, line: 1, column: 1, message: "magic")
  let secondFinding = makeSwiftlintFinding(
    ruleId: "no_magic_numbers", file: sourcePath, line: 2, column: 1, message: "magic")

  // Both lines normalize to the same text, so they share one key with count 2.
  #expect(BaselineKey.of(firstFinding) == BaselineKey.of(secondFinding))
  let baseline = [makeRecord(from: firstFinding), makeRecord(from: secondFinding)]
  let evaluation = CountAwareGate.evaluate(
    current: [firstFinding, secondFinding], baseline: baseline)
  #expect(evaluation.passed)
  #expect(evaluation.goneCount == 0)
}

@Test
func evaluatePassesWhenCurrentMatchesBaselineKeysAndCounts() {
  let firstFinding = makeSwiftlintFinding(
    ruleId: "identifier_name",
    file: "Sources/App.swift",
    line: 12,
    column: 5,
    message: "Identifier name should be between 3 and 40 characters long"
  )
  let secondFinding = makeSwiftlintFinding(
    ruleId: "function_body_length",
    file: "Sources/App.swift",
    line: 42,
    column: 1,
    message: "Function body should span 40 lines or less"
  )
  let baseline = [
    makeRecord(from: firstFinding),
    makeRecord(from: secondFinding),
  ]

  let evaluation = CountAwareGate.evaluate(
    current: [firstFinding, secondFinding],
    baseline: baseline
  )

  #expect(evaluation.passed)
  #expect(evaluation.newFindings.isEmpty)
  #expect(evaluation.goneCount == 0)
}

@Test
func evaluatePassesWhenOnlySwiftlintLocationAndMessageDrift() {
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

  let evaluation = CountAwareGate.evaluate(
    current: [currentFinding],
    baseline: [makeRecord(from: baselineFinding)]
  )

  #expect(evaluation.passed)
  #expect(evaluation.newFindings.isEmpty)
  #expect(evaluation.goneCount == 0)
}

@Test
func evaluateFailsWhenSameRuleFindingExceedsBaselineCount() throws {
  let baselineFinding = makeSwiftlintFinding(
    ruleId: "function_body_length",
    file: "Sources/FileA.swift",
    line: 10,
    column: 1,
    message: "Function body should span 40 lines or less"
  )
  let excessFinding = makeSwiftlintFinding(
    ruleId: "function_body_length",
    file: "Sources/FileA.swift",
    line: 80,
    column: 1,
    message: "Function body should span 40 lines or less"
  )

  let evaluation = CountAwareGate.evaluate(
    current: [baselineFinding, excessFinding],
    baseline: [makeRecord(from: baselineFinding)]
  )

  #expect(!evaluation.passed)
  #expect(evaluation.newFindings.count == 1)
  #expect(try #require(evaluation.newFindings.first) == excessFinding)
  #expect(evaluation.goneCount == 0)
}

@Test
func evaluateFailsWhenCurrentFindingHasBrandNewKey() throws {
  let currentFinding = makeSwiftlintFinding(
    ruleId: "identifier_name",
    file: "Sources/NewFile.swift",
    line: 12,
    column: 5,
    message: "Identifier name should be between 3 and 40 characters long"
  )

  let evaluation = CountAwareGate.evaluate(
    current: [currentFinding],
    baseline: []
  )

  #expect(!evaluation.passed)
  #expect(evaluation.newFindings.count == 1)
  #expect(try #require(evaluation.newFindings.first) == currentFinding)
  #expect(evaluation.goneCount == 0)
}

@Test
func evaluateCountsFixedBaselineOccurrences() {
  let fixedFinding = makeSwiftlintFinding(
    ruleId: "identifier_name",
    file: "Sources/App.swift",
    line: 12,
    column: 5,
    message: "Identifier name should be between 3 and 40 characters long"
  )

  let evaluation = CountAwareGate.evaluate(
    current: [],
    baseline: [makeRecord(from: fixedFinding)]
  )

  #expect(evaluation.passed)
  #expect(evaluation.newFindings.isEmpty)
  #expect(evaluation.goneCount == 1)
}

@Test
func evaluatePreservesCurrentOrderForExcessFindings() {
  let firstAllowed = makeSwiftlintFinding(
    ruleId: "identifier_name",
    file: "Sources/App.swift",
    line: 12,
    column: 5,
    message: "Identifier name should be between 3 and 40 characters long"
  )
  let secondAllowed = makeSwiftlintFinding(
    ruleId: "function_body_length",
    file: "Sources/App.swift",
    line: 20,
    column: 1,
    message: "Function body should span 40 lines or less"
  )
  let firstExcess = makeSwiftlintFinding(
    ruleId: "identifier_name",
    file: "Sources/App.swift",
    line: 30,
    column: 8,
    message: "Identifier name should be between 3 and 40 characters long"
  )
  let secondExcess = makeSwiftlintFinding(
    ruleId: "function_body_length",
    file: "Sources/App.swift",
    line: 80,
    column: 1,
    message: "Function body should span 40 lines or less"
  )
  let thirdExcess = makeSwiftlintFinding(
    ruleId: "identifier_name",
    file: "Sources/App.swift",
    line: 90,
    column: 12,
    message: "Identifier name should be between 3 and 40 characters long"
  )
  let current = [firstAllowed, secondAllowed, firstExcess, secondExcess, thirdExcess]
  let baseline = [
    makeRecord(from: firstAllowed),
    makeRecord(from: secondAllowed),
  ]

  let evaluation = CountAwareGate.evaluate(current: current, baseline: baseline)

  #expect(!evaluation.passed)
  #expect(evaluation.newFindings == [firstExcess, secondExcess, thirdExcess])
  #expect(evaluation.goneCount == 0)
}

private func writeSource(_ lines: [String], to path: String) throws {
  let content = lines.joined(separator: "\n") + "\n"
  try content.write(toFile: path, atomically: true, encoding: .utf8)
}

private func makeSwiftlintFinding(
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

private func makeRecord(from finding: Finding) -> BaselineRecord {
  BaselineRecord.from(
    finding,
    firstAdded: "2026-06-08T10:00:00Z",
    lastSeen: "2026-06-08T11:00:00Z"
  )
}
