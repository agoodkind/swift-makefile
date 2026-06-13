//
//  BaselineKey.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-08.
//  Copyright © 2026, all rights reserved.
//

// MARK: - BaselineKey

public enum BaselineKey {
  /// SwiftLint rules that describe a whole file rather than one line, so there
  /// is no single offending line to key on; these stay keyed on file + rule.
  static let fileScopedRules: Set<String> = ["file_length", "file_name", "file_header"]

  /// The baseline key for a finding. Periphery keeps its symbol key. File-scoped
  /// swiftlint rules keep file + rule. Every other finding gains the normalized
  /// offending source line, so a real edit to that line stops matching the old
  /// entry while moving the code (new line number, same tokens) keeps matching.
  /// `readLine` is injected so tests stay deterministic; production reads disk.
  public static func of(
    _ finding: Finding,
    readLine: (String, Int) -> String? = BaselineKey.readSourceLine
  ) -> String {
    if finding.tool == "periphery" {
      return "\(finding.file.lowercased())\t\(finding.symbol ?? finding.ruleId)"
    }
    if fileScopedRules.contains(finding.ruleId) {
      return ruleKey(finding)
    }
    guard let rawLine = readLine(finding.file, finding.line) else {
      return ruleKey(finding)
    }
    let normalized = normalizeLine(rawLine)
    guard !normalized.isEmpty else {
      return ruleKey(finding)
    }
    return contentKey(file: finding.file, rule: finding.ruleId, lineText: normalized)
  }

  static func ruleKey(_ finding: Finding) -> String {
    "\(finding.file.lowercased())\t\(finding.ruleId)"
  }

  /// Trim ends, then collapse every internal whitespace run to a single space,
  /// so reindentation or a swift-format reflow of the same code keeps the key.
  static func normalizeLine(_ text: String) -> String {
    text.split { $0.isWhitespace }.joined(separator: " ")
  }

  static func contentKey(file: String, rule: String, lineText: String) -> String {
    "\(file.lowercased())\t\(rule)\t\(lineText)"
  }

  /// Read the 1-based line from the working-copy source file. Returns nil when
  /// the file is unreadable or the line is out of range, so the key falls back
  /// to file + rule deterministically against the same tree.
  public static func readSourceLine(_ file: String, _ line: Int) -> String? {
    guard line >= 1 else {
      return nil
    }
    let lines = Text.readLines(file)
    guard line <= lines.count else {
      return nil
    }
    return lines[line - 1]
  }
}
