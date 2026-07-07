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
  static func poolSharedSpmCacheDisablesAutomaticPackageResolution() {
    withSharedCacheEnv(
      module: "/tmp/swift-mk-mc",
      spm: "/tmp/swift-mk-spm",
      cas: "/tmp/swift-mk-cas",
      pool: "1"
    ) {
      let args = Toolchain.sharedCacheArguments()
      #expect(args.contains("-clonedSourcePackagesDirPath"))
      #expect(args.contains("/tmp/swift-mk-spm"))
      #expect(args.contains("-disableAutomaticPackageResolution"))
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
}
