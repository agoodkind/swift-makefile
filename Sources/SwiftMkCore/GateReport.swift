//
//  GateReport.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-06.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - GateRunStatus

public enum GateRunStatus: Sendable {
  case failed
  case ok
}

// MARK: - GateStepResult

public struct GateStepResult: Sendable {
  public let name: String
  public let status: GateRunStatus
  public let note: String?
  public let findings: [String]
  public let remediation: String?

  public init(
    name: String,
    status: GateRunStatus,
    note: String?,
    findings: [String],
    remediation: String?
  ) {
    self.name = name
    self.status = status
    self.note = note
    self.findings = findings
    self.remediation = remediation
  }
}

// MARK: - GateReport

public enum GateReport {
  public static func nameWidth(_ steps: [GateStepResult]) -> Int {
    steps.map(\.name.count).max() ?? 0
  }

  public static func row(width: Int, name: String, cell: String) -> String {
    let paddedName = name.padding(toLength: width, withPad: " ", startingAt: 0)
    return "  \(paddedName)  \(cell)"
  }

  public static func statusLabel(_ step: GateStepResult) -> String {
    switch step.status {
    case .ok:
      return "ok"
    case .failed:
      guard let note = step.note, !note.isEmpty else {
        return "FAILED"
      }
      return "FAILED  (\(note))"
    }
  }

  public static func stepRow(width: Int, step: GateStepResult) -> String {
    row(width: width, name: step.name, cell: statusLabel(step))
  }

  public static func findingsBlock(step: GateStepResult) -> String {
    guard step.status == .failed, !step.findings.isEmpty else {
      return ""
    }
    var lines = [""]
    for finding in step.findings {
      for line in finding.components(separatedBy: "\n") {
        if line.isEmpty {
          lines.append("")
        } else {
          lines.append("    \(line)")
        }
      }
    }
    if let remediation = step.remediation, !remediation.isEmpty {
      lines.append("    Fix: \(remediation)")
    }
    return lines.joined(separator: "\n") + "\n"
  }

  public static func footer(failedNames: [String]) -> String {
    if failedNames.isEmpty {
      return "\nAll checks passed."
    }
    let noun = failedNames.count == 1 ? "check" : "checks"
    return "\n\(failedNames.count) \(noun) failed: \(failedNames.joined(separator: ", "))"
  }

  public static func render(title: String, steps: [GateStepResult]) -> String {
    let width = nameWidth(steps)
    var report = title + "\n"
    for step in steps {
      report += stepRow(width: width, step: step) + "\n"
    }
    for step in steps {
      report += findingsBlock(step: step)
    }
    let failedNames = steps.filter { $0.status == .failed }.map(\.name)
    report += footer(failedNames: failedNames)
    return report
  }
}
