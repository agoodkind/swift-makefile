//
//  CountAwareGate.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-08.
//  Copyright © 2026, all rights reserved.
//

// MARK: - GateEvaluation

public struct GateEvaluation: Sendable, Equatable {
  public let passed: Bool
  public let newFindings: [Finding]
  public let goneCount: Int

  public init(passed: Bool, newFindings: [Finding], goneCount: Int) {
    self.passed = passed
    self.newFindings = newFindings
    self.goneCount = goneCount
  }
}

// MARK: - CountAwareGate

public enum CountAwareGate {
  public static func evaluate(
    current: [Finding],
    baseline: [BaselineRecord]
  ) -> GateEvaluation {
    let allowed = BaselineStore.keyCounts(baseline)
    let currentCounts = keyCounts(current)
    var remainingAllowance = allowed
    var newFindings: [Finding] = []

    for finding in current {
      let key = BaselineKey.of(finding)
      let remaining = remainingAllowance[key] ?? 0
      if remaining > 0 {
        remainingAllowance[key] = remaining - 1
      } else {
        newFindings.append(finding)
      }
    }

    var goneCount = 0
    for (key, allowedCount) in allowed {
      let currentCount = currentCounts[key] ?? 0
      if allowedCount > currentCount {
        goneCount += allowedCount - currentCount
      }
    }

    return GateEvaluation(
      passed: newFindings.isEmpty,
      newFindings: newFindings,
      goneCount: goneCount
    )
  }

  private static func keyCounts(_ findings: [Finding]) -> [String: Int] {
    var counts: [String: Int] = [:]
    for finding in findings {
      counts[BaselineKey.of(finding), default: 0] += 1
    }
    return counts
  }
}
