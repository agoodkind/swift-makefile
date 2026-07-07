//
//  GateReportTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-06.
//  Copyright © 2026, all rights reserved.
//

import Testing

@testable import SwiftMkCore

// MARK: - GateReportTests

enum GateReportTests {
  private static let cleanStep = GateStepResult(
    name: "lint-format",
    status: .ok,
    note: nil,
    findings: [],
    remediation: nil)

  private static let failedStep = GateStepResult(
    name: "swiftcheck-extra",
    status: .failed,
    note: "2 findings",
    findings: [
      "swiftcheck-extra: FAILED",
      "Sources/App.swift:1:1\n  fix this symbol",
    ],
    remediation: "Fix these violations before this gate will pass.")

  @Test
  static func formatsRowsAndLabels() {
    let steps = [cleanStep, failedStep]

    #expect(GateReport.nameWidth(steps) == 16)
    #expect(GateReport.statusLabel(cleanStep) == "ok")
    #expect(GateReport.statusLabel(failedStep) == "FAILED  (2 findings)")
    #expect(GateReport.row(width: 16, name: "lint-format", cell: "ok") == "  lint-format       ok")
    #expect(
      GateReport.stepRow(width: 16, step: failedStep) == "  swiftcheck-extra  FAILED  (2 findings)")
  }

  @Test
  static func formatsFindingsBlockOnlyForFailedStepsWithFindings() {
    #expect(GateReport.findingsBlock(step: cleanStep).isEmpty)
    #expect(
      GateReport.findingsBlock(step: failedStep)
        == "\n"
        + "    swiftcheck-extra: FAILED\n"
        + "    Sources/App.swift:1:1\n"
        + "      fix this symbol\n"
        + "    Fix: Fix these violations before this gate will pass.\n")
  }

  @Test
  static func formatsFooterWithExistingVerdictWording() {
    #expect(GateReport.footer(failedNames: []) == "\nAll checks passed.")
    #expect(GateReport.footer(failedNames: ["lint-format"]) == "\n1 check failed: lint-format")
    #expect(
      GateReport.footer(failedNames: ["lint-format", "swiftcheck-extra"])
        == "\n2 checks failed: lint-format, swiftcheck-extra")
  }

  @Test
  static func renderMatchesStreamedAssemblyByteForByte() {
    let steps = [cleanStep, failedStep]
    let width = GateReport.nameWidth(steps)
    let rows = steps.map { GateReport.stepRow(width: width, step: $0) }
    let findings = steps.map(GateReport.findingsBlock(step:)).joined()
    let failedNames = steps.filter { $0.status == .failed }.map(\.name)
    let streamed =
      "Lint gates\n"
      + rows.map { $0 + "\n" }.joined()
      + findings
      + GateReport.footer(failedNames: failedNames)
    let expected =
      "Lint gates\n"
      + "  lint-format       ok\n"
      + "  swiftcheck-extra  FAILED  (2 findings)\n"
      + "\n"
      + "    swiftcheck-extra: FAILED\n"
      + "    Sources/App.swift:1:1\n"
      + "      fix this symbol\n"
      + "    Fix: Fix these violations before this gate will pass.\n"
      + "\n"
      + "1 check failed: swiftcheck-extra"

    #expect(GateReport.render(title: "Lint gates", steps: steps) == streamed)
    #expect(GateReport.render(title: "Lint gates", steps: steps) == expected)
  }
}
