//
//  BaselineReport.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-29.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - BaselineUpdateStats

/// One component's baseline update result, derived from the baseline file's key
/// set before and after the rewrite. The counts describe what changed in the
/// file, independent of which update mode produced the change, so the rendered
/// output never needs to name a mode.
public struct BaselineUpdateStats: Sendable {
  public let label: String
  public let baselinePath: String
  public let scopePattern: String
  public let findingsCaptured: Int
  public let added: Int
  public let refreshed: Int
  public let removed: Int
  public let covered: Int
  public let remaining: Int

  public init(
    label: String,
    baselinePath: String,
    scopePattern: String,
    findingsCaptured: Int,
    added: Int,
    refreshed: Int,
    removed: Int,
    covered: Int,
    remaining: Int
  ) {
    self.label = label
    self.baselinePath = baselinePath
    self.scopePattern = scopePattern
    self.findingsCaptured = findingsCaptured
    self.added = added
    self.refreshed = refreshed
    self.removed = removed
    self.covered = covered
    self.remaining = remaining
  }

  /// True when the recorded key set did not change.
  public var isNoop: Bool { added == 0 && removed == 0 }
}

// MARK: - BaselineReport

/// Renders baseline update results. This is the single place baseline-update
/// wording lives. Output reports neutral counts only: it never names an update
/// mode and never suggests pruning, accepting, skipping, or otherwise
/// circumventing a baseline.
public enum BaselineReport {
  /// Whether to emit machine-readable JSON instead of human-readable text.
  static func jsonRequested() -> Bool {
    Env.get("BASELINE_OUTPUT_FORMAT").lowercased() == "json"
  }

  /// Neutral phrase describing the net change to one baseline.
  static func changePhrase(_ stats: BaselineUpdateStats) -> String {
    var parts: [String] = []
    if stats.added > 0 {
      parts.append("\(stats.added) added")
    }
    if stats.removed > 0 {
      parts.append("\(stats.removed) removed")
    }
    if parts.isEmpty {
      return "no change"
    }
    return parts.joined(separator: ", ")
  }

  /// Third-column phrase: the before/after key counts, or "no existing" when
  /// the baseline was empty and stayed empty. `before` is the old key set,
  /// which partitions exactly into removed and refreshed.
  static func remainingPhrase(_ stats: BaselineUpdateStats) -> String {
    let before = stats.removed + stats.refreshed
    if before == 0, stats.remaining == 0 {
      return "no existing"
    }
    return "\(before) -> \(stats.remaining)"
  }

  /// Lines for a single-component run.
  static func singleLines(_ stats: BaselineUpdateStats) -> [String] {
    [
      "\(stats.label) baseline",
      "  \(changePhrase(stats)), \(stats.remaining) remaining.",
    ]
  }

  /// Lines for a multi-component run: one aligned row per component plus a
  /// closing summary.
  static func rollupLines(_ all: [BaselineUpdateStats]) -> [String] {
    var lines: [String] = []
    let count = all.count
    lines.append("Updating \(count) baseline\(count == 1 ? "" : "s")")
    lines.append("")
    let labelWidth = all.map(\.label.count).max() ?? 0
    let changeWidth = all.map { changePhrase($0).count }.max() ?? 0
    for stats in all {
      let label = stats.label.padding(toLength: labelWidth, withPad: " ", startingAt: 0)
      let change = changePhrase(stats).padding(
        toLength: changeWidth, withPad: " ", startingAt: 0)
      lines.append("  \(label)   \(change)   \(remainingPhrase(stats))")
    }
    let totalRemaining = all.reduce(0) { $0 + $1.remaining }
    lines.append("")
    lines.append(
      "  Done. \(totalRemaining) remaining across \(count) baseline\(count == 1 ? "" : "s").")
    return lines
  }

  public static func renderSingle(_ stats: BaselineUpdateStats) {
    if jsonRequested() {
      emitJSON([stats])
      return
    }
    for line in singleLines(stats) {
      Output.log(line)
    }
  }

  public static func renderRollup(_ all: [BaselineUpdateStats]) {
    if all.isEmpty {
      return
    }
    if jsonRequested() {
      emitJSON(all)
      return
    }
    if all.count == 1 {
      for line in singleLines(all[0]) {
        Output.log(line)
      }
      return
    }
    for line in rollupLines(all) {
      Output.log(line)
    }
  }

  private struct BaselineEntry: Encodable {
    let label: String
    let file: String
    let findingsCaptured: Int
    let added: Int
    let refreshed: Int
    let removed: Int
    let covered: Int
    let remaining: Int
    let changed: Bool
  }

  private struct Totals: Encodable {
    let added: Int
    let refreshed: Int
    let removed: Int
    let remaining: Int
    let baselines: Int
  }

  private struct Document: Encodable {
    let scope: String
    let baselines: [BaselineEntry]
    let totals: Totals
  }

  static func jsonString(_ all: [BaselineUpdateStats]) -> String {
    let entries = all.map { stats in
      BaselineEntry(
        label: stats.label,
        file: stats.baselinePath,
        findingsCaptured: stats.findingsCaptured,
        added: stats.added,
        refreshed: stats.refreshed,
        removed: stats.removed,
        covered: stats.covered,
        remaining: stats.remaining,
        changed: !stats.isNoop
      )
    }
    let scope = all.first { !$0.scopePattern.isEmpty }?.scopePattern ?? "all"
    let document = Document(
      scope: scope,
      baselines: entries,
      totals: Totals(
        added: all.reduce(0) { $0 + $1.added },
        refreshed: all.reduce(0) { $0 + $1.refreshed },
        removed: all.reduce(0) { $0 + $1.removed },
        remaining: all.reduce(0) { $0 + $1.remaining },
        baselines: all.count
      )
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    do {
      let data = try encoder.encode(document)
      return String(data: data, encoding: .utf8) ?? "{}"
    } catch {
      return "{}"
    }
  }

  static func emitJSON(_ all: [BaselineUpdateStats]) {
    Output.emitStandardOutput(jsonString(all) + "\n")
  }
}
