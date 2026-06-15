//
//  Lint+GitIgnore.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-14.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - Lint git-ignore filtering

extension Lint {
  /// Paths per `git check-ignore` call. `git check-ignore` is a single exec, and a
  /// process is capped at a few thousand arguments (macOS raises
  /// `NSInvalidArgumentException ... too many arguments ... limit is 4096` from
  /// `Process`), so a large consumer tree must be checked in batches. Kept well
  /// under the limit to leave room for the `check-ignore` argument itself.
  static let gitCheckIgnoreBatchSize = 2_000

  /// The git-ignored subset of `paths`, computed in batches so a large path list
  /// never overflows the process argument limit. `git check-ignore` prints the
  /// ignored subset of its argument paths on stdout; outside a git work tree it
  /// prints none, so every path is kept. The exit status is intentionally not
  /// consulted (it is nonzero when nothing is ignored), only the printed subset.
  static func gitIgnoredPaths(_ paths: [String]) -> Set<String> {
    guard !paths.isEmpty else {
      return []
    }
    Output.debug("lint: checking \(paths.count) path(s) against git ignore")
    var ignored: Set<String> = []
    var index = 0
    while index < paths.count {
      let end = min(index + gitCheckIgnoreBatchSize, paths.count)
      let result = Shell.run("git", ["check-ignore"] + Array(paths[index..<end]))
      for line in result.stdout.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
          ignored.insert(trimmed)
        }
      }
      index = end
    }
    return ignored
  }

  /// Drops paths that git ignores, so generated or otherwise untracked files are
  /// never linted.
  static func dropGitIgnored(_ paths: [String]) -> [String] {
    let ignored = gitIgnoredPaths(paths)
    guard !ignored.isEmpty else {
      return paths
    }
    return paths.filter { !ignored.contains($0) }
  }
}
