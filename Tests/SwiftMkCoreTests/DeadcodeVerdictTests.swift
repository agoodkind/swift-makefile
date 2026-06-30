//
//  DeadcodeVerdictTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-29.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - DeadcodeVerdictTests

/// Empty namesake type so SwiftLint `file_name` finds a declaration matching
/// `DeadcodeVerdictTests.swift`; the suite is written as free `@Test` functions.
enum DeadcodeVerdictTests {}

@Test
func incompleteMessageEmptyIndexReadsAsBuildFailureNotFlake() {
  let message = IndexCompleteness.incompleteMessage(
    missingCount: 66, expectedCount: 66, logPath: "/logs/missing.log")
  #expect(message.contains("produced no index"))
  #expect(message.contains("0 of 66 sources indexed"))
  #expect(message.contains("Not a flake"))
  #expect(message.contains("/logs/missing.log"))
  #expect(!message.contains("not indexed, not scanning"))
}

@Test
func incompleteMessagePartialIndexNamesUnbuiltTargets() {
  let message = IndexCompleteness.incompleteMessage(
    missingCount: 15, expectedCount: 66, logPath: "/logs/missing.log")
  #expect(message.contains("indexed 51 of 66 sources"))
  #expect(message.contains("15 targets unbuilt"))
  #expect(message.contains("Not a flake"))
}

@Test
func classifyDeadcodeFailureDetectsEmptyIndex() {
  let raw = IndexCompleteness.incompleteMessage(
    missingCount: 66, expectedCount: 66, logPath: "/logs/missing.log")
  let lines = raw.components(separatedBy: "\n")
  #expect(Lint.classifyDeadcodeFailure(rawLines: lines) == .incompleteIndex)
}

@Test
func classifyDeadcodeFailureDetectsPartialIndex() {
  let raw = IndexCompleteness.incompleteMessage(
    missingCount: 15, expectedCount: 66, logPath: "/logs/missing.log")
  let lines = raw.components(separatedBy: "\n")
  #expect(Lint.classifyDeadcodeFailure(rawLines: lines) == .incompleteIndex)
}

@Test
func classifyDeadcodeFailureDetectsCrashedCoverageBuild() {
  let raw = ["lint-deadcode: the coverage build failed status=133; the index store is incomplete"]
  #expect(Lint.classifyDeadcodeFailure(rawLines: raw) == .buildFailed)
}

@Test
func classifyDeadcodeFailureFallsBackToUnknown() {
  let raw = ["periphery: some unexpected error", "Error: Found 1 issue"]
  #expect(Lint.classifyDeadcodeFailure(rawLines: raw) == .unknown)
}

@Test
func deadcodeVerdictRulesOutTheFlakeReflexOnEveryBuildCause() {
  #expect(
    Lint.deadcodeVerdict(.compileError, status: 2).contains("clearing DerivedData will not help"))
  #expect(Lint.deadcodeVerdict(.incompleteIndex, status: 2).contains("Not a transient flake"))
  #expect(Lint.deadcodeVerdict(.buildFailed, status: 133).contains("not a flake"))
  #expect(Lint.deadcodeVerdict(.unknown, status: 7).contains("status 7"))
}
