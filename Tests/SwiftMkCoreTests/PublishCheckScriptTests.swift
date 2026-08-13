//
//  PublishCheckScriptTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-08-12.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - PublishCheckScriptTests

/// The CI gate publishes one named check run per verify stage so a branch
/// ruleset can require a stage by name. Publishing is reporting, not a gate, so
/// these tests pin both halves of that contract: a healthy run reaches the
/// check-runs endpoint with the stage's name and conclusion, and a run that
/// cannot publish leaves the job's own result alone.
@Suite(.serialized)
enum PublishCheckScriptTests {
  private static let executablePermission = 0o755

  @Test(.timeLimit(.minutes(1)))
  static func publishesTheNamedCheckRunAgainstTheHeadCommit() throws {
    try withHarness(githubExitStatus: 0) { harness in
      let result = harness.run(checkName: "Build", conclusion: "success", headSHA: "cafe1234")
      let arguments = try harness.recordedArguments()

      #expect(result.status == 0)
      #expect(
        arguments == [
          "api",
          "repos/agoodkind/swift-makefile/check-runs",
          "--method",
          "POST",
          "--field",
          "name=Build",
          "--field",
          "head_sha=cafe1234",
          "--field",
          "status=completed",
          "--field",
          "conclusion=success",
        ])
      #expect(result.stdout.contains("published Build=success on cafe1234"))
    }
  }

  /// A stage name with spaces has to survive as one API field rather than
  /// splitting into extra arguments.
  @Test(.timeLimit(.minutes(1)))
  static func keepsAMultiWordStageNameInOneField() throws {
    try withHarness(githubExitStatus: 0) { harness in
      let result = harness.run(
        checkName: "Release dry run", conclusion: "skipped", headSHA: "cafe1234")
      let arguments = try harness.recordedArguments()

      #expect(result.status == 0)
      #expect(arguments.contains("name=Release dry run"))
      #expect(arguments.contains("conclusion=skipped"))
    }
  }

  /// A token without `checks: write` is the normal state of a fork pull request
  /// and of a caller whose own workflow permissions omit it. The stage already
  /// ran and passed, so a rejected publish must not turn the job red, and it
  /// must leave the rejection readable in the log.
  @Test(.timeLimit(.minutes(1)))
  static func survivesARejectedPublishAndReportsWhy() throws {
    try withHarness(githubExitStatus: 1) { harness in
      let result = harness.run(checkName: "Tests", conclusion: "success", headSHA: "cafe1234")

      #expect(result.status == 0)
      #expect(result.stderr.contains("could not publish Tests=success"))
      #expect(result.stderr.contains("exit 1"))
      #expect(result.stderr.contains("Resource not accessible by integration"))
    }
  }

  /// Outside a pull request there is no head commit to attach a check run to, so
  /// the publish is skipped rather than attempted against an empty sha.
  @Test(.timeLimit(.minutes(1)))
  static func skipsPublishingWithoutAHeadCommit() throws {
    try withHarness(githubExitStatus: 0) { harness in
      let result = harness.run(checkName: "Quality", conclusion: "success", headSHA: "")
      let arguments = try harness.recordedArguments()

      #expect(result.status == 0)
      #expect(arguments.isEmpty)
      #expect(result.stderr.contains("no head sha"))
    }
  }

  @Test(.timeLimit(.minutes(1)))
  static func rejectsAMalformedInvocation() throws {
    try withHarness(githubExitStatus: 0) { harness in
      let result = harness.runRaw(arguments: ["Build"])

      #expect(result.status == 2)
      #expect(result.stderr.contains("usage"))
    }
  }

  /// Every stage published its own green check, so the bookkeeping sweep has
  /// nothing left to report and must not publish a second row for any name.
  @Test(.timeLimit(.minutes(1)))
  static func sweepsNothingWhenEveryStagePublished() throws {
    try withHarness(githubExitStatus: 0) { harness in
      let result = harness.runOutstandingSweep(
        unfinishedConclusion: "failure",
        published: ["success", "success", "success", "success"])
      let published = try harness.publishedChecks()

      #expect(result.status == 0)
      #expect(published.isEmpty)
    }
  }

  /// The stages run in order and each one publishes only after it passes, so the
  /// first name still missing a green check is the stage that failed, and every
  /// later name was cancelled by that failure.
  @Test(.timeLimit(.minutes(1)))
  static func sweepsTheFailedStageAndCancelsTheRest() throws {
    try withHarness(githubExitStatus: 0) { harness in
      let result = harness.runOutstandingSweep(
        unfinishedConclusion: "failure",
        published: ["success", "skipped", "skipped", "skipped"])
      let published = try harness.publishedChecks()

      #expect(result.status == 0)
      #expect(
        published == [
          "Tests=failure",
          "Quality=cancelled",
          "Release dry run=cancelled",
        ])
    }
  }

  /// A cancelled run has no failing stage, so no name may be reported as one.
  @Test(.timeLimit(.minutes(1)))
  static func sweepsEveryUnfinishedStageAsCancelledOnACancelledRun() throws {
    try withHarness(githubExitStatus: 0) { harness in
      let result = harness.runOutstandingSweep(
        unfinishedConclusion: "cancelled",
        published: ["skipped", "skipped", "skipped", "missing"])
      let published = try harness.publishedChecks()

      #expect(result.status == 0)
      #expect(
        published == [
          "Build=cancelled",
          "Tests=cancelled",
          "Quality=cancelled",
          "Release dry run=cancelled",
        ])
    }
  }

  /// A docs-only change occupies no macOS runner, so the ubuntu no-op reports
  /// every required stage name green instead of leaving the checks pending.
  @Test(.timeLimit(.minutes(1)))
  static func reportsEveryStageGreenFromTheIndexedSkipPath() throws {
    try withHarness(githubExitStatus: 0) { harness in
      let result = harness.runStep(named: "Publish skipped stage checks", environment: [:])
      let published = try harness.publishedChecks()

      #expect(result.status == 0)
      #expect(
        published == [
          "Build=success",
          "Tests=success",
          "Quality=success",
          "Release dry run=success",
        ])
    }
  }

  private static func withHarness(
    githubExitStatus: Int,
    _ run: (Harness) throws -> Void
  ) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "swift-mk-publish-check-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { removeTemporary(directory.path) }

    try run(try Harness(directory: directory, githubExitStatus: githubExitStatus))
  }

  private static func scriptPath() throws -> String {
    try repositoryPath(for: ".github/actions/ci-gate/publish-check.sh")
  }

  private static func repositoryRoot() throws -> String {
    try repositoryDirectory(containing: ".github/actions/ci-gate/action.yml")
  }

  private static func repositoryPath(for relativePath: String) throws -> String {
    let root = try repositoryDirectory(containing: relativePath)
    return (root as NSString).appendingPathComponent(relativePath)
  }

  private static func repositoryDirectory(containing relativePath: String) throws -> String {
    var directory = (#filePath as NSString).deletingLastPathComponent
    while directory != "/" {
      let candidate = (directory as NSString).appendingPathComponent(relativePath)
      if FileManager.default.fileExists(atPath: candidate) {
        return directory
      }
      directory = (directory as NSString).deletingLastPathComponent
    }
    throw PublishCheckTestError.fileNotFound(relativePath)
  }

  // MARK: Harness

  struct Harness {
    let directory: URL
    let binDirectory: URL
    let recordFile: URL
    let scriptPath: String
    let repositoryRoot: String
    let githubExitStatus: Int

    init(directory: URL, githubExitStatus: Int) throws {
      self.directory = directory
      self.githubExitStatus = githubExitStatus
      binDirectory = directory.appendingPathComponent("bin", isDirectory: true)
      recordFile = directory.appendingPathComponent("gh-arguments")
      scriptPath = try PublishCheckScriptTests.scriptPath()
      repositoryRoot = try PublishCheckScriptTests.repositoryRoot()

      try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
      try writeFakeGitHubCLI()
    }

    func run(checkName: String, conclusion: String, headSHA: String) -> Shell.Result {
      runRaw(arguments: [checkName, conclusion], headSHA: headSHA)
    }

    func runRaw(arguments: [String], headSHA: String = "cafe1234") -> Shell.Result {
      Shell.run(
        "bash",
        [scriptPath] + arguments,
        environment: [
          "FAKE_GH_EXIT_STATUS": String(githubExitStatus),
          "FAKE_GH_RECORD_FILE": recordFile.path,
          "GITHUB_REPOSITORY": "agoodkind/swift-makefile",
          "HEAD_SHA": headSHA,
          "PATH": binDirectory.path + ":"
            + ProcessInfo.processInfo.environment["PATH", default: ""],
        ])
    }

    func runOutstandingSweep(
      unfinishedConclusion: String,
      published: [String]
    ) -> Shell.Result {
      runStep(
        named: "Publish outstanding stage checks",
        environment: [
          "UNFINISHED_CONCLUSION": unfinishedConclusion,
          "BUILD_PUBLISHED": published[0],
          "TESTS_PUBLISHED": published[1],
          "QUALITY_PUBLISHED": published[2],
          "RELEASE_PUBLISHED": published[3],
        ])
    }

    /// Runs the gate step's own `run` script out of the composite action, so the
    /// stage-to-conclusion mapping under test is the one CI executes rather than
    /// a copy of it.
    func runStep(named stepName: String, environment: [String: String]) -> Shell.Result {
      let reader = """
        require "yaml"
        action = YAML.load_file(ARGV[0])
        step = action["runs"]["steps"].find { |s| s["name"] == ARGV[1] }
        abort "no step named #{ARGV[1]}" if step.nil?
        print step.fetch("run")
        """
      let actionPath = (repositoryRoot as NSString)
        .appendingPathComponent(".github/actions/ci-gate/action.yml")
      let extracted = Shell.run("ruby", ["-e", reader, actionPath, stepName])
      guard extracted.status == 0 else {
        return extracted
      }

      let stepScript = directory.appendingPathComponent("step.sh")
      do {
        try extracted.stdout.write(to: stepScript, atomically: true, encoding: .utf8)
      } catch {
        Output.error("test: could not write \(stepScript.path): \(error)")
      }

      var stepEnvironment = environment
      stepEnvironment["FAKE_GH_EXIT_STATUS"] = String(githubExitStatus)
      stepEnvironment["FAKE_GH_RECORD_FILE"] = recordFile.path
      stepEnvironment["GITHUB_REPOSITORY"] = "agoodkind/swift-makefile"
      stepEnvironment["HEAD_SHA"] = "cafe1234"
      stepEnvironment["SWIFT_MK_HELPER_ROOT"] = repositoryRoot
      stepEnvironment["PATH"] =
        binDirectory.path + ":" + ProcessInfo.processInfo.environment["PATH", default: ""]

      return Shell.run("bash", [stepScript.path], environment: stepEnvironment)
    }

    /// The `name=` and `conclusion=` fields of each recorded `gh api` call, in
    /// the order the step published them.
    func publishedChecks() throws -> [String] {
      let arguments = try recordedArguments()
      var checks: [String] = []
      var pendingName = ""
      for argument in arguments {
        if argument.hasPrefix("name=") {
          pendingName = String(argument.dropFirst("name=".count))
        }
        if argument.hasPrefix("conclusion=") {
          checks.append("\(pendingName)=\(argument.dropFirst("conclusion=".count))")
        }
      }
      return checks
    }

    func recordedArguments() throws -> [String] {
      guard FileManager.default.fileExists(atPath: recordFile.path) else {
        return []
      }
      let contents = try String(contentsOf: recordFile, encoding: .utf8)
      return contents.split(separator: "\n", omittingEmptySubsequences: false)
        .dropLast()
        .map(String.init)
    }

    /// Records one argument per line, so a stage name carrying spaces is
    /// distinguishable from two arguments.
    private func writeFakeGitHubCLI() throws {
      let fakeGitHubCLI = binDirectory.appendingPathComponent("gh")
      let script = """
        #!/usr/bin/env bash
        set -euo pipefail

        for argument in "$@"; do
            printf '%s\\n' "${argument}" >> "${FAKE_GH_RECORD_FILE:?}"
        done

        if ((${FAKE_GH_EXIT_STATUS:?} != 0)); then
            printf 'gh: Resource not accessible by integration (HTTP 403)\\n' >&2
            exit "${FAKE_GH_EXIT_STATUS}"
        fi

        printf '{"id":1}\\n'
        """
      try script.write(to: fakeGitHubCLI, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: PublishCheckScriptTests.executablePermission)],
        ofItemAtPath: fakeGitHubCLI.path)
    }
  }

  enum PublishCheckTestError: Error {
    case fileNotFound(String)
  }
}
