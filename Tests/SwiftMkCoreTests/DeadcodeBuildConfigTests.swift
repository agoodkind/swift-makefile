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
    #expect(!text.contains("SYMROOT"))
}

@Test
func deadcodeBuildConfigWritesXcconfigAndReturnsAbsolutePath() throws {
    let makeDir = NSTemporaryDirectory() + "swiftmk-xcconfig-" + UUID().uuidString
    let environment = DeadcodeBuildConfig.buildEnvironment(
        derivedData: "/proj/build/DerivedData", makeDir: makeDir)
    let path = try #require(environment["XCODE_XCCONFIG_FILE"])
    #expect((path as NSString).isAbsolutePath)
    let written = try String(contentsOfFile: path, encoding: .utf8)
    #expect(written == DeadcodeBuildConfig.contents(derivedData: "/proj/build/DerivedData"))
}
