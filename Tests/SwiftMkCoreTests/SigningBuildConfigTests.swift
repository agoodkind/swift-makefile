//
//  SigningBuildConfigTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-05.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - SigningBuildConfigTests

/// Empty namesake type so SwiftLint `file_name` finds a declaration matching
/// `SigningBuildConfigTests.swift`; the suite is written as free `@Test` functions.
enum SigningBuildConfigTests {}

@Test
func signingBuildConfigAdHocFromDashIdentity() throws {
    let text = try #require(SigningBuildConfig.contents(identity: "-", team: "", style: ""))
    #expect(text.contains("CODE_SIGN_IDENTITY = -"))
    #expect(text.contains("CODE_SIGN_STYLE = Manual"))
    #expect(text.contains("CODE_SIGNING_ALLOWED = YES"))
    #expect(text.contains("CODE_SIGNING_REQUIRED = NO"))
    // Ad-hoc needs no team.
    #expect(!text.contains("DEVELOPMENT_TEAM"))
}

@Test
func signingBuildConfigAdHocKeepsTeamWhenProvided() throws {
    // The PR-check context sets identity "-" with a team; the team is harmless and
    // is preserved, but signing still stays ad-hoc and not required.
    let text = try #require(
        SigningBuildConfig.contents(identity: "-", team: "H3BMXM4W7H", style: ""))
    #expect(text.contains("CODE_SIGN_IDENTITY = -"))
    #expect(text.contains("DEVELOPMENT_TEAM = H3BMXM4W7H"))
    #expect(text.contains("CODE_SIGNING_REQUIRED = NO"))
}

@Test
func signingBuildConfigDeveloperIdFromIdentityAndTeam() throws {
    let identity = "Developer ID Application: Alex Goodkind (H3BMXM4W7H)"
    let text = try #require(
        SigningBuildConfig.contents(identity: identity, team: "H3BMXM4W7H", style: ""))
    #expect(text.contains("CODE_SIGN_IDENTITY = \(identity)"))
    #expect(text.contains("CODE_SIGN_STYLE = Manual"))
    #expect(text.contains("DEVELOPMENT_TEAM = H3BMXM4W7H"))
    // A real identity is never ad-hoc, so the ad-hoc allowances stay out.
    #expect(!text.contains("CODE_SIGNING_REQUIRED = NO"))
}

@Test
func signingBuildConfigAutomaticFromTeamOnly() throws {
    let text = try #require(SigningBuildConfig.contents(identity: "", team: "H3BMXM4W7H", style: ""))
    #expect(text.contains("CODE_SIGN_STYLE = Automatic"))
    #expect(text.contains("DEVELOPMENT_TEAM = H3BMXM4W7H"))
    // No identity setting line when the identity is empty; Automatic resolves the
    // identity. Match a real setting line (leading newline), not the header comment.
    #expect(!text.contains("\nCODE_SIGN_IDENTITY ="))
}

@Test
func signingBuildConfigEmptyInputsProduceNoOverride() {
    #expect(SigningBuildConfig.contents(identity: "", team: "", style: "") == nil)
    #expect(SigningBuildConfig.contents(identity: "  ", team: "  ", style: "  ") == nil)
}

@Test
func signingBuildConfigExplicitStyleWins() throws {
    // An empty identity with a team would infer Automatic; an explicit style overrides.
    let text = try #require(
        SigningBuildConfig.contents(identity: "", team: "H3BMXM4W7H", style: "Manual"))
    #expect(text.contains("CODE_SIGN_STYLE = Manual"))
}

@Test
func signingBuildConfigWriteReturnsNilWithoutOverride() {
    let makeDir = NSTemporaryDirectory() + "swiftmk-signing-none-" + UUID().uuidString
    let path = SigningBuildConfig.write(identity: "", team: "", style: "", makeDir: makeDir)
    #expect(path == nil)
}

@Test
func signingBuildConfigWriteWritesXcconfigAndReturnsAbsolutePath() throws {
    let makeDir = NSTemporaryDirectory() + "swiftmk-signing-" + UUID().uuidString
    let path = try #require(
        SigningBuildConfig.write(
            identity: "", team: "H3BMXM4W7H", style: "", makeDir: makeDir))
    #expect((path as NSString).isAbsolutePath)
    let written = try String(contentsOfFile: path, encoding: .utf8)
    #expect(written == SigningBuildConfig.contents(identity: "", team: "H3BMXM4W7H", style: ""))
}
