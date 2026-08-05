//
//  ReleaseSourceScriptTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-26.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - ReleaseSourceScriptTests

@Suite(.serialized)
enum ReleaseSourceScriptTests {
  @Test
  static func resolvesLegacyCallersFromTheWorkflowCommit() throws {
    try withHarness { harness in
      let result = try harness.run(
        track: "", candidateTag: "", sourceSHA: "", allowSourceSHA: "false")
      let resolution = try harness.resolution()

      #expect(result.status == 0)
      #expect(resolution.enabled)
      #expect(resolution.track == nil)
      #expect(resolution.sourceSHA == Harness.workflowSHA)
      #expect(resolution.releaseTag == nil)
    }
  }

  @Test
  static func rejectsAnUnknownReleaseOnMergePolicy() throws {
    try withHarness { harness in
      let result = try harness.run(
        track: "",
        candidateTag: "",
        sourceSHA: "",
        allowSourceSHA: "false",
        releaseOnMerge: "nightly",
        eventName: "push",
        ref: "refs/heads/main")

      #expect(result.status != 0)
      #expect(!result.stderr.isEmpty)
    }
  }

  @Test
  static func skipsAManualMainBranchPush() throws {
    try withHarness { harness in
      let result = try harness.run(
        track: "",
        candidateTag: "",
        sourceSHA: "",
        allowSourceSHA: "false",
        releaseOnMerge: "manual",
        eventName: "push",
        ref: "refs/heads/main")
      let resolution = try harness.resolution()

      #expect(result.status == 0)
      #expect(!resolution.enabled)
      #expect(resolution.track == nil)
      #expect(resolution.sourceSHA == Harness.workflowSHA)
      #expect(resolution.releaseTag == nil)
    }
  }

  @Test
  static func resolvesAStableMainBranchPushFromThePolicy() throws {
    try withHarness { harness in
      let result = try harness.run(
        track: "",
        candidateTag: "",
        sourceSHA: "",
        allowSourceSHA: "false",
        releaseOnMerge: "stable",
        eventName: "push",
        ref: "refs/heads/main")
      let resolution = try harness.resolution()

      #expect(result.status == 0)
      #expect(resolution.enabled)
      #expect(resolution.track == .stable)
      #expect(resolution.sourceSHA == Harness.workflowSHA)
      #expect(resolution.releaseTag == Harness.stableTag)
    }
  }

  @Test
  static func resolvesAPrereleaseMainBranchPushFromThePolicy() throws {
    try withHarness { harness in
      let result = try harness.run(
        track: "",
        candidateTag: "",
        sourceSHA: "",
        allowSourceSHA: "false",
        releaseOnMerge: "prerelease",
        eventName: "push",
        ref: "refs/heads/main")
      let resolution = try harness.resolution()

      #expect(result.status == 0)
      #expect(resolution.enabled)
      #expect(resolution.track == .prerelease)
      #expect(resolution.sourceSHA == Harness.workflowSHA)
      #expect(resolution.releaseTag == nil)
    }
  }

  @Test
  static func resolvesAnEmptyDispatchTrackAsStable() throws {
    try withHarness { harness in
      let result = try harness.run(
        track: "",
        candidateTag: "",
        sourceSHA: "",
        allowSourceSHA: "false",
        eventName: "workflow_dispatch",
        ref: "refs/heads/main")
      let resolution = try harness.resolution()

      #expect(result.status == 0)
      #expect(resolution.enabled)
      #expect(resolution.track == .stable)
      #expect(resolution.sourceSHA == Harness.workflowSHA)
      #expect(resolution.releaseTag == Harness.stableTag)
    }
  }

  @Test
  static func resolvesPullRequestDryRunsAsPrereleases() throws {
    try withHarness { harness in
      let result = try harness.run(
        track: "",
        candidateTag: "",
        sourceSHA: "",
        allowSourceSHA: "false",
        eventName: "pull_request",
        ref: "refs/pull/123/merge")
      let resolution = try harness.resolution()

      #expect(result.status == 0)
      #expect(resolution.enabled)
      #expect(resolution.track == .prerelease)
      #expect(resolution.sourceSHA == Harness.workflowSHA)
      #expect(resolution.releaseTag == nil)
    }
  }

  @Test
  static func resolvesPrereleaseFromTheWorkflowCommit() throws {
    try withHarness { harness in
      let result = try harness.run(
        track: "prerelease", candidateTag: "", sourceSHA: "", allowSourceSHA: "false")
      let resolution = try harness.resolution()

      #expect(result.status == 0)
      #expect(resolution.enabled)
      #expect(resolution.track == .prerelease)
      #expect(resolution.sourceSHA == Harness.workflowSHA)
      #expect(resolution.releaseTag == nil)
    }
  }

  @Test
  static func promotesTheCandidateTagCommitAndAllocatesTheNextRevision() throws {
    try withHarness { harness in
      let result = try harness.run(
        track: "stable",
        candidateTag: "26.7.26-pre.202607261030+abc1234",
        sourceSHA: "",
        allowSourceSHA: "false")
      let resolution = try harness.resolution()

      #expect(result.status == 0)
      #expect(resolution.sourceSHA == "candidate-commit-sha")
      #expect(resolution.releaseTag == Harness.stableTag)
    }
  }

  @Test
  static func rejectsADraftCandidate() throws {
    try withHarness { harness in
      let result = try harness.run(
        track: "stable",
        candidateTag: "26.7.26-pre.202607261030+abc1234",
        sourceSHA: "",
        allowSourceSHA: "false",
        candidateIsDraft: "true")

      #expect(result.status != 0)
      #expect(!result.stderr.isEmpty)
    }
  }

  @Test
  static func rejectsAnEmergencySourceSHAWithoutAcknowledgement() throws {
    try withHarness { harness in
      let result = try harness.run(
        track: "stable",
        candidateTag: "",
        sourceSHA: "emergency-sha",
        allowSourceSHA: "false")

      #expect(result.status != 0)
      #expect(!result.stderr.isEmpty)
    }
  }

  @Test
  static func usesOneClockReadForEmergencyStableTag() throws {
    try withHarness { harness in
      let result = try harness.run(
        track: "stable", candidateTag: "", sourceSHA: "emergency-sha", allowSourceSHA: "true")
      let resolution = try harness.resolution()

      #expect(result.status == 0)
      #expect(resolution.sourceSHA == "emergency-commit-sha")
      #expect(resolution.releaseTag == Harness.stableTag)
      #expect(try harness.dateCallCount() == 1)
    }
  }

  @Test
  static func allocatesPastAnOrphanedRemoteTag() throws {
    try withHarness { harness in
      let result = try harness.run(
        track: "stable",
        candidateTag: "",
        sourceSHA: "",
        allowSourceSHA: "false",
        remoteTags: [Harness.stableTag])
      let resolution = try harness.resolution()

      #expect(result.status == 0)
      #expect(resolution.track == .stable)
      #expect(resolution.releaseTag == "26.7.26-r2")
    }
  }

  @Test
  static func ignoresAPrefixOnlyRemoteTagMatch() throws {
    try withHarness { harness in
      let result = try harness.run(
        track: "stable",
        candidateTag: "",
        sourceSHA: "",
        allowSourceSHA: "false",
        remoteTags: ["26.7.26-r10"])
      let resolution = try harness.resolution()

      #expect(result.status == 0)
      #expect(resolution.track == .stable)
      #expect(resolution.releaseTag == Harness.stableTag)
    }
  }

  private static func withHarness(_ body: (Harness) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "swift-mk-release-source-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
      do {
        try FileManager.default.removeItem(at: directory)
      } catch {
        Output.warning("cleanup failed: \(error.localizedDescription)")
      }
    }
    try body(Harness(directory: directory))
  }
}

// MARK: - Harness

private struct Harness {
  private static let outputFieldPartCount = 2

  static let stableTag = "26.7.26-r1"
  static let workflowSHA = "pre-source-sha"

  let directory: URL
  let binDirectory: URL
  let dateCallsFile: URL
  let outputFile: URL

  init(directory: URL) throws {
    self.directory = directory
    binDirectory = directory.appendingPathComponent("bin", isDirectory: true)
    dateCallsFile = directory.appendingPathComponent("date-calls")
    outputFile = directory.appendingPathComponent("output")
    try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
    try writeFakeDate()
    try writeFakeGitHub()
  }

  func run(
    track: String,
    candidateTag: String,
    sourceSHA: String,
    allowSourceSHA: String,
    candidateIsDraft: String = "false",
    releaseOnMerge: String? = nil,
    eventName: String = "push",
    ref: String = "refs/tags/legacy",
    remoteTags: Set<String> = []
  ) throws -> Shell.Result {
    var environment = [
      "ALLOW_SOURCE_SHA": allowSourceSHA,
      "CANDIDATE_ASSET_PATTERN": "*.dmg",
      "CANDIDATE_IS_DRAFT": candidateIsDraft,
      "CANDIDATE_TAG": candidateTag,
      "DATE_CALLS_FILE": dateCallsFile.path,
      "GITHUB_OUTPUT": outputFile.path,
      "GITHUB_REPOSITORY": "example/repo",
      "GITHUB_SHA": "pre-source-sha",
      "GITHUB_EVENT_NAME": eventName,
      "GITHUB_REF": ref,
      "PATH":
        binDirectory.path + ":" + ProcessInfo.processInfo.environment["PATH", default: ""],
      "RELEASE_TRACK": track,
      "REMOTE_TAGS": remoteTags.sorted().joined(separator: ","),
      "SOURCE_SHA": sourceSHA,
    ]
    if let releaseOnMerge {
      environment["RELEASE_ON_MERGE"] = releaseOnMerge
    }
    return Shell.run("bash", [try scriptPath()], environment: environment)
  }

  func output() throws -> String {
    try String(contentsOf: outputFile, encoding: .utf8)
  }

  func resolution() throws -> ReleaseResolution {
    let lines = try output().split(whereSeparator: \.isNewline)
    var fields: [String: String] = [:]
    for line in lines {
      let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == Self.outputFieldPartCount else {
        throw ReleaseSourceScriptTestError.invalidOutput(String(line))
      }
      fields[String(parts[0])] = String(parts[1])
    }

    guard let enabledText = fields["enabled"], let enabled = Bool(enabledText),
      let trackText = fields["release_track"], let sourceSHA = fields["source_sha"],
      let releaseTag = fields["release_tag"]
    else {
      throw ReleaseSourceScriptTestError.invalidOutput(try output())
    }

    let track: VersionMeta.ReleaseTrack?
    if trackText.isEmpty {
      track = nil
    } else {
      guard let parsedTrack = VersionMeta.ReleaseTrack(rawValue: trackText) else {
        throw ReleaseSourceScriptTestError.invalidOutput(trackText)
      }
      track = parsedTrack
    }

    return ReleaseResolution(
      enabled: enabled,
      track: track,
      sourceSHA: sourceSHA,
      releaseTag: releaseTag.isEmpty ? nil : releaseTag)
  }

  func dateCallCount() throws -> Int {
    guard FileManager.default.fileExists(atPath: dateCallsFile.path) else {
      return 0
    }
    let calls = try String(contentsOf: dateCallsFile, encoding: .utf8)
    return calls.split(whereSeparator: \.isNewline).count
  }

  private func scriptPath() throws -> String {
    var searchDirectory = (#filePath as NSString).deletingLastPathComponent
    while searchDirectory != "/" {
      let candidate =
        (searchDirectory as NSString).appendingPathComponent(
          ".github/actions/resolve-release-source/resolve.sh")
      if FileManager.default.fileExists(atPath: candidate) {
        return candidate
      }
      searchDirectory = (searchDirectory as NSString).deletingLastPathComponent
    }
    throw ReleaseSourceScriptTestError.scriptNotFound
  }

  private func writeFakeGitHub() throws {
    let executable = binDirectory.appendingPathComponent("gh")
    let script = """
      #!/usr/bin/env bash
      set -euo pipefail

      case "$*" in
          *"release view 26.7.26-pre.202607261030+abc1234"*"--json isPrerelease,isDraft"*)
              printf 'true\\t%s\\n' "${CANDIDATE_IS_DRAFT}"
              ;;
          *"release view 26.7.26-pre.202607261030+abc1234"*"--jq .isPrerelease"*)
              printf 'true\\n'
              ;;
          *"release view 26.7.26-pre.202607261030+abc1234"*"--jq .assets[].name"*)
              printf 'candidate.dmg\\n'
              ;;
          *"release view 26.7.26-r1"*)
              printf 'release not found\\n' >&2
              exit 1
              ;;
          *"release view 26.7.26-r2"*)
              printf 'release not found\\n' >&2
              exit 1
              ;;
          *"release view 26.7.26"*)
              exit 0
              ;;
          *"api"*"repos/example/repo/git/matching-refs/tags/"*)
              tag="${3##*/}"
              if [[ -n "${REMOTE_TAGS}" ]]; then
                  while IFS= read -r remote_tag; do
                      if [[ "${remote_tag}" == "${tag}"* ]]; then
                          printf 'refs/tags/%s\\n' "${remote_tag}"
                      fi
                  done < <(printf '%s\\n' "${REMOTE_TAGS}" | tr ',' '\\n')
              fi
              ;;
          *"api repos/example/repo/commits/26.7.26-pre.202607261030+abc1234"*)
              printf 'candidate-commit-sha\\n'
              ;;
          *"api repos/example/repo/commits/pre-source-sha"*)
              printf 'pre-source-sha\\n'
              ;;
          *"api repos/example/repo/commits/emergency-sha"*)
              printf 'emergency-commit-sha\\n'
              ;;
          *)
              printf 'unexpected gh call: %s\\n' "$*" >&2
              exit 2
              ;;
      esac
      """
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: executable.path)
  }

  private func writeFakeDate() throws {
    let executable = binDirectory.appendingPathComponent("date")
    let script = """
      #!/usr/bin/env bash
      set -euo pipefail

      printf '%s\\n' "$*" >> "${DATE_CALLS_FILE}"
      case "$*" in
          "-u +%y")
              printf '26\\n'
              ;;
          "-u +%-m")
              printf '7\\n'
              ;;
          "-u +%-d")
              printf '26\\n'
              ;;
          "-u +%y.%-m.%-d")
              printf '26.7.26\\n'
              ;;
          *)
              printf 'unexpected date call: %s\\n' "$*" >&2
              exit 2
              ;;
      esac
      """
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: executable.path)
  }
}

// MARK: - ReleaseResolution

private struct ReleaseResolution: Equatable {
  let enabled: Bool
  let track: VersionMeta.ReleaseTrack?
  let sourceSHA: String
  let releaseTag: String?
}

// MARK: - ReleaseSourceScriptTestError

private enum ReleaseSourceScriptTestError: Error {
  case invalidOutput(String)
  case scriptNotFound
}
