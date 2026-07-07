//
//  CachePrunePlanner.swift
//  SwiftMkMaintCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-05.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - CachePruneEntry

public struct CachePruneEntry: Equatable {
  public let name: String
  public let size: UInt64
  public let modificationDate: Date

  public init(
    name: String,
    size: UInt64,
    modificationDate: Date
  ) {
    self.name = name
    self.size = size
    self.modificationDate = modificationDate
  }
}

// MARK: - CachePrunePlanner

public enum CachePrunePlanner {
  public static func evictions(
    entries: [CachePruneEntry],
    maxBytes: UInt64
  ) -> [CachePruneEntry] {
    var remainingBytes = totalSize(entries)
    if remainingBytes <= maxBytes {
      return []
    }

    // Top-level `.tmp*` entries are in-flight cache writes. Their bytes still count
    // toward the measured total, but the planner never returns them for eviction.
    let candidates =
      entries
      .filter { !$0.name.hasPrefix(".tmp") }
      .sorted { left, right in
        if left.modificationDate == right.modificationDate {
          return left.name < right.name
        }
        return left.modificationDate < right.modificationDate
      }

    var evictions: [CachePruneEntry] = []
    for candidate in candidates {
      if remainingBytes <= maxBytes {
        break
      }
      evictions.append(candidate)
      remainingBytes = subtract(candidate.size, from: remainingBytes)
    }
    return evictions
  }

  public static func totalSize(_ entries: [CachePruneEntry]) -> UInt64 {
    var total: UInt64 = 0
    for entry in entries {
      total = add(total, entry.size)
    }
    return total
  }

  static func remainingSize(
    totalBytes: UInt64,
    evictedEntries: [CachePruneEntry]
  ) -> UInt64 {
    var remainingBytes = totalBytes
    for entry in evictedEntries {
      remainingBytes = subtract(entry.size, from: remainingBytes)
    }
    return remainingBytes
  }

  static func add(_ left: UInt64, _ right: UInt64) -> UInt64 {
    let result = left.addingReportingOverflow(right)
    if result.overflow {
      return UInt64.max
    }
    return result.partialValue
  }

  private static func subtract(_ size: UInt64, from total: UInt64) -> UInt64 {
    if size >= total {
      return 0
    }
    return total - size
  }
}
