//
//  VersionMetaTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-22.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - VersionMetaTests

/// Fixed inputs so every case is deterministic without touching the clock, git,
/// or the environment.
private func inputs(
  marketingEnv: String = "",
  buildEnv: String = "",
  githubRefType: String = "",
  githubRefName: String = "",
  githubRunNumber: String = "",
  timestamp: String = "202607221530",
  calendar: String = "26.7.22",
  shortSHA: String = "a1b2c3d"
) -> VersionMeta.Inputs {
  VersionMeta.Inputs(
    marketingEnv: marketingEnv,
    buildEnv: buildEnv,
    githubRefType: githubRefType,
    githubRefName: githubRefName,
    githubRunNumber: githubRunNumber,
    timestamp: timestamp,
    calendar: calendar,
    shortSHA: shortSHA)
}

@Test
func devBuildMarksShortVersionAndUsesTimestampBuild() throws {
  let version = try VersionMeta.compute(inputs())
  #expect(version.marketing == "26.7.22+a1b2c3d-dev")
  #expect(version.build == "202607221530")
  #expect(version.tag == "202607221530-a1b2c3d-dev")
}

@Test
func devBuildWithoutGitDropsTheShaMarker() throws {
  let version = try VersionMeta.compute(inputs(shortSHA: ""))
  #expect(version.marketing == "26.7.22-dev")
  #expect(version.build == "202607221530")
  #expect(version.tag == "202607221530-dev")
}

@Test
func ciRunComputesTheReleaseScheme() throws {
  // The release meta job runs with a run number but no explicit version env.
  let version = try VersionMeta.compute(inputs(githubRunNumber: "80"))
  #expect(version.marketing == "26.7.22")
  #expect(version.build == "20260722153080")
  #expect(version.tag == "202607221530-50-a1b2c3d")
}

@Test
func tagRefUsesThePushedTagName() throws {
  let version = try VersionMeta.compute(
    inputs(githubRefType: "tag", githubRefName: "v1.2.3", githubRunNumber: "80"))
  #expect(version.tag == "v1.2.3")
  #expect(version.marketing == "26.7.22")
  #expect(version.build == "20260722153080")
}

@Test
func explicitEnvironmentVersionPassesThrough() throws {
  // The release build step sets both, already resolved by the meta job.
  let version = try VersionMeta.compute(
    inputs(
      marketingEnv: "26.7.22",
      buildEnv: "20260722153080",
      githubRunNumber: "80"))
  #expect(version.marketing == "26.7.22")
  #expect(version.build == "20260722153080")
  #expect(version.tag == "202607221530-50-a1b2c3d")
}

@Test
func buildVersionPastEighteenCharactersFailsLoud() {
  // A run number that pushes the build number past CFBundleVersion's cap must fail.
  #expect(throws: VersionMeta.VersionError.self) {
    try VersionMeta.compute(inputs(githubRunNumber: "1234567"))
  }
}

@Test
func releaseSchemeMatchesTheDocumentedReleaseMetaShape() throws {
  // Drift guard: the Swift release scheme must reproduce swift-release.mk's
  // release-meta (calendar yy.m.d short version, <timestamp><run> build number,
  // <timestamp>-<hex run>-<sha> tag) so the two cannot silently diverge.
  let version = try VersionMeta.compute(
    inputs(githubRunNumber: "255", timestamp: "202601020304", calendar: "26.1.2"))
  #expect(version.marketing == "26.1.2")
  #expect(version.build == "202601020304255")
  #expect(version.tag == "202601020304-ff-a1b2c3d")
}

@Test
func nonNumericRunNumberUsesTheDevSchemeConsistently() throws {
  // GitHub always sets a numeric run number; a non-numeric value must not take the
  // release build number while the tag falls back to a dev form. Both agree on dev.
  let version = try VersionMeta.compute(inputs(githubRunNumber: "abc"))
  #expect(version.marketing == "26.7.22+a1b2c3d-dev")
  #expect(version.build == "202607221530")
  #expect(version.tag == "202607221530-a1b2c3d-dev")
}

@Test
func versionStampInjectsBothSettingsWhenAbsent() throws {
  let request = Toolchain.Request(
    generator: .tuist, scheme: "App", workspace: "App.xcworkspace")
  let stamped = try Toolchain.versionStamped(request)
  #expect(stamped.extraSettings["MARKETING_VERSION"] != nil)
  #expect(stamped.extraSettings["CURRENT_PROJECT_VERSION"] != nil)
}

@Test
func versionStampLeavesAnExplicitCallerValueUntouched() throws {
  // A caller that already supplied the version (the release build step) keeps it.
  let request = Toolchain.Request(
    generator: .tuist,
    scheme: "App",
    workspace: "App.xcworkspace",
    extraSettings: [
      "MARKETING_VERSION": "9.9.9",
      "CURRENT_PROJECT_VERSION": "999999999999",
    ])
  let stamped = try Toolchain.versionStamped(request)
  #expect(stamped.extraSettings["MARKETING_VERSION"] == "9.9.9")
  #expect(stamped.extraSettings["CURRENT_PROJECT_VERSION"] == "999999999999")
}
