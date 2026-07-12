//
//  ToolchainTuistCacheTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-11.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - ToolchainTuistCacheTests

/// Drives `Toolchain.runTuistResolve` against a fake `tuist` on `PATH`, with `HOME`
/// pointed at a temp root so the per-slot cache sits inside a cache-clean safe root.
/// Mutates `HOME`, `PATH`, and the pool env, so every body runs under
/// `TestGlobalLock` to serialize against the other cwd/env-mutating suites.
@Suite(.serialized)
enum ToolchainTuistCacheTests {
  @Test
  static func healsStaleArtifactAndIsolatesCacheOnPool() throws {
    try withFakeTuist(mode: .failOnce) { context in
      let stalePath = "\(context.cache)/artifacts/stale.zip"
      try writeFile(stalePath, "partial")

      let status = Toolchain.runTuistResolve(["install"])

      #expect(status == 0)
      // The retried resolve succeeded, so the marker is cleared.
      #expect(!FileManager.default.fileExists(atPath: context.marker))
      // The exact stale artifact named in the failure was removed before the retry.
      #expect(!FileManager.default.fileExists(atPath: stalePath))
      // Both attempts passed the per-slot cache, so co-tenant slots never share.
      let invocations = try argvLines(context)
      #expect(invocations.count == 2)
      for line in invocations {
        #expect(line.contains("--cache-path \(context.cache)"))
      }
    }
  }

  @Test
  static func scrubsArtifactsAndStaleLocksWhenMarkerPresent() throws {
    try withFakeTuist(mode: .succeed) { context in
      // A leftover marker means the previous resolve on this slot was interrupted.
      try writeFile(context.marker, "")
      try writeFile("\(context.cache)/artifacts/old.zip", "partial")
      try writeFile("\(context.cache)/repositories/dep/stale.lock", "lock")
      try writeFile("\(context.cache)/repositories/dep/config", "keep")
      try writeFile("\(context.cache)/manifests/manifest.db", "keep")

      let status = Toolchain.runTuistResolve(["install"])

      #expect(status == 0)
      // The crash-fragile artifacts tree and the stale git lock are scrubbed.
      #expect(!FileManager.default.fileExists(atPath: "\(context.cache)/artifacts"))
      #expect(
        !FileManager.default.fileExists(atPath: "\(context.cache)/repositories/dep/stale.lock"))
      // The warm bulk of the cache is kept.
      #expect(FileManager.default.fileExists(atPath: "\(context.cache)/repositories/dep/config"))
      #expect(FileManager.default.fileExists(atPath: "\(context.cache)/manifests/manifest.db"))
      // A clean resolve clears the marker it wrote.
      #expect(!FileManager.default.fileExists(atPath: context.marker))
    }
  }

  @Test
  static func refusesToRemoveStalePathOutsideSafeRoots() throws {
    try withFakeTuist(mode: .failOnce) { context in
      let outside = "\(context.root)/outside/stale.zip"
      try writeFile(outside, "partial")
      setenv("SWIFT_MK_TEST_STALE_PATH", outside, 1)

      let status = Toolchain.runTuistResolve(["install"])

      // The retry still succeeds, but the guard refuses the out-of-roots removal.
      #expect(status == 0)
      #expect(FileManager.default.fileExists(atPath: outside))
    }
  }

  @Test
  static func offPoolRunsUnchangedWithoutCachePathOrMarker() throws {
    try withFakeTuist(mode: .succeed, pool: false) { context in
      let status = Toolchain.runTuistResolve(["install"])

      #expect(status == 0)
      let invocations = try argvLines(context)
      #expect(invocations == ["install"])
      #expect(!FileManager.default.fileExists(atPath: context.marker))
    }
  }

  @Test
  static func staleArtifactPathParsesOffendingPath() {
    let output = """
      Downloading binary artifact https://example.com/Sparkle.zip
      error: failed downloading 'https://example.com/Sparkle.zip' which is required \
      by binary target 'Sparkle': /Users/admin/Library/Caches/org.swift.swiftpm/\
      artifacts/Sparkle.zip already exists in file system
      error: fatalError
      """
    #expect(
      Toolchain.staleArtifactPath(in: output)
        == "/Users/admin/Library/Caches/org.swift.swiftpm/artifacts/Sparkle.zip")
  }

  @Test
  static func staleArtifactPathReturnsNilWhenAbsent() {
    #expect(Toolchain.staleArtifactPath(in: "Resolving dependencies\nDone") == nil)
  }

  // MARK: Fixtures

  private enum FakeMode: String {
    case failOnce = "fail-once"
    case succeed
  }

  private struct Context {
    let root: String
    let cache: String
    let marker: String
    let argvLog: String
  }

  /// Build a temp `HOME` with a per-slot cache and a fake `tuist` on `PATH`, run
  /// `body`, then restore every mutated env var and remove the temp tree.
  private static func withFakeTuist(
    mode: FakeMode, pool: Bool = true, _ body: (Context) throws -> Void
  ) throws {
    try TestGlobalLock.withLock {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "swift-mk-tuist-cache-\(UUID().uuidString)", isDirectory: true
      ).path
      let binDir = "\(root)/bin"
      let cache = "\(root)/Library/Caches/swift-mk/tuist-spm/test-slot"
      let context = Context(
        root: root,
        cache: cache,
        marker: "\(cache)/\(Toolchain.resolveMarkerName)",
        argvLog: "\(root)/tuist-argv.log")
      try FileManager.default.createDirectory(
        atPath: binDir, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(
        atPath: cache, withIntermediateDirectories: true)
      try writeFakeTuist(binDir: binDir)

      let saved = savedEnvironment()
      setenv("HOME", root, 1)
      setenv("PATH", "\(binDir):\(saved.path ?? "/usr/bin:/bin")", 1)
      setenv("SWIFT_MK_TEST_TUIST_MODE", mode.rawValue, 1)
      setenv("SWIFT_MK_TEST_TUIST_ARGV_LOG", context.argvLog, 1)
      setenv("SWIFT_MK_TEST_TUIST_STATE", "\(root)/tuist-state", 1)
      setenv("SWIFT_MK_TEST_STALE_PATH", "\(cache)/artifacts/stale.zip", 1)
      if pool {
        setenv("SWIFT_MK_POOL", "1", 1)
      } else {
        unsetenv("SWIFT_MK_POOL")
      }
      setenv("SWIFT_MK_TUIST_SPM_CACHE", cache, 1)
      defer {
        restoreEnvironment(saved)
        removeTree(root)
      }
      try body(context)
    }
  }

  /// A fake `tuist` that logs its argv and, in `fail-once` mode, emits the
  /// stale-artifact signature naming `SWIFT_MK_TEST_STALE_PATH` on its first call and
  /// exits nonzero, then succeeds on the retry.
  private static func writeFakeTuist(binDir: String) throws {
    let script = """
      #!/bin/sh
      printf '%s\\n' "$*" >> "$SWIFT_MK_TEST_TUIST_ARGV_LOG"
      if [ "$SWIFT_MK_TEST_TUIST_MODE" = "fail-once" ]; then
        n=$(cat "$SWIFT_MK_TEST_TUIST_STATE" 2>/dev/null || echo 0)
        n=$((n + 1))
        printf '%s' "$n" > "$SWIFT_MK_TEST_TUIST_STATE"
        if [ "$n" -eq 1 ]; then
          echo "target 'Sparkle': $SWIFT_MK_TEST_STALE_PATH already exists in file system" 1>&2
          echo "error: fatalError" 1>&2
          exit 1
        fi
      fi
      exit 0
      """
    let path = "\(binDir)/tuist"
    try script.write(toFile: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: path)
  }

  private static func argvLines(_ context: Context) throws -> [String] {
    guard FileManager.default.fileExists(atPath: context.argvLog) else {
      return []
    }
    let contents = try String(contentsOfFile: context.argvLog, encoding: .utf8)
    return contents.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
  }

  private static func removeTree(_ path: String) {
    let removal = Swift.Result {
      try FileManager.default.removeItem(atPath: path)
    }
    if case .failure(let error) = removal {
      Issue.record("could not remove temporary directory \(path): \(error)")
    }
  }

  private static func writeFile(_ path: String, _ contents: String) throws {
    let directory = (path as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(
      atPath: directory, withIntermediateDirectories: true)
    try contents.write(toFile: path, atomically: true, encoding: .utf8)
  }

  private struct SavedEnvironment {
    let home: String?
    let path: String?
    let pool: String?
    let tuistCache: String?
    let mode: String?
    let argvLog: String?
    let state: String?
    let stalePath: String?
  }

  private static func savedEnvironment() -> SavedEnvironment {
    SavedEnvironment(
      home: currentEnv("HOME"),
      path: currentEnv("PATH"),
      pool: currentEnv("SWIFT_MK_POOL"),
      tuistCache: currentEnv("SWIFT_MK_TUIST_SPM_CACHE"),
      mode: currentEnv("SWIFT_MK_TEST_TUIST_MODE"),
      argvLog: currentEnv("SWIFT_MK_TEST_TUIST_ARGV_LOG"),
      state: currentEnv("SWIFT_MK_TEST_TUIST_STATE"),
      stalePath: currentEnv("SWIFT_MK_TEST_STALE_PATH"))
  }

  private static func restoreEnvironment(_ saved: SavedEnvironment) {
    setOrUnset("HOME", saved.home)
    setOrUnset("PATH", saved.path)
    setOrUnset("SWIFT_MK_POOL", saved.pool)
    setOrUnset("SWIFT_MK_TUIST_SPM_CACHE", saved.tuistCache)
    setOrUnset("SWIFT_MK_TEST_TUIST_MODE", saved.mode)
    setOrUnset("SWIFT_MK_TEST_TUIST_ARGV_LOG", saved.argvLog)
    setOrUnset("SWIFT_MK_TEST_TUIST_STATE", saved.state)
    setOrUnset("SWIFT_MK_TEST_STALE_PATH", saved.stalePath)
  }

  private static func currentEnv(_ name: String) -> String? {
    guard let raw = getenv(name) else {
      return nil
    }
    return String(cString: raw)
  }

  private static func setOrUnset(_ name: String, _ value: String?) {
    if let value {
      setenv(name, value, 1)
    } else {
      unsetenv(name)
    }
  }
}
