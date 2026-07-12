//
//  BuildLock.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-27.
//  Copyright © 2026, all rights reserved.
//

import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

// MARK: - BuildLock

/// A re-entrant, per-worktree build lock. Two heavy builds in one worktree share the
/// same SwiftPM `.build` and the same DerivedData; SwiftPM single-instance-locks a
/// `.build` directory, so an unserialized second build aborts the first and leaves a
/// partial index. `BuildLock` serializes every build the engine drives in one worktree
/// behind one advisory `flock`, while builds in different worktrees stay fully parallel
/// because the lock file is keyed to the worktree root.
///
/// It is re-entrant two ways so the make build -> build-the-dev-tool -> dev-tool calls
/// the engine in-process chain never self-deadlocks:
///   - an in-process depth counter for a nested call inside one process;
///   - an inherited environment marker for a child process the holder spawned, carrying
///     the holder's pid and honored only when its worktree matches and that pid is still
///     alive, so a stale or recycled marker never makes a build skip a lock it needs.
///
/// `flock` releases when the holding process dies, so a killed build never wedges the
/// lock. The build orchestration runs the lock sites sequentially per process, so the
/// process-global state is `nonisolated(unsafe)` like the rest of the engine's gate
/// state.
public enum BuildLock {
  static let envMarker = "SWIFT_MK_BUILD_LOCK_HELD"

  /// The marker value is "<pid> <root>", two space-separated fields.
  private static let markerFieldCount = 2

  nonisolated(unsafe) private static var depth = 0
  nonisolated(unsafe) private static var cachedRoot: String?

  /// The worktree this lock serializes: the git toplevel of the working directory, or
  /// the working directory itself when it is not in a git repo. Cached for the process,
  /// so the key is stable from any subdirectory of the worktree.
  public static func worktreeRoot() -> String {
    if let cachedRoot {
      return cachedRoot
    }
    Output.debug("build-lock: resolving worktree root via git toplevel")
    let workingDirectory = FileManager.default.currentDirectoryPath
    let result = Shell.run("git", ["rev-parse", "--show-toplevel"])
    let resolved: String
    if result.status == 0 {
      let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
      resolved = trimmed.isEmpty ? workingDirectory : trimmed
    } else {
      resolved = workingDirectory
    }
    let standardized = (resolved as NSString).standardizingPath
    cachedRoot = standardized
    return standardized
  }

  /// The lock file for a worktree root: `<root>/.make/build.lock`. It lives under
  /// `.make`, not inside DerivedData, so the dead-code coverage build's
  /// `rm -rf $(SWIFT_MK_DERIVED_DATA)` cannot delete it out from under a held lock.
  static func lockPath(root: String) -> String {
    (root as NSString).appendingPathComponent(".make/build.lock")
  }

  /// Run `body` while holding the per-worktree build lock. Best-effort: when the lock
  /// file cannot be opened the body runs unserialized rather than blocking forever.
  @discardableResult
  public static func withLock<Value>(_ body: () -> Value) -> Value {
    let root = worktreeRoot()

    // This process already holds the lock: re-enter without a second flock, because
    // flock is per-open-file-description and a second open would block on ourselves.
    if depth > 0 {
      depth += 1
      defer { depth -= 1 }
      return body()
    }

    // A live ancestor process holds the lock for this worktree: inherit it. The child
    // shares the ancestor's serialized critical section, so it must not re-lock.
    if inheritedHold(root: root) {
      return body()
    }

    let path = lockPath(root: root)
    do {
      try FileManager.default.createDirectory(
        atPath: (path as NSString).deletingLastPathComponent,
        withIntermediateDirectories: true)
    } catch {
      // Non-fatal: fall through and let the FileLock open attempt below decide. Logged
      // so a missing lock directory is visible rather than silently swallowed.
      Output.error("build-lock: could not create lock directory: \(error)")
    }
    guard let lock = FileLock(path: path) else {
      Output.error(
        "build-lock: could not open the lock file at \(path); building unserialized")
      return body()
    }
    let acquired = lock.acquire {
      Output.info("build: waiting for the per-worktree build lock")
    }
    guard acquired else {
      // The flock failed, so this build is not serialized. Close the descriptor and run
      // unserialized without setting depth or the marker, so a nested or child call does
      // not inherit a hold this process never took.
      Output.error(
        "build-lock: could not acquire the lock at \(path); building unserialized")
      lock.release()
      return body()
    }
    depth = 1
    let priorMarker = getenvString(envMarker)
    setenv(envMarker, markerValue(root: root), 1)
    defer {
      depth -= 1
      if let priorMarker {
        setenv(envMarker, priorMarker, 1)
      } else {
        unsetenv(envMarker)
      }
      lock.release()
    }
    return body()
  }

  // MARK: - Marker

  /// The inherited-hold marker: the holder's pid, a space, then the worktree root. The
  /// pid leads so a root containing spaces still parses; an env value cannot contain a
  /// NUL, so a space separator is safe.
  private static func markerValue(root: String) -> String {
    "\(getpid()) \(root)"
  }

  /// True when the inherited marker proves a live ancestor already holds the lock for
  /// this worktree. Reads the C environment so a marker set by `setenv` after a
  /// Foundation environment snapshot is still seen.
  private static func inheritedHold(root: String) -> Bool {
    guard let raw = getenvString(envMarker) else {
      return false
    }
    let parts = raw.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == markerFieldCount, String(parts[1]) == root else {
      return false
    }
    guard let pid = Int32(parts[0]) else {
      return false
    }
    // Honor the marker only when the holder is still alive. `kill(pid, 0)` returns 0
    // when the process exists and the signal could be sent, or fails with EPERM when it
    // exists but is owned by another user; either proves it is alive.
    if kill(pid, 0) == 0 {
      return true
    }
    return errno == EPERM
  }

  private static func getenvString(_ name: String) -> String? {
    guard let value = getenv(name) else {
      return nil
    }
    return String(cString: value)
  }
}
