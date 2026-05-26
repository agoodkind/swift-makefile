import Foundation
import Testing

@testable import SwiftMkCore

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
