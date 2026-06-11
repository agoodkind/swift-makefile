//
//  BuildCacheTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-10.
//  Copyright © 2026, all rights reserved.
//

import Testing

@testable import SwiftMkCore

// MARK: - BuildCacheTests

enum BuildCacheTests {}

@Test
func disabledSelectionsAreRecognized() {
  #expect(BuildCache.isDisabled(""))
  #expect(BuildCache.isDisabled("none"))
  #expect(BuildCache.isDisabled("OFF"))
  #expect(BuildCache.isDisabled("0"))
  #expect(!BuildCache.isDisabled("ccache"))
}

@Test
func wrapperEnvironmentUsesTwoWordCompilerValues() {
  let environment = BuildCache.wrapperEnvironment(toolPath: "/opt/homebrew/bin/ccache")
  #expect(environment["CC"] == "/opt/homebrew/bin/ccache /usr/bin/clang")
  #expect(environment["CXX"] == "/opt/homebrew/bin/ccache /usr/bin/clang++")
}
