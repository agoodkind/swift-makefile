//
//  CachePrunePlannerTests.swift
//  SwiftMkMaintCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-05.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkMaintCore

// MARK: - CachePrunePlannerTests

enum CachePrunePlannerTests {
  struct PlannerCase {
    let name: String
    let entries: [CachePruneEntry]
    let maxBytes: UInt64
    let expectedEvictions: [String]
  }

  @Test
  static func lruOrderEvictsOldestFirstAndStopsAtCap() {
    let entries = [
      entry("newest", size: 40, modifiedAt: 300),
      entry("oldest", size: 35, modifiedAt: 100),
      entry("middle", size: 30, modifiedAt: 200),
    ]

    let evictions = CachePrunePlanner.evictions(entries: entries, maxBytes: 45)

    #expect(evictions.map(\.name) == ["oldest", "middle"])
  }

  @Test
  static func byteCapBoundaryEvictsOnlyWhenOverCap() {
    let cases = [
      PlannerCase(
        name: "exact cap",
        entries: [
          entry("oldest", size: 40, modifiedAt: 100),
          entry("newest", size: 60, modifiedAt: 200),
        ],
        maxBytes: 100,
        expectedEvictions: []),
      PlannerCase(
        name: "one byte over",
        entries: [
          entry("oldest", size: 1, modifiedAt: 100),
          entry("newest", size: 100, modifiedAt: 200),
        ],
        maxBytes: 100,
        expectedEvictions: ["oldest"]),
    ]

    for testCase in cases {
      let evictions = CachePrunePlanner.evictions(
        entries: testCase.entries,
        maxBytes: testCase.maxBytes)

      #expect(
        evictions.map(\.name) == testCase.expectedEvictions,
        "case: \(testCase.name)")
    }
  }

  @Test
  static func temporaryEntriesAreSkippedButStillCountTowardTotal() {
    let cases = [
      PlannerCase(
        name: "old temporary entry is skipped",
        entries: [
          entry(".tmp-download", size: 80, modifiedAt: 100),
          entry("oldest-evictable", size: 30, modifiedAt: 200),
          entry("newest", size: 20, modifiedAt: 300),
        ],
        maxBytes: 100,
        expectedEvictions: ["oldest-evictable"]),
      PlannerCase(
        name: "only temporary entries remain",
        entries: [
          entry(".tmp-a", size: 80, modifiedAt: 100),
          entry(".tmp-b", size: 80, modifiedAt: 200),
        ],
        maxBytes: 100,
        expectedEvictions: []),
    ]

    for testCase in cases {
      let evictions = CachePrunePlanner.evictions(
        entries: testCase.entries,
        maxBytes: testCase.maxBytes)

      #expect(
        evictions.map(\.name) == testCase.expectedEvictions,
        "case: \(testCase.name)")
    }
  }

  @Test
  static func directoryAlreadyUnderCapIsNoOp() {
    let entries = [
      entry("oldest", size: 10, modifiedAt: 100),
      entry("newest", size: 20, modifiedAt: 200),
    ]

    let evictions = CachePrunePlanner.evictions(entries: entries, maxBytes: 40)

    #expect(evictions.isEmpty)
  }

  private static func entry(
    _ name: String,
    size: UInt64,
    modifiedAt timestamp: TimeInterval
  ) -> CachePruneEntry {
    CachePruneEntry(
      name: name,
      size: size,
      modificationDate: Date(timeIntervalSince1970: timestamp))
  }
}
