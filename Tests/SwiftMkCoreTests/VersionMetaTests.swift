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

enum VersionMetaTests {
  /// Fixed inputs so every case is deterministic without touching the clock, git,
  /// or the environment.
  private static func inputs(
    marketingEnv: String = "",
    buildEnv: String = "",
    githubRefType: String = "",
    githubRefName: String = "",
    githubRunNumber: String = "",
    timestamp: String = "202607221530",
    calendar: String = "26.7.22",
    shortSHA: String = "a1b2c3d",
    releaseTrack: VersionMeta.ReleaseTrack? = nil,
    releaseTag: String = ""
  ) -> VersionMeta.Inputs {
    VersionMeta.Inputs(
      marketingEnv: marketingEnv,
      buildEnv: buildEnv,
      githubRefType: githubRefType,
      githubRefName: githubRefName,
      githubRunNumber: githubRunNumber,
      timestamp: timestamp,
      calendar: calendar,
      shortSHA: shortSHA,
      releaseTrack: releaseTrack,
      releaseTag: releaseTag)
  }

  @Test
  static func devBuildMarksShortVersionAndUsesTimestampBuild() throws {
    let version = try VersionMeta.compute(inputs())
    #expect(version.marketing == "26.7.22+a1b2c3d-dev")
    #expect(version.build == "202607221530")
    #expect(version.tag == "202607221530-a1b2c3d-dev")
  }

  @Test
  static func devBuildWithoutGitDropsTheShaMarker() throws {
    let version = try VersionMeta.compute(inputs(shortSHA: ""))
    #expect(version.marketing == "26.7.22-dev")
    #expect(version.build == "202607221530")
    #expect(version.tag == "202607221530-dev")
  }

  @Test
  static func ciRunComputesTheReleaseScheme() throws {
    // The release meta job runs with a run number but no explicit version env.
    let version = try VersionMeta.compute(inputs(githubRunNumber: "80"))
    #expect(version.marketing == "26.7.22")
    #expect(version.build == "20260722153080")
    #expect(version.tag == "202607221530-50-a1b2c3d")
  }

  @Test
  static func prereleaseTrackBuildsTheApprovedTagAndArtifactVersion() throws {
    // Removing the prerelease tag grammar would make a candidate impossible to
    // publish and a filename unsafe for a literal plus sign.
    let version = try VersionMeta.compute(
      inputs(githubRunNumber: "87", releaseTrack: .prerelease))
    #expect(version.marketing == "26.7.22")
    #expect(version.build == "202607221530000087")
    #expect(version.tag == "26.7.22-pre.202607221530+a1b2c3d")
    #expect(version.artifact == "26.7.22-pre.202607221530-a1b2c3d")
    #expect(version.track == .prerelease)
  }

  @Test
  static func stableTrackUsesTheResolvedTagBaseForMarketingVersion() throws {
    let version = try VersionMeta.compute(
      inputs(
        githubRunNumber: "87",
        calendar: "26.7.27",
        releaseTrack: .stable,
        releaseTag: "26.7.26-r1"))

    #expect(version.marketing == "26.7.26")
    #expect(version.tag == "26.7.26-r1")
  }

  @Test(arguments: ["26.7.26", "26.7.26-r1", "26.7.26-r12"])
  static func stableTagsAcceptBaseAndSameDayRevisions(tag: String) {
    // Rejecting a valid revision tag would prevent a corrected same-day stable release.
    #expect(VersionMeta.isValidStableTag(tag))
  }

  @Test(arguments: ["26.7.26-r0", "26.7.26-r01", "26.7.26-pre.202607261030+abc1234"])
  static func stableTagsRejectInvalidFormats(tag: String) {
    // Accepting a pre-release or malformed revision as stable would cross tracks.
    #expect(!VersionMeta.isValidStableTag(tag))
  }

  @Test
  static func fixedWidthBuildNumbersPreserveSameDayOrdering() throws {
    // Dropping zero padding would make run 87 rank after run 123456 in lexical consumers.
    let earlier = try VersionMeta.compute(
      inputs(githubRunNumber: "87", releaseTrack: .prerelease))
    let later = try VersionMeta.compute(
      inputs(githubRunNumber: "88", releaseTrack: .prerelease))
    #expect(earlier.build == "202607221530000087")
    #expect(later.build == "202607221530000088")
    #expect(earlier.build.count == 18)
    #expect(earlier.build < later.build)
  }

  @Test(arguments: ["", "0", "000000", "abc", "1000000"])
  static func invalidRunNumbersFailTheReleaseContract(runNumber: String) {
    // Treating an invalid run number as a distributable version would break ordering.
    #expect(throws: VersionMeta.VersionError.self) {
      try VersionMeta.compute(inputs(githubRunNumber: runNumber, releaseTrack: .prerelease))
    }
  }

  @Test
  static func sourceSelectionRejectsConflictingAndUnacknowledgedInputs() {
    // Accepting either combination could publish a stable release from an unintended commit.
    #expect(throws: VersionMeta.VersionError.self) {
      try VersionMeta.validateSource(
        track: .stable,
        candidateTag: "26.7.26-pre.202607261030+abc1234",
        sourceSHA: "abc1234",
        allowSourceSHA: true)
    }
    #expect(throws: VersionMeta.VersionError.self) {
      try VersionMeta.validateSource(
        track: .stable,
        candidateTag: "",
        sourceSHA: "abc1234",
        allowSourceSHA: false)
    }
  }

  @Test
  static func stableSourceSelectionUsesTheSelectedWorkflowRef() throws {
    try VersionMeta.validateSource(
      track: .stable, candidateTag: "", sourceSHA: "", allowSourceSHA: false)
  }

  @Test
  static func prereleaseSourceSelectionUsesTheWorkflowCommit() throws {
    // Rejecting an empty pre-release selection would prevent the workflow commit
    // from being the pre-release source.
    try VersionMeta.validateSource(
      track: .prerelease, candidateTag: "", sourceSHA: "", allowSourceSHA: false)
  }

  @Test
  static func sourceValidationCallsTheTrackPreRelease() {
    let workflowCommitError = sourceValidationError {
      try VersionMeta.validateSource(
        track: .prerelease,
        candidateTag: "26.7.26-pre.202607261030+abc1234",
        sourceSHA: "",
        allowSourceSHA: false)
    }
    let candidateTagError = sourceValidationError {
      try VersionMeta.validateSource(
        track: .stable,
        candidateTag: "not-a-pre-release-tag",
        sourceSHA: "",
        allowSourceSHA: false)
    }

    #expect(
      workflowCommitError
        == "version-meta: invalid release source selection: pre-release builds use the workflow commit"
    )
    #expect(
      candidateTagError
        == "version-meta: invalid release source selection: candidate-tag must use the pre-release tag format"
    )
  }

  private static func sourceValidationError(_ operation: () throws -> Void) -> String {
    do {
      try operation()
      return ""
    } catch {
      return String(describing: error)
    }
  }

  @Test
  static func tagRefUsesThePushedTagName() throws {
    let version = try VersionMeta.compute(
      inputs(githubRefType: "tag", githubRefName: "v1.2.3", githubRunNumber: "80"))
    #expect(version.tag == "v1.2.3")
    #expect(version.marketing == "26.7.22")
    #expect(version.build == "20260722153080")
  }

  @Test
  static func explicitEnvironmentVersionPassesThrough() throws {
    // The release build step sets both, already resolved by the meta job.
    let version = try VersionMeta.compute(
      inputs(
        marketingEnv: "26.7.22",
        buildEnv: "202607221530000080",
        githubRunNumber: "80",
        releaseTrack: .prerelease))
    #expect(version.marketing == "26.7.22")
    #expect(version.build == "202607221530000080")
    #expect(version.tag == "26.7.22-pre.202607221530+a1b2c3d")
  }

  @Test
  static func buildVersionPastEighteenCharactersFailsLoud() {
    // A run number that pushes the build number past CFBundleVersion's cap must fail.
    #expect(throws: VersionMeta.VersionError.self) {
      try VersionMeta.compute(inputs(githubRunNumber: "1234567"))
    }
  }

  @Test
  static func releaseSchemeMatchesTheDocumentedReleaseMetaShape() throws {
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
  static func nonNumericRunNumberUsesTheDevSchemeConsistently() throws {
    // GitHub always sets a numeric run number; a non-numeric value must not take the
    // release build number while the tag falls back to a dev form. Both agree on dev.
    let version = try VersionMeta.compute(inputs(githubRunNumber: "abc"))
    #expect(version.marketing == "26.7.22+a1b2c3d-dev")
    #expect(version.build == "202607221530")
    #expect(version.tag == "202607221530-a1b2c3d-dev")
  }

  @Test
  static func versionStampInjectsBothSettingsWhenAbsent() throws {
    let request = Toolchain.Request(
      generator: .tuist, scheme: "App", workspace: "App.xcworkspace")
    let stamped = try Toolchain.versionStamped(request)
    #expect(stamped.extraSettings["MARKETING_VERSION"] != nil)
    #expect(stamped.extraSettings["CURRENT_PROJECT_VERSION"] != nil)
  }

  @Test
  static func versionStampLeavesAnExplicitCallerValueUntouched() throws {
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

  @Test
  static func unicodeDigitRunNumberUsesTheDevScheme() throws {
    // Character.isNumber accepts non-ASCII digits that UInt64 rejects; the run number
    // must gate on UInt64 parsing so the build number and the tag stay on one scheme.
    let version = try VersionMeta.compute(inputs(githubRunNumber: "\u{0661}\u{0662}"))
    #expect(version.marketing == "26.7.22+a1b2c3d-dev")
    #expect(version.build == "202607221530")
    #expect(version.tag == "202607221530-a1b2c3d-dev")
  }

  @Test
  static func versionStampTreatsAnEmptyValueAsMissing() throws {
    // An empty forwarded value must be stamped, not treated as an explicit version.
    let request = Toolchain.Request(
      generator: .tuist,
      scheme: "App",
      workspace: "App.xcworkspace",
      extraSettings: ["MARKETING_VERSION": "", "CURRENT_PROJECT_VERSION": ""])
    let stamped = try Toolchain.versionStamped(request)
    #expect(!(stamped.extraSettings["MARKETING_VERSION"] ?? "").isEmpty)
    #expect(!(stamped.extraSettings["CURRENT_PROJECT_VERSION"] ?? "").isEmpty)
  }

  @Test
  static func versionStampTreatsAWhitespaceOrNewlineValueAsMissing() throws {
    // A value that is only spaces or newlines is blank, not an explicit version, so
    // the newline case must not slip past the trim the way `.whitespaces` would.
    let request = Toolchain.Request(
      generator: .tuist,
      scheme: "App",
      workspace: "App.xcworkspace",
      extraSettings: ["MARKETING_VERSION": "\n", "CURRENT_PROJECT_VERSION": "   "])
    let stamped = try Toolchain.versionStamped(request)
    let marketing = stamped.extraSettings["MARKETING_VERSION"] ?? ""
    let build = stamped.extraSettings["CURRENT_PROJECT_VERSION"] ?? ""
    #expect(!marketing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    #expect(!build.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }

  @Test
  static func injectionForMarketingOnlyIgnoresAnOverlongBuild() throws {
    // When only the marketing key is missing, the build-number cap is irrelevant, so
    // an overlong computed build must not fail the injection.
    let version = VersionMeta.Version(
      marketing: "26.7.22", build: "1234567890123456789", tag: "t")
    let settings = try VersionMeta.injectionSettings(
      forMissing: ["MARKETING_VERSION"], version: version)
    #expect(settings == ["MARKETING_VERSION": "26.7.22"])
  }

  @Test
  static func injectionForBuildRejectsAnOverlongBuild() {
    // When the build key is injected, an overlong build number fails loudly.
    let version = VersionMeta.Version(
      marketing: "26.7.22", build: "1234567890123456789", tag: "t")
    #expect(throws: VersionMeta.VersionError.self) {
      try VersionMeta.injectionSettings(
        forMissing: ["CURRENT_PROJECT_VERSION"], version: version)
    }
  }

  @Test
  static func injectionForBothReturnsBothWithinTheCap() throws {
    let version = VersionMeta.Version(
      marketing: "26.7.22+a1b2c3d-dev", build: "202607221530", tag: "t")
    let settings = try VersionMeta.injectionSettings(
      forMissing: ["MARKETING_VERSION", "CURRENT_PROJECT_VERSION"], version: version)
    #expect(settings["MARKETING_VERSION"] == "26.7.22+a1b2c3d-dev")
    #expect(settings["CURRENT_PROJECT_VERSION"] == "202607221530")
  }
}

// MARK: - VersionMetaEnvironmentTests

/// `injectionSettings(forMissing:)` reads the process environment, so it is nested
/// under `EnvironmentSerialized` and restores the keys it touches.
extension EnvironmentSerialized {
  @Suite enum VersionMetaEnvironmentTests {
    private static let versionKeys = [
      "MARKETING_VERSION", "CURRENT_PROJECT_VERSION",
      "GITHUB_RUN_NUMBER", "GITHUB_REF_TYPE", "GITHUB_REF_NAME",
    ]

    @Test
    static func whitespaceOnlyEnvironmentVersionIsNotPassedThrough() throws {
      // TestGlobalLock as well as the `.serialized` parent: the parent only orders this
      // suite against its siblings, and the gate harnesses that also write the
      // environment are top-level suites the lock is what excludes.
      try TestGlobalLock.withLock {
        // A whitespace-only MARKETING_VERSION in the environment is blank, not an
        // explicit version, so resolution must stamp a real value rather than
        // forward the spaces.
        let saved = Environment.snapshot(versionKeys)
        defer { saved.restore() }
        for key in versionKeys {
          unsetenv(key)
        }
        setenv("MARKETING_VERSION", "   ", 1)

        let settings = try VersionMeta.injectionSettings(forMissing: ["MARKETING_VERSION"])
        let marketing = settings["MARKETING_VERSION"] ?? ""
        #expect(!marketing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(marketing != "   ")
      }
    }
  }
}
