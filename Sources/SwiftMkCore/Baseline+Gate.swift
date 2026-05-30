//
//  Baseline+Gate.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-25.
//  Copyright © 2026
//

import Foundation

// MARK: - Baseline Gate

extension Baseline {
    /// Extract baseline findings: strip metadata, normalize, exclude, scope, dedupe.
    /// Port of `swift_mk_baseline_findings`.
    public static func findings(_ spec: BaselineSpec, context: PathContext) -> [String] {
        guard FileManager.default.fileExists(atPath: spec.baselinePath) else { return [] }
        let extracted = Text.readLines(spec.baselinePath).compactMap { line in
            Findings.baselineFinding(line, label: spec.label, context)
        }
        let excluded = Text.filterExclude(extracted, spec.excludePattern)
        let scoped = Text.filterScope(excluded, spec.scopePattern)
        return Text.sortedUnique(scoped)
    }

    static func keyize(_ lines: [String], _ context: PathContext) -> Set<String> {
        Set(lines.map { Findings.key($0, context) })
    }

    public static func recordFailedGate(_ gateName: String) {
        Capture.ensureMakeDir()
        let path = ".make/lint.failed"
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        handle.seekToEndOfFile()
        handle.write(Data("\(gateName)\n".utf8))
        do {
            try handle.close()
        } catch {
            Output.error("baseline: could not close \(path): \(error)")
        }
    }

    /// Compare current findings to the baseline. Fail on findings present now
    /// but absent from the baseline. Port of `swift_mk_run_baseline_diff_gate`.
    @discardableResult
    public static func runDiffGate(
        gateName: String,
        spec: BaselineSpec,
        remediation: String,
        context: PathContext
    ) -> Bool {
        let findingsLines = Text.readLines(spec.findingsPath)
        let baselineLines = findings(spec, context: context)
        let baselineKeys = keyize(baselineLines, context)
        let findingKeyOf = { (line: String) in Findings.key(line, context) }

        let newFindings = findingsLines.filter { !baselineKeys.contains(findingKeyOf($0)) }
        if !newFindings.isEmpty {
            Output.log("\(gateName): FAILED")
            Output.log("  New findings: \(newFindings.count)\n")
            Output.log("Findings:")
            for line in newFindings { Output.log(Findings.rendered(line, context)) }
            Output.log("\n  \(remediation)")
            recordFailedGate(gateName)
            return false
        }

        let findingsKeys = keyize(findingsLines, context)
        let goneCount = baselineLines.filter { !findingsKeys.contains(findingKeyOf($0)) }.count
        Output.log("\(gateName): OK")
        Output.log("  New findings: 0")
        if goneCount > 0 {
            Output.log("  Saved findings now fixed: \(goneCount)")
        }
        return true
    }

    /// Full component baseline update: snapshot the key set, rewrite the file,
    /// and return neutral counts describing what changed. Rendering is the
    /// caller's job. Port of `write_component_baseline`.
    @discardableResult
    public static func writeComponent(
        title: String, _ spec: BaselineSpec, mode: BaselineMode, context: PathContext
    ) throws -> BaselineUpdateStats {
        let directory = URL(fileURLWithPath: spec.baselinePath).deletingLastPathComponent().path
        if !directory.isEmpty {
            do {
                try FileManager.default.createDirectory(
                    atPath: directory, withIntermediateDirectories: true)
            } catch {
                Output.error("baseline: could not create \(directory): \(error)")
            }
        }
        if !FileManager.default.fileExists(atPath: spec.baselinePath) {
            FileManager.default.createFile(atPath: spec.baselinePath, contents: nil)
        }

        let findingsLines = Text.readLines(spec.findingsPath)
        let oldBaselineKeys = keyize(findings(spec, context: context), context)

        let temporary = spec.baselinePath + ".tmp"
        try writeBaselineFile(
            BaselineWriteRequest(
                title: title,
                oldBaselinePath: spec.baselinePath,
                findingsPath: spec.findingsPath,
                label: spec.label,
                outputPath: temporary,
                mode: mode,
                scopePattern: spec.scopePattern,
                now: iso8601Now()
            )
        )
        do {
            _ = try FileManager.default.replaceItemAt(
                URL(fileURLWithPath: spec.baselinePath), withItemAt: URL(fileURLWithPath: temporary)
            )
        } catch {
            Output.error("baseline: could not replace \(spec.baselinePath): \(error)")
        }

        let newBaselineKeys = keyize(findings(spec, context: context), context)
        let covered = findingsLines.filter { line in
            newBaselineKeys.contains(Findings.key(line, context))
        }.count

        return BaselineUpdateStats(
            label: spec.label,
            baselinePath: spec.baselinePath,
            scopePattern: spec.scopePattern,
            findingsCaptured: findingsLines.count,
            added: newBaselineKeys.subtracting(oldBaselineKeys).count,
            refreshed: oldBaselineKeys.intersection(newBaselineKeys).count,
            removed: oldBaselineKeys.subtracting(newBaselineKeys).count,
            covered: covered,
            remaining: newBaselineKeys.count
        )
    }
}
