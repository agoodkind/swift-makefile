//
//  SigningVerificationTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-06.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - SigningVerificationTests

/// Empty namesake type so SwiftLint `file_name` finds a declaration matching
/// `SigningVerificationTests.swift`; the suite is written as free `@Test` functions.
enum SigningVerificationTests {}

@Test
func artifactAdHocPassesWhenAdHocExpected() {
    let output = "Signature=adhoc\nTeamIdentifier=not set\n"
    #expect(
        SigningVerification.artifactSignatureSatisfies(
            output: output, status: 0, expectAdHoc: true, expectedTeam: ""))
}

@Test
func artifactAdHocFailsWhenTeamExpected() {
    let output = "Signature=adhoc\nTeamIdentifier=not set\n"
    #expect(
        !SigningVerification.artifactSignatureSatisfies(
            output: output, status: 0, expectAdHoc: false, expectedTeam: "H3BMXM4W7H"))
}

@Test
func artifactTeamMatchPasses() {
    let output = "Authority=Apple Development\nTeamIdentifier=H3BMXM4W7H\n"
    #expect(
        SigningVerification.artifactSignatureSatisfies(
            output: output, status: 0, expectAdHoc: false, expectedTeam: "H3BMXM4W7H"))
}

@Test
func artifactTeamMismatchFails() {
    let output = "TeamIdentifier=WRONG00000\n"
    #expect(
        !SigningVerification.artifactSignatureSatisfies(
            output: output, status: 0, expectAdHoc: false, expectedTeam: "H3BMXM4W7H"))
}

@Test
func artifactNonZeroStatusFails() {
    #expect(
        !SigningVerification.artifactSignatureSatisfies(
            output: "", status: 1, expectAdHoc: false, expectedTeam: "H3BMXM4W7H"))
}

@Test
func settingsMatchPassesForDeveloperSigning() {
    let output =
        "CODE_SIGN_IDENTITY = Apple Development\n"
        + "CODE_SIGN_STYLE = Automatic\n"
        + "DEVELOPMENT_TEAM = H3BMXM4W7H\n"
    #expect(
        SigningVerification.settingsMatch(
            output: output, expectedIdentity: "Apple Development", expectedTeam: "H3BMXM4W7H"))
}

@Test
func settingsMatchFailsWhenTargetIsAdHoc() {
    let output = "CODE_SIGN_IDENTITY = -\nDEVELOPMENT_TEAM = H3BMXM4W7H\n"
    #expect(
        !SigningVerification.settingsMatch(
            output: output, expectedIdentity: "Apple Development", expectedTeam: "H3BMXM4W7H"))
}

@Test
func settingsMatchFailsOnWrongTeam() {
    let output =
        "CODE_SIGN_IDENTITY = Apple Development\nDEVELOPMENT_TEAM = WRONG00000\n"
    #expect(
        !SigningVerification.settingsMatch(
            output: output, expectedIdentity: "Apple Development", expectedTeam: "H3BMXM4W7H"))
}

@Test
func settingsMatchAdHocContextAcceptsDashAndRejectsRealIdentity() {
    #expect(
        SigningVerification.settingsMatch(
            output: "CODE_SIGN_IDENTITY = -\n", expectedIdentity: "-", expectedTeam: ""))
    #expect(
        !SigningVerification.settingsMatch(
            output: "CODE_SIGN_IDENTITY = Apple Development\n",
            expectedIdentity: "-",
            expectedTeam: ""))
}
