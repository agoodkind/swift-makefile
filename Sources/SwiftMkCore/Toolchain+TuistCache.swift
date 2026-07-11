//
//  Toolchain+TuistCache.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-11.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - Tuist resolve cache isolation and self-healing

/// Keep the Tuist dependency resolve's SwiftPM cache warm and uncorruptible on the
/// self-hosted pool.
///
/// The pool runs two job slots per VM that share `/Users/admin`, so a bare `tuist
/// install` resolves into the one default `~/Library/Caches/org.swift.swiftpm` and
/// two co-tenant slots race on the same `artifacts/` and `repositories/` trees. That
/// race is what fails a pool build with `... already exists in file system` /
/// `error: fatalError` on a binary artifact, and it is the same race behind the
/// non-fatal `cannot lock ref ... is at X but expected Y` on the shared git mirror.
/// SwiftPM resolves that cache location through the account home (getpwuid), so a
/// per-slot `HOME` cannot move it; an explicit `--cache-path` can.
extension Toolchain {
  /// Env var naming the persistent per-slot SwiftPM cache the pool setup provisions
  /// for the Tuist resolve. Empty off the pool, where the default cache is used.
  static let tuistCacheEnvKey = "SWIFT_MK_TUIST_SPM_CACHE"

  /// Marker written in the per-slot cache while a resolve runs. If it is still there
  /// when the next resolve starts, the previous resolve on this slot was interrupted
  /// (the process group can be reaped on timeout), so the cache may hold a partial
  /// binary artifact that SwiftPM would refuse to overwrite.
  static let resolveMarkerName = ".swift-mk-resolving"

  /// The SwiftPM failure substring that means a stale binary-artifact entry is
  /// blocking a fresh download. The offending path precedes it on the same line.
  static let staleArtifactMarker = "already exists in file system"

  /// Run a `tuist` dependency-resolution command, isolating and self-healing the
  /// SwiftPM cache on the pool. Off the pool, or when no per-slot cache is
  /// configured, this runs `tuist <arguments>` exactly as before.
  @discardableResult
  static func runTuistResolve(_ arguments: [String]) -> Int32 {
    guard Env.get("SWIFT_MK_POOL") == "1" else {
      return Shell.runForwardingOutput("tuist", arguments)
    }
    let cache = Env.get(tuistCacheEnvKey)
    guard !cache.isEmpty else {
      return Shell.runForwardingOutput("tuist", arguments)
    }

    prepareResolveCache(cache)
    let marker = "\(cache)/\(resolveMarkerName)"
    writeResolveMarker(marker)
    let resolveArguments = arguments + ["--cache-path", cache]
    let status = resolveWithArtifactHealing(resolveArguments)
    if status == 0 {
      removeResolveMarker(marker)
    }
    return status
  }

  /// Create the per-slot cache and, when the previous resolve on this slot did not
  /// finish cleanly, scrub the only crash-fragile parts before the next resolve. The
  /// warm bulk (`repositories/` and `manifests/`) is kept, so only a possibly-partial
  /// artifact download is re-fetched.
  private static func prepareResolveCache(_ cache: String) {
    do {
      try FileManager.default.createDirectory(
        atPath: cache, withIntermediateDirectories: true)
    } catch {
      Output.error("toolchain: could not create tuist cache \(cache): \(error)")
      return
    }
    guard FileManager.default.fileExists(atPath: "\(cache)/\(resolveMarkerName)") else {
      return
    }
    Output.info("toolchain: previous tuist resolve on this slot was interrupted; healing cache")
    removeIfSafe("\(cache)/artifacts")
    sweepStaleLocks(in: "\(cache)/repositories")
  }

  /// Run the resolve forwarding output live while capturing it, and on a stale
  /// artifact failure remove that exact entry and retry once. The scrub targets only
  /// the path named in this process's own failure, so it never disturbs a co-tenant.
  private static func resolveWithArtifactHealing(_ arguments: [String]) -> Int32 {
    let result = Shell.runForwardingAndCapturing("tuist", arguments)
    guard result.status != 0,
      let stalePath = staleArtifactPath(in: result.combined)
    else {
      return result.status
    }
    Output.info("toolchain: removing stale artifact and retrying resolve: \(stalePath)")
    removeIfSafe(stalePath)
    return Shell.runForwardingOutput("tuist", arguments)
  }

  /// The absolute path of the first stale artifact named in resolve output, or nil.
  /// The line reads `... binary target '<name>': <path> already exists in file
  /// system`, so the path is the text between the last `: ` and the marker.
  static func staleArtifactPath(in output: String) -> String? {
    for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
      guard let markerRange = line.range(of: staleArtifactMarker) else {
        continue
      }
      let head = line[line.startIndex..<markerRange.lowerBound]
      guard let separator = head.range(of: ": ", options: .backwards) else {
        continue
      }
      let candidate = head[separator.upperBound...].trimmingCharacters(in: .whitespaces)
      if !candidate.isEmpty {
        return candidate
      }
    }
    return nil
  }

  /// Remove every `*.lock` file under `repositories/`, left by a `git remote update`
  /// that was reaped mid-write. Git recreates the lock on its next fetch, so removing
  /// a stale one is safe on a single-owner per-slot cache while keeping the mirror warm.
  private static func sweepStaleLocks(in repositoriesDir: String) {
    guard let enumerator = FileManager.default.enumerator(atPath: repositoriesDir) else {
      return
    }
    for case let relative as String in enumerator where relative.hasSuffix(".lock") {
      removeIfSafe("\(repositoriesDir)/\(relative)")
    }
  }

  /// Remove a path only when it exists and sits within the swift-mk cache safe roots,
  /// reusing the `cache clean` guard so a removal can never escape those roots.
  private static func removeIfSafe(_ path: String) {
    guard CacheService.isWithinSafeRoots(path) else {
      Output.error("toolchain: refusing to remove path outside the cache roots: \(path)")
      return
    }
    guard FileManager.default.fileExists(atPath: path) else {
      return
    }
    do {
      try FileManager.default.removeItem(atPath: path)
      Output.info("toolchain: removed \(path)")
    } catch {
      Output.error("toolchain: could not remove \(path): \(error)")
    }
  }

  private static func writeResolveMarker(_ marker: String) {
    guard !FileManager.default.createFile(atPath: marker, contents: nil) else {
      return
    }
    Output.debug("toolchain: could not write resolve marker \(marker)")
  }

  private static func removeResolveMarker(_ marker: String) {
    guard FileManager.default.fileExists(atPath: marker) else {
      return
    }
    do {
      try FileManager.default.removeItem(atPath: marker)
    } catch {
      Output.debug("toolchain: could not remove resolve marker \(marker): \(error)")
    }
  }
}
