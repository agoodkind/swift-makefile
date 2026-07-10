//
//  ToolchainPoolCacheTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-01.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - ToolchainPoolCacheTests

/// Env-driven, so serialized to keep process-global cache vars from racing.
@Suite(.serialized)
enum ToolchainPoolCacheTests {
  @Test
  static func poolSharedSpmCacheAllowsResolutionWhenCheckoutsAreCold() throws {
    try withTemporaryDirectory { directory in
      let sourcePackages = directory.appendingPathComponent("SourcePackages", isDirectory: true)
      try FileManager.default.createDirectory(
        at: sourcePackages,
        withIntermediateDirectories: true)

      withSharedCacheEnv(
        module: "/tmp/swift-mk-mc",
        spm: sourcePackages.path,
        cas: "/tmp/swift-mk-cas",
        pool: "1"
      ) {
        let args = Toolchain.sharedCacheArguments()
        #expect(args.contains("-clonedSourcePackagesDirPath"))
        #expect(args.contains(sourcePackages.path))
        #expect(!args.contains("-disableAutomaticPackageResolution"))
      }
    }
  }

  @Test
  static func poolSharedSpmCacheAllowsResolutionWhenCheckoutsAreEmpty() throws {
    try withTemporaryDirectory { directory in
      let sourcePackages = directory.appendingPathComponent("SourcePackages", isDirectory: true)
      let checkouts = sourcePackages.appendingPathComponent("checkouts", isDirectory: true)

      try FileManager.default.createDirectory(
        at: checkouts,
        withIntermediateDirectories: true)

      withSharedCacheEnv(
        module: "/tmp/swift-mk-mc",
        spm: sourcePackages.path,
        cas: "/tmp/swift-mk-cas",
        pool: "1"
      ) {
        let args = Toolchain.sharedCacheArguments()
        #expect(args.contains("-clonedSourcePackagesDirPath"))
        #expect(args.contains(sourcePackages.path))
        #expect(!args.contains("-disableAutomaticPackageResolution"))
      }
    }
  }

  @Test
  static func poolSharedSpmCacheDisablesAutomaticPackageResolutionWhenCheckoutsExist() throws {
    try withTemporaryDirectory { directory in
      let sourcePackages = directory.appendingPathComponent("SourcePackages", isDirectory: true)
      let checkouts = sourcePackages.appendingPathComponent("checkouts", isDirectory: true)

      try FileManager.default.createDirectory(
        at: checkouts.appendingPathComponent("dependency", isDirectory: true),
        withIntermediateDirectories: true)

      withSharedCacheEnv(
        module: "/tmp/swift-mk-mc",
        spm: sourcePackages.path,
        cas: "/tmp/swift-mk-cas",
        pool: "1"
      ) {
        let args = Toolchain.sharedCacheArguments()
        #expect(args.contains("-clonedSourcePackagesDirPath"))
        #expect(args.contains(sourcePackages.path))
        #expect(args.contains("-disableAutomaticPackageResolution"))
      }
    }
  }

  @Test
  static func poolSharedSpmCacheKeepsManifestPackageSupportCacheVmLocalWhenCheckoutsExist()
    throws
  {
    try withTemporaryDirectory { directory in
      let sharedRoot = directory.appendingPathComponent("shared", isDirectory: true)
      let sourcePackages = sharedRoot.appendingPathComponent(
        "SourcePackages", isDirectory: true)
      let checkouts = sourcePackages.appendingPathComponent("checkouts", isDirectory: true)

      try FileManager.default.createDirectory(
        at: checkouts.appendingPathComponent("dependency", isDirectory: true),
        withIntermediateDirectories: true)

      withSharedCacheEnv(
        module: sharedRoot.appendingPathComponent("module-cache").path,
        spm: sourcePackages.path,
        cas: "/tmp/swift-mk-cas",
        pool: "1"
      ) {
        let args = Toolchain.sharedCacheArguments()
        #expect(args.contains("-clonedSourcePackagesDirPath"))
        #expect(args.contains(sourcePackages.path))
        #expect(args.contains("-disableAutomaticPackageResolution"))

        let packageCache = argument(after: "-packageCachePath", in: args)
        #expect(packageCache != nil)
        if let packageCache {
          #expect(!packageCache.hasPrefix(sharedRoot.path))
          #expect(packageCache.contains("swift-mk"))
        }
      }
    }
  }

  @Test
  static func poolModuleCacheUsesVmLocalPathWhenEnvPointsAtSharedMount() throws {
    try withTemporaryDirectory { directory in
      let sharedRoot = directory.appendingPathComponent("shared", isDirectory: true)
      let sharedModuleCache = sharedRoot.appendingPathComponent(
        "module-cache", isDirectory: true)

      withSharedCacheEnv(
        module: sharedModuleCache.path,
        spm: "none",
        cas: "off",
        pool: "1"
      ) {
        let args = Toolchain.sharedCacheArguments()
        let moduleCache = moduleCachePath(in: args)
        #expect(moduleCache != nil)
        if let moduleCache {
          #expect(!moduleCache.hasPrefix(sharedRoot.path))
          #expect(moduleCache.contains("swift-mk"))
        }
      }
    }
  }

  @Test
  static func hostedSharedSpmCacheAllowsAutomaticPackageResolution() {
    withSharedCacheEnv(
      module: "/tmp/swift-mk-mc",
      spm: "/tmp/swift-mk-spm",
      cas: "/tmp/swift-mk-cas",
      pool: nil
    ) {
      let args = Toolchain.sharedCacheArguments()
      #expect(args.contains("-clonedSourcePackagesDirPath"))
      #expect(args.contains("/tmp/swift-mk-spm"))
      #expect(!args.contains("-disableAutomaticPackageResolution"))
    }
  }

  private static func withSharedCacheEnv(
    module: String?, spm: String?, cas: String?, pool: String?, _ run: () -> Void
  ) {
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

  private static func argument(after flag: String, in arguments: [String]) -> String? {
    guard let flagIndex = arguments.firstIndex(of: flag) else {
      return nil
    }
    let valueIndex = arguments.index(after: flagIndex)
    guard valueIndex < arguments.endIndex else {
      return nil
    }
    return arguments[valueIndex]
  }

  private static func moduleCachePath(in arguments: [String]) -> String? {
    let prefix = "MODULE_CACHE_DIR="
    for argument in arguments
    where argument.hasPrefix(prefix) {
      return String(argument.dropFirst(prefix.count))
    }
    return nil
  }

  // currentEnv reads the live process environment via getenv rather than the
  // launch-time ProcessInfo snapshot, so a value an earlier test set with setenv
  // is captured and restored correctly.
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

  private static func withTemporaryDirectory(_ run: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "swift-mk-toolchain-pool-\(UUID().uuidString)",
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
