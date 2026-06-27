//
//  XcconfigValues.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-26.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - XcconfigValues

/// Read and expand `KEY = value` settings from xcconfig files for the in-process
/// project-generation path.
///
/// `SigningBuildConfig.xcconfigValues` reads a single file's raw `KEY = value`
/// pairs without expanding references. A consumer's xcconfig chains values, such
/// as `AGENT_BUNDLE_ID = $(BUNDLE_ID_PREFIX).agent`, so the generation path needs
/// the resolved value, not the literal `$(BUNDLE_ID_PREFIX)` text. This reads one
/// or more files (later files override earlier ones, matching xcconfig include
/// precedence) and expands `$(KEY)` and `${KEY}` references against the merged
/// settings, so a consumer's `generateProject` can render a manifest from the same
/// values `make xcconfig-generate-project` would have produced.
public enum XcconfigValues {
  /// The number of components a parsed `KEY = value` line splits into.
  private static let keyAndValueComponentCount = 2

  /// A bound on reference-expansion passes, so a self-referential or mutually
  /// referential xcconfig (`A = $(B)`, `B = $(A)`) terminates rather than looping.
  private static let maxExpansionPasses = 16

  /// Read `paths` in order and return the merged, reference-expanded settings. A
  /// missing or unreadable file contributes nothing, so a gitignored local
  /// xcconfig that is absent in a fresh worktree is simply skipped.
  public static func read(paths: [String]) -> [String: String] {
    var merged: [String: String] = [:]
    for path in paths {
      for (key, value) in rawValues(atPath: path) {
        merged[key] = value
      }
    }
    return expand(merged)
  }

  // MARK: Parsing

  /// Parse one xcconfig file's `KEY = value` lines, ignoring blank lines,
  /// comments, and trailing `//` or `;` segments, and stripping surrounding
  /// quotes. Returns an empty dictionary on any read failure.
  static func rawValues(atPath path: String) -> [String: String] {
    let contents: String
    do {
      contents = try String(contentsOfFile: path, encoding: .utf8)
    } catch {
      return [:]
    }
    var values: [String: String] = [:]
    for rawLine in contents.components(separatedBy: .newlines) {
      var line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.hasPrefix("//") || line.hasPrefix("#") {
        continue
      }
      if let comment = line.range(of: "//") {
        line = String(line[..<comment.lowerBound]).trimmingCharacters(in: .whitespaces)
      }
      if let semicolon = line.firstIndex(of: ";") {
        line = String(line[..<semicolon]).trimmingCharacters(in: .whitespaces)
      }
      let parts = line.split(
        separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == keyAndValueComponentCount else {
        continue
      }
      let key = stripConditionSuffix(parts[0].trimmingCharacters(in: .whitespaces))
      let value = parts[1]
        .trimmingCharacters(in: .whitespaces)
        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
      if !key.isEmpty {
        values[key] = value
      }
    }
    return values
  }

  /// Drop an xcconfig conditional suffix such as `[sdk=iphoneos*]` from a key, so
  /// `SETTING[arch=arm64]` resolves under the base `SETTING` name. A key with no
  /// bracket is returned unchanged.
  private static func stripConditionSuffix(_ key: String) -> String {
    guard let bracket = key.firstIndex(of: "[") else {
      return key
    }
    return String(key[..<bracket]).trimmingCharacters(in: .whitespaces)
  }

  // MARK: Expansion

  /// Expand `$(KEY)` and `${KEY}` references against the merged settings, iterating
  /// until no reference resolves or the pass bound is reached. An unresolved
  /// reference (a key with no definition) is left literal rather than blanked, so a
  /// build-time variable the consumer supplies later survives.
  static func expand(_ values: [String: String]) -> [String: String] {
    var resolved = values
    for _ in 0..<maxExpansionPasses {
      var changed = false
      for (key, value) in resolved {
        let expanded = expandReferences(value, in: resolved)
        if expanded != value {
          resolved[key] = expanded
          changed = true
        }
      }
      if !changed {
        break
      }
    }
    return resolved
  }

  /// Replace each `$(KEY)`/`${KEY}` in `text` with the value of `KEY` from
  /// `values`, leaving an unknown key's reference literal.
  static func expandReferences(_ text: String, in values: [String: String]) -> String {
    var result = ""
    var index = text.startIndex
    while index < text.endIndex {
      let character = text[index]
      if character == "$", let reference = referenceRange(in: text, startingAt: index) {
        let name = String(text[reference.nameRange])
        if let value = values[name] {
          result.append(value)
        } else {
          result.append(contentsOf: text[index..<reference.end])
        }
        index = reference.end
        continue
      }
      result.append(character)
      index = text.index(after: index)
    }
    return result
  }

  private struct Reference {
    let nameRange: Range<String.Index>
    let end: String.Index
  }

  /// Parse a `$(NAME)` or `${NAME}` reference beginning at `dollar`, or nil when
  /// the text at that position is not a complete reference.
  private static func referenceRange(in text: String, startingAt dollar: String.Index) -> Reference?
  {
    let afterDollar = text.index(after: dollar)
    guard afterDollar < text.endIndex else {
      return nil
    }
    let open = text[afterDollar]
    let close: Character
    switch open {
    case "(":
      close = ")"
    case "{":
      close = "}"
    default:
      return nil
    }
    let nameStart = text.index(after: afterDollar)
    guard let closeIndex = text[nameStart...].firstIndex(of: close), closeIndex > nameStart
    else {
      return nil
    }
    return Reference(
      nameRange: nameStart..<closeIndex, end: text.index(after: closeIndex))
  }
}
