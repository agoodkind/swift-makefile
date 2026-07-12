//
//  ToolchainSharedCacheTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-07.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - ToolchainSharedCacheTests

/// Env-driven, so serialized to keep the process-global cache vars from racing.
@Suite(.serialized)
enum ToolchainSharedCacheTests {
  @Test
  static func buildSharesModuleCacheSpmCloneAndCasAcrossWorktrees() {
    withSharedCacheEnv(
      module: "/tmp/swift-mk-mc",
      spm: "/tmp/swift-mk-spm",
      cas: "/tmp/swift-mk-cas"
    ) {
      let request = Toolchain.Request(
        generator: .tuist,
        scheme: "App",
        workspace: "App.xcworkspace",
        derivedDataPath: ".derived-data"
      )
      let args = Toolchain.xcodebuildArguments(request, actions: ["build"])
      // DerivedData stays per worktree; only the content-addressed caches are shared.
      #expect(args.contains("-derivedDataPath"))
      #expect(args.contains(".derived-data"))
      #expect(args.contains("-clonedSourcePackagesDirPath"))
      #expect(args.contains("/tmp/swift-mk-spm"))
      #expect(args.contains("MODULE_CACHE_DIR=/tmp/swift-mk-mc"))
      // The CAS store is pinned outside DerivedData so the dead-code `rm` cannot wipe it.
      #expect(args.contains("COMPILATION_CACHE_CAS_PATH=/tmp/swift-mk-cas"))
      #expect(args.last == "build")
    }
  }

  @Test
  static func sharedCachesOmittedWhenDisabled() {
    withSharedCacheEnv(module: "off", spm: "none", cas: "off") {
      #expect(Toolchain.sharedCacheArguments().isEmpty)
    }
  }

  @Test
  static func sharedCachesFallBackToLibraryCachesWhenUnset() {
    withSharedCacheEnv(module: nil, spm: nil, cas: nil) {
      let joined = Toolchain.sharedCacheArguments().joined(separator: " ")
      #expect(joined.contains("Library/Caches/swift-mk/ModuleCache"))
      #expect(joined.contains("Library/Caches/swift-mk/SourcePackages"))
      #expect(joined.contains("Library/Caches/swift-mk/CompilationCache"))
    }
  }

  @Test
  static func sharedSourcePackagesPopulationProbeUsesEnumerator() throws {
    let source = try rootFile("Sources/SwiftMkCore/Toolchain.swift")

    #expect(source.contains("private static func sharedSourcePackagesCheckoutIsPopulated"))
    #expect(source.contains("FileManager.default.enumerator(atPath: checkoutsURL.path)"))
    #expect(source.contains("return enumerator.nextObject() != nil"))
    #expect(!source.contains("contentsOfDirectory(atPath: checkoutsURL.path)"))
  }

  @Test
  static func sharedSourcePackagesCheckoutPopulationGatesPoolResolution() throws {
    try withTemporaryDirectory { directory in
      let checkouts = directory.appendingPathComponent("checkouts", isDirectory: true)

      withSharedCacheEnv(module: "off", spm: directory.path, cas: "off", pool: "1") {
        #expect(!Toolchain.sharedCacheArguments().contains("-disableAutomaticPackageResolution"))
      }

      try FileManager.default.createDirectory(
        at: checkouts, withIntermediateDirectories: true)
      withSharedCacheEnv(module: "off", spm: directory.path, cas: "off", pool: "1") {
        #expect(!Toolchain.sharedCacheArguments().contains("-disableAutomaticPackageResolution"))
      }

      let checkout = checkouts.appendingPathComponent("dependency")
      try "dependency\n".write(to: checkout, atomically: true, encoding: .utf8)
      withSharedCacheEnv(module: "off", spm: directory.path, cas: "off", pool: "1") {
        #expect(Toolchain.sharedCacheArguments().contains("-disableAutomaticPackageResolution"))
      }
    }
  }

  @Test
  static func withSharedCacheEnvRestoresLiveEnvironmentValues() {
    TestGlobalLock.withLock {
      let savedModule = currentEnv("SWIFT_MK_MODULE_CACHE")
      let savedSpm = currentEnv("SWIFT_MK_SPM_CACHE")
      let savedCas = currentEnv("SWIFT_MK_XCODE_CACHE_PATH")
      let savedPool = currentEnv("SWIFT_MK_POOL")
      _ = ProcessInfo.processInfo.environment
      setOrUnset("SWIFT_MK_MODULE_CACHE", "/tmp/live-module")
      setOrUnset("SWIFT_MK_SPM_CACHE", "/tmp/live-spm")
      setOrUnset("SWIFT_MK_XCODE_CACHE_PATH", "/tmp/live-cas")
      setOrUnset("SWIFT_MK_POOL", "1")
      defer {
        setOrUnset("SWIFT_MK_MODULE_CACHE", savedModule)
        setOrUnset("SWIFT_MK_SPM_CACHE", savedSpm)
        setOrUnset("SWIFT_MK_XCODE_CACHE_PATH", savedCas)
        setOrUnset("SWIFT_MK_POOL", savedPool)
      }

      withSharedCacheEnv(module: "off", spm: "none", cas: "off", pool: nil) {
        #expect(Toolchain.sharedCacheArguments().isEmpty)
      }

      #expect(currentEnv("SWIFT_MK_MODULE_CACHE") == "/tmp/live-module")
      #expect(currentEnv("SWIFT_MK_SPM_CACHE") == "/tmp/live-spm")
      #expect(currentEnv("SWIFT_MK_XCODE_CACHE_PATH") == "/tmp/live-cas")
      #expect(currentEnv("SWIFT_MK_POOL") == "1")
    }
  }

  // Serialize on the shared process-wide lock so a suite reading SWIFT_MK_POOL live
  // (ToolchainTuistCacheTests) never observes this suite's env mutations mid-read.
  private static func withSharedCacheEnv(
    module: String?, spm: String?, cas: String?, pool: String? = nil, _ run: () -> Void
  ) {
    TestGlobalLock.withLock {
      let priorModule = currentEnv("SWIFT_MK_MODULE_CACHE")
      let priorSpm = currentEnv("SWIFT_MK_SPM_CACHE")
      let priorCas = currentEnv("SWIFT_MK_XCODE_CACHE_PATH")
      let priorPool = currentEnv("SWIFT_MK_POOL")
      setOrUnset("SWIFT_MK_MODULE_CACHE", module)
      setOrUnset("SWIFT_MK_SPM_CACHE", spm)
      setOrUnset("SWIFT_MK_XCODE_CACHE_PATH", cas)
      setOrUnset("SWIFT_MK_POOL", pool)
      defer {
        setOrUnset("SWIFT_MK_MODULE_CACHE", priorModule)
        setOrUnset("SWIFT_MK_SPM_CACHE", priorSpm)
        setOrUnset("SWIFT_MK_XCODE_CACHE_PATH", priorCas)
        setOrUnset("SWIFT_MK_POOL", priorPool)
      }
      run()
    }
  }

  private static func currentEnv(_ name: String) -> String? {
    guard let raw = getenv(name) else { return nil }
    return String(cString: raw)
  }

  private static func setOrUnset(_ name: String, _ value: String?) {
    if let value {
      setenv(name, value, 1)
    } else {
      unsetenv(name)
    }
  }

  private static func rootFile(_ relativePath: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    return try String(
      contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
  }

  private static func withTemporaryDirectory(_ run: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "swift-mk-shared-cache-\(UUID().uuidString)",
      isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
      removeTemporaryDirectory(directory)
    }
    try run(directory)
  }

  private static func removeTemporaryDirectory(_ directory: URL) {
    let removalResult = Result {
      try FileManager.default.removeItem(at: directory)
    }
    if case .failure(let error) = removalResult {
      Issue.record("could not remove temporary directory \(directory.path): \(error)")
    }
  }
}
