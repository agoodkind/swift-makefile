import Foundation

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

    /// Per-update key counts. Port of `swift_mk_print_baseline_update_counts`.
    public static func printUpdateCounts(
        _ spec: BaselineSpec, mode: BaselineMode, context: PathContext
    ) {
        let findingsLines = Text.readLines(spec.findingsPath)
        let baselineLines = findings(spec, context: context)
        let findingsKeys = keyize(findingsLines, context)
        let baselineKeys = keyize(baselineLines, context)
        let new = findingsKeys.subtracting(baselineKeys).count
        let refreshed = findingsKeys.intersection(baselineKeys).count
        let gone = baselineKeys.subtracting(findingsKeys).count

        Output.log("This update:")
        Output.log("  Findings captured: \(findingsLines.count)")
        switch mode {
        case .pruneFixed:
            Output.log("  Keys added: 0")
            Output.log("  Keys refreshed: \(refreshed)")
            Output.log("  Keys removed: \(gone)")
            if new > 0 { Output.log("  Keys left unsaved: \(new)") }
        case .acceptNew:
            Output.log("  Keys added: \(new)")
            Output.log("  Keys refreshed: \(refreshed)")
            Output.log("  Keys removed: 0")
            if gone > 0 { Output.log("  Keys kept unchanged: \(gone)") }
        case .sync:
            Output.log("  Keys added: \(new)")
            Output.log("  Keys refreshed: \(refreshed)")
            Output.log("  Keys removed: \(gone)")
        }
    }

    /// Overall coverage counts. Port of `swift_mk_print_baseline_overall_counts`.
    public static func printOverallCounts(_ spec: BaselineSpec, context: PathContext) {
        let findingsLines = Text.readLines(spec.findingsPath)
        let baselineLines = findings(spec, context: context)
        let baselineKeys = keyize(baselineLines, context)
        let covered = findingsLines.filter { baselineKeys.contains(Findings.key($0, context)) }
            .count
        Output.log("\nOverall baseline:")
        Output.log("  Current findings covered: \(covered)")
        Output.log("  Total keys: \(baselineKeys.count)")
    }

    /// Full component baseline update: counts, rewrite, overall counts.
    /// Port of `write_component_baseline`.
    public static func writeComponent(
        title: String, _ spec: BaselineSpec, mode: BaselineMode, context: PathContext
    ) throws {
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
        Output.log("\(spec.label) baseline update")
        Output.log("  File: \(spec.baselinePath)")
        Output.log("  Mode: \(mode.rawValue)")
        Output.log("  Scope: \(spec.scopePattern.isEmpty ? "all" : spec.scopePattern)\n")
        printUpdateCounts(spec, mode: mode, context: context)
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
        printOverallCounts(spec, context: context)
        Output.log("\n\(spec.label): baseline \(spec.baselinePath) refreshed")
    }
}
