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
  /// What a finding flags, which selects its remediation text.
  public enum Kind: Sendable, Equatable {
    case codesign
    case toolchain
  }

  /// A finding: the file, the 1-based line, and the offending line text.
  public struct Finding: Sendable, Equatable {
    public let path: String
    public let line: Int
    public let text: String
    public let kind: Kind

    public init(path: String, line: Int, text: String, kind: Kind = .toolchain) {
      self.path = path
      self.line = line
      self.text = text
      self.kind = kind
    }

    public var rendered: String {
      switch kind {
      case .toolchain:
        return "\(path):\(line): build-tooling-audit: invoke the build toolchain through "
          + "$(SWIFT_MK_BIN) toolchain, not tuist/xcodegen/xcodebuild directly: \(text)"
      case .codesign:
        return "\(path):\(line): build-tooling-audit: sign through swift-mk codesign-run; "
          + "no direct codesign is permitted in consumer files: \(text)"
      }
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

  /// Scan build-pipeline files for direct codesign invocations. The detector is
  /// text-level on purpose: a spawn's flags may sit on later lines, so naming
  /// the codesign binary at all requires either routing through codesign-run or
  /// the explicit fallback marker.
  public static func scanCodesign(paths: [String]) -> [Finding] {
    var findings: [Finding] = []
    for path in paths {
      let contents: String
      do {
        contents = try String(contentsOfFile: path, encoding: .utf8)
      } catch {
        continue
      }
      let lines = contents.components(separatedBy: .newlines)
      for (index, rawLine) in lines.enumerated() where lineRunsCodesign(rawLine) {
        findings.append(
          Finding(
            path: path,
            line: index + 1,
            text: rawLine.trimmingCharacters(in: .whitespaces),
            kind: .codesign))
      }
    }
    return findings
  }

  /// Whether a line reaches the codesign binary outside the canonical channel.
  /// There is deliberately no opt-out marker: a marker is exactly the string a
  /// code-generating agent would copy onto a bypass. Comments cannot execute
  /// and pass; a line that only verifies (`--verify` present, no sign flag)
  /// passes because verification is not a signing path; everything else that
  /// names codesign is a bypass, including spawns whose flags sit on later
  /// lines.
  static func lineRunsCodesign(_ line: String) -> Bool {
    if line.contains("codesign-run") {
      return false
    }
    guard line.contains("codesign") else {
      return false
    }
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("#") || trimmed.hasPrefix("//") {
      return false
    }
    if line.contains("--sign - ") || line.contains(" -s - ") {
      // Explicit ad-hoc signing cannot carry an identity, cannot notarize, and
      // is how the bootstrap signs the swift-mk binary into existence.
      return false
    }
    if line.contains("--sign") || line.contains(" -s ") {
      return true
    }
    if line.contains("--verify") {
      return false
    }
    let spawnForms = ["\"codesign\"", "'codesign'", "/usr/bin/codesign"]
    if spawnForms.contains(where: { line.contains($0) }) {
      return true
    }
    return trimmed.hasPrefix("codesign ")
  }

  /// Build-output and vendored-dependency directory names excluded from the
  /// codesign scan. A dev-tool SPM package under Tools/ checks its dependencies
  /// out into Tools/.build/checkouts/, which contains swift-mk's own source; that
  /// source legitimately spawns `codesign`, so scanning it would flag the engine
  /// as a consumer violation. These are never consumer-authored sources.
  static let scanExcludedDirectories: Set<String> = [
    ".build", ".swiftpm", "SourcePackages", "checkouts", "DerivedData",
    "Products", ".git",
  ]

  /// The default codesign scan set: the entry Makefile, the project manifests,
  /// and every script or dev-tool source under Scripts/ and Tools/, skipping
  /// build output and vendored SPM dependency checkouts.
  public static func codesignScanPaths(makefile: String) -> [String] {
    var paths = [makefile, "project.yml", "Project.swift", "Workspace.swift"]
    let fileManager = FileManager.default
    for root in ["Scripts", "Tools"] {
      guard let enumerator = fileManager.enumerator(atPath: root) else {
        continue
      }
      for case let relative as String in enumerator {
        if pathIsInExcludedDirectory(relative) {
          // Skip the whole vendored or build subtree, not just this entry.
          enumerator.skipDescendants()
          continue
        }
        if relative.hasSuffix(".swift") || relative.hasSuffix(".sh")
          || relative.hasSuffix(".yml")
        {
          paths.append(root + "/" + relative)
        }
      }
    }
    return paths
  }

  /// Whether a Scripts/Tools-relative path lies inside an excluded build or
  /// vendored-dependency directory, so the codesign scan skips it.
  static func pathIsInExcludedDirectory(_ relative: String) -> Bool {
    relative.split(separator: "/").contains { scanExcludedDirectories.contains(String($0)) }
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
      if bareTools.contains(commandWord) {
        return true
      }
      return segmentInvokesSwiftBuild(segment, commandWord: commandWord)
    }
  }

  /// Whether a recipe command segment runs `swift build`/`run`/`test`, the compiling
  /// subcommands that must route through `$(SWIFT_MK_BIN)` instead of a bare `swift`.
  /// `swift package ...` and `swift <file>.swift` are allowed: the former is metadata
  /// or clean, the latter runs a standalone script. A `swift build` in a make variable
  /// assignment (`SWIFT_BUILD_CMD := swift build`) is not reached here, since
  /// `lineInvokesToolchain` only inspects tab-indented recipe lines, so the consumer's
  /// configured build command stays clean.
  private static func segmentInvokesSwiftBuild(_ segment: Substring, commandWord: String)
    -> Bool
  {
    guard commandWord == "swift" else {
      return false
    }
    guard let subcommand = argumentWord(in: segment, after: commandWord) else {
      return false
    }
    return subcommand == "build" || subcommand == "run" || subcommand == "test"
  }

  /// The first token after `commandWord` in a command segment, quotes stripped and
  /// leading assignment prefixes skipped, or nil when the command has no argument.
  private static func argumentWord(in segment: Substring, after commandWord: String) -> String? {
    var sawCommand = false
    var isFirstToken = true
    for rawToken in segment.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
      let token = MakeTokenParsing.stripSurroundingQuotes(String(rawToken))
      if !sawCommand {
        // The recipe prefix (@ - +) attaches only to the first token, so strip it there
        // and match against the normalized command word; every later token, including an
        // `env -i` flag, keeps its raw form. Non-matching tokens (env, its flags) are
        // skipped until the command word, whose next token is the returned argument.
        var normalized = token
        if isFirstToken {
          normalized = stripRecipePrefix(token)
        }
        isFirstToken = false
        if normalized.isEmpty || MakeTokenParsing.isAssignmentPrefix(normalized) {
          continue
        }
        if normalized == commandWord {
          sawCommand = true
        }
        continue
      }
      return token
    }
    return nil
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

  // env short options that take a separate following argument, so the argument is
  // skipped with the flag rather than mistaken for the wrapped command.
  private static let envOptionsTakingArgument: Set<String> = ["-u", "-C", "-S"]

  private static func commandWord(in segment: Substring) -> String? {
    let tokens =
      segment
      .split { $0 == " " || $0 == "\t" }
      .map { MakeTokenParsing.stripSurroundingQuotes(String($0)) }
    var index = 0
    var isFirstToken = true
    while index < tokens.count {
      var token = tokens[index]
      // GNU make recipe prefixes (@ - +) attach only to the first token of the recipe,
      // so strip them there and nowhere else (an `env -i` flag keeps its leading dash).
      if isFirstToken {
        token = stripRecipePrefix(token)
        isFirstToken = false
      }
      if token.isEmpty || MakeTokenParsing.isAssignmentPrefix(token) {
        index += 1
        continue
      }
      // `env [OPTION]... [NAME=VALUE]... cmd` runs cmd, so treat a leading `env` as a
      // transparent wrapper and resolve to the wrapped command, which is then flagged.
      if token == "env" {
        index = indexAfterEnvArguments(tokens, from: index + 1)
        continue
      }
      return token
    }
    return nil
  }

  /// The index of the command `env` wraps, skipping env's option flags (and the
  /// following argument of `-u`/`-C`/`-S`) and its `NAME=VALUE` assignments.
  private static func indexAfterEnvArguments(_ tokens: [String], from start: Int) -> Int {
    var index = start
    while index < tokens.count {
      let token = tokens[index]
      if MakeTokenParsing.isAssignmentPrefix(token) || token == "-" {
        index += 1
        continue
      }
      guard token.hasPrefix("-") else {
        break
      }
      index += 1
      if envOptionsTakingArgument.contains(token) {
        index += 1
      }
    }
    return index
  }

  /// A command token with any leading GNU make recipe prefixes removed, so a
  /// silenced or error-ignoring recipe such as `@swift`, `-swift`, or `+@swift`
  /// still resolves to `swift`. The prefixes are `@` (silent), `-` (ignore errors),
  /// and `+` (always run). A token that is only prefixes becomes empty and is skipped.
  private static func stripRecipePrefix(_ word: String) -> String {
    var result = Substring(word)
    while let first = result.first, first == "@" || first == "-" || first == "+" {
      result = result.dropFirst()
    }
    return String(result)
  }

}

// MARK: - MakeTokenParsing

/// Shell-token parsing shared by the make-recipe audit: quote stripping, `VAR=val`
/// assignment detection, and the shell-name character classes they rely on.
private enum MakeTokenParsing {
  static let minimumQuotedWordLength = 2
  static let uppercaseA: Unicode.Scalar = "A"
  static let uppercaseZ: Unicode.Scalar = "Z"
  static let lowercaseA: Unicode.Scalar = "a"
  static let lowercaseZ: Unicode.Scalar = "z"
  static let zeroDigit: Unicode.Scalar = "0"
  static let nineDigit: Unicode.Scalar = "9"

  static func stripSurroundingQuotes(_ word: String) -> String {
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

  static func isAssignmentPrefix(_ word: String) -> Bool {
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

  static func isShellNameStart(_ scalar: Unicode.Scalar) -> Bool {
    scalar == "_" || isAsciiLetter(scalar)
  }

  static func isShellNameCharacter(_ scalar: Unicode.Scalar) -> Bool {
    isShellNameStart(scalar) || isAsciiDigit(scalar)
  }

  static func isAsciiLetter(_ scalar: Unicode.Scalar) -> Bool {
    (uppercaseA...uppercaseZ).contains(scalar) || (lowercaseA...lowercaseZ).contains(scalar)
  }

  static func isAsciiDigit(_ scalar: Unicode.Scalar) -> Bool {
    (zeroDigit...nineDigit).contains(scalar)
  }
}
