//
//  CacheServiceTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-24.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - CacheServiceTests

enum CacheServiceTests {}

@Test
func cleanRefusesPathsOutsideKnownCacheRoots() {
  // Reads the process working directory, so serialize against the gate tests that
  // temporarily chdir into a scratch checkout.
  TestGlobalLock.withLock {
    let home = Env.get("HOME", FileManager.default.homeDirectoryForCurrentUser.path)
    let cwd = FileManager.default.currentDirectoryPath
    // The filesystem root, $HOME, and the workspace itself are never removable, nor is
    // a sibling tree a misconfigured EXTRA_CACHE_PATHS (`.`, `..`) could resolve to.
    #expect(!CacheService.isWithinSafeRoots("/"))
    #expect(!CacheService.isWithinSafeRoots(""))
    #expect(!CacheService.isWithinSafeRoots("/usr/local/bin"))
    #expect(!CacheService.isWithinSafeRoots(home))
    #expect(!CacheService.isWithinSafeRoots(cwd))
    #expect(
      !CacheService.isWithinSafeRoots(
        (cwd as NSString).deletingLastPathComponent + "/other-repo"))
    #expect(!CacheService.isWithinSafeRoots("\(home)/Sites/some-project"))
  }
}

@Test
func cleanAllowsKnownCacheRoots() {
  // Reads the process working directory, so serialize against the gate tests that
  // temporarily chdir into a scratch checkout.
  TestGlobalLock.withLock {
    let home = Env.get("HOME", FileManager.default.homeDirectoryForCurrentUser.path)
    let cwd = FileManager.default.currentDirectoryPath
    #expect(CacheService.isWithinSafeRoots("\(home)/Library/Caches/swift-mk/ModuleCache"))
    #expect(CacheService.isWithinSafeRoots("\(home)/.local/share/mise/installs"))
    #expect(CacheService.isWithinSafeRoots("\(cwd)/.build"))
    #expect(CacheService.isWithinSafeRoots("\(cwd)/.derived-data/Index.noindex"))
  }
}

@Test
func customDerivedDataOutsideBoundaryIsNotCleanable() {
  // A consumer-set SWIFT_MK_DERIVED_DATA outside $HOME/workspace must not enter the
  // cleanable allowlist, or cache clean could delete an unrelated tree.
  #expect(
    CacheService.boundedDerivedDataRoot("/opt/external/.derived-data", home: "/h", cwd: "/ws")
      == nil)
  #expect(
    CacheService.boundedDerivedDataRoot("/ws/.derived-data", home: "/h", cwd: "/ws")
      == "/ws/.derived-data")
  // The workspace root itself (no subpath) is not a cleanable DerivedData root.
  #expect(CacheService.boundedDerivedDataRoot("/ws", home: "/h", cwd: "/ws") == nil)
}
