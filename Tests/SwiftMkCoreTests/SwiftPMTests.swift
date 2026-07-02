//
//  SwiftPMTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-27.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - SwiftPMTests

/// Serialized because `cacheArgumentsWordSplit...` mutates the process environment.
@Suite(.serialized)
enum SwiftPMTests {
  @Test
  static func configurationArgumentsLowerTheXcodeName() {
    #expect(
      SwiftPM.configurationArguments(SwiftPM.Request(configuration: .debug)) == ["-c", "debug"])
    #expect(
      SwiftPM.configurationArguments(SwiftPM.Request(configuration: .release)) == ["-c", "release"])
  }

  @Test
  static func packageArgumentsOnlyWhenPathIsSet() {
    #expect(SwiftPM.packageArguments(SwiftPM.Request()).isEmpty)
    let withPath = SwiftPM.packageArguments(SwiftPM.Request(packagePath: "Tools"))
    #expect(withPath == ["--package-path", "Tools"])
  }

  @Test
  static func productArgumentsOnlyWhenProductIsSet() {
    #expect(SwiftPM.productArguments(SwiftPM.Request()).isEmpty)
    let withProduct = SwiftPM.productArguments(SwiftPM.Request(product: "CellTunnelDev"))
    #expect(withProduct == ["--product", "CellTunnelDev"])
  }

  @Test
  static func cacheArgumentsWordSplitTheEnvironmentFlags() {
    let priorPointer = getenv("SWIFT_MK_SWIFTPM_CACHE_ARGS")
    let prior = priorPointer.map { String(cString: $0) }
    // The compile cache is on by default, so `make test` exports
    // SWIFT_MK_SWIFTPM_COMPILE_CACHE_ENABLED=YES and cacheArguments() would append the
    // compile flags. Isolate the word-split behavior by forcing the compile cache off.
    let priorEnabled = getenv("SWIFT_MK_SWIFTPM_COMPILE_CACHE_ENABLED").map { String(cString: $0) }
    setenv("SWIFT_MK_SWIFTPM_CACHE_ARGS", "--enable-dependency-cache --manifest-cache shared", 1)
    setenv("SWIFT_MK_SWIFTPM_COMPILE_CACHE_ENABLED", "NO", 1)
    defer {
      if let prior {
        setenv("SWIFT_MK_SWIFTPM_CACHE_ARGS", prior, 1)
      } else {
        unsetenv("SWIFT_MK_SWIFTPM_CACHE_ARGS")
      }
      if let priorEnabled {
        setenv("SWIFT_MK_SWIFTPM_COMPILE_CACHE_ENABLED", priorEnabled, 1)
      } else {
        unsetenv("SWIFT_MK_SWIFTPM_COMPILE_CACHE_ENABLED")
      }
    }
    #expect(
      SwiftPM.cacheArguments() == ["--enable-dependency-cache", "--manifest-cache", "shared"])
  }

  @Test
  static func compileCacheFlagsAppendedWhenEnabled() {
    let priorEnabled = getenv("SWIFT_MK_SWIFTPM_COMPILE_CACHE_ENABLED").map { String(cString: $0) }
    let priorPath = getenv("SWIFT_MK_SWIFTPM_CACHE_PATH").map { String(cString: $0) }
    let priorDiag = getenv("SWIFT_MK_SWIFTPM_CACHE_DIAGNOSTICS").map { String(cString: $0) }
    let priorArgs = getenv("SWIFT_MK_SWIFTPM_CACHE_ARGS").map { String(cString: $0) }
    setenv("SWIFT_MK_SWIFTPM_COMPILE_CACHE_ENABLED", "YES", 1)
    setenv("SWIFT_MK_SWIFTPM_CACHE_PATH", "/tmp/x", 1)
    unsetenv("SWIFT_MK_SWIFTPM_CACHE_DIAGNOSTICS")
    unsetenv("SWIFT_MK_SWIFTPM_CACHE_ARGS")
    defer {
      if let value = priorEnabled {
        setenv("SWIFT_MK_SWIFTPM_COMPILE_CACHE_ENABLED", value, 1)
      } else {
        unsetenv("SWIFT_MK_SWIFTPM_COMPILE_CACHE_ENABLED")
      }
      if let value = priorPath {
        setenv("SWIFT_MK_SWIFTPM_CACHE_PATH", value, 1)
      } else {
        unsetenv("SWIFT_MK_SWIFTPM_CACHE_PATH")
      }
      if let value = priorDiag {
        setenv("SWIFT_MK_SWIFTPM_CACHE_DIAGNOSTICS", value, 1)
      } else {
        unsetenv("SWIFT_MK_SWIFTPM_CACHE_DIAGNOSTICS")
      }
      if let value = priorArgs {
        setenv("SWIFT_MK_SWIFTPM_CACHE_ARGS", value, 1)
      } else {
        unsetenv("SWIFT_MK_SWIFTPM_CACHE_ARGS")
      }
    }
    let args = SwiftPM.cacheArguments()
    let expected = [
      "-Xswiftc", "-explicit-module-build",
      "-Xswiftc", "-cache-compile-job",
      "-Xswiftc", "-cas-path",
      "-Xswiftc", "/tmp/x",
    ]
    let suffix = Array(args.suffix(expected.count))
    #expect(suffix == expected, "expected compile-cache flags at end of \(args)")
    #expect(!args.contains("-Rcache-compile-job"), "diagnostics flag must be absent when unset")
  }

  @Test
  static func compileCacheFlagsAbsentWhenDisabled() {
    let priorEnabled = getenv("SWIFT_MK_SWIFTPM_COMPILE_CACHE_ENABLED").map { String(cString: $0) }
    let priorPath = getenv("SWIFT_MK_SWIFTPM_CACHE_PATH").map { String(cString: $0) }
    let priorArgs = getenv("SWIFT_MK_SWIFTPM_CACHE_ARGS").map { String(cString: $0) }
    defer {
      if let value = priorEnabled {
        setenv("SWIFT_MK_SWIFTPM_COMPILE_CACHE_ENABLED", value, 1)
      } else {
        unsetenv("SWIFT_MK_SWIFTPM_COMPILE_CACHE_ENABLED")
      }
      if let value = priorPath {
        setenv("SWIFT_MK_SWIFTPM_CACHE_PATH", value, 1)
      } else {
        unsetenv("SWIFT_MK_SWIFTPM_CACHE_PATH")
      }
      if let value = priorArgs {
        setenv("SWIFT_MK_SWIFTPM_CACHE_ARGS", value, 1)
      } else {
        unsetenv("SWIFT_MK_SWIFTPM_CACHE_ARGS")
      }
    }
    unsetenv("SWIFT_MK_SWIFTPM_CACHE_ARGS")
    unsetenv("SWIFT_MK_SWIFTPM_COMPILE_CACHE_ENABLED")
    setenv("SWIFT_MK_SWIFTPM_CACHE_PATH", "/tmp/x", 1)
    #expect(!SwiftPM.cacheArguments().contains("-explicit-module-build"))

    setenv("SWIFT_MK_SWIFTPM_COMPILE_CACHE_ENABLED", "NO", 1)
    #expect(!SwiftPM.cacheArguments().contains("-explicit-module-build"))
  }

  @Test
  static func compileCachePathDisableTokenIsIgnored() {
    // The engine owns the compile cache with no consumer opt-out, so a disable token on
    // the store path is ignored: with the enable flag YES, the flags are still injected.
    let priorEnabled = getenv("SWIFT_MK_SWIFTPM_COMPILE_CACHE_ENABLED").map { String(cString: $0) }
    let priorPath = getenv("SWIFT_MK_SWIFTPM_CACHE_PATH").map { String(cString: $0) }
    let priorArgs = getenv("SWIFT_MK_SWIFTPM_CACHE_ARGS").map { String(cString: $0) }
    setenv("SWIFT_MK_SWIFTPM_COMPILE_CACHE_ENABLED", "YES", 1)
    setenv("SWIFT_MK_SWIFTPM_CACHE_PATH", "off", 1)
    unsetenv("SWIFT_MK_SWIFTPM_CACHE_ARGS")
    defer {
      if let value = priorEnabled {
        setenv("SWIFT_MK_SWIFTPM_COMPILE_CACHE_ENABLED", value, 1)
      } else {
        unsetenv("SWIFT_MK_SWIFTPM_COMPILE_CACHE_ENABLED")
      }
      if let value = priorPath {
        setenv("SWIFT_MK_SWIFTPM_CACHE_PATH", value, 1)
      } else {
        unsetenv("SWIFT_MK_SWIFTPM_CACHE_PATH")
      }
      if let value = priorArgs {
        setenv("SWIFT_MK_SWIFTPM_CACHE_ARGS", value, 1)
      } else {
        unsetenv("SWIFT_MK_SWIFTPM_CACHE_ARGS")
      }
    }
    #expect(SwiftPM.cacheArguments().contains("-explicit-module-build"))
  }

  @Test
  static func compileCacheDiagnosticsFlagAppendedWhenSet() {
    let priorEnabled = getenv("SWIFT_MK_SWIFTPM_COMPILE_CACHE_ENABLED").map { String(cString: $0) }
    let priorPath = getenv("SWIFT_MK_SWIFTPM_CACHE_PATH").map { String(cString: $0) }
    let priorDiag = getenv("SWIFT_MK_SWIFTPM_CACHE_DIAGNOSTICS").map { String(cString: $0) }
    let priorArgs = getenv("SWIFT_MK_SWIFTPM_CACHE_ARGS").map { String(cString: $0) }
    setenv("SWIFT_MK_SWIFTPM_COMPILE_CACHE_ENABLED", "YES", 1)
    setenv("SWIFT_MK_SWIFTPM_CACHE_PATH", "/tmp/x", 1)
    setenv("SWIFT_MK_SWIFTPM_CACHE_DIAGNOSTICS", "1", 1)
    unsetenv("SWIFT_MK_SWIFTPM_CACHE_ARGS")
    defer {
      if let value = priorEnabled {
        setenv("SWIFT_MK_SWIFTPM_COMPILE_CACHE_ENABLED", value, 1)
      } else {
        unsetenv("SWIFT_MK_SWIFTPM_COMPILE_CACHE_ENABLED")
      }
      if let value = priorPath {
        setenv("SWIFT_MK_SWIFTPM_CACHE_PATH", value, 1)
      } else {
        unsetenv("SWIFT_MK_SWIFTPM_CACHE_PATH")
      }
      if let value = priorDiag {
        setenv("SWIFT_MK_SWIFTPM_CACHE_DIAGNOSTICS", value, 1)
      } else {
        unsetenv("SWIFT_MK_SWIFTPM_CACHE_DIAGNOSTICS")
      }
      if let value = priorArgs {
        setenv("SWIFT_MK_SWIFTPM_CACHE_ARGS", value, 1)
      } else {
        unsetenv("SWIFT_MK_SWIFTPM_CACHE_ARGS")
      }
    }
    #expect(SwiftPM.cacheArguments().contains("-Rcache-compile-job"))
  }

  @Test
  static func executablePathJoinsBinPathAndProduct() {
    #expect(
      SwiftPM.executablePath(binPath: "/x/.build/debug", product: "Tool") == "/x/.build/debug/Tool")
    #expect(SwiftPM.executablePath(binPath: nil, product: "Tool") == nil)
    #expect(SwiftPM.executablePath(binPath: "/x/.build/debug", product: nil) == nil)
  }
}
