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
        TokenGate.passes(
            confirmValue: Env.get("BASELINE_CONFIRM"),
            tokenValue: Env.get("BASELINE_TOKEN"),
            tokenCommand: Env.get("BASELINE_TOKEN_CMD", Env.get("SWIFT_MK_GATE_TOKEN_CMD"))
        )
    }

    private static func swiftcheckExclude() -> String {
        Text.excludePattern(
            Env.get("SWIFTCHECK_EXTRA_DEFAULT_EXCLUDE_PATHS"),
            Env.get("SWIFTCHECK_EXTRA_EXCLUDE_PATHS")
        )
    }

    /// Static description of one component baseline: how it is titled and
    /// labeled, where its baseline file lives, and how it filters findings.
    private struct Component {
        let title: String
        let label: String
        let baselineEnv: String
        let baselineDefault: String
        let exclude: String
        var scope: String = ""
    }

    /// Capture findings for a component and rewrite its baseline, returning the
    /// neutral counts describing what changed.
    @discardableResult
    private static func writeFrom(
        _ component: Component,
        capture: (String, String) -> Void,
        mode: BaselineMode,
        context: PathContext
    ) throws -> BaselineUpdateStats {
        Capture.ensureMakeDir()
        let raw = ".make/\(component.label)-baseline.raw.out"
        let findings = ".make/\(component.label)-baseline.out"
        capture(raw, findings)
        let spec = BaselineSpec(
            findingsPath: findings,
            baselinePath: Env.get(component.baselineEnv, component.baselineDefault),
            label: component.label,
            excludePattern: component.exclude,
            scopePattern: component.scope
        )
        return try Baseline.writeComponent(
            title: component.title, spec, mode: mode, context: context)
    }

    private static func swiftlintComponent(scope: String = "") -> Component {
        Component(
            title: "swiftlint",
            label: "swiftlint",
            baselineEnv: "SWIFTLINT_BASELINE",
            baselineDefault: ".swiftlint-baseline.txt",
            exclude: Lint.swiftlintExclude(),
            scope: scope
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
            capture: { raw, findings in
                Lint.captureSwiftlint(
                    rawPath: raw,
                    findingsPath: findings,
                    onlyRules: [],
                    context: context
                )
            },
            mode: mode,
            context: context
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
            title: "swiftlint-complexity",
            label: "swiftlint-complexity",
            baselineEnv: "SWIFTLINT_COMPLEXITY_BASELINE",
            baselineDefault: ".swiftlint-complexity-baseline.txt",
            exclude: Lint.swiftlintExclude()
        )
        return try writeFrom(
            component,
            capture: { raw, findings in
                Lint.captureSwiftlint(
                    rawPath: raw,
                    findingsPath: findings,
                    onlyRules: rules,
                    context: context
                )
            },
            mode: mode,
            context: context
        )
    }

    @discardableResult
    public static func updateDeadcode(
        mode: BaselineMode, context: PathContext
    ) throws -> BaselineUpdateStats? {
        guard tokenGatePasses() else { return nil }
        _ = Lint.runTools(context: context)
        let component = Component(
            title: "periphery",
            label: "periphery",
            baselineEnv: "PERIPHERY_BASELINE",
            baselineDefault: ".periphery-baseline.txt",
            exclude: Lint.peripheryExclude()
        )
        return try writeFrom(
            component,
            capture: { Lint.captureDeadcode(rawPath: $0, findingsPath: $1, context: context) },
            mode: mode,
            context: context
        )
    }

    @discardableResult
    public static func updateSwiftcheck(
        mode: BaselineMode, context: PathContext
    ) throws -> BaselineUpdateStats? {
        guard tokenGatePasses() else { return nil }
        _ = Swiftcheck.resolveBin()
        let component = Component(
            title: "swiftcheck-extra",
            label: "swiftcheck-extra",
            baselineEnv: "SWIFTCHECK_EXTRA_BASELINE",
            baselineDefault: ".swiftcheck-extra-baseline.txt",
            exclude: swiftcheckExclude()
        )
        return try writeFrom(
            component,
            capture: { raw, findings in
                Swiftcheck.captureFindings(rawPath: raw, findingsPath: findings, context: context)
            },
            mode: mode,
            context: context
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
        return try writeFrom(
            swiftlintComponent(scope: scope),
            capture: { raw, findings in
                Lint.captureSwiftlintScope(rawPath: raw, findingsPath: findings, context: context)
            },
            mode: mode,
            context: context
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
        return try writeFrom(
            swiftlintComponent(scope: scope),
            capture: { raw, findings in
                Lint.captureSwiftlintScope(rawPath: raw, findingsPath: findings, context: context)
            },
            mode: .sync,
            context: context
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
