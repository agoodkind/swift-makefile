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
func cleanRefusesPathsOutsideSafeRoots() {
  // The filesystem root and an arbitrary system path are never safe to remove.
  #expect(!CacheService.isWithinSafeRoots("/"))
  #expect(!CacheService.isWithinSafeRoots("/usr/local/bin"))
  #expect(!CacheService.isWithinSafeRoots(""))
}

@Test
func cleanAllowsPathsInsideHomeOrWorkspace() {
  let home = Env.get("HOME", FileManager.default.homeDirectoryForCurrentUser.path)
  let cwd = FileManager.default.currentDirectoryPath
  #expect(CacheService.isWithinSafeRoots("\(home)/Library/Caches/swift-mk/ModuleCache"))
  #expect(CacheService.isWithinSafeRoots("\(cwd)/.derived-data/Index.noindex"))
}
