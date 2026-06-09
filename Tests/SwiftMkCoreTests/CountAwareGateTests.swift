//
//  CountAwareGateTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-08.
//  Copyright © 2026, all rights reserved.
//

import Testing

@testable import SwiftMkCore

// MARK: - CountAwareGateTests

enum CountAwareGateTests {}

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
