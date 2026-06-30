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
    compileCacheEnabled: true,
    dependencyKey: "dk",
    dependencyRestoreKeys: ["rk"],
    buildKey: "bk",
    buildRestoreKeys: [],
    compileKey: "ck",
    compileRestoreKeys: ["cw-", "cf-"])
  let paths = CachePaths.Resolved(dependency: ["/a", "/b"], build: ["/c"], compile: ["/cas"])
  let expected = """
    dependency-cache-enabled=true
    build-cache-enabled=false
    compile-cache-enabled=true
    dependency-key=dk
    dependency-restore-keys<<CACHE_KEYS
    rk
    CACHE_KEYS
    build-key=bk
    build-restore-keys<<CACHE_KEYS
    CACHE_KEYS
    compile-key=ck
    compile-restore-keys<<CACHE_KEYS
    cw-
    cf-
    CACHE_KEYS
    dependency-paths<<CACHE_PATHS
    /a
    /b
    CACHE_PATHS
    build-paths<<CACHE_PATHS
    /c
    CACHE_PATHS
    compile-paths<<CACHE_PATHS
    /cas
    CACHE_PATHS

    """
  #expect(CacheOutput.githubOutput(plan: plan, paths: paths) == expected)
}

@Test
func githubOutputEmitsEmptyRestoreKeyBlock() {
  let plan = CachePlan.Result(
    dependencyCacheEnabled: false,
    buildCacheEnabled: false,
    compileCacheEnabled: false,
    dependencyKey: "dk",
    dependencyRestoreKeys: [],
    buildKey: "bk",
    buildRestoreKeys: [],
    compileKey: "ck",
    compileRestoreKeys: [])
  let output = CacheOutput.githubOutput(
    plan: plan, paths: CachePaths.Resolved(dependency: [], build: [], compile: []))
  // An empty list still emits the open/close delimiters so the action reads "".
  #expect(output.contains("dependency-restore-keys<<CACHE_KEYS\nCACHE_KEYS\n"))
  #expect(output.contains("build-restore-keys<<CACHE_KEYS\nCACHE_KEYS\n"))
  #expect(output.contains("compile-restore-keys<<CACHE_KEYS\nCACHE_KEYS\n"))
}

@Test
func githubOutputDelimiterAvoidsCollisionWithValues() {
  // A path value equal to the base delimiter (e.g. from EXTRA_CACHE_PATHS) must not end
  // the heredoc block early; the delimiter is extended until no value line matches.
  let plan = CachePlan.Result(
    dependencyCacheEnabled: true,
    buildCacheEnabled: true,
    compileCacheEnabled: false,
    dependencyKey: "dk",
    dependencyRestoreKeys: [],
    buildKey: "bk",
    buildRestoreKeys: [],
    compileKey: "ck",
    compileRestoreKeys: [])
  let paths = CachePaths.Resolved(
    dependency: [], build: ["CACHE_PATHS", "real/path"], compile: [])
  let output = CacheOutput.githubOutput(plan: plan, paths: paths)
  // The build-paths block opens and closes with the extended delimiter, and the literal
  // value is preserved on its own line between them.
  let expectedBlock = "build-paths<<CACHE_PATHS_EOF\nCACHE_PATHS\nreal/path\nCACHE_PATHS_EOF\n"
  #expect(output.contains(expectedBlock))
}
