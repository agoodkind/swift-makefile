import Foundation

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

    /// Capture findings for a component and rewrite its baseline.
    private static func writeFrom(
        _ component: Component,
        capture: (String, String) -> Void,
        mode: BaselineMode,
        context: PathContext
    ) throws {
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
        try Baseline.writeComponent(title: component.title, spec, mode: mode, context: context)
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

    public static func updateSwiftlint(mode: BaselineMode, context: PathContext) throws {
        guard tokenGatePasses() else { return }
        _ = Lint.runTools(context: context)
        try writeFrom(
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

    public static func updateComplexity(mode: BaselineMode, context: PathContext) throws {
        guard tokenGatePasses() else { return }
        _ = Lint.runTools(context: context)
        let rules = Lint.complexityRules()
        let component = Component(
            title: "swiftlint-complexity",
            label: "swiftlint-complexity",
            baselineEnv: "SWIFTLINT_COMPLEXITY_BASELINE",
            baselineDefault: ".swiftlint-complexity-baseline.txt",
            exclude: Lint.swiftlintExclude()
        )
        try writeFrom(
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

    public static func updateDeadcode(mode: BaselineMode, context: PathContext) throws {
        guard tokenGatePasses() else { return }
        _ = Lint.runTools(context: context)
        let component = Component(
            title: "periphery",
            label: "periphery",
            baselineEnv: "PERIPHERY_BASELINE",
            baselineDefault: ".periphery-baseline.txt",
            exclude: Lint.peripheryExclude()
        )
        try writeFrom(
            component,
            capture: { Lint.captureDeadcode(rawPath: $0, findingsPath: $1, context: context) },
            mode: mode,
            context: context
        )
    }

    public static func updateSwiftcheck(mode: BaselineMode, context: PathContext) throws {
        guard tokenGatePasses() else { return }
        _ = Swiftcheck.resolveBin()
        let component = Component(
            title: "swiftcheck-extra",
            label: "swiftcheck-extra",
            baselineEnv: "SWIFTCHECK_EXTRA_BASELINE",
            baselineDefault: ".swiftcheck-extra-baseline.txt",
            exclude: swiftcheckExclude()
        )
        try writeFrom(
            component,
            capture: { raw, findings in
                Swiftcheck.captureFindings(rawPath: raw, findingsPath: findings, context: context)
            },
            mode: mode,
            context: context
        )
    }

    /// Token-gated scoped swiftlint baseline. Refuses to run unscoped.
    public static func updateSwiftlintScope(mode: BaselineMode, context: PathContext) throws {
        let scope = Scope.swiftlintPattern()
        guard !scope.isEmpty else {
            Output.log(
                "swiftlint scope baseline: set RULE=<id> or SWIFTLINT_BASELINE_SCOPE_PATTERN")
            return
        }
        guard tokenGatePasses() else { return }
        _ = Lint.runTools(context: context)
        try writeFrom(
            swiftlintComponent(scope: scope),
            capture: { raw, findings in
                Lint.captureSwiftlintScope(rawPath: raw, findingsPath: findings, context: context)
            },
            mode: mode,
            context: context
        )
    }

    /// Token-free, scope-limited swiftlint baseline used by the notice rollout.
    public static func autoBaselineSwiftlintScope(context: PathContext) throws {
        let scope = Scope.swiftlintPattern()
        guard !scope.isEmpty else {
            Output.log("auto-baseline: missing scope; set RULE or SWIFTLINT_BASELINE_SCOPE_PATTERN")
            return
        }
        _ = Lint.runTools(context: context)
        try writeFrom(
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
            try updateSwiftlint(mode: mode, context: context)
            try updateComplexity(mode: mode, context: context)
            try updateDeadcode(mode: mode, context: context)
            try updateSwiftcheck(mode: mode, context: context)
        case "swiftlint": try updateSwiftlint(mode: mode, context: context)
        case "complexity": try updateComplexity(mode: mode, context: context)
        case "deadcode": try updateDeadcode(mode: mode, context: context)
        case "swiftcheck-extra": try updateSwiftcheck(mode: mode, context: context)
        case "swiftlint-scope": try updateSwiftlintScope(mode: mode, context: context)
        case "auto-baseline-scope": try autoBaselineSwiftlintScope(context: context)
        default:
            Output.emitStandardError("baseline: unknown component \(component)\n")
        }
    }
}
