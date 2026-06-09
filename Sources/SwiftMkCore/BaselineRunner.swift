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

  private static func swiftcheckExclude() -> String {
    Text.excludePattern(
      Env.get("SWIFTCHECK_EXTRA_DEFAULT_EXCLUDE_PATHS"),
      Env.get("SWIFTCHECK_EXTRA_EXCLUDE_PATHS")
    )
  }

  @discardableResult
  public static func updateSwiftlint(
    mode: BaselineMode, context: PathContext
  ) throws -> BaselineUpdateStats? {
    guard tokenGatePasses() else { return nil }
    _ = Lint.runTools(context: context)
    return try writeFrom(
      swiftlintComponent(),
      capture: { raw, _ in
        Lint.captureSwiftlintStructured(
          rawPath: raw,
          onlyRules: [],
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
    guard tokenGatePasses() else { return nil }
    _ = Lint.runTools(context: context)
    let rules = Lint.complexityRules()
    let component = Component(
      label: "swiftlint-complexity",
      baselineEnv: "SWIFTLINT_COMPLEXITY_BASELINE",
      baselineDefault: ".swiftlint-complexity-baseline.jsonl"
    )
    return try writeFrom(
      component,
      capture: { raw, _ in
        Lint.captureSwiftlintStructured(
          rawPath: raw,
          onlyRules: rules,
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
    guard tokenGatePasses() else { return nil }
    _ = Lint.runTools(context: context)
    let component = Component(
      label: "periphery",
      baselineEnv: "PERIPHERY_BASELINE",
      baselineDefault: ".periphery-baseline.jsonl"
    )
    return try writeFrom(
      component,
      capture: { raw, findings in
        Lint.captureDeadcode(rawPath: raw, findingsPath: findings, context: context)
        return Lint.parseDeadcodeFindings(findingsPath: findings, context: context)
      },
      mode: mode
    )
  }

  @discardableResult
  public static func updateSwiftcheck(
    mode: BaselineMode, context: PathContext
  ) throws -> BaselineUpdateStats? {
    guard tokenGatePasses() else { return nil }
    _ = Swiftcheck.resolveBin()
    let component = Component(
      label: "swiftcheck-extra",
      baselineEnv: "SWIFTCHECK_EXTRA_BASELINE",
      baselineDefault: ".swiftcheck-extra-baseline.jsonl"
    )
    return try writeFrom(
      component,
      capture: { raw, findings in
        Swiftcheck.captureFindings(rawPath: raw, findingsPath: findings, context: context)
        return Swiftcheck.structuredFindings(
          rawPath: raw,
          exclude: swiftcheckExclude(),
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
    guard tokenGatePasses() else { return nil }
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

  public static func update(component: String, context: PathContext) throws {
    let mode = self.mode()
    switch component {
    case "all":
      var stats: [BaselineUpdateStats] = []
      if let value = try updateSwiftlint(mode: mode, context: context) {
        stats.append(value)
      }
      if let value = try updateComplexity(mode: mode, context: context) {
        stats.append(value)
      }
      if let value = try updateDeadcode(mode: mode, context: context) {
        stats.append(value)
      }
      if let value = try updateSwiftcheck(mode: mode, context: context) {
        stats.append(value)
      }
      BaselineReport.renderRollup(stats)
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
