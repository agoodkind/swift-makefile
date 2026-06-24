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
  #expect(BuildCache.isDisabled("none"))
  #expect(BuildCache.isDisabled("OFF"))
  #expect(BuildCache.isDisabled("0"))
  // Unset is auto-detect, not disabled.
  #expect(!BuildCache.isDisabled(""))
  #expect(!BuildCache.isDisabled("ccache"))
}

@Test
func wrapperEnvironmentUsesTwoWordCompilerValues() {
  let environment = BuildCache.wrapperEnvironment(toolPath: "/opt/homebrew/bin/ccache")
  #expect(environment["CC"] == "/opt/homebrew/bin/ccache /usr/bin/clang")
  #expect(environment["CXX"] == "/opt/homebrew/bin/ccache /usr/bin/clang++")
}

@Test
func explicitOptOutReturnsNilEvenWhenToolInstalled() {
  let result = BuildCache.resolve(selection: "off") { _ in "/opt/homebrew/bin/ccache" }
  #expect(result == nil)
}

@Test
func unsetAutoDetectsCcacheFirst() {
  let result = BuildCache.resolve(selection: "") { tool in
    tool == "ccache" ? "/opt/homebrew/bin/ccache" : "/opt/homebrew/bin/sccache"
  }
  #expect(result?["CC"] == "/opt/homebrew/bin/ccache /usr/bin/clang")
}

@Test
func unsetFallsBackToSccacheWhenOnlySccacheInstalled() {
  let result = BuildCache.resolve(selection: "") { tool in
    tool == "sccache" ? "/opt/homebrew/bin/sccache" : nil
  }
  #expect(result?["CC"] == "/opt/homebrew/bin/sccache /usr/bin/clang")
}

@Test
func unsetReturnsNilWhenNoToolInstalled() {
  let result = BuildCache.resolve(selection: "") { _ in nil }
  #expect(result == nil)
}

@Test
func explicitToolUsedWhenInstalled() {
  let result = BuildCache.resolve(selection: "ccache") { tool in
    tool == "ccache" ? "/usr/bin/ccache" : nil
  }
  #expect(result?["CXX"] == "/usr/bin/ccache /usr/bin/clang++")
}

@Test
func explicitToolReturnsNilWhenNotInstalled() {
  let result = BuildCache.resolve(selection: "ccache") { _ in nil }
  #expect(result == nil)
}

@Test
func unknownSelectionReturnsNil() {
  let result = BuildCache.resolve(selection: "foo") { _ in "/x" }
  #expect(result == nil)
}
