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
    setenv("SWIFT_MK_SWIFTPM_CACHE_ARGS", "--enable-dependency-cache --manifest-cache shared", 1)
    defer {
      if let prior {
        setenv("SWIFT_MK_SWIFTPM_CACHE_ARGS", prior, 1)
      } else {
        unsetenv("SWIFT_MK_SWIFTPM_CACHE_ARGS")
      }
    }
    #expect(
      SwiftPM.cacheArguments() == ["--enable-dependency-cache", "--manifest-cache", "shared"])
  }

  @Test
  static func executablePathJoinsBinPathAndProduct() {
    #expect(
      SwiftPM.executablePath(binPath: "/x/.build/debug", product: "Tool") == "/x/.build/debug/Tool")
    #expect(SwiftPM.executablePath(binPath: nil, product: "Tool") == nil)
    #expect(SwiftPM.executablePath(binPath: "/x/.build/debug", product: nil) == nil)
  }
}
