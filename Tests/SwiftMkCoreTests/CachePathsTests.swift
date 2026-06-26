//
//  CachePathsTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-24.
//  Copyright © 2026, all rights reserved.
//

import Testing

@testable import SwiftMkCore

// MARK: - CachePathsTests

enum CachePathsTests {}

private func sampleInputs(
  spmCachePath: String? = "/h/Library/Caches/swift-mk/SourcePackages",
  moduleCachePath: String? = "/h/Library/Caches/swift-mk/ModuleCache",
  xcodeCachePath: String? = "/h/Library/Caches/swift-mk/CompilationCache",
  extraPaths: [String] = []
) -> CachePaths.Inputs {
  CachePaths.Inputs(
    home: "/h",
    derivedDataPath: "/ws/.derived-data",
    spmCachePath: spmCachePath,
    moduleCachePath: moduleCachePath,
    xcodeCachePath: xcodeCachePath,
    extraPaths: extraPaths)
}

@Test
func dependencyBucketKeepsLegacyHomeCaches() {
  let resolved = CachePaths.resolve(sampleInputs())
  // Parity with the former cache-plan.sh dependency list.
  for expected in [
    "/h/.cache/tuist",
    "/h/.local/share/mise/downloads",
    "/h/.local/share/mise/installs",
    "/h/.local/share/mise/plugins",
    "/h/Library/Caches/org.swift.swiftpm",
    "/h/Library/Caches/ccache",
    "/h/Library/Caches/Mozilla.sccache",
    "/h/.cache/sccache",
    "Tuist/.build",
  ] {
    #expect(resolved.dependency.contains(expected), "missing \(expected)")
  }
}

@Test
func dependencyBucketAddsSharedSwiftMkCaches() {
  // The gap: the engine's shared module, SPM, and CAS caches were never persisted.
  let resolved = CachePaths.resolve(sampleInputs())
  #expect(resolved.dependency.contains("/h/Library/Caches/swift-mk/SourcePackages"))
  #expect(resolved.dependency.contains("/h/Library/Caches/swift-mk/ModuleCache"))
  #expect(resolved.dependency.contains("/h/Library/Caches/swift-mk/CompilationCache"))
}

@Test
func sharedCachesOmittedWhenDisabled() {
  let resolved = CachePaths.resolve(
    sampleInputs(spmCachePath: nil, moduleCachePath: nil, xcodeCachePath: nil))
  #expect(!resolved.dependency.contains("/h/Library/Caches/swift-mk/SourcePackages"))
  #expect(!resolved.dependency.contains("/h/Library/Caches/swift-mk/ModuleCache"))
  #expect(!resolved.dependency.contains("/h/Library/Caches/swift-mk/CompilationCache"))
}

@Test
func buildBucketKeepsLocalBuildDirs() {
  let resolved = CachePaths.resolve(sampleInputs())
  for expected in [
    ".build", "swiftcheck/.build", "Tools/.build",
    ".make/swift-mk-build", ".make/swiftcheck/.build",
  ] {
    #expect(resolved.build.contains(expected), "missing \(expected)")
  }
}

@Test
func buildBucketUsesResolvedDerivedDataRoot() {
  // The engine knows the real DerivedData root, so it emits that one root's
  // subdirs rather than the four guessed roots the shell script hardcoded.
  let resolved = CachePaths.resolve(sampleInputs())
  for expected in [
    "/ws/.derived-data/Build/Intermediates.noindex",
    "/ws/.derived-data/Index.noindex",
    "/ws/.derived-data/SourcePackages",
  ] {
    #expect(resolved.build.contains(expected), "missing \(expected)")
  }
}

@Test
func compilationCacheIsADependencyOutsideDerivedData() {
  // The CAS store is the shared content-addressed path, NOT a DerivedData subdir, so
  // the dead-code build's `rm -rf` of DerivedData cannot destroy it and cross-run
  // replay survives. It must be in the dependency bucket and absent from the build
  // bucket (no DerivedData CompilationCache.noindex entry).
  let resolved = CachePaths.resolve(sampleInputs())
  #expect(resolved.dependency.contains("/h/Library/Caches/swift-mk/CompilationCache"))
  #expect(!resolved.build.contains("/ws/.derived-data/CompilationCache.noindex"))
  #expect(!resolved.build.contains(where: { $0.hasSuffix("/CompilationCache.noindex") }))
}

@Test
func extraPathsAppendToBuildBucket() {
  let resolved = CachePaths.resolve(sampleInputs(extraPaths: ["custom/dir", "another/dir"]))
  #expect(resolved.build.contains("custom/dir"))
  #expect(resolved.build.contains("another/dir"))
}
