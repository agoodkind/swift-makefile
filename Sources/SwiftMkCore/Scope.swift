//
//  Scope.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-25.
//

import Foundation

// MARK: - Scope

/// Resolve the scope regex for a scoped swiftlint baseline or run.
public enum Scope {
    /// `SWIFTLINT_BASELINE_SCOPE_PATTERN` verbatim, else `RULE` mapped to the
    /// trailing `(rule_id)` tag, else empty.
    public static func swiftlintPattern() -> String {
        let raw = Env.get("SWIFTLINT_BASELINE_SCOPE_PATTERN")
        if !raw.isEmpty { return raw }
        let rule = Env.get("RULE")
        if !rule.isEmpty { return "\\(\(rule)\\)$" }
        return ""
    }
}

// MARK: - Lint

extension Lint {
    /// Capture only the findings for one rule: run swiftlint (only that rule
    /// when named) and filter to the scope.
    static func captureSwiftlintScope(
        rawPath: String, findingsPath: String, context: PathContext
    ) {
        let rule = Env.get("RULE")
        let onlyRules = rule.isEmpty ? [] : [rule]
        captureSwiftlint(
            rawPath: rawPath, findingsPath: findingsPath, onlyRules: onlyRules, context: context)
        let scoped = Text.filterScope(Text.readLines(findingsPath), Scope.swiftlintPattern())
        do {
            try Text.writeLines(scoped, to: findingsPath)
        } catch {
            Output.error("swiftlint-scope: could not write \(findingsPath): \(error)")
        }
    }

    /// Run and gate a single rule against its slice of the swiftlint baseline.
    @discardableResult
    public static func runSwiftlintScope(context: PathContext) -> Bool {
        let scope = Scope.swiftlintPattern()
        if scope.isEmpty {
            Output.log("lint-swiftlint-scope: set RULE=<id> or SWIFTLINT_BASELINE_SCOPE_PATTERN")
            return false
        }
        Capture.ensureMakeDir()
        let raw = ".make/swiftlint-scope.raw.out"
        let findings = ".make/swiftlint-scope.out"
        captureSwiftlintScope(rawPath: raw, findingsPath: findings, context: context)
        let spec = BaselineSpec(
            findingsPath: findings,
            baselinePath: Env.get("SWIFTLINT_BASELINE", ".swiftlint-baseline.txt"),
            label: "swiftlint",
            excludePattern: swiftlintExclude(),
            scopePattern: scope
        )
        return Baseline.runDiffGate(
            gateName: "swiftlint",
            spec: spec,
            remediation: remediation,
            context: context
        )
    }
}
