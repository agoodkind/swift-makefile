//
//  BaselineRunner+StructuredWrite.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-09.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - Structured Baseline Write

extension BaselineRunner {
  struct Component {
    let label: String
    let baselineEnv: String
    let baselineDefault: String
    var scope: String = ""
  }

  @discardableResult
  static func writeFrom(
    _ component: Component,
    capture: (String, String) -> [Finding],
    mode: BaselineMode
  ) throws -> BaselineUpdateStats {
    Capture.ensureMakeDir()
    let raw = ".make/\(component.label)-baseline.raw.out"
    let findings = ".make/\(component.label)-baseline.out"
    let capturedFindings = capture(raw, findings)
    let currentFindings = scopedFindings(capturedFindings, scopePattern: component.scope)
    let baselinePath = Env.get(component.baselineEnv, component.baselineDefault)
    let oldRecords = BaselineStore.read(baselinePath)
    let now = Baseline.iso8601Now()
    var records = BaselineStore.rewrite(
      current: currentFindings,
      old: oldRecords,
      mode: mode,
      now: now
    )
    records = preservingOutOfScopeRecords(
      records,
      old: oldRecords,
      current: currentFindings,
      mode: mode,
      scopePattern: component.scope
    )
    ensureBaselineDirectory(for: baselinePath)
    try BaselineStore.write(records, to: baselinePath)
    return stats(
      component: component,
      baselinePath: baselinePath,
      old: oldRecords,
      new: records,
      currentCount: currentFindings.count
    )
  }

  static func swiftlintComponent(scope: String = "") -> Component {
    Component(
      label: "swiftlint",
      baselineEnv: "SWIFTLINT_BASELINE",
      baselineDefault: ".swiftlint-baseline.jsonl",
      scope: scope
    )
  }

  private static func scopedFindings(_ findings: [Finding], scopePattern: String) -> [Finding] {
    guard let scope = Text.compile(scopePattern) else {
      return findings
    }
    return findings.filter { findingScopeText($0).contains(scope) }
  }

  private static func preservingOutOfScopeRecords(
    _ records: [BaselineRecord],
    old: [BaselineRecord],
    current: [Finding],
    mode: BaselineMode,
    scopePattern: String
  ) -> [BaselineRecord] {
    guard mode != .acceptNew else {
      return records
    }
    guard let scope = Text.compile(scopePattern) else {
      return records
    }
    let currentKeys = Set(current.map { BaselineKey.of($0) })
    let outOfScopeRecords = old.filter { record in
      guard !currentKeys.contains(record.key) else {
        return false
      }
      return !recordScopeText(record).contains(scope)
    }
    return records + outOfScopeRecords
  }

  private static func findingScopeText(_ finding: Finding) -> String {
    "\(finding.file):\(finding.line):\(finding.column): \(finding.message) (\(finding.ruleId))"
  }

  private static func recordScopeText(_ record: BaselineRecord) -> String {
    "\(record.display) (\(record.rule))"
  }

  private static func ensureBaselineDirectory(for path: String) {
    let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
    guard !directory.isEmpty else {
      return
    }
    do {
      try FileManager.default.createDirectory(
        atPath: directory,
        withIntermediateDirectories: true
      )
    } catch {
      Output.error("baseline: could not create \(directory): \(error)")
    }
  }

  private static func stats(
    component: Component,
    baselinePath: String,
    old: [BaselineRecord],
    new: [BaselineRecord],
    currentCount: Int
  ) -> BaselineUpdateStats {
    let oldKeys = Set(old.map(\.key))
    let newKeys = Set(new.map(\.key))
    return BaselineUpdateStats(
      label: component.label,
      baselinePath: baselinePath,
      scopePattern: component.scope,
      findingsCaptured: currentCount,
      added: newKeys.subtracting(oldKeys).count,
      refreshed: oldKeys.intersection(newKeys).count,
      removed: oldKeys.subtracting(newKeys).count,
      covered: currentCount,
      remaining: newKeys.count
    )
  }
}
