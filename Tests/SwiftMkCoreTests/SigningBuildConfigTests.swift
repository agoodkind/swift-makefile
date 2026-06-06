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
    let text = try #require(
        SigningBuildConfig.contents(identity: "", team: "H3BMXM4W7H", style: ""))
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

@Test
func signingBuildConfigWriteDegradesSafelyOnFailure() {
    // A makeDir under a non-directory cannot be created, so the write throws; the
    // function must degrade to nil (build proceeds with existing signing) not crash.
    let path = SigningBuildConfig.write(
        identity: "-", team: "", style: "", makeDir: "/dev/null/swiftmk-cannot-create")
    #expect(path == nil)
}

@Test
func signingXcconfigValuesParsesKeysIgnoringCommentsAndQuotes() throws {
    let path = NSTemporaryDirectory() + "swiftmk-xcc-" + UUID().uuidString + ".xcconfig"
    let text = """
        // a leading comment
        DEVELOPMENT_TEAM = H3BMXM4W7H
        CODE_SIGN_IDENTITY = Apple Development // trailing comment
        CODE_SIGN_STYLE = Automatic;
        QUOTED = "Apple Development"
        """
    try text.write(toFile: path, atomically: true, encoding: .utf8)
    let values = SigningBuildConfig.xcconfigValues(atPath: path)
    #expect(values["DEVELOPMENT_TEAM"] == "H3BMXM4W7H")
    #expect(values["CODE_SIGN_IDENTITY"] == "Apple Development")
    #expect(values["CODE_SIGN_STYLE"] == "Automatic")
    #expect(values["QUOTED"] == "Apple Development")
}

@Test
func signingXcconfigValuesReturnsEmptyForMissingFile() {
    let path = NSTemporaryDirectory() + "swiftmk-missing-" + UUID().uuidString + ".xcconfig"
    #expect(SigningBuildConfig.xcconfigValues(atPath: path).isEmpty)
}

// MARK: - SigningEnvironmentOverrideTests

/// The override mutates the process environment (`XCODE_XCCONFIG_FILE` and the
/// signing inputs), so these run serialized to keep that global state from one
/// test out of another.
@Suite(.serialized)
enum SigningEnvironmentOverrideTests {
    private static let signingEnvironmentKeys = [
        "CODE_SIGN_IDENTITY", "DEVELOPMENT_TEAM", "CODE_SIGN_STYLE",
        "SWIFT_MK_SIGN_IDENTITY", "SWIFT_MK_SIGN_TEAM", "SWIFT_MK_SIGN_STYLE",
    ]

    @Test
    static func noOpWhenXcodeXcconfigFileAlreadySet() {
        setenv("XCODE_XCCONFIG_FILE", "/tmp/preexisting.xcconfig", 1)
        let makeDir = NSTemporaryDirectory() + "swiftmk-noop-" + UUID().uuidString
        let path = SigningBuildConfig.applyEnvironmentOverride(makeDir: makeDir)
        unsetenv("XCODE_XCCONFIG_FILE")
        #expect(path == nil)
    }

    @Test
    static func writesAndSetsEnvFromXcconfigWhenUnset() throws {
        unsetenv("XCODE_XCCONFIG_FILE")
        for key in signingEnvironmentKeys {
            setenv(key, "", 1)
        }
        let makeDir = NSTemporaryDirectory() + "swiftmk-apply-" + UUID().uuidString
        let xcconfig = makeDir + ".xcconfig"
        try "DEVELOPMENT_TEAM = H3BMXM4W7H\n".write(
            toFile: xcconfig, atomically: true, encoding: .utf8)
        let path = SigningBuildConfig.applyEnvironmentOverride(
            localXcconfigPaths: [xcconfig], makeDir: makeDir)
        let applied = ProcessInfo.processInfo.environment["XCODE_XCCONFIG_FILE"]
        unsetenv("XCODE_XCCONFIG_FILE")
        for key in signingEnvironmentKeys {
            unsetenv(key)
        }
        let resolved = try #require(path)
        #expect(applied == resolved)
        let written = try String(contentsOfFile: resolved, encoding: .utf8)
        #expect(written.contains("DEVELOPMENT_TEAM = H3BMXM4W7H"))
        #expect(written.contains("CODE_SIGN_STYLE = Automatic"))
    }
}
