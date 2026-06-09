//
//  Swiftcheck.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-25.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - Swiftcheck

/// Build, resolve, and run the `swiftcheck-extra` analyzer binary.
///
/// Port of `scripts/swift-mk-swiftcheck-extra.sh`.
public enum Swiftcheck {
  private static let executablePermissions: Int16 = 0o755
  private static let locationFieldCount = 2
  private static let toolName = "swiftcheck-extra"
  private static var locationPattern: Regex<Substring> { /:[0-9]+:[0-9]+:/ }

  static func outputPath() -> String {
    let root = Env.get("SWIFT_MK_ROOT", FileManager.default.currentDirectoryPath)
    return root + "/.make/swiftcheck-extra"
  }

  private static func modificationDate(of path: String) -> Date? {
    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: path)
      return attributes[.modificationDate] as? Date
    } catch {
      return nil
    }
  }

  static func missingFlags(_ binary: String) -> Bool {
    Output.debug("swiftcheck-extra: probing flags of \(binary)")
    let available = Shell.run(binary, ["-flags"]).combined
    for word in Env.words(Env.get("SWIFTCHECK_EXTRA_FLAGS")) {
      let name = word.hasPrefix("-") ? String(word.dropFirst()) : word
      if !available.contains("Name: \(name)") { return true }
    }
    return false
  }

  @discardableResult
  static func buildFromRepo() -> Bool {
    Output.info("swiftcheck-extra: building analyzer from repo")
    let repo = Env.get("SWIFTCHECK_EXTRA_BUILD_REPO")
    let product = Env.get("SWIFTCHECK_EXTRA_BUILD_PRODUCT", "swiftcheck-extra")
    let output = outputPath()
    do {
      try FileManager.default.createDirectory(
        atPath: URL(fileURLWithPath: output).deletingLastPathComponent().path,
        withIntermediateDirectories: true
      )
    } catch {
      Output.error("swiftcheck-extra: could not create output directory: \(error)")
    }
    let build = Shell.run(
      "swift", ["build", "--package-path", repo, "-c", "release", "--product", product])
    if build.status != 0 {
      Output.emitStandardError(build.combined)
      return false
    }
    let binPathOutput = Shell.run(
      "swift", ["build", "--package-path", repo, "-c", "release", "--show-bin-path"]
    ).stdout
    let binDir = binPathOutput.split(separator: "\n").last.map(String.init) ?? ""
    let built = binDir + "/" + product
    removeIfPresent(output)
    do {
      try FileManager.default.copyItem(atPath: built, toPath: output)
    } catch {
      Output.emitStandardError("swiftcheck-extra: copy failed: \(error)\n")
      return false
    }
    do {
      try FileManager.default.setAttributes(
        [.posixPermissions: executablePermissions], ofItemAtPath: output)
    } catch {
      Output.error("swiftcheck-extra: could not set permissions on \(output): \(error)")
    }
    return true
  }

  /// Remove a path if it exists, reporting but tolerating a removal failure.
  private static func removeIfPresent(_ path: String) {
    guard FileManager.default.fileExists(atPath: path) else { return }
    do {
      try FileManager.default.removeItem(atPath: path)
    } catch {
      Output.error("swiftcheck-extra: could not remove \(path): \(error)")
    }
  }

  private static func newestSwiftModified(under directory: String) -> Date? {
    guard let enumerator = FileManager.default.enumerator(atPath: directory) else { return nil }
    var newest: Date?
    for case let path as String in enumerator where path.hasSuffix(".swift") {
      let full = directory + "/" + path
      guard let date = modificationDate(of: full) else { continue }
      if let current = newest {
        if date > current { newest = date }
      } else {
        newest = date
      }
    }
    return newest
  }

  /// The `SWIFTCHECK_EXTRA_BIN` override, or nil when unset or empty.
  private static func configuredBin() -> String? {
    let configured = ProcessInfo.processInfo.environment["SWIFTCHECK_EXTRA_BIN"] ?? ""
    return configured.isEmpty ? nil : configured
  }

  private static func outputNeedsBuild(output: String, repo: String) -> Bool {
    guard FileManager.default.isExecutableFile(atPath: output) else { return true }
    guard let outputDate = modificationDate(of: output) else { return true }
    if let newest = newestSwiftModified(under: repo), newest > outputDate { return true }
    return missingFlags(output)
  }

  @discardableResult
  public static func resolveBin() -> Bool {
    if let configured = configuredBin() {
      guard FileManager.default.isExecutableFile(atPath: configured) else {
        Output.log("swiftcheck-extra: \(configured) not executable")
        return false
      }
      guard !missingFlags(configured) else {
        Output.log("swiftcheck-extra: \(configured) does not support requested flags")
        return false
      }
      return true
    }
    let repo = Env.get("SWIFTCHECK_EXTRA_BUILD_REPO")
    guard !repo.isEmpty, FileManager.default.fileExists(atPath: repo) else {
      Output.log("swiftcheck-extra: build repo \(repo) not present")
      return false
    }
    if outputNeedsBuild(output: outputPath(), repo: repo) {
      return buildFromRepo()
    }
    return true
  }

  static func selectedBin() -> String? {
    if let configured = configuredBin() { return configured }
    let output = outputPath()
    return FileManager.default.isExecutableFile(atPath: output) ? output : nil
  }

  public static func captureFindings(
    rawPath: String,
    findingsPath: String,
    context: PathContext
  ) {
    Output.debug("swiftcheck-extra: capturing analyzer findings")
    Capture.write("", to: rawPath)
    GateStatus.last = 0
    guard let binary = selectedBin(), FileManager.default.isExecutableFile(atPath: binary)
    else {
      Output.log("swiftcheck-extra: not configured")
      Capture.write("", to: findingsPath)
      return
    }
    let flags = Env.words(Env.get("SWIFTCHECK_EXTRA_FLAGS"))
    let exclude = Text.excludePattern(
      Env.get("SWIFTCHECK_EXTRA_DEFAULT_EXCLUDE_PATHS"),
      Env.get("SWIFTCHECK_EXTRA_EXCLUDE_PATHS")
    )
    // Drop excluded and git-ignored paths so generated or untracked files are
    // never analyzed.
    let targets = Lint.dropGitIgnored(
      Text.filterExclude(
        Env.words(Env.get("SWIFTCHECK_EXTRA_TARGETS", "Sources Tests Package.swift")),
        exclude
      )
    )
    let result = Shell.run(binary, flags + targets)
    GateStatus.last = result.status
    Capture.write(result.combined, to: rawPath)
    let normalized = Text.readLines(rawPath).map { Findings.normalizePath($0, context) }
    let excluded = Text.filterExclude(normalized, exclude)
    do {
      try Text.writeLines(Text.sortedUnique(excluded), to: findingsPath)
    } catch {
      Output.error("swiftcheck-extra: could not write findings to \(findingsPath): \(error)")
    }
  }

  private static func parseFindingLine(_ line: String, context: PathContext) -> Finding? {
    guard let locationRange = line.firstRange(of: locationPattern) else {
      return nil
    }

    let file = String(line[line.startIndex..<locationRange.lowerBound])
    let coordinateText = line[locationRange].split(separator: ":")
    guard coordinateText.count == locationFieldCount,
      let lineNumber = Int(coordinateText[0]),
      let columnNumber = Int(coordinateText[1])
    else {
      return nil
    }

    var rest = String(line[locationRange.upperBound...])
    if rest.hasPrefix(" ") {
      rest.removeFirst()
    }
    guard let separatorRange = rest.range(of: ": ") else {
      return nil
    }

    let ruleId = String(rest[..<separatorRange.lowerBound])
    guard !ruleId.isEmpty else {
      return nil
    }
    let message = String(rest[separatorRange.upperBound...])

    return Finding(
      tool: toolName,
      ruleId: ruleId,
      file: Findings.normalizePath(file, context),
      line: lineNumber,
      column: columnNumber,
      severity: .warning,
      message: message
    )
  }

  private static func applyExclude(_ findings: [Finding], exclude: String) -> [Finding] {
    let includedFiles = Set(Text.filterExclude(findings.map(\.file), exclude))
    return findings.filter { includedFiles.contains($0.file) }
  }

  private static func dropGitIgnored(_ findings: [Finding]) -> [Finding] {
    let files = Set(findings.map(\.file).filter { !$0.isEmpty })
    let keptFiles = Set(Lint.dropGitIgnored(Array(files)))
    return findings.filter { $0.file.isEmpty || keptFiles.contains($0.file) }
  }

  private static func structuredFindings(
    rawPath: String,
    exclude: String,
    context: PathContext
  ) -> [Finding] {
    let parsed = Text.readLines(rawPath).compactMap { parseFindingLine($0, context: context) }
    let excluded = applyExclude(parsed, exclude: exclude)
    return dropGitIgnored(excluded)
  }

  @discardableResult
  public static func runGate(context: PathContext) -> Bool {
    Capture.ensureMakeDir()
    let raw = ".make/swiftcheck-extra.raw.out"
    let findings = ".make/swiftcheck-extra.out"
    let exclude = Text.excludePattern(
      Env.get("SWIFTCHECK_EXTRA_DEFAULT_EXCLUDE_PATHS"),
      Env.get("SWIFTCHECK_EXTRA_EXCLUDE_PATHS")
    )
    captureFindings(rawPath: raw, findingsPath: findings, context: context)
    let parsedFindings = structuredFindings(rawPath: raw, exclude: exclude, context: context)
    let status = GateStatus.last
    if !StructuredGate.run(
      gateName: "swiftcheck-extra",
      findings: parsedFindings,
      baselinePath: Env.get("SWIFTCHECK_EXTRA_BASELINE", ".swiftcheck-extra-baseline.jsonl"),
      remediation: Lint.remediation,
    ) {
      return false
    }
    if status != 0, parsedFindings.isEmpty {
      Output.log("swiftcheck-extra: FAILED")
      Output.log("  Exit status: \(status)\n")
      Output.log("Output:")
      Output.log(Text.readLines(raw).joined(separator: "\n"))
      Baseline.recordFailedGate("swiftcheck-extra")
      return false
    }
    return true
  }
}
