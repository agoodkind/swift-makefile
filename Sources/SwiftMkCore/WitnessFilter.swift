//
//  WitnessFilter.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-05.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import IndexStore

// MARK: - WitnessFilter

/// Drops periphery findings that are protocol witnesses reached only through the
/// protocol.
///
/// periphery decides a declaration is unused from direct references in the index.
/// When a method satisfies a protocol requirement and every call goes through the
/// protocol (dynamic dispatch), the concrete method has no direct reference, so
/// periphery reports it unused even though a call runs it. The index records the
/// truth: the witness's definition carries an `overrideOf` relation to the
/// requirement, and the call records a `reference` occurrence of that requirement.
/// This reads both facts and removes a finding when its declaration overrides a
/// requirement that is referenced somewhere, while leaving every other finding,
/// including a witness whose requirement is never called, untouched.
public enum WitnessFilter {
    // MARK: Finding

    /// One periphery result line parsed into its location and declaration name.
    public struct Finding: Equatable {
        public let file: String
        public let line: Int
        public let column: Int
        public let name: String
    }

    // MARK: Index facts

    /// The two facts the decision needs, read from the index in one pass: every USR
    /// that is referenced somewhere, and, keyed by declaration site, the requirement
    /// USRs each witness overrides. The declaration key is `file\nline\nname`, the
    /// same triple a periphery finding carries, joined so it needs no stored type.
    struct IndexFacts {
        var referencedUSRs: Set<String> = []
        var requirementsByDecl: [String: Set<String>] = [:]
    }

    /// The declaration key for a site: its absolute file, line, and symbol name.
    static func declKey(file: String, line: Int, name: String) -> String {
        "\(file)\n\(line)\n\(name)"
    }

    // MARK: Entry point

    /// Remove witness false positives from periphery's combined output. Returns the
    /// output with suppressed lines dropped and the findings that were dropped.
    /// Reads the index once; a finding that does not parse or does not match a
    /// referenced-requirement witness is kept, so the filter never hides a real
    /// finding.
    public static func apply(
        toCombinedOutput output: String,
        indexStorePath: String
    ) throws -> (text: String, dropped: [Finding]) {
        let facts = try buildFacts(indexStorePath: indexStorePath)
        return applyFacts(toCombinedOutput: output, facts: facts)
    }

    /// Filter the output against already-read facts. Split from `apply` so the
    /// line-keeping is testable without an index store.
    static func applyFacts(
        toCombinedOutput output: String,
        facts: IndexFacts
    ) -> (text: String, dropped: [Finding]) {
        var keptLines: [String] = []
        var dropped: [Finding] = []
        for line in output.components(separatedBy: "\n") {
            guard let finding = parseFinding(line), isSuppressed(finding, facts: facts) else {
                keptLines.append(line)
                continue
            }
            dropped.append(finding)
        }
        return (keptLines.joined(separator: "\n"), dropped)
    }

    // MARK: Decision

    /// A finding is suppressed when its declaration site overrides a protocol
    /// requirement whose USR is referenced somewhere in the index.
    static func isSuppressed(_ finding: Finding, facts: IndexFacts) -> Bool {
        let key = declKey(
            file: IndexCompleteness.standardize(finding.file),
            line: finding.line,
            name: finding.name)
        guard let requirements = facts.requirementsByDecl[key] else {
            return false
        }
        return !requirements.isDisjoint(with: facts.referencedUSRs)
    }

    // MARK: Index reading

    /// Walk every non-system unit's records once, collecting referenced USRs and the
    /// requirement USRs each witness definition overrides.
    static func buildFacts(indexStorePath: String) throws -> IndexFacts {
        let store = try IndexStore(path: indexStorePath)
        var facts = IndexFacts()
        for unit in store.units where !unit.isSystem {
            let file = IndexCompleteness.standardize(unit.mainFile)
            for recordName in unit.recordNames {
                let record = try RecordReader(indexStore: store, recordName: recordName)
                // `forEach(occurrence:)` is the index library's only occurrence reader;
                // it is not a `Sequence`, so it cannot become a for-in loop.
                // swift-format-ignore: ReplaceForEachWithForLoop
                record.forEach { (occurrence: SymbolOccurrence) in
                    collect(occurrence: occurrence, file: file, into: &facts)
                }
            }
        }
        return facts
    }

    /// Record one occurrence's contribution: a referenced USR, and, for a definition
    /// that overrides one or more requirements, the witness-to-requirement mapping.
    private static func collect(
        occurrence: SymbolOccurrence,
        file: String,
        into facts: inout IndexFacts
    ) {
        if occurrence.roles.contains(.reference) {
            facts.referencedUSRs.insert(occurrence.symbol.usr)
        }
        guard occurrence.roles.contains(.definition) else {
            return
        }
        var requirements: Set<String> = []
        // `forEach(relation:)` is the index library's only relation reader; it is not
        // a `Sequence`, so it cannot become a for-in loop.
        // swift-format-ignore: ReplaceForEachWithForLoop
        occurrence.forEach { relatedSymbol, relationRoles in
            if relationRoles.contains(.overrideOf) {
                requirements.insert(relatedSymbol.usr)
            }
        }
        guard !requirements.isEmpty else {
            return
        }
        let (line, _) = occurrence.location
        let key = declKey(file: file, line: line, name: occurrence.symbol.name)
        facts.requirementsByDecl[key, default: []].formUnion(requirements)
    }

    // MARK: Parsing

    /// The capture groups in `findingExpression`, named so the indices are not bare
    /// magic numbers at the call site.
    private enum CaptureGroup {
        static let file = 1
        static let line = 2
        static let column = 3
        static let message = 4
    }

    /// Parse one periphery `xcode`-format line into a `Finding`. The format is
    /// `path:line:column: warning: <Kind> 'name' is unused`. Returns nil for any
    /// line that is not a finding, so non-result output passes through untouched.
    static func parseFinding(_ line: String) -> Finding? {
        guard let expression = findingExpression,
            let match = expression.firstMatch(
                in: line, range: NSRange(line.startIndex..., in: line))
        else {
            return nil
        }
        guard let fileRange = Range(match.range(at: CaptureGroup.file), in: line),
            let lineRange = Range(match.range(at: CaptureGroup.line), in: line),
            let columnRange = Range(match.range(at: CaptureGroup.column), in: line),
            let messageRange = Range(match.range(at: CaptureGroup.message), in: line),
            let lineNumber = Int(line[lineRange]),
            let columnNumber = Int(line[columnRange])
        else {
            return nil
        }
        return Finding(
            file: String(line[fileRange]),
            line: lineNumber,
            column: columnNumber,
            name: declarationName(in: String(line[messageRange])))
    }

    /// The single-quoted declaration name in a periphery message, or an empty string
    /// when the message has none.
    static func declarationName(in message: String) -> String {
        guard let open = message.firstIndex(of: "'") else {
            return ""
        }
        let afterOpen = message.index(after: open)
        guard let close = message[afterOpen...].firstIndex(of: "'") else {
            return ""
        }
        return String(message[afterOpen..<close])
    }

    private static let findingExpression: NSRegularExpression? = makeFindingExpression()

    /// Compile the finding pattern once. The pattern is a constant, so this is
    /// expected to succeed; a nil result makes `parseFinding` keep every line.
    private static func makeFindingExpression() -> NSRegularExpression? {
        // path : line : column : space warning|error : space message
        let pattern = "^(.*?):([0-9]+):([0-9]+): (?:warning|error): (.*)$"
        do {
            return try NSRegularExpression(pattern: pattern)
        } catch {
            return nil
        }
    }
}
