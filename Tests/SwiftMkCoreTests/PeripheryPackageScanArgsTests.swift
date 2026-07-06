//
//  PeripheryPackageScanArgsTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-05.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - PeripheryPackageScanArgsTests

/// The periphery package scan builds the package itself, so it must build in the same
/// module mode as the routed product build. These tests pin that the compile-cache flags
/// are forwarded to periphery after `--` when the cache is enabled, absent when disabled,
/// and merged into an existing `--` passthrough rather than doubled.
///
/// Env-driven, so serialized to keep the process-global cache vars from racing.
@Suite(.serialized)
enum PeripheryPackageScanArgsTests {
  @Test
  static func forwardsCompileCacheFlagsAfterDashDashWhenEnabled() {
    withEnv(
      peripheryArgs: "scan --config .make/periphery.yml --strict",
      compileCacheEnabled: "YES",
      cachePath: "/tmp/periphery-cas-test"
    ) {
      let args = Lint.peripheryPackageScanArguments()
      let dashDash = args.firstIndex(of: "--")
      #expect(dashDash != nil, "a passthrough separator is present: \(args)")
      #expect(args.contains("-explicit-module-build"), "explicit-module-build forwarded: \(args)")
      #expect(args.contains("-cache-compile-job"))
      #expect(args.contains("/tmp/periphery-cas-test"))
      if let dashDash {
        let scanFlagsBeforePassthrough = args[..<dashDash]
        #expect(
          !scanFlagsBeforePassthrough.contains("-explicit-module-build"),
          "the compile flags sit after `--`, not among the scan flags")
      }
    }
  }

  @Test
  static func staysPlainWhenCompileCacheDisabled() {
    withEnv(
      peripheryArgs: "scan --config .make/periphery.yml --strict",
      compileCacheEnabled: "NO",
      cachePath: "/tmp/periphery-cas-test"
    ) {
      let args = Lint.peripheryPackageScanArguments()
      #expect(args == ["scan", "--config", ".make/periphery.yml", "--strict"])
      #expect(!args.contains("--"))
      #expect(!args.contains("-explicit-module-build"))
    }
  }

  @Test
  static func mergesIntoAnExistingPassthroughRatherThanDoubling() {
    withEnv(
      peripheryArgs: "scan --config .periphery.yml --strict -- -Xswiftc -DFOO",
      compileCacheEnabled: "YES",
      cachePath: "/tmp/periphery-cas-test"
    ) {
      let args = Lint.peripheryPackageScanArguments()
      let dashDashCount = args.filter { $0 == "--" }.count
      #expect(dashDashCount == 1, "exactly one `--`: \(args)")
      #expect(args.contains("-explicit-module-build"))
      #expect(args.contains("-DFOO"), "the consumer's own passthrough survives: \(args)")
    }
  }

  private static func withEnv(
    peripheryArgs: String,
    compileCacheEnabled: String,
    cachePath: String,
    _ run: () -> Void
  ) {
    let priorArgs = ProcessInfo.processInfo.environment["PERIPHERY_ARGS"]
    let priorEnabled = ProcessInfo.processInfo.environment["SWIFT_MK_SWIFTPM_COMPILE_CACHE_ENABLED"]
    let priorPath = ProcessInfo.processInfo.environment["SWIFT_MK_SWIFTPM_CACHE_PATH"]
    let priorCacheArgs = ProcessInfo.processInfo.environment["SWIFT_MK_SWIFTPM_CACHE_ARGS"]
    setenv("PERIPHERY_ARGS", peripheryArgs, 1)
    setenv("SWIFT_MK_SWIFTPM_COMPILE_CACHE_ENABLED", compileCacheEnabled, 1)
    setenv("SWIFT_MK_SWIFTPM_CACHE_PATH", cachePath, 1)
    // The cache-args env feeds a different (dependency/manifest) knob; clear it so this
    // test reads only the compile-cache forwarding.
    unsetenv("SWIFT_MK_SWIFTPM_CACHE_ARGS")
    defer {
      setOrUnset("PERIPHERY_ARGS", priorArgs)
      setOrUnset("SWIFT_MK_SWIFTPM_COMPILE_CACHE_ENABLED", priorEnabled)
      setOrUnset("SWIFT_MK_SWIFTPM_CACHE_PATH", priorPath)
      setOrUnset("SWIFT_MK_SWIFTPM_CACHE_ARGS", priorCacheArgs)
    }
    run()
  }

  private static func setOrUnset(_ name: String, _ value: String?) {
    if let value {
      setenv(name, value, 1)
    } else {
      unsetenv(name)
    }
  }
}
