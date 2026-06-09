//
//  StructuredGate.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-08.
//  Copyright © 2026, all rights reserved.
//

// MARK: - StructuredGate

public enum StructuredGate {
  /// Read the JSONL baseline, evaluate current findings, render the gate result,
  /// and record failed gates through the same boundary as the text baseline gate.
  @discardableResult
  public static func run(
    gateName: String,
    findings: [Finding],
    baselinePath: String,
    remediation: String
  ) -> Bool {
    let baseline = BaselineStore.read(baselinePath)
    let result = CountAwareGate.evaluate(current: findings, baseline: baseline)

    if !result.passed {
      Output.log("\(gateName): FAILED")
      Output.log("  New findings: \(result.newFindings.count)\n")
      Output.log("Findings:")
      for finding in result.newFindings {
        Output.log("  \(finding.file):\(finding.line):\(finding.column)\n    \(finding.message)")
      }
      Output.log("\n  \(remediation)")
      Baseline.recordFailedGate(gateName)
      return false
    }

    Output.log("\(gateName): OK")
    Output.log("  New findings: 0")
    if result.goneCount > 0 {
      Output.log("  Saved findings now fixed: \(result.goneCount)")
    }
    return true
  }
}
