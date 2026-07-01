//
//  DeadcodeBuildConfigTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-05.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - DeadcodeBuildConfigTests

/// Empty namesake type so SwiftLint `file_name` finds a declaration matching
/// `DeadcodeBuildConfigTests.swift`; the suite is written as free `@Test` functions.
enum DeadcodeBuildConfigTests {}

@Test
func deadcodeBuildConfigDisablesSigning() {
  let text = DeadcodeBuildConfig.contents(derivedData: "")
  #expect(text.contains("CODE_SIGNING_ALLOWED = NO"))
  #expect(text.contains("CODE_SIGNING_REQUIRED = NO"))
  #expect(text.contains("CODE_SIGN_IDENTITY = -"))
  #expect(text.contains("COMPILER_INDEX_STORE_ENABLE = YES"))
  #expect(DeadcodeBuildConfig.baseContents.contains("COMPILATION_CACHE_ENABLE_CACHING = NO"))
  #expect(text.contains("COMPILATION_CACHE_ENABLE_CACHING = NO"))
  #expect(
    DeadcodeBuildConfig.baseContents.contains(
      "COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS = NO"))
  #expect(text.contains("COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS = NO"))
  #expect(DeadcodeBuildConfig.baseContents.contains("ONLY_ACTIVE_ARCH = YES"))
  #expect(text.contains("ONLY_ACTIVE_ARCH = YES"))
}

@Test
func deadcodeBuildConfigOmitsObjrootWithoutDerivedData() {
  let text = DeadcodeBuildConfig.contents(derivedData: "  ")
  #expect(!text.contains("OBJROOT"))
}

@Test
func deadcodeBuildConfigRedirectsObjrootButNotSymroot() {
  let text = DeadcodeBuildConfig.contents(derivedData: "/proj/build/DerivedData")
  #expect(text.contains("OBJROOT = /proj/build/DerivedData/DeadcodeBuild/Intermediates.noindex"))
  // SYMROOT must NOT be redirected: products stay where the consumer expects them.
  // Match a real setting assignment, not the word "SYMROOT" in the header comment.
  #expect(!text.contains("SYMROOT ="))
}

@Test
func deadcodeBuildConfigResolvesRelativeObjrootAgainstConsumerRoot() {
  let text = DeadcodeBuildConfig.contents(
    derivedData: "build", currentDirectory: "/repo/Consumer")
  #expect(text.contains("OBJROOT = /repo/Consumer/build/DeadcodeBuild/Intermediates.noindex"))
  #expect(!text.contains("OBJROOT = build/DeadcodeBuild"))
}

@Test
func deadcodeBuildConfigWritesXcconfigAndReturnsAbsolutePath() throws {
  let makeDir = NSTemporaryDirectory() + "swiftmk-xcconfig-" + UUID().uuidString
  let environment = DeadcodeBuildConfig.buildEnvironment(
    derivedData: "/proj/build/DerivedData", makeDir: makeDir)
  let path = try #require(environment["XCODE_XCCONFIG_FILE"])
  #expect((path as NSString).isAbsolutePath)
  let written = try String(contentsOfFile: path, encoding: .utf8)
  #expect(
    written
      == DeadcodeBuildConfig.contents(
        derivedData: "/proj/build/DerivedData",
        developmentTeam: Env.get("DEVELOPMENT_TEAM")))
}

@Test
func deadcodeBuildConfigSetsResultBundleDirectoryWithDerivedData() {
  let makeDir = NSTemporaryDirectory() + "swiftmk-xcconfig-" + UUID().uuidString
  let environment = DeadcodeBuildConfig.buildEnvironment(
    derivedData: "/proj/build/DerivedData", makeDir: makeDir)
  #expect(
    environment["SWIFT_MK_RESULT_BUNDLE_DIR"] == "/proj/build/DerivedData/ResultBundles")
}

@Test
func deadcodeBuildConfigResultBundleUsesResolvedDerivedData() {
  let makeDir = NSTemporaryDirectory() + "swiftmk-xcconfig-" + UUID().uuidString
  let environment = DeadcodeBuildConfig.buildEnvironment(
    derivedData: "build", makeDir: makeDir, currentDirectory: "/repo/Consumer")
  #expect(environment["SWIFT_MK_RESULT_BUNDLE_DIR"] == "/repo/Consumer/build/ResultBundles")
}

@Test
func deadcodeBuildConfigOmitsResultBundleDirectoryWithoutDerivedData() {
  let makeDir = NSTemporaryDirectory() + "swiftmk-xcconfig-" + UUID().uuidString
  let environment = DeadcodeBuildConfig.buildEnvironment(derivedData: "  ", makeDir: makeDir)
  #expect(environment["SWIFT_MK_RESULT_BUNDLE_DIR"] == nil)
}

@Test
func deadcodeBuildConfigCarriesDevelopmentTeamThroughSigningOverride() {
  // The deadcode xcconfig displaces the signing xcconfig that otherwise supplies
  // DEVELOPMENT_TEAM, and a consumer's config-generation script phase can require
  // the team as non-signing context, so the override must carry it through while
  // signing stays disabled.
  let text = DeadcodeBuildConfig.contents(
    derivedData: "/proj/build/DerivedData", developmentTeam: "H3BMXM4W7H")
  #expect(text.contains("DEVELOPMENT_TEAM = H3BMXM4W7H"))
  #expect(text.contains("CODE_SIGNING_ALLOWED = NO"))
}

@Test
func deadcodeBuildConfigOmitsDevelopmentTeamWhenUnknown() {
  let text = DeadcodeBuildConfig.contents(derivedData: "", developmentTeam: "  ")
  #expect(!text.contains("DEVELOPMENT_TEAM"))
}
