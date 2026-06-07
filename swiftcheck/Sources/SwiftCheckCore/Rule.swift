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
    case unroutedBuildTooling = "unrouted_build_tooling"
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
        case .unroutedBuildTooling:
            return
                "run the build toolchain through swift-mk's Toolchain, not tuist/xcodegen/xcodebuild directly"
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

/// Whether a string literal is the name of a build-toolchain executable, used as a
/// command argument. The match is exact (trimmed): `"xcodebuild"`, `"tuist"`, or
/// `"xcodegen"`, which is how a process spawn names the program (`Shell.run(
/// "xcodebuild", ...)`, the `"tuist"` element of an argument array). Exact match,
/// not prefix, so prose that merely starts with the word, such as an error string
/// "xcodegen requires --project", does not match. Combined with an invocation-
/// context check at the call site, this flags spawning the build toolchain, not
/// mentioning it. The single sanctioned site is swift-mk's own `Toolchain`, which
/// swift-mk excludes through its own lint config; a consumer has no such file, so
/// any consumer invocation is a violation with no opt-out.
func buildToolNeedlePresent(in literal: String) -> Bool {
    let trimmed = literal.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed == "tuist" || trimmed == "xcodegen" || trimmed == "xcodebuild"
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
    private(set) var violations = Set<Violation>()

    init(
        path: String, enabledRules: Set<Rule>, converter: SourceLocationConverter
    ) {
        self.path = path
        self.enabledRules = enabledRules
        self.converter = converter
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

        return .visitChildren
    }

    override func visit(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        guard enabledRules.contains(.unroutedBuildTooling) else {
            return .visitChildren
        }
        var literal = ""
        for segment in node.segments {
            if let stringSegment = segment.as(StringSegmentSyntax.self) {
                literal += stringSegment.content.text
            }
        }
        if buildToolNeedlePresent(in: literal), isInvocationContext(node) {
            record(.unroutedBuildTooling, position: node.positionAfterSkippingLeadingTrivia)
        }
        return .visitChildren
    }

    /// Whether a string literal sits where a process is spawned: an argument to a
    /// function call (`Shell.run("xcodebuild", ...)`) or an element of an array
    /// (`["xcodebuild", "-version"]`, a `process.arguments` vector). This excludes a
    /// literal used as data, such as a `var generator = "tuist"` default or an enum
    /// raw value, so the rule flags invocations of the build toolchain, not mentions
    /// of it.
    private func isInvocationContext(_ node: StringLiteralExprSyntax) -> Bool {
        // The wrapper nodes between a literal and its enclosing call are few; this
        // bounds the climb so a deeply nested literal cannot loop unboundedly.
        let maxAncestorHops = 8
        var current: Syntax? = node.parent
        var hops = 0
        while let parent = current, hops < maxAncestorHops {
            // A literal reaches an invocation only when its enclosing expression is a
            // function call, either a direct argument or an element of an array passed
            // as an argument. A bare array bound to a variable, such as a needle table,
            // never reaches a call, so it is data, not an invocation.
            if parent.is(FunctionCallExprSyntax.self) {
                return true
            }
            // Climb through the wrapper nodes that sit between a literal and the call,
            // including array nodes; stop at any other syntax (a binding, an
            // assignment, an operator) so data literals are not treated as invocations.
            let isWrapper =
                parent.is(LabeledExprSyntax.self) || parent.is(LabeledExprListSyntax.self)
                || parent.is(ArrayElementSyntax.self) || parent.is(ArrayElementListSyntax.self)
                || parent.is(ArrayExprSyntax.self) || parent.is(TupleExprElementListSyntax.self)
            if !isWrapper {
                return false
            }
            current = parent.parent
            hops += 1
        }
        return false
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
        path: path, enabledRules: enabledRules, converter: converter)
    visitor.walk(tree)
    var violations = visitor.violations
    if enabledRules.contains(.missingSectionMark) {
        let sectionViolations = missingSectionMarkViolations(
            path: path, tree: tree, converter: converter)
        violations.formUnion(sectionViolations)
    }
    return Array(violations).sorted()
}
