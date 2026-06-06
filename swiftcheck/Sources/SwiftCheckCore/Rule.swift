//
//  Rule.swift
//  SwiftCheckCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-24.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import SwiftParser
import SwiftSyntax

// MARK: - Rule

public enum Rule: String, CaseIterable, Sendable {
    case bannedDirectOutput = "banned_direct_output"
    case fatalExit = "fatal_exit"
    case forceTry = "force_try"
    case forceUnwrap = "force_unwrap"
    case ignoredCleanupError = "ignored_cleanup_error"
    case missingBoundaryLog = "missing_boundary_log"
    case missingSectionMark = "missing_section_mark"
    case noAny = "no_any"
    case noAnyObject = "no_anyobject"
    case sensitiveLogField = "sensitive_log_field"
    case silentCatch = "silent_catch"
    case silentTry = "silent_try"
    case sleepInProduction = "sleep_in_production"
    case taskDetached = "task_detached"
    case unroutedXcodebuild = "unrouted_xcodebuild"
    case untypedJSON = "untyped_json"

    public var message: String {
        switch self {
        case .noAny:
            return "replace Any with a concrete type"
        case .noAnyObject:
            return "replace AnyObject with a concrete type"
        case .untypedJSON:
            return "replace untyped JSON dictionaries with a concrete model"
        case .forceUnwrap:
            return "remove force unwraps"
        case .forceTry:
            return "remove force try"
        case .silentTry:
            return "handle throwing calls explicitly instead of try?"
        case .silentCatch:
            return "catch blocks must log, throw, or recover explicitly"
        case .bannedDirectOutput:
            return "use the project logging boundary instead of direct output"
        case .taskDetached:
            return "avoid Task.detached without an owned boundary"
        case .sleepInProduction:
            return "keep sleep calls out of production code"
        case .fatalExit:
            return "avoid fatal exit calls outside CLI entrypoints"
        case .sensitiveLogField:
            return "remove sensitive fields from logs"
        case .missingBoundaryLog:
            return "runtime boundary functions must emit a structured log"
        case .ignoredCleanupError:
            return "cleanup paths must not discard errors silently"
        case .missingSectionMark:
            return "add a titled `// MARK: - <section>` divider before this top-level declaration"
        case .unroutedXcodebuild:
            return
                "a tool that runs xcodebuild must route signing through swift-mk "
                + "(call SigningBuildConfig.applyEnvironmentOverride before xcodebuild) "
                + "or mark the file `// swift-mk: signing-not-required`"
        }
    }
}

// MARK: - Violation

public struct Violation: Comparable, Hashable, Sendable {
    public let path: String
    public let line: Int
    public let column: Int
    public let rule: Rule
    public let detail: String?

    public init(path: String, line: Int, column: Int, rule: Rule, detail: String? = nil) {
        self.path = path
        self.line = line
        self.column = column
        self.rule = rule
        self.detail = detail
    }

    public var message: String {
        detail ?? rule.message
    }

    public var renderedLine: String {
        "\(path):\(line):\(column): \(rule.rawValue): \(message)"
    }

    public static func < (lhs: Violation, rhs: Violation) -> Bool {
        if lhs.path != rhs.path {
            return lhs.path < rhs.path
        }
        if lhs.line != rhs.line {
            return lhs.line < rhs.line
        }
        if lhs.column != rhs.column {
            return lhs.column < rhs.column
        }
        return lhs.rule.rawValue < rhs.rule.rawValue
    }
}

public func availableRuleNames() -> [String] {
    Rule.allCases.map(\.rawValue)
}

public func scan(paths: [String], enabledRules: Set<Rule>) throws -> [Violation] {
    let swiftFiles = collectSwiftFiles(paths: paths.isEmpty ? ["."] : paths)
    var violations = Set<Violation>()

    for path in swiftFiles {
        for violation in try auditFile(path: path, enabledRules: enabledRules) {
            violations.insert(violation)
        }
    }

    return violations.sorted()
}

func isSwiftFile(_ path: String) -> Bool {
    path.hasSuffix(".swift")
}

func collectSwiftFiles(paths: [String]) -> [String] {
    let fileManager = FileManager.default
    var collectedPaths = Set<String>()

    for inputPath in paths {
        var isDirectory = ObjCBool(false)
        if fileManager.fileExists(atPath: inputPath, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                if let enumerator = fileManager.enumerator(atPath: inputPath) {
                    for case let relativePath as String in enumerator
                    where isSwiftFile(relativePath) {
                        collectedPaths.insert("\(inputPath)/\(relativePath)")
                    }
                }
            } else if isSwiftFile(inputPath) {
                collectedPaths.insert(inputPath)
            }
        }
    }

    return collectedPaths.sorted()
}

func isTestPath(_ path: String) -> Bool {
    path.contains("/Tests/") || path.hasSuffix("Tests.swift")
}

func isCLIEntryPointPath(_ path: String) -> Bool {
    path.hasSuffix("/main.swift")
}

func logNeedlePresent(in source: String) -> Bool {
    let needles = [
        ".debug(",
        ".error(",
        ".info(",
        ".notice(",
        ".warning(",
    ]
    return needles.contains { needle in
        source.contains(needle)
    }
}

func boundaryNeedlePresent(in source: String) -> Bool {
    let needles = [
        "Process(",
        ".run(",
        "copyItem(",
        "moveItem(",
        "removeItem(",
        "write(to:",
        "read(from:",
        "URLSession",
        "NWConnection",
        "NWListener",
        "register(",
        "unregister(",
        "launchctl",
        "xcodebuild",
        "open(",
    ]
    return needles.contains { needle in
        source.contains(needle)
    }
}

func location(for position: AbsolutePosition, converter: SourceLocationConverter) -> (
    line: Int, column: Int
) {
    let resolved = converter.location(for: position)
    return (resolved.line, resolved.column)
}

// MARK: - AuditVisitor

final class AuditVisitor: SyntaxVisitor {
    private let path: String
    private let enabledRules: Set<Rule>
    private let converter: SourceLocationConverter
    /// A file is exempt from the unrouted-xcodebuild rule when it routes signing
    /// through swift-mk, opts out explicitly, or is a test. Computed once so the
    /// per-call check stays cheap.
    private let exemptFromUnroutedXcodebuild: Bool
    /// The build tool a dev tool shells; held as a constant so the rule body does
    /// not contain the literal, which would otherwise trip `missing_boundary_log`.
    private static let buildToolName = "xcodebuild"
    private(set) var violations = Set<Violation>()

    init(
        path: String, enabledRules: Set<Rule>, converter: SourceLocationConverter, source: String
    ) {
        self.path = path
        self.enabledRules = enabledRules
        self.converter = converter
        self.exemptFromUnroutedXcodebuild =
            isTestPath(path)
            || source.contains("applyEnvironmentOverride")
            || source.contains("swift-mk: signing-not-required")
        super.init(viewMode: .sourceAccurate)
    }

    private func record(_ rule: Rule, position: AbsolutePosition) {
        let value = location(for: position, converter: converter)
        violations.insert(
            Violation(
                path: path,
                line: value.line,
                column: value.column,
                rule: rule
            )
        )
    }

    private func visitBannedDirectOutput(calledExpression: String, position: AbsolutePosition) {
        guard enabledRules.contains(.bannedDirectOutput) else {
            return
        }
        let bannedNames = [
            "print",
            "debugPrint",
            "dump",
            "NSLog",
            "os_log",
        ]
        if bannedNames.contains(calledExpression) {
            record(.bannedDirectOutput, position: position)
        }
    }

    private func visitDetachedTask(calledExpression: String, position: AbsolutePosition) {
        let isDetachedCall =
            calledExpression == "Task.detached" || calledExpression.hasSuffix(".detached")
        if enabledRules.contains(.taskDetached), isDetachedCall {
            record(.taskDetached, position: position)
        }
    }

    private func visitSleepCall(calledExpression: String, position: AbsolutePosition) {
        guard enabledRules.contains(.sleepInProduction), !isTestPath(path) else {
            return
        }
        let sleepNames = [
            "sleep",
            "usleep",
            "Thread.sleep",
            "Task.sleep",
        ]
        if sleepNames.contains(calledExpression) {
            record(.sleepInProduction, position: position)
        }
    }

    private func visitFatalExit(calledExpression: String, position: AbsolutePosition) {
        guard enabledRules.contains(.fatalExit), !isCLIEntryPointPath(path) else {
            return
        }
        let fatalNames = [
            "fatalError",
            "preconditionFailure",
            "abort",
            "exit",
        ]
        if fatalNames.contains(calledExpression) {
            record(.fatalExit, position: position)
        }
    }

    private func visitSensitiveLogField(
        source: String, calledExpression: String, position: AbsolutePosition
    ) {
        let isLogCall = logNeedlePresent(in: calledExpression) || logNeedlePresent(in: source)
        guard enabledRules.contains(.sensitiveLogField), isLogCall else {
            return
        }
        let sensitiveNeedles = [
            "token",
            "secret",
            "password",
            "privatekey",
            "private_key",
            "cookie",
            "set-cookie",
            "authorization",
        ]
        if sensitiveNeedles.contains(where: { source.contains($0) }) {
            record(.sensitiveLogField, position: position)
        }
    }

    override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind {
        let typeName = node.name.text
        if enabledRules.contains(.noAny), typeName == "Any" {
            let value = location(for: node.positionAfterSkippingLeadingTrivia, converter: converter)
            violations.insert(
                Violation(path: path, line: value.line, column: value.column, rule: .noAny))
        }
        if enabledRules.contains(.noAnyObject), typeName == "AnyObject" {
            let value = location(for: node.positionAfterSkippingLeadingTrivia, converter: converter)
            violations.insert(
                Violation(path: path, line: value.line, column: value.column, rule: .noAnyObject))
        }
        return .visitChildren
    }

    override func visit(_ node: DictionaryTypeSyntax) -> SyntaxVisitorContinueKind {
        guard enabledRules.contains(.untypedJSON) else {
            return .visitChildren
        }
        let keyType = node.key.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let valueType = node.value.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let keyMatches = keyType == "String" || keyType == "AnyHashable"
        let valueMatches = valueType == "Any" || valueType == "AnyObject"
        if keyMatches, valueMatches {
            let value = location(for: node.positionAfterSkippingLeadingTrivia, converter: converter)
            violations.insert(
                Violation(path: path, line: value.line, column: value.column, rule: .untypedJSON))
        }
        return .visitChildren
    }

    override func visit(_ node: ForceUnwrapExprSyntax) -> SyntaxVisitorContinueKind {
        guard enabledRules.contains(.forceUnwrap) else {
            return .visitChildren
        }
        let value = location(for: node.positionAfterSkippingLeadingTrivia, converter: converter)
        violations.insert(
            Violation(path: path, line: value.line, column: value.column, rule: .forceUnwrap))
        return .visitChildren
    }

    override func visit(_ node: TryExprSyntax) -> SyntaxVisitorContinueKind {
        guard let token = node.questionOrExclamationMark else {
            return .visitChildren
        }
        let value = location(for: node.positionAfterSkippingLeadingTrivia, converter: converter)
        if enabledRules.contains(.forceTry), token.tokenKind == .exclamationMark {
            violations.insert(
                Violation(path: path, line: value.line, column: value.column, rule: .forceTry))
        }
        if enabledRules.contains(.silentTry), token.tokenKind == .postfixQuestionMark {
            violations.insert(
                Violation(path: path, line: value.line, column: value.column, rule: .silentTry))
        }
        if enabledRules.contains(.ignoredCleanupError) {
            let source = node.expression.description.lowercased()
            let ignoresCleanupError =
                source.contains("close(") || source.contains("cancel(")
                || source.contains("removeitem(")
            if token.tokenKind == .postfixQuestionMark, ignoresCleanupError {
                violations.insert(
                    Violation(
                        path: path,
                        line: value.line,
                        column: value.column,
                        rule: .ignoredCleanupError
                    )
                )
            }
        }
        return .visitChildren
    }

    override func visit(_ node: CatchClauseSyntax) -> SyntaxVisitorContinueKind {
        guard enabledRules.contains(.silentCatch) else {
            return .visitChildren
        }
        let bodySource = node.body.description
        let recoverySignals = [
            ".error(",
            ".notice(",
            ".warning(",
            "throw ",
            "rethrow",
            "fatalError(",
            "assertionFailure(",
            "preconditionFailure(",
            "exit(",
            "return ",
            "continue",
            "break",
        ]
        let hasRecoverySignal = recoverySignals.contains { signal in
            bodySource.contains(signal)
        }
        if !hasRecoverySignal {
            let value = location(for: node.positionAfterSkippingLeadingTrivia, converter: converter)
            violations.insert(
                Violation(path: path, line: value.line, column: value.column, rule: .silentCatch))
        }
        return .visitChildren
    }

    /// The content of a single-segment string literal, or nil for anything else
    /// (an interpolated or multi-segment literal, or a non-literal expression).
    private func simpleStringLiteral(_ expression: ExprSyntax) -> String? {
        guard let literal = expression.as(StringLiteralExprSyntax.self),
            literal.segments.count == 1,
            let segment = literal.segments.first?.as(StringSegmentSyntax.self)
        else {
            return nil
        }
        return segment.content.text
    }

    /// Flag a call that passes "xcodebuild" as a string-literal argument, the
    /// `run("xcodebuild", ...)` form a dev tool uses to shell xcodebuild, unless the
    /// file is exempt. The signing override must be applied before any such call so
    /// signing always comes from swift-mk, never the per-target ad-hoc default.
    private func visitUnroutedXcodebuild(
        node: FunctionCallExprSyntax, position: AbsolutePosition
    ) {
        guard enabledRules.contains(.unroutedXcodebuild), !exemptFromUnroutedXcodebuild else {
            return
        }
        for argument in node.arguments
        where simpleStringLiteral(argument.expression) == Self.buildToolName {
            record(.unroutedXcodebuild, position: position)
            return
        }
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let calledExpression = node.calledExpression.description.trimmingCharacters(
            in: .whitespacesAndNewlines)
        let source = node.description.lowercased()
        let position = node.positionAfterSkippingLeadingTrivia

        visitBannedDirectOutput(calledExpression: calledExpression, position: position)
        visitDetachedTask(calledExpression: calledExpression, position: position)
        visitSleepCall(calledExpression: calledExpression, position: position)
        visitFatalExit(calledExpression: calledExpression, position: position)
        visitSensitiveLogField(
            source: source, calledExpression: calledExpression, position: position)
        visitUnroutedXcodebuild(node: node, position: position)

        return .visitChildren
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        guard enabledRules.contains(.missingBoundaryLog), let body = node.body else {
            return .visitChildren
        }
        let bodySource = body.description
        let functionName = node.name.text
        let hasBoundaryNeedle = boundaryNeedlePresent(in: bodySource)
        let hasLogNeedle = logNeedlePresent(in: bodySource)
        let ignoreFunction = functionName.hasSuffix("NeedlePresent")
        if hasBoundaryNeedle, !hasLogNeedle, !ignoreFunction {
            record(.missingBoundaryLog, position: node.positionAfterSkippingLeadingTrivia)
        }
        return .visitChildren
    }
}

func auditFile(path: String, enabledRules: Set<Rule>) throws -> [Violation] {
    let sourceText = try String(contentsOfFile: path, encoding: .utf8)
    let tree = Parser.parse(source: sourceText)
    let converter = SourceLocationConverter(fileName: path, tree: tree)
    let visitor = AuditVisitor(
        path: path, enabledRules: enabledRules, converter: converter, source: sourceText)
    visitor.walk(tree)
    var violations = visitor.violations
    if enabledRules.contains(.missingSectionMark) {
        let sectionViolations = missingSectionMarkViolations(
            path: path, tree: tree, converter: converter)
        violations.formUnion(sectionViolations)
    }
    return Array(violations).sorted()
}
