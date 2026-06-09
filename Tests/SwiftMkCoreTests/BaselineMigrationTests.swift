//
//  BaselineMigrationTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-08.
//  Copyright © 2026, all rights reserved.
//

import Testing

@testable import SwiftMkCore

// MARK: - BaselineMigrationTests

enum BaselineMigrationTests {}

// MARK: - Fixtures

private let swiftlintComplexityFirstLine =
  "Sources/Helper/SMCFanHelper.swift:321:5: error: Cyclomatic Complexity Violation: "
  + "Function should have complexity 10 or less; currently complexity is 14 "
  + "(cyclomatic_complexity)\t# swiftlint-complexity:first_added=2026-06-06T23:27:35Z "
  + "last_seen=2026-06-06T23:27:35Z"

private let swiftlintComplexitySecondLine =
  "Sources/Helper/SMCFanHelper.swift:195:5: error: Function Body Length Violation: "
  + "Function body should span 60 lines or less excluding comments and whitespace: "
  + "currently spans 66 lines (function_body_length)\t# swiftlint-complexity:"
  + "first_added=2026-06-06T23:27:35Z last_seen=2026-06-06T23:27:35Z"

private let swiftcheckExtraLine =
  "Sources/AppLog/BuildInfo.swift:21:24: silent_try: handle throwing calls "
  + "explicitly instead of try?\t# swiftcheck-extra:first_added=2026-06-06T23:28:46Z "
  + "last_seen=2026-06-06T23:28:46Z"

private let peripheryLine =
  "Sources/SMCFanKit/SMCFanKey.swift:10:1: warning: Unused imported module "
  + "'SMCKit'\t# periphery:first_added=2026-06-06T23:28:45Z "
  + "last_seen=2026-06-06T23:28:45Z"

@Test
func migratesSwiftlintComplexityLines() throws {
  let records = try BaselineMigration.recordsFromTextBaseline(
    label: "swiftlint-complexity",
    lines: [swiftlintComplexityFirstLine, swiftlintComplexitySecondLine]
  )

  #expect(records.count == 2)
  let firstRecord = try #require(records.first)
  #expect(firstRecord.tool == "swiftlint")
  #expect(firstRecord.file == "Sources/Helper/SMCFanHelper.swift")
  #expect(firstRecord.rule == "cyclomatic_complexity")
  #expect(firstRecord.firstAdded == "2026-06-06T23:27:35Z")
  #expect(firstRecord.lastSeen == "2026-06-06T23:27:35Z")
  #expect(firstRecord.key == "Sources/Helper/SMCFanHelper.swift\tcyclomatic_complexity")

  let secondRecord = try #require(records.dropFirst().first)
  #expect(secondRecord.tool == "swiftlint")
  #expect(secondRecord.file == "Sources/Helper/SMCFanHelper.swift")
  #expect(secondRecord.rule == "function_body_length")
  #expect(secondRecord.firstAdded == "2026-06-06T23:27:35Z")
  #expect(secondRecord.lastSeen == "2026-06-06T23:27:35Z")
  #expect(secondRecord.key == "Sources/Helper/SMCFanHelper.swift\tfunction_body_length")
}

@Test
func migratesSwiftcheckExtraLine() throws {
  let records = try BaselineMigration.recordsFromTextBaseline(
    label: "swiftcheck-extra",
    lines: [swiftcheckExtraLine]
  )

  #expect(records.count == 1)
  let record = try #require(records.first)
  #expect(record.tool == "swiftcheck-extra")
  #expect(record.file == "Sources/AppLog/BuildInfo.swift")
  #expect(record.rule == "silent_try")
  #expect(record.key == "Sources/AppLog/BuildInfo.swift\tsilent_try")
  #expect(record.firstAdded == "2026-06-06T23:28:46Z")
}

@Test
func skipsHeaderCommentsAndBlankLines() throws {
  let records = try BaselineMigration.recordsFromTextBaseline(
    label: "swiftcheck-extra",
    lines: [
      "# swiftcheck-extra: generated_at=2026-06-06T23:28:46Z",
      "   ",
      "  # swiftcheck-extra: generated_at=2026-06-06T23:28:46Z",
      swiftcheckExtraLine,
    ]
  )

  #expect(records.count == 1)
  #expect(records.first?.rule == "silent_try")
}

@Test
func migratesPeripheryLine() throws {
  let records = try BaselineMigration.recordsFromTextBaseline(
    label: "periphery",
    lines: [peripheryLine]
  )

  #expect(records.count == 1)
  let record = try #require(records.first)
  #expect(record.tool == "periphery")
  #expect(record.key == "Sources/SMCFanKit/SMCFanKey.swift\tSMCKit")
  #expect(record.firstAdded == "2026-06-06T23:28:45Z")
}

@Test
func rejectsPeripheryLineWithoutSingleQuotedToken() {
  let line =
    "Sources/SMCFanKit/SMCFanKey.swift:10:1: warning: Unused imported module SMCKit"

  #expect(throws: BaselineMigration.MigrationError.unparsableLine(line)) {
    try BaselineMigration.recordsFromTextBaseline(label: "periphery", lines: [line])
  }
}

@Test
func preservesDuplicateKeyCounts() throws {
  let firstLine =
    "Sources/Helper/SMCFanHelper.swift:321:5: error: Cyclomatic Complexity Violation: "
    + "Function should have complexity 10 or less; currently complexity is 14 "
    + "(cyclomatic_complexity)\t# swiftlint-complexity:"
    + "first_added=2026-06-06T23:27:35Z last_seen=2026-06-06T23:27:35Z"
  let secondLine =
    "Sources/Helper/SMCFanHelper.swift:400:7: error: Cyclomatic Complexity Violation: "
    + "Function should have complexity 10 or less; currently complexity is 15 "
    + "(cyclomatic_complexity)\t# swiftlint-complexity:"
    + "first_added=2026-06-06T23:27:35Z last_seen=2026-06-06T23:27:35Z"

  let records = try BaselineMigration.recordsFromTextBaseline(
    label: "swiftlint-complexity",
    lines: [firstLine, secondLine]
  )
  let counts = BaselineStore.keyCounts(records)
  let key = "Sources/Helper/SMCFanHelper.swift\tcyclomatic_complexity"

  #expect(records.count == 2)
  #expect(records.first?.key == key)
  #expect(records.dropFirst().first?.key == key)
  #expect(try #require(counts[key]) == 2)
}
