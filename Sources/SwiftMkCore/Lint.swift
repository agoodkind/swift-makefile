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

  // MARK: swiftlint

  static func swiftlintExclude() -> String {
    Text.excludePattern(
      Env.get("SWIFTLINT_DEFAULT_EXCLUDE_PATHS"), Env.get("SWIFTLINT_EXCLUDE_PATHS"))
  }

  static func captureSwiftlint(
    rawPath: String, findingsPath: String, onlyRules: [String], context: PathContext
  ) {
    Output.debug("swiftlint: capturing findings (only: \(onlyRules.joined(separator: ",")))")
    let flags = Env.words(
      Env.get("SWIFTLINT_FLAGS", "--config .make/swiftlint.yml --reporter xcode"))
    let invocation = SwiftlintCapture.invocation(onlyRules: onlyRules, flags: flags)
    let result = Shell.run(
      invocation.executable,
      invocation.arguments,
      environment: invocation.environment
    )
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

  static func captureSwiftlintStructured(
    rawPath: String,
    onlyRules: [String],
    context: PathContext
  ) -> [Finding] {
    SwiftlintCapture.capture(rawPath: rawPath, onlyRules: onlyRules, context: context)
  }

  @discardableResult
  public static func runSwiftlint(context: PathContext) -> Bool {
    Capture.ensureMakeDir()
    Output.debug("swiftlint: running gate")
    let raw = ".make/swiftlint.raw.out"
    let findings = captureSwiftlintStructured(rawPath: raw, onlyRules: [], context: context)
    let status = GateStatus.last
    if !StructuredGate.run(
      gateName: "swiftlint",
      findings: findings,
      baselinePath: Env.get("SWIFTLINT_BASELINE", ".swiftlint-baseline.jsonl"),
      remediation: remediation
    ) {
      return false
    }
    if status != 0, findings.isEmpty {
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
    Output.debug("lint-complexity: running gate")
    let raw = ".make/lint-complexity.raw.out"
    let findings = captureSwiftlintStructured(
      rawPath: raw,
      onlyRules: complexityRules(),
      context: context
    )
    return StructuredGate.run(
      gateName: "lint-complexity",
      findings: findings,
      baselinePath: Env.get(
        "SWIFTLINT_COMPLEXITY_BASELINE", ".swiftlint-complexity-baseline.jsonl"),
      remediation: remediation
    )
  }

  // MARK: deadcode (periphery)

  /// A `periphery` exit status of 0 means no findings and 1 means findings; this
  /// threshold and above is a build or usage failure the gate fails loudly on.
  static let deadcodeHardFailStatus: Int32 = 2

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
    // Label the first of the two scans, then echo its result, so the package scan's
    // "No unused code detected" is plainly the package half and is never confused
    // with the Xcode scan's verdict below. The label goes into the raw capture too,
    // so a later `Output:` dump of the capture stays self-describing.
    Output.log(DeadcodeScan.packageScanLabel)
    let args = Env.words(
      Env.get("PERIPHERY_ARGS", "scan --config .make/periphery.yml --strict"))
    let result = Shell.run(
      Env.get("PERIPHERY", "periphery"), args, environment: lintEnvironment())
    GateStatus.last = result.status
    Capture.write(DeadcodeScan.packageScanLabel + "\n" + result.combined, to: rawPath)
    Output.log(result.combined.trimmingCharacters(in: .newlines))
    DeadcodeScan.appendXcodeFindings(rawPath: rawPath)
    Capture.extractFindings(
      rawPath: rawPath,
      findingsPath: findingsPath,
      excludePattern: peripheryExclude(),
      context: context
    )
    applyLineRanges(findingsPath)
  }

  /// Whether a build-output line is a Swift compiler error
  /// (`<path>.swift:<line>:<col>: error: ...`), as opposed to a periphery finding,
  /// which periphery emits as a `warning:`, or periphery's own `Error: Found N
  /// issues` summary, which carries no `file:line:col`.
  static func isSwiftCompileError(_ line: String) -> Bool {
    line.range(of: #"\.swift:[0-9]+:[0-9]+: error:"#, options: .regularExpression) != nil
  }

  static func parseDeadcodeFindings(findingsPath: String, context: PathContext) -> [Finding] {
    Text.readLines(findingsPath)
      .compactMap(parsePeripheryFinding)
      .map { normalizeFinding($0, context: context) }
  }

  @discardableResult
  public static func runDeadcode(context: PathContext) -> Bool {
    // The Xcode coverage build is analysis-only, but it still routes through the
    // guarded toolchain path, so the deadcode gate must carry the gate proof.
    GateProof.mark(context: context)
    Capture.ensureMakeDir()
    Output.debug("lint-deadcode: running gate")
    let raw = ".make/periphery.raw.out"
    let findings = ".make/periphery.out"
    captureDeadcode(rawPath: raw, findingsPath: findings, context: context)
    let status = GateStatus.last
    // A compile error during periphery's own build leaves a partial index, and
    // periphery then reports referenced declarations as unused. Periphery does not
    // fail loudly on this (it builds what it can and analyzes the rest), so without
    // this check the gate passes the resulting phantom findings to the baseline
    // diff, where a real build break masquerades as dead code. The shared reporter
    // detects the compile error and the index/build failures, prints the classifying
    // verdict, and fails on the real cause first.
    if reportDeadcodeBuildFailure(rawPath: raw, status: status) {
      Baseline.recordFailedGate("lint-deadcode")
      return false
    }
    let parsedFindings = parseDeadcodeFindings(findingsPath: findings, context: context)
    return StructuredGate.run(
      gateName: "lint-deadcode",
      findings: parsedFindings,
      baselinePath: Env.get("PERIPHERY_BASELINE", ".periphery-baseline.jsonl"),
      remediation: remediation
    )
  }
}

private func parsePeripheryFinding(_ line: String) -> Finding? {
  let fileCaptureGroup = 1
  let lineCaptureGroup = 2
  let columnCaptureGroup = 3
  let messageCaptureGroup = 4
  let pattern = #"^(.*?):([0-9]+):([0-9]+): (?:warning|error): (.*)$"#
  let expression: NSRegularExpression
  do {
    expression = try NSRegularExpression(pattern: pattern)
  } catch {
    return nil
  }
  guard
    let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
  else {
    return nil
  }
  guard let fileRange = Range(match.range(at: fileCaptureGroup), in: line),
    let lineRange = Range(match.range(at: lineCaptureGroup), in: line),
    let columnRange = Range(match.range(at: columnCaptureGroup), in: line),
    let messageRange = Range(match.range(at: messageCaptureGroup), in: line),
    let lineNumber = Int(line[lineRange]),
    let columnNumber = Int(line[columnRange])
  else {
    return nil
  }
  let message = String(line[messageRange])
  return Finding(
    tool: "periphery",
    ruleId: "",
    file: String(line[fileRange]),
    line: lineNumber,
    column: columnNumber,
    severity: .warning,
    message: message,
    usr: nil,
    symbol: firstSingleQuotedToken(in: message)
  )
}

private func firstSingleQuotedToken(in text: String) -> String {
  guard let openIndex = text.firstIndex(of: "'") else {
    return ""
  }
  let tokenStart = text.index(after: openIndex)
  guard let closeIndex = text[tokenStart...].firstIndex(of: "'") else {
    return ""
  }
  return String(text[tokenStart..<closeIndex])
}

private func normalizeFinding(_ finding: Finding, context: PathContext) -> Finding {
  Finding(
    tool: finding.tool,
    ruleId: finding.ruleId,
    file: Findings.normalizePath(finding.file, context),
    line: finding.line,
    column: finding.column,
    severity: finding.severity,
    message: finding.message,
    usr: finding.usr,
    symbol: finding.symbol,
    hints: finding.hints
  )
}

// MARK: - SwiftlintCapture

private enum SwiftlintCapture {
  struct Invocation {
    let executable: String
    let arguments: [String]
    let environment: [String: String]
  }

  static func invocation(onlyRules: [String], flags: [String]) -> Invocation {
    let onlyArgs = onlyRules.flatMap { ["--only-rule", $0] }
    let swiftlint = Env.get("SWIFTLINT", "swiftlint")
    let lintFiles = Env.get("LINT_FILES")
    if !lintFiles.isEmpty {
      let files = Env.words(lintFiles)
      var environment = Lint.lintEnvironment()
      for (index, file) in files.enumerated() {
        environment["SCRIPT_INPUT_FILE_\(index)"] = file
      }
      environment["SCRIPT_INPUT_FILE_COUNT"] = String(files.count)
      return Invocation(
        executable: swiftlint,
        arguments: ["lint", "--strict", "--use-script-input-files"] + onlyArgs + flags,
        environment: environment
      )
    }

    // Keep excluded or git-ignored explicit targets out of swiftlint itself.
    let targets = Lint.dropGitIgnored(
      Text.filterExclude(
        Env.words(Env.get("SWIFTLINT_TARGETS", "Sources Tests Package.swift")),
        Lint.swiftlintExclude()
      )
    )
    return Invocation(
      executable: swiftlint,
      arguments: ["lint", "--strict"] + onlyArgs + flags + targets,
      environment: Lint.lintEnvironment()
    )
  }

  static func capture(rawPath: String, onlyRules: [String], context: PathContext) -> [Finding] {
    Output.debug(
      "swiftlint: capturing structured findings (only: \(onlyRules.joined(separator: ",")))")
    Capture.write("", to: rawPath)
    let invocation = invocation(onlyRules: onlyRules, flags: structuredFlags())
    var captured: [Finding] = []
    var decodeError: Error?
    do {
      captured = try FindingsSource.swiftlint(
        executable: invocation.executable,
        arguments: invocation.arguments,
        environment: invocation.environment
      )
    } catch {
      decodeError = error
      Output.error(
        "swiftlint: \(error); failing the gate rather than passing on undecodable output")
    }
    let result = Shell.run(
      invocation.executable,
      invocation.arguments + ["--reporter", "json"],
      environment: invocation.environment
    )
    GateStatus.last = result.status
    Capture.write(result.combined, to: rawPath)

    let normalized = captured.map { normalize($0, context: context) }
    let excluded = applyExclude(normalized)
    let notIgnored = dropGitIgnored(excluded)
    var findings = applyLineRanges(notIgnored)
    if let decodeError {
      // A non-empty, undecodable result is unknown, not clean: append a finding the
      // baseline never matches so the gate fails loud, past the exclude and line-range
      // filters so it cannot be dropped.
      findings.append(undecodableFinding(decodeError))
    }
    return findings
  }

  private static func undecodableFinding(_ error: Error) -> Finding {
    Finding(
      tool: "swiftlint",
      ruleId: "output-not-decodable",
      file: "",
      line: 0,
      column: 0,
      severity: .error,
      message:
        "swiftlint --reporter json output could not be decoded; "
        + "the gate cannot verify results: \(error)"
    )
  }

  private static func structuredFlags() -> [String] {
    let flags = Env.words(Env.get("SWIFTLINT_FLAGS", "--config .make/swiftlint.yml"))
    var filtered: [String] = []
    var shouldSkipNext = false
    for flag in flags {
      if shouldSkipNext {
        shouldSkipNext = false
        continue
      }
      if flag == "--reporter" {
        shouldSkipNext = true
        continue
      }
      if flag.hasPrefix("--reporter=") {
        continue
      }
      filtered.append(flag)
    }
    return filtered
  }

  private static func normalize(_ finding: Finding, context: PathContext) -> Finding {
    Finding(
      tool: finding.tool,
      ruleId: finding.ruleId,
      file: Findings.normalizePath(finding.file, context),
      line: finding.line,
      column: finding.column,
      severity: finding.severity,
      message: finding.message,
      usr: finding.usr,
      symbol: finding.symbol,
      hints: finding.hints
    )
  }

  private static func applyExclude(_ findings: [Finding]) -> [Finding] {
    let includedFiles = Set(Text.filterExclude(findings.map(\.file), Lint.swiftlintExclude()))
    return findings.filter { includedFiles.contains($0.file) }
  }

  private static func dropGitIgnored(_ findings: [Finding]) -> [Finding] {
    let files = Set(findings.map(\.file).filter { !$0.isEmpty })
    let keptFiles = Set(Lint.dropGitIgnored(Array(files)))
    return findings.filter { $0.file.isEmpty || keptFiles.contains($0.file) }
  }

  private static func applyLineRanges(_ findings: [Finding]) -> [Finding] {
    let rangesPath = Env.get("LINT_LINE_RANGES")
    guard !rangesPath.isEmpty, FileManager.default.fileExists(atPath: rangesPath),
      !Text.readLines(rangesPath).isEmpty
    else { return findings }
    let ranges = Lint.parseRangesFile(rangesPath)
    return findings.filter { finding in
      ranges.contains { $0.contains(file: finding.file, line: finding.line) }
    }
  }
}

// MARK: - GateStatus

/// Last external command status, mirroring `SWIFT_MK_COMMAND_STATUS`.
enum GateStatus {
  nonisolated(unsafe) static var last: Int32 = 0
}
