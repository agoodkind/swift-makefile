//
//  Capture.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-25.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - LineRange

/// An inclusive line range within a single file, used by diff-scoped linting.
public struct LineRange: Sendable {
  public let file: String
  public let start: Int
  public let end: Int

  public init(file: String, start: Int, end: Int) {
    self.file = file
    self.start = start
    self.end = end
  }

  func contains(file otherFile: String, line: Int) -> Bool {
    file == otherFile && line >= start && line <= end
  }
}

// MARK: - Capture

/// Capture lint output and reduce it to normalized, deduplicated findings.
public enum Capture {
  /// Lines that look like `path:line:col:`. Equivalent to the shell
  /// `SWIFT_FINDING_PATTERN`.
  public static let findingPattern = "^\\S[^:]+:[0-9]+:[0-9]+:"

  private static let diffHeaderPrefix = "+++ "
  private static let diffHeaderPrefixLength = diffHeaderPrefix.count
  private static let gitPathPrefixLength = 2
  private static let hunkMarker = "@@"
  private static let hunkMinimumFieldCount = 3
  private static let hunkRangeFieldIndex = 2
  private static let defaultHunkCount = 1
  private static let findingFileFieldIndex = 0
  private static let findingLineFieldIndex = 1
  private static let findingMinimumFieldCount = 2

  static func ensureMakeDir() {
    do {
      try FileManager.default.createDirectory(
        atPath: ".make", withIntermediateDirectories: true)
    } catch {
      Output.error("capture: could not create .make directory: \(error)")
    }
  }

  static func write(_ text: String, to path: String) {
    do {
      try text.write(toFile: path, atomically: true, encoding: .utf8)
    } catch {
      Output.error("capture: could not write \(path): \(error)")
    }
  }

  /// Normalize, exclude, and dedupe the finding lines of a raw capture.
  /// Port of `swift_mk_extract_findings`.
  public static func extractFindings(
    rawPath: String,
    findingsPath: String,
    excludePattern: String,
    context: PathContext,
    matchPattern: String = findingPattern
  ) {
    let raw = Text.readLines(rawPath)
    let matched: [String]
    if let regex = Text.compile(matchPattern) {
      matched = raw.filter { $0.contains(regex) }
    } else {
      matched = raw
    }
    let normalized = matched.map { Findings.normalizePath($0, context) }
    let excluded = dropGitIgnoredFindings(Text.filterExclude(normalized, excludePattern))
    do {
      try Text.writeLines(Text.sortedUnique(excluded), to: findingsPath)
    } catch {
      Output.error("capture: could not write findings to \(findingsPath): \(error)")
    }
  }

  /// Drops findings whose file is git-ignored, so generated or untracked output
  /// never trips a gate. A path pattern is deliberately not used for this: it
  /// would let a tracked file in a matching directory escape the gate. Findings
  /// without an attributable path, and all findings outside a git work tree, are
  /// kept. `git check-ignore` prints the ignored subset of its argument paths.
  static func dropGitIgnoredFindings(_ findings: [String]) -> [String] {
    let paths = Set(findings.compactMap { Findings.filePath($0) })
    guard !paths.isEmpty else {
      return findings
    }
    // Batched so a large finding set never overflows the process argument limit.
    let ignored = Lint.gitIgnoredPaths(Array(paths))
    guard !ignored.isEmpty else {
      return findings
    }
    return findings.filter { line in
      guard let path = Findings.filePath(line) else {
        return true
      }
      return !ignored.contains(path)
    }
  }

  /// Parse a unified diff into inclusive line ranges per file.
  /// Port of the awk `ranges` action.
  public static func diffRanges(_ diff: String) -> [LineRange] {
    var ranges: [LineRange] = []
    var currentFile = ""
    for line in diff.components(separatedBy: "\n") {
      if line.hasPrefix(diffHeaderPrefix) {
        var name =
          String(line.dropFirst(diffHeaderPrefixLength))
          .split(separator: " ").first.map(String.init) ?? ""
        if name.hasPrefix("b/") { name = String(name.dropFirst(gitPathPrefixLength)) }
        currentFile = (name == "/dev/null") ? "" : name
        continue
      }
      let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(
        String.init)
      guard fields.first == hunkMarker, !currentFile.isEmpty,
        fields.count >= hunkMinimumFieldCount
      else { continue }
      var rangeText = fields[hunkRangeFieldIndex]
      if rangeText.hasPrefix("+") { rangeText = String(rangeText.dropFirst()) }
      let parts = rangeText.split(separator: ",").map(String.init)
      let start = Int(parts.first ?? "0") ?? 0
      let count = parts.count > 1 ? (Int(parts[1]) ?? defaultHunkCount) : defaultHunkCount
      if count > 0 {
        ranges.append(LineRange(file: currentFile, start: start, end: start + count - 1))
      }
    }
    return ranges
  }

  /// Keep only findings whose line falls inside one of the ranges.
  /// Port of the awk `linefilter` action.
  public static func filterByRanges(_ findings: [String], ranges: [LineRange]) -> [String] {
    findings.filter { line in
      let parts = line.split(separator: ":", omittingEmptySubsequences: false).map(
        String.init)
      guard parts.count >= findingMinimumFieldCount,
        let lineNumber = Int(parts[findingLineFieldIndex])
      else { return false }
      let file = parts[findingFileFieldIndex]
      return ranges.contains { $0.contains(file: file, line: lineNumber) }
    }
  }
}
