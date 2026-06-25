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

@Test
func githubOutputDelimiterAvoidsCollisionWithValues() {
  // A path value equal to the base delimiter (e.g. from EXTRA_CACHE_PATHS) must not end
  // the heredoc block early; the delimiter is extended until no value line matches.
  let plan = CachePlan.Result(
    dependencyCacheEnabled: true,
    buildCacheEnabled: true,
    dependencyKey: "dk",
    dependencyRestoreKeys: [],
    buildKey: "bk",
    buildRestoreKeys: [])
  let paths = CachePaths.Resolved(dependency: [], build: ["CACHE_PATHS", "real/path"])
  let output = CacheOutput.githubOutput(plan: plan, paths: paths)
  // The build-paths block opens and closes with the extended delimiter, and the literal
  // value is preserved on its own line between them.
  let expectedBlock = "build-paths<<CACHE_PATHS_EOF\nCACHE_PATHS\nreal/path\nCACHE_PATHS_EOF\n"
  #expect(output.contains(expectedBlock))
}
