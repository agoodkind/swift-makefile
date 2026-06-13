//
//  BaselineRunner.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-25.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - BaselineRunner

/// Drive baseline updates per component. Port of `scripts/swift-mk-baseline.sh`.
public enum BaselineRunner {
  enum RunnerError: Error, Equatable {
    case unsupportedComponent(String)
  }

  public static func mode() -> BaselineMode {
    BaselineMode(argument: Env.get("BASELINE_UPDATE_MODE", "sync")) ?? .sync
  }

  static func tokenGatePasses() -> Bool {
    TokenGate.passesNative(
      confirmValue: Env.get("BASELINE_CONFIRM"),
      tokenValue: Env.get("BASELINE_TOKEN"),
      tokenCommandOverride: Env.get("BASELINE_TOKEN_CMD")
    )
  }

  static func tokenGateRefusalMessage() -> String {
    "baseline: refused: token gate not satisfied (set BASELINE_CONFIRM and BASELINE_"
      + "TOKEN); no baseline was written"
  }

  static func tokenGatePassesOrReportsRefusal() -> Bool {
    guard tokenGatePasses() else {
      Output.logError(tokenGateRefusalMessage())
      return false
    }
    return true
  }

  private static func swiftcheckExclude() -> String {
    Text.excludePattern(
      Env.get("SWIFTCHECK_EXTRA_DEFAULT_EXCLUDE_PATHS"),
      Env.get("SWIFTCHECK_EXTRA_EXCLUDE_PATHS")
    )
  }

  static func captureStructuredFindings(
    label: String,
    rawPath: String,
    findingsPath: String,
    context: PathContext
  ) throws -> [Finding] {
    switch label {
    case "swiftlint":
      return captureSwiftlintFindings(rawPath: rawPath, context: context)
    case "swiftlint-complexity":
      return captureComplexityFindings(rawPath: rawPath, context: context)
    case "periphery":
      return captureDeadcodeFindings(
        rawPath: rawPath,
        findingsPath: findingsPath,
        context: context
      )
    case "swiftcheck-extra":
      return captureSwiftcheckFindings(
        rawPath: rawPath,
        findingsPath: findingsPath,
        context: context
      )
    default:
      throw RunnerError.unsupportedComponent(label)
    }
  }

  private static func captureSwiftlintFindings(
    rawPath: String,
    context: PathContext
  ) -> [Finding] {
    Lint.captureSwiftlintStructured(
      rawPath: rawPath,
      onlyRules: [],
      context: context
    )
  }

  private static func captureComplexityFindings(
    rawPath: String,
    context: PathContext
  ) -> [Finding] {
    Lint.captureSwiftlintStructured(
      rawPath: rawPath,
      onlyRules: Lint.complexityRules(),
      context: context
    )
  }

  private static func captureDeadcodeFindings(
    rawPath: String,
    findingsPath: String,
    context: PathContext
  ) -> [Finding] {
    Lint.captureDeadcode(rawPath: rawPath, findingsPath: findingsPath, context: context)
    return Lint.parseDeadcodeFindings(findingsPath: findingsPath, context: context)
  }

  private static func captureSwiftcheckFindings(
    rawPath: String,
    findingsPath: String,
    context: PathContext
  ) -> [Finding] {
    Swiftcheck.captureFindings(rawPath: rawPath, findingsPath: findingsPath, context: context)
    return Swiftcheck.structuredFindings(
      rawPath: rawPath,
      exclude: swiftcheckExclude(),
      context: context
    )
  }

  @discardableResult
  public static func updateSwiftlint(
    mode: BaselineMode, context: PathContext
  ) throws -> BaselineUpdateStats? {
    guard tokenGatePassesOrReportsRefusal() else { return nil }
    _ = Lint.runTools(context: context)
    return try writeFrom(
      swiftlintComponent(),
      capture: { raw, findings in
        try captureStructuredFindings(
          label: "swiftlint",
          rawPath: raw,
          findingsPath: findings,
          context: context
        )
      },
      mode: mode
    )
  }

  @discardableResult
  public static func updateComplexity(
    mode: BaselineMode, context: PathContext
  ) throws -> BaselineUpdateStats? {
    guard tokenGatePassesOrReportsRefusal() else { return nil }
    _ = Lint.runTools(context: context)
    let component = Component(
      label: "swiftlint-complexity",
      baselineEnv: "SWIFTLINT_COMPLEXITY_BASELINE",
      baselineDefault: ".swiftlint-complexity-baseline.jsonl"
    )
    return try writeFrom(
      component,
      capture: { raw, findings in
        try captureStructuredFindings(
          label: "swiftlint-complexity",
          rawPath: raw,
          findingsPath: findings,
          context: context
        )
      },
      mode: mode
    )
  }

  @discardableResult
  public static func updateDeadcode(
    mode: BaselineMode, context: PathContext
  ) throws -> BaselineUpdateStats? {
    guard tokenGatePassesOrReportsRefusal() else { return nil }
    _ = Lint.runTools(context: context)
    let component = Component(
      label: "periphery",
      baselineEnv: "PERIPHERY_BASELINE",
      baselineDefault: ".periphery-baseline.jsonl"
    )
    return try writeFrom(
      component,
      capture: { raw, findings in
        try captureStructuredFindings(
          label: "periphery",
          rawPath: raw,
          findingsPath: findings,
          context: context
        )
      },
      mode: mode
    )
  }

  @discardableResult
  public static func updateSwiftcheck(
    mode: BaselineMode, context: PathContext
  ) throws -> BaselineUpdateStats? {
    guard tokenGatePassesOrReportsRefusal() else { return nil }
    _ = Swiftcheck.resolveBin()
    let component = Component(
      label: "swiftcheck-extra",
      baselineEnv: "SWIFTCHECK_EXTRA_BASELINE",
      baselineDefault: ".swiftcheck-extra-baseline.jsonl"
    )
    return try writeFrom(
      component,
      capture: { raw, findings in
        try captureStructuredFindings(
          label: "swiftcheck-extra",
          rawPath: raw,
          findingsPath: findings,
          context: context
        )
      },
      mode: mode
    )
  }

  /// Token-gated scoped swiftlint baseline. Refuses to run unscoped.
  @discardableResult
  public static func updateSwiftlintScope(
    mode: BaselineMode, context: PathContext
  ) throws -> BaselineUpdateStats? {
    let scope = Scope.swiftlintPattern()
    guard !scope.isEmpty else {
      Output.log(
        "swiftlint scope baseline: set RULE=<id> or SWIFTLINT_BASELINE_SCOPE_PATTERN")
      return nil
    }
    guard tokenGatePassesOrReportsRefusal() else { return nil }
    _ = Lint.runTools(context: context)
    let rule = Env.get("RULE")
    let onlyRules = rule.isEmpty ? [] : [rule]
    return try writeFrom(
      swiftlintComponent(scope: scope),
      capture: { raw, _ in
        Lint.captureSwiftlintStructured(
          rawPath: raw,
          onlyRules: onlyRules,
          context: context
        )
      },
      mode: mode
    )
  }

  /// Token-free, scope-limited swiftlint baseline used by the notice rollout.
  @discardableResult
  public static func autoBaselineSwiftlintScope(
    context: PathContext
  ) throws -> BaselineUpdateStats? {
    let scope = Scope.swiftlintPattern()
    guard !scope.isEmpty else {
      Output.log("auto-baseline: missing scope; set RULE or SWIFTLINT_BASELINE_SCOPE_PATTERN")
      return nil
    }
    _ = Lint.runTools(context: context)
    let rule = Env.get("RULE")
    let onlyRules = rule.isEmpty ? [] : [rule]
    return try writeFrom(
      swiftlintComponent(scope: scope),
      capture: { raw, _ in
        Lint.captureSwiftlintStructured(
          rawPath: raw,
          onlyRules: onlyRules,
          context: context
        )
      },
      mode: .sync
    )
  }

  private static func append(_ value: BaselineUpdateStats?, to stats: inout [BaselineUpdateStats]) {
    guard let value else { return }
    stats.append(value)
  }

  private static func updateAll(mode: BaselineMode, context: PathContext) throws {
    guard tokenGatePassesOrReportsRefusal() else { return }
    var stats: [BaselineUpdateStats] = []
    append(try updateSwiftlint(mode: mode, context: context), to: &stats)
    append(try updateComplexity(mode: mode, context: context), to: &stats)
    append(try updateDeadcode(mode: mode, context: context), to: &stats)
    append(try updateSwiftcheck(mode: mode, context: context), to: &stats)
    BaselineReport.renderRollup(stats)
  }

  public static func update(component: String, context: PathContext) throws {
    let mode = self.mode()
    switch component {
    case "all":
      try updateAll(mode: mode, context: context)
    case "swiftlint":
      if let value = try updateSwiftlint(mode: mode, context: context) {
        BaselineReport.renderSingle(value)
      }
    case "complexity":
      if let value = try updateComplexity(mode: mode, context: context) {
        BaselineReport.renderSingle(value)
      }
    case "deadcode":
      if let value = try updateDeadcode(mode: mode, context: context) {
        BaselineReport.renderSingle(value)
      }
    case "swiftcheck-extra":
      if let value = try updateSwiftcheck(mode: mode, context: context) {
        BaselineReport.renderSingle(value)
      }
    case "swiftlint-scope":
      if let value = try updateSwiftlintScope(mode: mode, context: context) {
        BaselineReport.renderSingle(value)
      }
    case "auto-baseline-scope":
      if let value = try autoBaselineSwiftlintScope(context: context) {
        BaselineReport.renderSingle(value)
      }
    default:
      Output.emitStandardError("baseline: unknown component \(component)\n")
    }
  }
}
