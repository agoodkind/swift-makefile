//
//  SwiftlintCapture.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-09-02.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - SwiftlintCapture

enum SwiftlintCapture {
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
    guard LintResources.ensure(context: context) else {
      Output.error("swiftlint: could not materialize SwiftLint config from git identity")
      GateStatus.last = 1
      return []
    }
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
