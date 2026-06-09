//
//  SwiftMkCoreTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-25.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - SwiftMkCoreTests

/// Empty namesake type so SwiftLint `file_name` finds a declaration matching
/// `SwiftMkCoreTests.swift`; the suite is written as free `@Test` functions.
enum SwiftMkCoreTests {}

@Test
func keyBlanksLineAndColumn() {
  let key = Findings.key(
    "Sources/A.swift:10:5: magic number (no_magic_numbers)", pwd: "", cwd: "")
  #expect(key == "Sources/A.swift::: magic number (no_magic_numbers)")
}

@Test
func normalizePathStripsPrefixesAndDotDot() {
  let normalized = Findings.normalizePath(
    "/root/Sources/A.swift:1:1: x", pwd: "/root/", cwd: "/root/"
  )
  #expect(normalized == "Sources/A.swift:1:1: x")
}

@Test
func slugifyKeepsAlphanumericLowercased() {
  #expect(TokenGate.slugify("Hello, World! 42") == "helloworld42")
  #expect(TokenGate.slugify("a-b_c") == "a-b_c")
}

private func temporaryDirectory() throws -> String {
  let path = NSTemporaryDirectory() + "swift-mk-test-" + UUID().uuidString
  try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
  return path
}

@Test
func writeBaselineSyncAddsMetadata() throws {
  let dir = try temporaryDirectory()
  let findings = dir + "/findings.out"
  let output = dir + "/baseline.txt"
  try "A.swift:5:1: msg (rule_x)\nB.swift:9:2: other (rule_y)\n".write(
    toFile: findings, atomically: true, encoding: .utf8)

  try Baseline.writeBaselineFile(
    BaselineWriteRequest(
      title: "swiftlint",
      oldBaselinePath: dir + "/missing.txt",
      findingsPath: findings,
      label: "swiftlint",
      outputPath: output,
      mode: .sync,
      scopePattern: "",
      now: "NOW"
    )
  )

  let lines = try String(contentsOfFile: output, encoding: .utf8).components(separatedBy: "\n")
  #expect(lines[0] == "# swiftlint: generated_at=NOW")
  #expect(lines.contains("A.swift:5:1: msg (rule_x)\t# swiftlint:first_added=NOW last_seen=NOW"))
  #expect(
    lines.contains("B.swift:9:2: other (rule_y)\t# swiftlint:first_added=NOW last_seen=NOW"))
}

@Test
func scopedSyncPreservesOutOfScopeRows() throws {
  let dir = try temporaryDirectory()
  let findings = dir + "/findings.out"
  let baseline = dir + "/baseline.txt"
  // Old baseline: one out-of-scope row and one in-scope row.
  try [
    "# swiftlint: generated_at=OLD",
    "C.swift:1:1: keep (other_rule)\t# swiftlint:first_added=OLD last_seen=OLD",
    "A.swift:5:1: msg (rule_x)\t# swiftlint:first_added=OLD last_seen=OLD",
    "",
  ].joined(separator: "\n").write(toFile: baseline, atomically: true, encoding: .utf8)
  // Current scoped findings: the rule_x finding, shifted to a new line.
  try "A.swift:7:1: msg (rule_x)\n".write(toFile: findings, atomically: true, encoding: .utf8)

  let output = dir + "/out.txt"
  try Baseline.writeBaselineFile(
    BaselineWriteRequest(
      title: "swiftlint",
      oldBaselinePath: baseline,
      findingsPath: findings,
      label: "swiftlint",
      outputPath: output,
      mode: .sync,
      scopePattern: "\\(rule_x\\)$",
      now: "NOW"
    )
  )

  let lines = try String(contentsOfFile: output, encoding: .utf8).components(separatedBy: "\n")
  // Out-of-scope row preserved verbatim.
  #expect(
    lines.contains("C.swift:1:1: keep (other_rule)\t# swiftlint:first_added=OLD last_seen=OLD"))
  // In-scope finding refreshed at the new line, first_added carried over by key.
  #expect(lines.contains("A.swift:7:1: msg (rule_x)\t# swiftlint:first_added=OLD last_seen=NOW"))
  // Old in-scope line no longer present.
  #expect(!lines.contains { $0.hasPrefix("A.swift:5:1:") })
}

@Test
func diffGateFindsNewAndPassesOnMatch() throws {
  let dir = try temporaryDirectory()
  let baseline = dir + "/baseline.txt"
  try [
    "# swiftlint: generated_at=OLD",
    "A.swift:5:1: msg (rule_x)\t# swiftlint:first_added=OLD last_seen=OLD",
    "",
  ].joined(separator: "\n").write(toFile: baseline, atomically: true, encoding: .utf8)
  let context = PathContext(pwd: dir + "/", cwd: dir + "/")

  // A finding already in the baseline (line shifted) passes.
  let matching = dir + "/match.out"
  try "A.swift:6:1: msg (rule_x)\n".write(toFile: matching, atomically: true, encoding: .utf8)
  let matchingSpec = BaselineSpec(
    findingsPath: matching,
    baselinePath: baseline,
    label: "swiftlint"
  )
  #expect(
    Baseline.runDiffGate(
      gateName: "swiftlint",
      spec: matchingSpec,
      remediation: "fix",
      context: context
    ) == true
  )

  // A brand-new finding fails.
  let new = dir + "/new.out"
  try "Z.swift:1:1: new (rule_z)\n".write(toFile: new, atomically: true, encoding: .utf8)
  let newSpec = BaselineSpec(
    findingsPath: new,
    baselinePath: baseline,
    label: "swiftlint"
  )
  #expect(
    Baseline.runDiffGate(
      gateName: "swiftlint",
      spec: newSpec,
      remediation: "fix",
      context: context
    ) == false
  )
}

// MARK: BaselineReport

private func makeStats(
  label: String,
  added: Int = 0,
  refreshed: Int = 0,
  removed: Int = 0,
  remaining: Int = 0,
  findingsCaptured: Int = 0,
  covered: Int = 0,
  scopePattern: String = ""
) -> BaselineUpdateStats {
  BaselineUpdateStats(
    label: label,
    baselinePath: ".\(label)-baseline.txt",
    scopePattern: scopePattern,
    findingsCaptured: findingsCaptured,
    added: added,
    refreshed: refreshed,
    removed: removed,
    covered: covered,
    remaining: remaining
  )
}

/// Tokens the output contract forbids in any user-facing baseline output.
private let forbiddenTokens = [
  "prune", "accept-new", "accept new", "remove-fixed", "removefixed",
  "skip", "disable", "silence", "weaken", "circumvent",
  "Mode:", "sync", "pruneFixed", "acceptNew",
]

private func assertNoForbiddenTokens(_ text: String) {
  let lower = text.lowercased()
  for token in forbiddenTokens {
    #expect(!lower.contains(token.lowercased()), "forbidden token \"\(token)\" in: \(text)")
  }
}

@Test
func reportChangePhraseIsNeutral() {
  #expect(BaselineReport.changePhrase(makeStats(label: "a", removed: 2)) == "2 removed")
  #expect(BaselineReport.changePhrase(makeStats(label: "a", added: 3)) == "3 added")
  #expect(
    BaselineReport.changePhrase(makeStats(label: "a", added: 3, removed: 1))
      == "3 added, 1 removed")
  #expect(BaselineReport.changePhrase(makeStats(label: "a", refreshed: 9)) == "no change")
  #expect(BaselineReport.changePhrase(makeStats(label: "a")) == "no change")
}

@Test
func reportIsNoopReflectsKeyChange() {
  #expect(makeStats(label: "a", refreshed: 5).isNoop)
  #expect(!makeStats(label: "a", added: 1).isNoop)
  #expect(!makeStats(label: "a", removed: 1).isNoop)
}

@Test
func reportSingleLinesAreNeutral() {
  let lines = BaselineReport.singleLines(
    makeStats(label: "golangci-lint", removed: 2, remaining: 17))
  #expect(lines == ["golangci-lint baseline", "  2 removed, 17 violations."])
  assertNoForbiddenTokens(lines.joined(separator: "\n"))
}

@Test
func reportRollupListsEachToolAndSummary() {
  let stats = [
    makeStats(label: "golangci-lint", removed: 2, remaining: 17),
    makeStats(label: "gocyclo", refreshed: 4, remaining: 0),
    makeStats(label: "deadcode", remaining: 0),
    makeStats(label: "staticcheck-extra", removed: 1, remaining: 14),
  ]
  let lines = BaselineReport.rollupLines(stats)
  let text = lines.joined(separator: "\n")
  #expect(lines.first == "Updating 4 baselines")
  #expect(text.contains("golangci-lint"))
  #expect(text.contains("no change"))
  #expect(text.contains("no existing"))
  #expect(text.contains("4 -> 0"))
  #expect(text.contains("Done. 31 violations across 4 baselines."))
  assertNoForbiddenTokens(text)
}

@Test
func reportJSONHasNeutralFieldsAndNoMode() throws {
  struct DecodedBaselineEntry: Decodable {
    let label: String
    let removed: Int
    let remaining: Int
    let changed: Bool
  }
  struct DecodedTotals: Decodable {
    let removed: Int
    let baselines: Int
  }
  struct DecodedReport: Decodable {
    let baselines: [DecodedBaselineEntry]
    let totals: DecodedTotals
  }

  let stats = [
    makeStats(
      label: "golangci-lint",
      added: 0,
      refreshed: 17,
      removed: 2,
      remaining: 17,
      findingsCaptured: 69,
      covered: 69
    ),
    makeStats(label: "gocyclo", remaining: 0),
  ]
  let json = BaselineReport.jsonString(stats)
  assertNoForbiddenTokens(json)

  let report = try JSONDecoder().decode(DecodedReport.self, from: Data(json.utf8))
  #expect(report.baselines.count == 2)
  #expect(report.baselines[0].label == "golangci-lint")
  #expect(report.baselines[0].removed == 2)
  #expect(report.baselines[0].remaining == 17)
  #expect(report.baselines[0].changed)
  #expect(!report.baselines[1].changed)
  #expect(report.totals.removed == 2)
  #expect(report.totals.baselines == 2)
  // No `mode` key anywhere in the document.
  #expect(!json.contains("\"mode\""))
}

// MARK: - DeadcodeScan

@Test
func deadcodeParsesProjectSchemes() {
  let json = """
    { "project": { "name": "App", "schemes": ["App", "AppTests"] } }
    """
  #expect(DeadcodeScan.parseSchemes(json) == ["App", "AppTests"])
}

@Test
func deadcodeParsesWorkspaceSchemes() {
  let json = """
    { "workspace": { "name": "App", "schemes": ["App", "Agent"] } }
    """
  #expect(DeadcodeScan.parseSchemes(json) == ["App", "Agent"])
}

@Test
func deadcodeParsesPackageTargets() {
  let json = """
    { "name": "Pkg", "targets": [ { "name": "Core" }, { "name": "CoreTests" } ] }
    """
  #expect(DeadcodeScan.parsePackageTargets(json) == ["Core", "CoreTests"])
}

@Test
func deadcodeJsonDataSkipsPreamble() {
  let text = "Command line invocation:\n  tool args\n{ \"project\": {} }"
  #expect(DeadcodeScan.jsonData(text) == Data("{ \"project\": {} }".utf8))
}

@Test
func deadcodeSchemesToScanDropsPackageTargets() {
  let scan = DeadcodeScan.schemesToScan(
    ["App", "Agent", "Core", "Log"], packageTargets: ["Core", "Log"])
  #expect(scan == ["App", "Agent"])
}

@Test
func deadcodeGeneratorCommandMatchesManifest() {
  let xcodegen = DeadcodeScan.generatorCommand(forManifest: "project.yml")
  #expect(xcodegen.tool == "xcodegen")
  #expect(xcodegen.arguments == ["generate"])
  let tuist = DeadcodeScan.generatorCommand(forManifest: "Project.swift")
  #expect(tuist.tool == "tuist")
  #expect(tuist.arguments == ["generate", "--no-open"])
}

@Test
func deadcodeFindsIndexStoreUnderDerivedData() throws {
  let base = NSTemporaryDirectory() + "swiftmk-deadcode-" + UUID().uuidString
  let store = base + "/Index.noindex/DataStore"
  try FileManager.default.createDirectory(
    atPath: store, withIntermediateDirectories: true)
  #expect(DeadcodeScan.existingIndexStore(base) == store)
  #expect(DeadcodeScan.existingIndexStore(base + "-missing") == nil)
}

@Test
func deadcodeHardFailThresholdIsTwo() {
  #expect(Lint.deadcodeHardFailStatus == 2)
}

@Test
func deadcodeDetectsSwiftCompileErrorButNotPeripheryFindings() {
  // A compile error during periphery's build must hard-fail the gate instead of
  // letting the resulting phantom "unused" findings reach the baseline diff.
  #expect(
    Lint.isSwiftCompileError(
      "Sources/SwiftLMRuntime/FanCoordinator.swift:500:103: error: consecutive statements"))
  #expect(
    Lint.isSwiftCompileError(
      "/abs/path/File.swift:12:5: error: cannot use optional chaining on non-optional value"))
  // Periphery emits its findings as warnings and its tally without a file location.
  #expect(
    !Lint.isSwiftCompileError(
      "Sources/SwiftLMMonitor/Sensors/Battery.swift:12:13: warning: Unused property 'log'"))
  #expect(!Lint.isSwiftCompileError("Error: Found 73 issues."))
}
