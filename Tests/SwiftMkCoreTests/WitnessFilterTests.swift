//
//  WitnessFilterTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-05.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - WitnessFilterTests

/// Empty namesake type so SwiftLint `file_name` finds a declaration matching
/// `WitnessFilterTests.swift`; the suite is written as free `@Test` functions.
enum WitnessFilterTests {}

// MARK: Parsing

@Test
func witnessParsesXcodeFindingLine() {
    let line =
        "/abs/Sources/RelayController.swift:168:17: warning: Function 'stop()' is unused"
    let finding = WitnessFilter.parseFinding(line)
    #expect(finding?.file == "/abs/Sources/RelayController.swift")
    #expect(finding?.line == 168)
    #expect(finding?.column == 17)
    #expect(finding?.name == "stop()")
}

@Test
func witnessParsesPropertyName() {
    let line = "/a/B.swift:3:9: warning: Property 'value' is unused"
    #expect(WitnessFilter.parseFinding(line)?.name == "value")
}

@Test
func witnessIgnoresNonFindingLines() {
    #expect(WitnessFilter.parseFinding("") == nil)
    #expect(WitnessFilter.parseFinding("* 18 unused declarations") == nil)
    #expect(WitnessFilter.parseFinding("Building for debugging...") == nil)
}

@Test
func witnessDeclarationNameEmptyWithoutQuotes() {
    #expect(WitnessFilter.declarationName(in: "no quoted name here").isEmpty)
}

// MARK: Decision

@Test
func witnessSuppressedWhenRequirementReferenced() {
    let file = IndexCompleteness.standardize("/proj/SimBackend.swift")
    var facts = WitnessFilter.IndexFacts()
    facts.referencedUSRs = ["requirement-usr"]
    facts.requirementsByDecl[WitnessFilter.declKey(file: file, line: 6, name: "stop()")] = [
        "requirement-usr"
    ]
    let finding = WitnessFilter.Finding(
        file: "/proj/SimBackend.swift", line: 6, column: 10, name: "stop()")
    #expect(WitnessFilter.isSuppressed(finding, facts: facts))
}

@Test
func witnessKeptWhenRequirementNeverReferenced() {
    let file = IndexCompleteness.standardize("/proj/SimBackend.swift")
    var facts = WitnessFilter.IndexFacts()
    facts.requirementsByDecl[WitnessFilter.declKey(file: file, line: 6, name: "stop()")] = [
        "requirement-usr"
    ]
    let finding = WitnessFilter.Finding(
        file: "/proj/SimBackend.swift", line: 6, column: 10, name: "stop()")
    #expect(!WitnessFilter.isSuppressed(finding, facts: facts))
}

@Test
func witnessKeptWhenNotAWitness() {
    var facts = WitnessFilter.IndexFacts()
    facts.referencedUSRs = ["requirement-usr"]
    let finding = WitnessFilter.Finding(
        file: "/proj/Helpers.swift", line: 42, column: 1, name: "deadHelper()")
    #expect(!WitnessFilter.isSuppressed(finding, facts: facts))
}

// MARK: Filtering the output

@Test
func witnessApplyFactsDropsWitnessKeepsRealFinding() {
    let witnessFile = IndexCompleteness.standardize("/p/A.swift")
    var facts = WitnessFilter.IndexFacts()
    facts.referencedUSRs = ["requirement-usr"]
    facts.requirementsByDecl[
        WitnessFilter.declKey(file: witnessFile, line: 6, name: "stop()")] = ["requirement-usr"]
    let output = [
        "/p/A.swift:6:10: warning: Function 'stop()' is unused",
        "/p/Helpers.swift:42:1: warning: Function 'deadHelper()' is unused",
        "* 2 unused declarations",
    ].joined(separator: "\n")
    let result = WitnessFilter.applyFacts(toCombinedOutput: output, facts: facts)
    #expect(result.dropped.count == 1)
    #expect(result.dropped.first?.name == "stop()")
    #expect(!result.text.contains("'stop()'"))
    #expect(result.text.contains("deadHelper()"))
    #expect(result.text.contains("2 unused declarations"))
}
