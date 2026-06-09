//
//  BaselineRecordTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-08.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - BaselineRecordTests

enum BaselineRecordTests {}

@Test
func recordRoundTripsThroughJSONL() throws {
  let record = makeRecord(
    key: "Sources/App.swift\tidentifier_name",
    firstAdded: "2026-06-08T10:00:00Z",
    lastSeen: "2026-06-08T11:00:00Z"
  )

  let serialized = BaselineStore.serialize([record])
  let parsed = try BaselineStore.parse(serialized)

  #expect(parsed == [record])
  let line = try #require(serialized.split(separator: "\n").first.map(String.init))
  let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
  let dictionary = try #require(object as? [String: String])
  #expect(dictionary.keys.contains("first_added"))
  #expect(dictionary.keys.contains("last_seen"))
}

@Test
func parseSkipsBlankLinesAndHeaderComment() throws {
  let record = makeRecord(
    key: "Sources/App.swift\tidentifier_name",
    firstAdded: "2026-06-08T10:00:00Z",
    lastSeen: "2026-06-08T11:00:00Z"
  )
  let text = "\n# baseline header\n\n\(BaselineStore.serialize([record]))\n"

  let parsed = try BaselineStore.parse(text)

  #expect(parsed == [record])
}

@Test
func recordFromSwiftlintFindingUsesBaselineKeyAndDisplay() {
  let finding = Finding(
    tool: "swiftlint",
    ruleId: "identifier_name",
    file: "Sources/App.swift",
    line: 12,
    column: 5,
    severity: .warning,
    message: "Identifier name should be between 3 and 40 characters long"
  )

  let record = BaselineRecord.from(
    finding,
    firstAdded: "2026-06-08T10:00:00Z",
    lastSeen: "2026-06-08T11:00:00Z"
  )

  #expect(record.tool == "swiftlint")
  #expect(record.rule == "identifier_name")
  #expect(record.file == "Sources/App.swift")
  #expect(record.key == BaselineKey.of(finding))
  #expect(
    record.display
      == "Sources/App.swift:12:5: Identifier name should be between 3 and 40 characters long")
}

@Test
func keyCountsReturnsMultiset() throws {
  let firstRecord = makeRecord(
    key: "shared",
    firstAdded: "2026-06-08T10:00:00Z",
    lastSeen: "2026-06-08T11:00:00Z"
  )
  let secondRecord = makeRecord(
    key: "shared",
    firstAdded: "2026-06-08T10:01:00Z",
    lastSeen: "2026-06-08T11:01:00Z"
  )
  let thirdRecord = makeRecord(
    key: "unique",
    firstAdded: "2026-06-08T10:02:00Z",
    lastSeen: "2026-06-08T11:02:00Z"
  )

  let counts = BaselineStore.keyCounts([firstRecord, secondRecord, thirdRecord])

  #expect(try #require(counts["shared"]) == 2)
  #expect(try #require(counts["unique"]) == 1)
}

@Test
func serializeIsDeterministicAcrossInputOrder() {
  let firstRecord = makeRecord(
    key: "b-key",
    firstAdded: "2026-06-08T10:02:00Z",
    lastSeen: "2026-06-08T11:02:00Z"
  )
  let secondRecord = makeRecord(
    key: "a-key",
    firstAdded: "2026-06-08T10:01:00Z",
    lastSeen: "2026-06-08T11:01:00Z"
  )
  let thirdRecord = makeRecord(
    key: "c-key",
    firstAdded: "2026-06-08T10:03:00Z",
    lastSeen: "2026-06-08T11:03:00Z"
  )

  let firstSerialized = BaselineStore.serialize([firstRecord, secondRecord, thirdRecord])
  let secondSerialized = BaselineStore.serialize([thirdRecord, firstRecord, secondRecord])

  #expect(firstSerialized == secondSerialized)
}

private func makeRecord(
  key: String,
  firstAdded: String,
  lastSeen: String
) -> BaselineRecord {
  BaselineRecord(
    tool: "swiftlint",
    rule: "identifier_name",
    file: "Sources/App.swift",
    key: key,
    display: "Sources/App.swift:12:5: Identifier name should be longer",
    firstAdded: firstAdded,
    lastSeen: lastSeen
  )
}
