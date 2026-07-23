//
//  AuditLockfiles.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-22.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - AuditLockfiles

/// Lockfiles the dependency audit should scan, resolved through git's effective
/// ignore stack rather than osv-scanner's recursive walk.
///
/// osv-scanner `--recursive` applies only the repository `.gitignore` tree. It does
/// not honor `core.excludesFile` (the global excludes file), so agent worktrees and
/// other globally-ignored paths still get scanned. `git ls-files --exclude-standard`
/// uses the full stack (repo ignore, `$GIT_DIR/info/exclude`, and
/// `core.excludesFile`), so the lockfile set here matches what git itself treats as
/// visible.
enum AuditLockfiles {
  /// Pathspecs for lockfiles and manifests osv-scanner understands for
  /// `scan source`, plus Swift/Cocoa lockfiles this engine's consumers use.
  /// Names match OSV-Scanner's supported set
  /// (https://google.github.io/osv-scanner/supported-languages-and-lockfiles/).
  /// `:(glob)**/...` is required so a nested consumer package's lockfile is listed
  /// when it is not ignored. Go uses `go.mod` (not `go.sum`).
  static let pathspecs: [String] = [
    // Swift / Cocoa (engine consumers)
    ":(glob)**/Package.resolved",
    ":(glob)**/Podfile.lock",
    ":(glob)**/Cartfile.resolved",
    // C/C++
    ":(glob)**/conan.lock",
    // Dart
    ":(glob)**/pubspec.lock",
    // Elixir
    ":(glob)**/mix.lock",
    // Go
    ":(glob)**/go.mod",
    // Haskell
    ":(glob)**/cabal.project.freeze",
    ":(glob)**/stack.yaml.lock",
    // Java
    ":(glob)**/buildscript-gradle.lockfile",
    ":(glob)**/gradle.lockfile",
    ":(glob)**/gradle/verification-metadata.xml",
    ":(glob)**/pom.xml",
    // JavaScript
    ":(glob)**/bun.lock",
    ":(glob)**/package-lock.json",
    ":(glob)**/pnpm-lock.yaml",
    ":(glob)**/yarn.lock",
    // .NET
    ":(glob)**/deps.json",
    ":(glob)**/packages.config",
    ":(glob)**/packages.lock.json",
    // PHP
    ":(glob)**/composer.lock",
    // Python
    ":(glob)**/Pipfile.lock",
    ":(glob)**/poetry.lock",
    ":(glob)**/requirements.txt",
    ":(glob)**/pdm.lock",
    ":(glob)**/pylock.toml",
    ":(glob)**/uv.lock",
    // R
    ":(glob)**/renv.lock",
    // Ruby
    ":(glob)**/Gemfile.lock",
    ":(glob)**/gems.locked",
    // Rust
    ":(glob)**/Cargo.lock",
  ]

  /// Lockfile basenames used by the non-git filesystem fallback.
  static let basenames: Set<String> = Set(
    pathspecs.compactMap { pathspec in
      let name = (pathspec as NSString).lastPathComponent
      return name.isEmpty ? nil : name
    })

  /// Discover visible lockfiles under `root` using git's effective ignore when
  /// possible, otherwise a pruned filesystem walk filtered through
  /// `Lint.dropGitIgnored`.
  static func discover(root: String) -> [String] {
    if let fromGit = gitVisibleLockfiles(root: root) {
      return fromGit
    }
    return filesystemLockfiles(root: root)
  }

  /// Build the `osv-scanner scan source` argument vector: configured scanner flags
  /// with `--recursive` stripped (discovery owns the file set), then one `-L` per
  /// lockfile. Does not append a directory root, so osv never walks ignored trees.
  static func scannerArguments(configured: [String], lockfiles: [String]) -> [String] {
    var args = ["scan", "source"]
    args += configured.filter { $0 != "--recursive" && $0 != "-r" }
    for lockfile in lockfiles {
      args += ["-L", lockfile]
    }
    return args
  }

  private static func gitVisibleLockfiles(root: String) -> [String]? {
    Output.debug("audit: discovering lockfiles via git ls-files in \(root)")
    let result = Shell.run(
      "git",
      [
        "-C", root, "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--",
      ] + pathspecs)
    guard result.status == 0 else {
      return nil
    }
    let paths =
      result.stdout
      .split(separator: "\u{0}", omittingEmptySubsequences: true)
      .map(String.init)
    let existing = paths.filter { path in
      let absolute =
        path.hasPrefix("/")
        ? path
        : (root as NSString).appendingPathComponent(path)
      return FileManager.default.fileExists(atPath: absolute)
    }
    return Array(Set(existing)).sorted()
  }

  private static func filesystemLockfiles(root: String) -> [String] {
    Output.debug("audit: discovering lockfiles via filesystem walk in \(root)")
    let manager = FileManager.default
    let rootURL = URL(fileURLWithPath: root, isDirectory: true)
    let rootPath = rootURL.standardizedFileURL.path
    guard
      let enumerator = manager.enumerator(
        at: rootURL,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [])
    else {
      return []
    }
    var paths: [String] = []
    for case let item as URL in enumerator {
      let isDirectory: Bool
      do {
        isDirectory = try item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory ?? false
      } catch {
        Output.warning("audit: could not stat \(item.path): \(error)")
        isDirectory = false
      }
      if isDirectory {
        if LintSourceSet.excludedDirectories.contains(item.lastPathComponent) {
          enumerator.skipDescendants()
        }
        continue
      }
      guard basenames.contains(item.lastPathComponent) else {
        continue
      }
      let absolute = item.standardizedFileURL.path
      if absolute.hasPrefix(rootPath + "/") {
        paths.append(String(absolute.dropFirst(rootPath.count + 1)))
      } else if absolute == rootPath {
        paths.append(item.lastPathComponent)
      } else {
        paths.append(absolute)
      }
    }
    return Lint.dropGitIgnored(Array(Set(paths))).sorted()
  }
}
