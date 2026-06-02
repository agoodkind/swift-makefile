//
//  Lint.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-25.
//  Copyright © 2026, all rights reserved.
//

import Foundation

#if canImport(Darwin)
    import Darwin
#endif

// MARK: - Lint

/// Lint orchestration. Port of `scripts/swift-mk-lint.sh`.
public enum Lint {
    static let remediation = "Fix the new findings before this gate will pass."

    static let complexityRulesDefault = [
        "cyclomatic_complexity", "function_body_length", "closure_body_length", "file_length",
        "type_body_length", "function_parameter_count", "large_tuple", "nesting", "todo",
    ].joined(separator: ",")

    /// The swiftlint rules the complexity gate and its baseline run against.
    static func complexityRules() -> [String] {
        Env.get("COMPLEXITY_RULES", complexityRulesDefault).split(separator: ",").map(String.init)
    }

    // MARK: concurrency

    private static let loadAverageSampleCount = 3
    private static let currentLoadIndex = 0
    private static let reservedProcessorCount = 1
    private static let singleProcessorMinimum = 1
    private static let multiProcessorMinimum = 2
    private static let multiProcessorThreshold = 2

    static func effectiveConcurrency() -> Int {
        let requested = Env.get("LINT_CONCURRENCY", "auto")
        let processors = max(ProcessInfo.processInfo.activeProcessorCount, 1)
        if requested != "auto" { return Int(requested) ?? 0 }
        var loads = [Double](repeating: 0, count: loadAverageSampleCount)
        #if canImport(Darwin)
            getloadavg(&loads, Int32(loadAverageSampleCount))
        #endif
        var value = Int(
            Double(processors) - loads[currentLoadIndex] - Double(reservedProcessorCount))
        let minimum =
            processors < multiProcessorThreshold
            ? singleProcessorMinimum : multiProcessorMinimum
        if value < minimum { value = minimum }
        if value > processors { value = processors }
        return value
    }

    static func lintEnvironment() -> [String: String] {
        let concurrency = effectiveConcurrency()
        return concurrency > 0 ? ["SWIFTLINT_NUMBER_OF_THREADS": String(concurrency)] : [:]
    }

    static func baselineEnabled() -> Bool {
        // Mirror the shell `${BASELINE:-1}`: an unset or empty value becomes "1",
        // so the baseline diff gate is the default and consults the baseline file.
        let value = ProcessInfo.processInfo.environment["BASELINE"] ?? ""
        return !(value.isEmpty ? "1" : value).isEmpty
    }

    // MARK: line ranges

    private static let rangeFieldFile = 0
    private static let rangeFieldStart = 1
    private static let rangeFieldEnd = 2
    private static let rangeMinimumFieldCount = 3

    static func parseRangesFile(_ path: String) -> [LineRange] {
        Text.readLines(path).compactMap { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(
                String.init)
            guard parts.count >= rangeMinimumFieldCount,
                let start = Int(parts[rangeFieldStart]), let end = Int(parts[rangeFieldEnd])
            else {
                return nil
            }
            return LineRange(file: parts[rangeFieldFile], start: start, end: end)
        }
    }

    private static func fileSize(_ path: String) -> Int {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            return (attributes[.size] as? Int) ?? 0
        } catch {
            return 0
        }
    }

    static func applyLineRanges(_ findingsPath: String) {
        let rangesPath = Env.get("LINT_LINE_RANGES")
        guard !rangesPath.isEmpty, FileManager.default.fileExists(atPath: rangesPath),
            fileSize(rangesPath) > 0
        else { return }
        let ranges = parseRangesFile(rangesPath)
        let filtered = Capture.filterByRanges(Text.readLines(findingsPath), ranges: ranges)
        do {
            try Text.writeLines(filtered, to: findingsPath)
        } catch {
            Output.error("lint: could not write filtered findings to \(findingsPath): \(error)")
        }
    }

    // MARK: print or gate

    @discardableResult
    static func printOrGate(
        gateName: String, spec: BaselineSpec, context: PathContext
    ) -> Bool {
        if !baselineEnabled() {
            let findings = Text.readLines(spec.findingsPath)
            if !findings.isEmpty {
                Output.log("\(gateName) findings:")
                for line in findings { Output.log(Findings.rendered(line, context)) }
                Baseline.recordFailedGate(gateName)
                return false
            }
            Output.log("\(gateName): OK")
            Output.log("  Findings: 0")
            return true
        }
        return Baseline.runDiffGate(
            gateName: gateName, spec: spec, remediation: remediation, context: context
        )
    }

    // MARK: swiftlint

    static func swiftlintExclude() -> String {
        Text.excludePattern(
            Env.get("SWIFTLINT_DEFAULT_EXCLUDE_PATHS"), Env.get("SWIFTLINT_EXCLUDE_PATHS"))
    }

    /// Drops paths that git ignores, so generated or otherwise untracked files are
    /// never linted. `git check-ignore` prints the ignored subset of its argument
    /// paths; outside a git work tree it reports none and every path is kept.
    static func dropGitIgnored(_ paths: [String]) -> [String] {
        guard !paths.isEmpty else {
            return paths
        }
        Output.debug("lint: checking \(paths.count) path(s) against git ignore")
        let result = Shell.run("git", ["check-ignore"] + paths)
        let ignored = Set(
            result.stdout
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
        guard !ignored.isEmpty else {
            return paths
        }
        return paths.filter { !ignored.contains($0) }
    }

    static func captureSwiftlint(
        rawPath: String, findingsPath: String, onlyRules: [String], context: PathContext
    ) {
        Output.debug("swiftlint: capturing findings (only: \(onlyRules.joined(separator: ",")))")
        let flags = Env.words(
            Env.get("SWIFTLINT_FLAGS", "--config .make/swiftlint.yml --reporter xcode"))
        let onlyArgs = onlyRules.flatMap { ["--only-rule", $0] }
        let swiftlint = Env.get("SWIFTLINT", "swiftlint")
        let lintFiles = Env.get("LINT_FILES")
        var result: Shell.Result
        if !lintFiles.isEmpty {
            let files = Env.words(lintFiles)
            var environment = lintEnvironment()
            for (index, file) in files.enumerated() {
                environment["SCRIPT_INPUT_FILE_\(index)"] = file
            }
            environment["SCRIPT_INPUT_FILE_COUNT"] = String(files.count)
            result = Shell.run(
                swiftlint,
                ["lint", "--strict", "--use-script-input-files"] + onlyArgs + flags,
                environment: environment
            )
        } else {
            // Apply the exclude pattern and drop git-ignored paths from the target
            // list so an excluded or untracked path (such as generated Swift) is
            // never linted. Without this, an explicit file target would still fail
            // the strict run even though its findings are excluded afterward.
            let targets = dropGitIgnored(
                Text.filterExclude(
                    Env.words(Env.get("SWIFTLINT_TARGETS", "Sources Tests Package.swift")),
                    swiftlintExclude()
                )
            )
            result = Shell.run(
                swiftlint,
                ["lint", "--strict"] + onlyArgs + flags + targets,
                environment: lintEnvironment()
            )
        }
        GateStatus.last = result.status
        Capture.write(result.combined, to: rawPath)
        Capture.extractFindings(
            rawPath: rawPath,
            findingsPath: findingsPath,
            excludePattern: swiftlintExclude(),
            context: context
        )
        applyLineRanges(findingsPath)
    }

    @discardableResult
    public static func runSwiftlint(context: PathContext) -> Bool {
        Capture.ensureMakeDir()
        let raw = ".make/swiftlint.raw.out"
        let findings = ".make/swiftlint.out"
        captureSwiftlint(rawPath: raw, findingsPath: findings, onlyRules: [], context: context)
        let status = GateStatus.last
        let spec = BaselineSpec(
            findingsPath: findings,
            baselinePath: Env.get("SWIFTLINT_BASELINE", ".swiftlint-baseline.txt"),
            label: "swiftlint",
            excludePattern: swiftlintExclude()
        )
        if !printOrGate(gateName: "swiftlint", spec: spec, context: context) {
            return false
        }
        if status != 0, Text.readLines(findings).isEmpty {
            Output.log("swiftlint: FAILED")
            Output.log("  Exit status: \(status)\n")
            Output.log("Output:")
            Output.log(Text.readLines(raw).joined(separator: "\n"))
            Baseline.recordFailedGate("swiftlint")
            return false
        }
        return true
    }

    // MARK: complexity

    @discardableResult
    public static func runComplexity(context: PathContext) -> Bool {
        Capture.ensureMakeDir()
        let raw = ".make/lint-complexity.raw.out"
        let findings = ".make/lint-complexity.out"
        captureSwiftlint(
            rawPath: raw,
            findingsPath: findings,
            onlyRules: complexityRules(),
            context: context
        )
        let spec = BaselineSpec(
            findingsPath: findings,
            baselinePath: Env.get(
                "SWIFTLINT_COMPLEXITY_BASELINE", ".swiftlint-complexity-baseline.txt"),
            label: "swiftlint-complexity",
            excludePattern: swiftlintExclude()
        )
        return printOrGate(gateName: "lint-complexity", spec: spec, context: context)
    }

    // MARK: deadcode (periphery)

    static func peripheryExclude() -> String {
        Text.excludePattern(
            Env.get("PERIPHERY_DEFAULT_EXCLUDE_PATHS"), Env.get("PERIPHERY_EXCLUDE_PATHS"))
    }

    public static func captureDeadcode(
        rawPath: String,
        findingsPath: String,
        context: PathContext
    ) {
        Output.debug("periphery: capturing dead-code findings")
        let args = Env.words(
            Env.get("PERIPHERY_ARGS", "scan --config .make/periphery.yml --strict"))
        let result = Shell.run(
            Env.get("PERIPHERY", "periphery"), args, environment: lintEnvironment())
        GateStatus.last = result.status
        Capture.write(result.combined, to: rawPath)
        Capture.extractFindings(
            rawPath: rawPath,
            findingsPath: findingsPath,
            excludePattern: peripheryExclude(),
            context: context
        )
        applyLineRanges(findingsPath)
    }

    @discardableResult
    public static func runDeadcode(context: PathContext) -> Bool {
        Capture.ensureMakeDir()
        let raw = ".make/periphery.raw.out"
        let findings = ".make/periphery.out"
        captureDeadcode(rawPath: raw, findingsPath: findings, context: context)
        let spec = BaselineSpec(
            findingsPath: findings,
            baselinePath: Env.get("PERIPHERY_BASELINE", ".periphery-baseline.txt"),
            label: "periphery",
            excludePattern: peripheryExclude()
        )
        return printOrGate(gateName: "lint-deadcode", spec: spec, context: context)
    }
}

// MARK: - GateStatus

/// Last external command status, mirroring `SWIFT_MK_COMMAND_STATUS`.
enum GateStatus {
    nonisolated(unsafe) static var last: Int32 = 0
}
