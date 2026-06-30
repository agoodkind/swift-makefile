//
//  CachePlanTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-24.
//  Copyright © 2026, all rights reserved.
//

import Testing

@testable import SwiftMkCore

// MARK: - CachePlanTests

enum CachePlanTests {}

// The xcode/swift version strings as they appear after sanitization. `sanitizeKeyPart`
// is idempotent on these (only allowed characters, single dashes), so passing them
// reproduces exactly what cache-plan.sh emitted for the same probe output.
private let goldenXcode = "Xcode-26.5-Build-version-17F42"
private let goldenSwift =
  "Apple-Swift-version-6.3.2-swiftlang-6.3.2.1.108-clang-2100.1.1.101-Target-arm64-apple-macosx26.0"
private let goldenPrefix = "macOS-ARM64-swift-mk-v1-\(goldenXcode)-\(goldenSwift)"

private func goldenInputs(
  profile: String = "safe",
  version: String = "v1",
  dependencyHash: String = "deadbeef",
  buildHash: String = "cafef00d",
  compileWriter: String = "",
  compileRunUnique: String = "",
  isCompileWriter: Bool = false
) -> CachePlan.Inputs {
  CachePlan.Inputs(
    profile: profile,
    version: version,
    dependencyHash: dependencyHash,
    buildHash: buildHash,
    runnerOS: "macOS",
    runnerArch: "ARM64",
    xcodeVersion: goldenXcode,
    swiftVersion: goldenSwift,
    weeklyEpoch: "2026w25",
    compileWriter: compileWriter,
    compileRunUnique: compileRunUnique,
    isCompileWriter: isCompileWriter)
}

@Test
func sanitizeKeyPartMatchesTrComplementSqueeze() {
  // Verified empirically against `tr -cs '[:alnum:]_.-' '-'`.
  #expect(CachePlan.sanitizeKeyPart("a  b") == "a-b")
  #expect(CachePlan.sanitizeKeyPart("a--b") == "a-b")
  #expect(CachePlan.sanitizeKeyPart("a -b") == "a-b")
  #expect(CachePlan.sanitizeKeyPart("a_b.c-d") == "a_b.c-d")
  #expect(CachePlan.sanitizeKeyPart("x/y:z") == "x-y-z")
  #expect(CachePlan.sanitizeKeyPart("Xcode 26.5\nBuild 17F42") == "Xcode-26.5-Build-17F42")
  #expect(CachePlan.sanitizeKeyPart("--lead") == "-lead")
  #expect(CachePlan.sanitizeKeyPart("trail--") == "trail-")
}

@Test
func sanitizeKeyPartIsIdempotentOnSanitizedValues() {
  #expect(CachePlan.sanitizeKeyPart(goldenXcode) == goldenXcode)
  #expect(CachePlan.sanitizeKeyPart(goldenSwift) == goldenSwift)
}

@Test
func computeProducesGoldenSafeKeys() throws {
  let result = try CachePlan.compute(goldenInputs())
  #expect(result.dependencyCacheEnabled)
  #expect(result.buildCacheEnabled)
  #expect(result.dependencyKey == "\(goldenPrefix)-deps-deadbeef")
  #expect(result.dependencyRestoreKeys == ["\(goldenPrefix)-deps-"])
  #expect(result.buildKey == "\(goldenPrefix)-build-2026w25-deps-deadbeef-build-cafef00d")
  // Build restore keys are deliberately empty: a fallback restore can mix
  // incompatible module maps across dependency or build hashes.
  #expect(result.buildRestoreKeys.isEmpty)
}

@Test
func computeSanitizesRawVersionStrings() throws {
  var inputs = goldenInputs()
  inputs.xcodeVersion = "Xcode 26.5\nBuild version 17F42"
  let result = try CachePlan.compute(inputs)
  #expect(result.dependencyKey.contains("-Xcode-26.5-Build-version-17F42-"))
}

@Test
func dependenciesProfileEnablesOnlyDependencyCache() throws {
  for profile in ["dependencies", "dependency", "deps", "DEPS"] {
    let result = try CachePlan.compute(goldenInputs(profile: profile))
    #expect(result.dependencyCacheEnabled, "profile \(profile)")
    #expect(!result.buildCacheEnabled, "profile \(profile)")
  }
}

@Test
func offProfileDisablesAllCaches() throws {
  for profile in ["off", "none", "false", "0", "OFF"] {
    let result = try CachePlan.compute(goldenInputs(profile: profile))
    #expect(!result.dependencyCacheEnabled, "profile \(profile)")
    #expect(!result.buildCacheEnabled, "profile \(profile)")
  }
}

@Test
func unknownProfileThrows() {
  #expect(throws: CachePlan.PlanError.self) {
    _ = try CachePlan.compute(goldenInputs(profile: "turbo"))
  }
}

@Test
func compileCacheRollsForACompilingGate() throws {
  let result = try CachePlan.compute(
    goldenInputs(compileWriter: "build", compileRunUnique: "1001-1", isCompileWriter: true))
  #expect(result.compileCacheEnabled)
  // The key carries the writer and the unique run value, so each save lands fresh.
  #expect(result.compileKey == "\(goldenPrefix)-compile-deps-deadbeef-build-1001-1")
  // Restore prefers the gate's own latest pile, then any sibling pile for the same deps.
  #expect(
    result.compileRestoreKeys == [
      "\(goldenPrefix)-compile-deps-deadbeef-build-",
      "\(goldenPrefix)-compile-deps-deadbeef-",
    ])
}

@Test
func compileKeyRollsWithRunUniqueButRestoreKeysStayStable() throws {
  let first = try CachePlan.compute(
    goldenInputs(compileWriter: "build", compileRunUnique: "1001-1", isCompileWriter: true))
  let second = try CachePlan.compute(
    goldenInputs(compileWriter: "build", compileRunUnique: "1002-1", isCompileWriter: true))
  // A new run yields a new key (so the post-job save always lands and the pile rolls)...
  #expect(first.compileKey != second.compileKey)
  // ...but the restore prefix is identical, so the next run finds the latest prior pile.
  #expect(first.compileRestoreKeys == second.compileRestoreKeys)
}

@Test
func compileCacheDisabledForANonCompilingGate() throws {
  let result = try CachePlan.compute(
    goldenInputs(compileWriter: "lint-format", compileRunUnique: "1001-1", isCompileWriter: false))
  #expect(!result.compileCacheEnabled)
}

@Test
func compileCacheDisabledWhenCachingIsOff() throws {
  let result = try CachePlan.compute(
    goldenInputs(
      profile: "off", compileWriter: "build", compileRunUnique: "1001-1", isCompileWriter: true))
  #expect(!result.compileCacheEnabled)
}

@Test
func emptyVersionAndHashesFallBackToDefaults() throws {
  let inputs = CachePlan.Inputs(
    profile: "safe",
    version: "",
    dependencyHash: "",
    buildHash: "",
    runnerOS: "macOS",
    runnerArch: "ARM64",
    xcodeVersion: goldenXcode,
    swiftVersion: goldenSwift,
    weeklyEpoch: "2026w25")
  let result = try CachePlan.compute(inputs)
  let prefix = "macOS-ARM64-swift-mk-v1-\(goldenXcode)-\(goldenSwift)"
  #expect(result.dependencyKey == "\(prefix)-deps-no-dependencies")
  #expect(result.buildKey == "\(prefix)-build-2026w25-deps-no-dependencies-build-no-build-config")
}
