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
/// `*.mk`, not swift-mk's own fetched modules) and reports any recipe line that
/// invokes the toolchain directly, by the bare executable name in command
/// position or a `$(TUIST)`-style alias. There is no opt-out marker and no
/// allowed form other than going through the binary.
public enum BuildToolingAudit {
  private static let minimumQuotedWordLength = 2
  private static let uppercaseA: Unicode.Scalar = "A"
  private static let uppercaseZ: Unicode.Scalar = "Z"
  private static let lowercaseA: Unicode.Scalar = "a"
  private static let lowercaseZ: Unicode.Scalar = "z"
  private static let zeroDigit: Unicode.Scalar = "0"
  private static let nineDigit: Unicode.Scalar = "9"

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

  /// Whether a make recipe line invokes the toolchain, as opposed to naming it as
  /// data. A recipe invokes the toolchain when it uses a `$(TUIST)`-style alias,
  /// or when a shell command segment runs a bare `tuist`/`xcodegen`/`xcodebuild`
  /// command. A tool name used as a variable value or flag argument, such as
  /// `--generator xcodegen`, is data, not an invocation, so it is not flagged.
  static func lineInvokesToolchain(_ line: String) -> Bool {
    // Only a recipe command line (tab-indented) runs a tool; a make variable
    // assignment that mentions the tool name or a `$(TUIST)` alias is data, such
    // as `LMD_DEV = ... TUIST="$(TUIST)" swift run ...`, which passes the alias
    // through as an env value rather than invoking it.
    guard line.hasPrefix("\t") else {
      return false
    }
    // A `$(TUIST)`-style alias invokes the tool only when used as a command, not
    // when passed as data such as an env value (`FOO="$(TUIST)" cmd`). Flag an
    // occurrence only when it is not immediately preceded by `=`, `"`, or `'`.
    for alias in ["$(TUIST)", "$(XCODEGEN)", "$(XCODEBUILD)"] {
      var searchStart = line.startIndex
      while let range = line.range(of: alias, range: searchStart..<line.endIndex) {
        let precededByData: Bool
        if range.lowerBound == line.startIndex {
          precededByData = false
        } else {
          let before = line[line.index(before: range.lowerBound)]
          precededByData = before == "=" || before == "\"" || before == "'"
        }
        if !precededByData {
          return true
        }
        searchStart = range.upperBound
      }
    }
    let bareTools: Set<String> = ["tuist", "xcodegen", "xcodebuild"]
    return commandSegments(in: line).contains { segment in
      guard let commandWord = commandWord(in: segment) else {
        return false
      }
      return bareTools.contains(commandWord)
    }
  }

  private static func commandSegments(in line: String) -> [Substring] {
    var segments: [Substring] = []
    var segmentStart = line.startIndex
    var index = line.startIndex
    var activeQuote: Character?

    while index < line.endIndex {
      let character = line[index]
      if let quote = activeQuote {
        if character == quote {
          activeQuote = nil
        }
        index = line.index(after: index)
        continue
      }
      if character == "\"" || character == "'" {
        activeQuote = character
        index = line.index(after: index)
        continue
      }
      if character == ";" || character == "|" || character == "&" {
        segments.append(line[segmentStart..<index])
        let nextIndex = line.index(after: index)
        if nextIndex < line.endIndex, line[nextIndex] == character {
          index = line.index(after: nextIndex)
        } else {
          index = nextIndex
        }
        segmentStart = index
        continue
      }
      index = line.index(after: index)
    }
    segments.append(line[segmentStart..<line.endIndex])
    return segments
  }

  private static func commandWord(in segment: Substring) -> String? {
    for rawToken in segment.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
      let token = stripSurroundingQuotes(String(rawToken))
      if isAssignmentPrefix(token) {
        continue
      }
      return token
    }
    return nil
  }

  private static func stripSurroundingQuotes(_ word: String) -> String {
    guard word.count >= minimumQuotedWordLength, let first = word.first, let last = word.last else {
      return word
    }
    if first == "\"", last == "\"" {
      return String(word.dropFirst().dropLast())
    }
    if first == "'", last == "'" {
      return String(word.dropFirst().dropLast())
    }
    return word
  }

  private static func isAssignmentPrefix(_ word: String) -> Bool {
    guard let equalsIndex = word.firstIndex(of: "="), equalsIndex != word.startIndex else {
      return false
    }
    let name = word[..<equalsIndex]
    guard let first = name.unicodeScalars.first, isShellNameStart(first) else {
      return false
    }
    for scalar in name.unicodeScalars.dropFirst() where !isShellNameCharacter(scalar) {
      return false
    }
    return true
  }

  private static func isShellNameStart(_ scalar: Unicode.Scalar) -> Bool {
    scalar == "_" || isAsciiLetter(scalar)
  }

  private static func isShellNameCharacter(_ scalar: Unicode.Scalar) -> Bool {
    isShellNameStart(scalar) || isAsciiDigit(scalar)
  }

  private static func isAsciiLetter(_ scalar: Unicode.Scalar) -> Bool {
    (uppercaseA...uppercaseZ).contains(scalar) || (lowercaseA...lowercaseZ).contains(scalar)
  }

  private static func isAsciiDigit(_ scalar: Unicode.Scalar) -> Bool {
    (zeroDigit...nineDigit).contains(scalar)
  }
}
