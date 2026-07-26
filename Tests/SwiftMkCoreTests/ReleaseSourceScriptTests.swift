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

      #expect(result.status == 0)
      guard result.status == 0 else {
        return
      }
      let output = try harness.output()
      #expect(output.contains("source_sha=pre-source-sha"))
      #expect(output.contains("release_tag=\n"))
    }
  }

  @Test
  static func resolvesPrereleaseFromTheWorkflowCommit() throws {
    try withHarness { harness in
      let result = try harness.run(
        track: "prerelease", candidateTag: "", sourceSHA: "", allowSourceSHA: "false")
      let output = try harness.output()

      #expect(result.status == 0)
      #expect(output.contains("source_sha=pre-source-sha"))
      #expect(output.contains("release_tag="))
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
      let output = try harness.output()

      #expect(result.status == 0)
      #expect(output.contains("source_sha=candidate-commit-sha"))
      #expect(output.contains("release_tag=26.7.26-r1"))
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
      #expect(result.stderr.contains("published non-draft GitHub pre-release"))
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
      #expect(result.stderr.contains("source-sha requires allow-source-sha=true"))
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

  private struct Harness {
    let directory: URL
    let binDirectory: URL
    let outputFile: URL

    init(directory: URL) throws {
      self.directory = directory
      binDirectory = directory.appendingPathComponent("bin", isDirectory: true)
      outputFile = directory.appendingPathComponent("output")
      try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
      try writeFakeGitHub()
    }

    func run(
      track: String,
      candidateTag: String,
      sourceSHA: String,
      allowSourceSHA: String,
      candidateIsDraft: String = "false"
    ) throws -> Shell.Result {
      Shell.run(
        "bash",
        [try scriptPath()],
        environment: [
          "ALLOW_SOURCE_SHA": allowSourceSHA,
          "CANDIDATE_ASSET_PATTERN": "*.dmg",
          "CANDIDATE_IS_DRAFT": candidateIsDraft,
          "CANDIDATE_TAG": candidateTag,
          "GITHUB_OUTPUT": outputFile.path,
          "GITHUB_REPOSITORY": "example/repo",
          "GITHUB_SHA": "pre-source-sha",
          "PATH":
            binDirectory.path + ":" + ProcessInfo.processInfo.environment["PATH", default: ""],
          "RELEASE_TRACK": track,
          "SOURCE_SHA": sourceSHA,
        ])
    }

    func output() throws -> String {
      try String(contentsOf: outputFile, encoding: .utf8)
    }

    private func scriptPath() throws -> String {
      var searchDirectory = (#filePath as NSString).deletingLastPathComponent
      while searchDirectory != "/" {
        let candidate =
          (searchDirectory as NSString).appendingPathComponent("scripts/release-source.sh")
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
            *"release view 26.7.26"*)
                exit 0
                ;;
            *"api repos/example/repo/commits/26.7.26-pre.202607261030+abc1234"*)
                printf 'candidate-commit-sha\\n'
                ;;
            *"api repos/example/repo/commits/pre-source-sha"*)
                printf 'pre-source-sha\\n'
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
  }

  private enum ReleaseSourceScriptTestError: Error {
    case scriptNotFound
  }
}
