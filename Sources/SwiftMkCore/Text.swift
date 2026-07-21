//
//  Text.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-25.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - PathContext

/// Path-normalization context: the working directory and project root, each
/// with a trailing slash, matching the `pwd`/`cwd` variables the awk receives.
public struct PathContext: Sendable {
  public let pwd: String
  public let cwd: String

  public init(pwd: String, cwd: String) {
    self.pwd = pwd
    self.cwd = cwd
  }

  public static func current() -> PathContext {
    let workingDirectory = FileManager.default.currentDirectoryPath
    let root = ProcessInfo.processInfo.environment["SWIFT_MK_ROOT"] ?? workingDirectory
    return PathContext(pwd: workingDirectory + "/", cwd: root + "/")
  }
}

// MARK: - Text

/// File and regex helpers shared by the lint and baseline engines.
public enum Text {
  public static func readLines(_ path: String) -> [String] {
    let text: String
    do {
      text = try String(contentsOfFile: path, encoding: .utf8)
    } catch {
      return []
    }
    var lines = text.components(separatedBy: "\n")
    if lines.last?.isEmpty == true {
      lines.removeLast()
    }
    return lines
  }

  public static func writeLines(_ lines: [String], to path: String) throws {
    let body = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    try body.write(toFile: path, atomically: true, encoding: .utf8)
  }

  /// Write UTF-8 `text` to `path` only when it differs from what is already there,
  /// and report whether a write happened. Delegates to the `Data` form so both share
  /// one write path and one change check.
  @discardableResult
  public static func writeIfChanged(_ text: String, toFile path: String) throws -> Bool {
    try writeIfChanged(Data(text.utf8), to: URL(fileURLWithPath: path))
  }

  /// Write `data` to `url` only when it differs from what is already there, and
  /// report whether a write happened. An atomic write replaces the file, giving it a
  /// new inode and modification time even when the bytes are identical, and a
  /// generated file sitting in a compiled source tree then re-triggers the whole
  /// downstream recompile on every run. Skipping the no-op write keeps the file's
  /// mtime stable so incremental builds stay incremental. A missing or unreadable
  /// file compares as different, so the write still happens on any doubt.
  @discardableResult
  public static func writeIfChanged(_ data: Data, to url: URL) throws -> Bool {
    if FileManager.default.contents(atPath: url.path) == data {
      return false
    }
    Output.debug("writeIfChanged: writing \(url.path)")
    try data.write(to: url, options: .atomic)
    return true
  }

  /// Join comma-separated default and extra patterns into one ERE alternation.
  public static func excludePattern(_ defaults: String, _ extra: String) -> String {
    let combined = defaults + "," + extra
    return
      combined
      .split(separator: ",", omittingEmptySubsequences: true)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
      .joined(separator: "|")
  }

  static func compile(_ pattern: String) -> Regex<AnyRegexOutput>? {
    guard !pattern.isEmpty else { return nil }
    do {
      return try Regex(pattern)
    } catch {
      return nil
    }
  }

  /// Drop lines matching the pattern (grep -Ev). Empty pattern keeps all.
  public static func filterExclude(_ lines: [String], _ pattern: String) -> [String] {
    guard let regex = compile(pattern) else { return lines }
    return lines.filter { !$0.contains(regex) }
  }

  /// Keep lines matching the pattern (grep -E). Empty pattern keeps all.
  public static func filterScope(_ lines: [String], _ pattern: String) -> [String] {
    guard let regex = compile(pattern) else { return lines }
    return lines.filter { $0.contains(regex) }
  }

  /// Sorted unique values (sort -u).
  public static func sortedUnique(_ lines: [String]) -> [String] {
    Array(Set(lines)).sorted()
  }
}
