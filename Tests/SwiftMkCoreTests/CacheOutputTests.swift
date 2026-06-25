//
//  CacheOutputTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-24.
//  Copyright © 2026, all rights reserved.
//

import Testing

@testable import SwiftMkCore

// MARK: - CacheOutputTests

enum CacheOutputTests {}

@Test
func githubOutputMatchesActionsCacheFormat() {
  let plan = CachePlan.Result(
    dependencyCacheEnabled: true,
    buildCacheEnabled: false,
    dependencyKey: "dk",
    dependencyRestoreKeys: ["rk"],
    buildKey: "bk",
    buildRestoreKeys: [])
  let paths = CachePaths.Resolved(dependency: ["/a", "/b"], build: ["/c"])
  let expected = """
    dependency-cache-enabled=true
    build-cache-enabled=false
    dependency-key=dk
    dependency-restore-keys<<CACHE_KEYS
    rk
    CACHE_KEYS
    build-key=bk
    build-restore-keys<<CACHE_KEYS
    CACHE_KEYS
    dependency-paths<<CACHE_PATHS
    /a
    /b
    CACHE_PATHS
    build-paths<<CACHE_PATHS
    /c
    CACHE_PATHS

    """
  #expect(CacheOutput.githubOutput(plan: plan, paths: paths) == expected)
}

@Test
func githubOutputEmitsEmptyRestoreKeyBlock() {
  let plan = CachePlan.Result(
    dependencyCacheEnabled: false,
    buildCacheEnabled: false,
    dependencyKey: "dk",
    dependencyRestoreKeys: [],
    buildKey: "bk",
    buildRestoreKeys: [])
  let output = CacheOutput.githubOutput(
    plan: plan, paths: CachePaths.Resolved(dependency: [], build: []))
  // An empty list still emits the open/close delimiters so the action reads "".
  #expect(output.contains("dependency-restore-keys<<CACHE_KEYS\nCACHE_KEYS\n"))
  #expect(output.contains("build-restore-keys<<CACHE_KEYS\nCACHE_KEYS\n"))
}
