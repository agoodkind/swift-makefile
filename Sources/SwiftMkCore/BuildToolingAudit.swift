//
//  BuildToolingAudit.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-06.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - BuildToolingAudit

/// The make-side half of the build-tooling ban. The swiftcheck `unrouted_build_tooling`
/// rule stops a Swift dev tool from shelling the build toolchain; this stops a
/// consumer Makefile from doing the same. A consumer routes generate/build/test
/// through `$(SWIFT_MK_BIN) toolchain ...`, so a consumer Makefile names `tuist`,
/// `xcodegen`, or `xcodebuild` only when it bypasses the chokepoint.
///
/// It scans the given make files (the consumer's `Makefile` and any consumer
/// `*.mk`, not swift-mk's own fetched modules) and reports any recipe or
/// assignment line that invokes the toolchain directly, by the bare executable
/// name or a `$(TUIST)`-style alias. There is no opt-out marker and no allowed
/// form other than going through the binary.
public enum BuildToolingAudit {
  /// A finding: the file, the 1-based line, and the offending line text.
  public struct Finding: Sendable, Equatable {
    public let path: String
    public let line: Int
    public let text: String

    public var rendered: String {
      "\(path):\(line): build-tooling-audit: invoke the build toolchain through "
        + "$(SWIFT_MK_BIN) toolchain, not tuist/xcodegen/xcodebuild directly: \(text)"
    }
  }

  /// Scan files for direct toolchain invocations. A missing file contributes
  /// nothing. Comment lines (after optional leading whitespace, starting with `#`)
  /// are skipped.
  public static func scan(paths: [String]) -> [Finding] {
    var findings: [Finding] = []
    for path in paths {
      findings.append(contentsOf: scanFile(path))
    }
    return findings
  }

  private static func scanFile(_ path: String) -> [Finding] {
    let contents: String
    do {
      contents = try String(contentsOfFile: path, encoding: .utf8)
    } catch {
      return []
    }
    var findings: [Finding] = []
    let lines = contents.components(separatedBy: .newlines)
    for (index, rawLine) in lines.enumerated() {
      let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty || trimmed.hasPrefix("#") {
        continue
      }
      if lineInvokesToolchain(rawLine) {
        findings.append(
          Finding(path: path, line: index + 1, text: trimmed))
      }
    }
    return findings
  }

  /// Whether a make line invokes the toolchain, as opposed to naming it as data.
  /// A line invokes the toolchain when it uses a `$(TUIST)`-style alias, or when
  /// it is a recipe line (tab-indented) that runs a bare `tuist`/`xcodegen`/
  /// `xcodebuild` command. A variable assignment whose value is the tool name,
  /// such as the sanctioned `SWIFT_XCODE_GENERATOR := tuist` generator selector,
  /// is data, not an invocation, so it is not flagged. The sanctioned
  /// `$(SWIFT_MK_BIN) toolchain build` recipe contains no such token.
  static func lineInvokesToolchain(_ line: String) -> Bool {
    for alias in ["$(TUIST)", "$(XCODEGEN)", "$(XCODEBUILD)"] where line.contains(alias) {
      return true
    }
    // Only a recipe command line (tab-indented) runs a bare executable; a make
    // variable assignment that mentions the tool name is data.
    guard line.hasPrefix("\t") else {
      return false
    }
    let separators = CharacterSet(charactersIn: " \t;&|()")
    let tokens = line.components(separatedBy: separators)
    let bareTools: Set<String> = ["tuist", "xcodegen", "xcodebuild"]
    return tokens.contains { bareTools.contains($0) }
  }
}
