//
//  SwiftMkUpdateTests.swift
//  SwiftMkUpdateTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-02.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkUpdate

// MARK: - SwiftMkUpdateTests

@Suite(.serialized)
enum SwiftMkUpdateTests {
  static let currentTag = SwiftMkUpdateSupport.currentTag
  static let newerTag = SwiftMkUpdateSupport.newerTag
  static let sha256 = SwiftMkUpdateSupport.sha256
  static let teamID = SwiftMkUpdateSupport.teamID
  static let successStatusCode = SwiftMkUpdateSupport.successStatusCode
  static let sampleTimestamp: TimeInterval = 1_782_000_000

  @Test
  static func configDefaultsAssetNameAndValidatesRequiredFields() throws {
    let config = UpdateConfig(
      repo: "agoodkind/swift-makefile",
      binary: "swift-mk",
      teamID: teamID,
      currentVersion: currentTag)

    #expect(config.assetName == "swift-mk_darwin_arm64.dmg")
    try config.validate()

    let invalid = UpdateConfig(
      repo: "",
      binary: "swift-mk",
      teamID: teamID,
      currentVersion: currentTag)
    #expect(throws: UpdateError.self) {
      try invalid.validate()
    }
  }

  @Test
  static func isNewerComparesTimestampPrefixes() {
    #expect(ReleaseResolver.isNewer(latest: newerTag, current: currentTag))
    #expect(!ReleaseResolver.isNewer(latest: currentTag, current: newerTag))
    #expect(!ReleaseResolver.isNewer(latest: currentTag, current: currentTag))
    #expect(ReleaseResolver.isNewer(latest: newerTag, current: "dev"))
    #expect(ReleaseResolver.isNewer(latest: newerTag, current: "unknown"))
    #expect(!ReleaseResolver.isNewer(latest: "bad-latest", current: currentTag))
    #expect(!ReleaseResolver.isNewer(latest: "bad-latest", current: "bad-current"))
  }

  @Test
  static func expectedSHA256ParsesChecksumLines() {
    let text = """
      111111 other.dmg
      \(sha256)  swift-mk_darwin_arm64.dmg
      222222 *another.dmg
      """

    #expect(
      ReleaseResolver.expectedSHA256(checksumsText: text, assetName: "swift-mk_darwin_arm64.dmg")
        == sha256)
    #expect(ReleaseResolver.expectedSHA256(checksumsText: text, assetName: "missing.dmg") == nil)
  }

  @Test
  static func assetURLSelectsMatchingAsset() throws {
    let wantedURL = try #require(URL(string: "https://example.test/swift-mk.dmg"))
    let ignoredURL = try #require(URL(string: "https://example.test/ignored.dmg"))
    let assets = [
      ReleaseAsset(name: "ignored.dmg", browserDownloadURL: ignoredURL, digest: nil),
      ReleaseAsset(
        name: "swift-mk_darwin_arm64.dmg",
        browserDownloadURL: wantedURL,
        digest: "sha256:\(sha256)"),
    ]

    #expect(
      ReleaseResolver.assetURL(assets: assets, assetName: "swift-mk_darwin_arm64.dmg")
        == wantedURL)
    #expect(ReleaseResolver.assetURL(assets: assets, assetName: "missing.dmg") == nil)
  }

  @Test
  static func codesignTeamIdentifierParsesDvvOutput() {
    let output = """
      Executable=/tmp/swift-mk
      Identifier=io.goodkind.swift-mk
      TeamIdentifier=\(teamID)
      Runtime Version=15.0.0
      """

    #expect(ReleaseResolver.codesignTeamIdentifier(output: output) == teamID)
    #expect(
      ReleaseResolver.codesignTeamIdentifier(output: "Identifier=io.goodkind.swift-mk") == nil)
  }

  @Test
  static func stateRoundTripsThroughAtomicSaveAndLoad() throws {
    try withTemporaryDirectory { directory in
      let path = directory.appendingPathComponent("state/update-state.json").path
      let now = Date(timeIntervalSince1970: sampleTimestamp)
      let state = UpdateState(
        lastCheck: now,
        lastResult: .applied,
        lastError: nil,
        lastAppliedTag: newerTag)

      try saveState(state, path: path)
      let loaded = try loadState(path: path)

      #expect(loaded == state)
    }
  }

  @Test
  static func optionsResolveSelfTargetAndExplicitTarget() throws {
    try withTemporaryDirectory { directory in
      let executableURL = directory.appendingPathComponent("swift-mk")
      try "binary".write(to: executableURL, atomically: true, encoding: .utf8)
      let resolved = UpdateOptions.defaultTargetPath(
        arguments: ["./swift-mk"],
        currentDirectory: directory.path)
      let explicit = UpdateOptions(
        config: Self.config(),
        targetPath: "/tmp/explicit-swift-mk")

      #expect(resolved == executableURL.resolvingSymlinksInPath().path)
      #expect(explicit.targetPath == "/tmp/explicit-swift-mk")
      _ = URLSessionReleaseHTTPClient()
      _ = ProcessCommandRunner()
    }
  }

  @Test
  static func applyStagesVerifiesAndSwapsCandidate() throws {
    try withPreparedUpdate { setup in
      let updater = Updater(options: setup.options)

      let result = try updater.apply()
      let targetContents = try String(contentsOf: setup.targetURL, encoding: .utf8)
      let state = try loadState(path: setup.statePath)

      #expect(result.applied)
      #expect(result.check.latestTag == newerTag)
      #expect(targetContents == StubCommandRunner.candidateContents)
      #expect(state.lastResult == .applied)
      #expect(state.lastAppliedTag == newerTag)
    }
  }

  @Test
  static func applyRefusesTeamMismatchWithoutSwapping() throws {
    try withPreparedUpdate(commandMode: .teamMismatch) { setup in
      let updater = Updater(options: setup.options)

      #expect(throws: UpdateError.self) {
        try updater.apply()
      }
      let targetContents = try String(contentsOf: setup.targetURL, encoding: .utf8)
      let state = try loadState(path: setup.statePath)

      #expect(targetContents == PreparedUpdate.originalContents)
      #expect(state.lastResult == .error)
    }
  }

  @Test
  static func applyRefusesValidateMismatchWithoutSwapping() throws {
    try withPreparedUpdate(commandMode: .validateMismatch) { setup in
      let updater = Updater(options: setup.options)

      #expect(throws: UpdateError.self) {
        try updater.apply()
      }
      let targetContents = try String(contentsOf: setup.targetURL, encoding: .utf8)
      let state = try loadState(path: setup.statePath)

      #expect(targetContents == PreparedUpdate.originalContents)
      #expect(state.lastResult == .error)
    }
  }

  @Test
  static func schedulerCheckModeDoesNotStopForRelaunch() throws {
    let runner = StubScheduledRunner(
      checkResult: CheckResult.sample(updateAvailable: true),
      applyResult: ApplyResult.sample(applied: true))
    let stopped = LockedBox(false)
    let hooks = SchedulerHooks(
      enabled: { true },
      mode: { .check },
      options: { UpdateOptions(config: Self.config()) },
      stopForRelaunch: { stopped.value = true },
      log: { _ in
        // Scheduler log output is not relevant to this assertion.
      })

    try UpdateScheduler.run(
      hooks: hooks,
      clock: TestSchedulerClock(),
      updater: runner,
      runOnce: true)

    #expect(runner.checkCount == 1)
    #expect(runner.applyCount == 0)
    #expect(!stopped.value)
  }

  @Test
  static func schedulerApplyModeStopsAfterAppliedResult() throws {
    let runner = StubScheduledRunner(
      checkResult: CheckResult.sample(updateAvailable: true),
      applyResult: ApplyResult.sample(applied: true))
    let stopped = LockedBox(false)
    let hooks = SchedulerHooks(
      enabled: { true },
      mode: { .apply },
      options: { UpdateOptions(config: Self.config()) },
      stopForRelaunch: { stopped.value = true },
      log: { _ in
        // Scheduler log output is not relevant to this assertion.
      })

    try UpdateScheduler.run(
      hooks: hooks,
      clock: TestSchedulerClock(),
      updater: runner,
      runOnce: true)

    #expect(runner.checkCount == 0)
    #expect(runner.applyCount == 1)
    #expect(stopped.value)
  }

  @Test
  static func schedulerApplyModeFallsBackToCheckForDevBuilds() throws {
    let runner = StubScheduledRunner(
      checkResult: CheckResult.sample(updateAvailable: true),
      applyResult: ApplyResult.sample(applied: true))
    let stopped = LockedBox(false)
    let hooks = SchedulerHooks(
      enabled: { true },
      mode: { .apply },
      options: { UpdateOptions(config: Self.config(currentVersion: "dev")) },
      stopForRelaunch: { stopped.value = true },
      log: { _ in
        // Scheduler log output is not relevant to this assertion.
      })

    try UpdateScheduler.run(
      hooks: hooks,
      clock: TestSchedulerClock(),
      updater: runner,
      runOnce: true)

    #expect(runner.checkCount == 1)
    #expect(runner.applyCount == 0)
    #expect(!stopped.value)
  }

  private static func config(currentVersion: String = currentTag) -> UpdateConfig {
    UpdateConfig(
      repo: "agoodkind/swift-makefile",
      binary: "swift-mk",
      teamID: teamID,
      currentVersion: currentVersion,
      assetName: "swift-mk_darwin_arm64.dmg")
  }

  private static func withPreparedUpdate(
    commandMode: StubCommandRunner.Mode = .success,
    _ run: (PreparedUpdate) throws -> Void
  ) throws {
    try withTemporaryDirectory { directory in
      let targetURL = directory.appendingPathComponent("swift-mk")
      try PreparedUpdate.originalContents.write(
        to: targetURL, atomically: true, encoding: .utf8)
      let httpClient = StubHTTPClient(
        responses: [
          "https://api.github.com/repos/agoodkind/swift-makefile/releases": (
            releaseListData(),
            successStatusCode
          ),
          "https://example.test/swift-mk.dmg": (Data("dmg".utf8), successStatusCode),
        ])
      let commandRunner = StubCommandRunner(binary: "swift-mk", mode: commandMode)
      let cacheDir = directory.appendingPathComponent("cache").path
      let statePath = directory.appendingPathComponent("state/update-state.json").path
      let options = UpdateOptions(
        config: config(),
        targetPath: targetURL.path,
        cacheDir: cacheDir,
        statePath: statePath,
        dryRun: false,
        httpClient: httpClient,
        commandRunner: commandRunner
      ) {
        Date(timeIntervalSince1970: sampleTimestamp)
      }

      try run(
        PreparedUpdate(
          options: options,
          targetURL: targetURL,
          statePath: statePath))
    }
  }

  private static func releaseListData() -> Data {
    Data(
      """
      [
        {
          "html_url": "https://github.com/agoodkind/swift-makefile/releases/tag/\(newerTag)",
          "tag_name": "\(newerTag)",
          "draft": false,
          "prerelease": true,
          "assets": [
            {
              "name": "swift-mk_darwin_arm64.dmg",
              "browser_download_url": "https://example.test/swift-mk.dmg",
              "digest": "sha256:\(sha256)"
            }
          ]
        }
      ]
      """.utf8)
  }

}
