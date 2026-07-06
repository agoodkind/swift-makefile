//
//  SwiftMkUpdateSupport.swift
//  SwiftMkUpdateTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-02.
//  Copyright © 2026, all rights reserved.
//

import Foundation

@testable import SwiftMkUpdate

// MARK: - SwiftMkUpdateSupport

/// Shared fixtures for the update test suites. Owning these here keeps the shared
/// stubs from reaching back into a specific test file's namespace.
enum SwiftMkUpdateSupport {
  static let currentTag = "202607010101-a-aaaaaaa"
  static let newerTag = "202607020101-a-bbbbbbb"
  static let sha256 = "abc123"
  static let teamID = "H3BMXM4W7H"
  static let successStatusCode = 200
  static let sampleTimestamp: TimeInterval = 1_782_000_000

  static func config(currentVersion: String = currentTag) -> UpdateConfig {
    UpdateConfig(
      repo: "agoodkind/swift-makefile",
      binary: "swift-mk",
      teamID: teamID,
      currentVersion: currentVersion,
      assetName: "swift-mk_darwin_arm64.dmg")
  }

  static func releaseListData() -> Data {
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

  static func releaseData() -> Data {
    Data(
      """
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
      """.utf8)
  }
}

/// Run `body` with a fresh temporary directory that is removed afterward. Shared
/// across the update test suites.
func withTemporaryDirectory(_ run: (URL) throws -> Void) throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "swift-mk-update-\(UUID().uuidString)",
    isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer {
    do {
      try FileManager.default.removeItem(at: directory)
    } catch {
      UpdateDiagnostics.warning("update test cleanup failed: \(error)")
    }
  }
  try run(directory)
}

func withPreparedUpdate(
  commandMode: StubCommandRunner.Mode = .success,
  _ run: (PreparedUpdate) throws -> Void
) throws {
  try withTemporaryDirectory { directory in
    let targetURL = directory.appendingPathComponent("swift-mk")
    try PreparedUpdate.originalContents.write(
      to: targetURL, atomically: true, encoding: .utf8)
    let taggedReleaseURL =
      "https://api.github.com/repos/agoodkind/swift-makefile/releases/tags/"
      + SwiftMkUpdateSupport.newerTag
    let httpClient = StubHTTPClient(
      responses: [
        "https://api.github.com/repos/agoodkind/swift-makefile/releases": (
          SwiftMkUpdateSupport.releaseListData(),
          SwiftMkUpdateSupport.successStatusCode
        ),
        taggedReleaseURL: (
          SwiftMkUpdateSupport.releaseData(),
          SwiftMkUpdateSupport.successStatusCode
        ),
        "https://example.test/swift-mk.dmg": (
          Data("dmg".utf8),
          SwiftMkUpdateSupport.successStatusCode
        ),
      ])
    let commandRunner = StubCommandRunner(binary: "swift-mk", mode: commandMode)
    let cacheDir = directory.appendingPathComponent("cache").path
    let statePath = directory.appendingPathComponent("state/update-state.json").path
    let options = UpdateOptions(
      config: SwiftMkUpdateSupport.config(),
      targetPath: targetURL.path,
      cacheDir: cacheDir,
      statePath: statePath,
      dryRun: false,
      httpClient: httpClient,
      commandRunner: commandRunner
    ) {
      Date(timeIntervalSince1970: SwiftMkUpdateSupport.sampleTimestamp)
    }

    try run(
      PreparedUpdate(
        options: options,
        targetURL: targetURL,
        statePath: statePath))
  }
}

// MARK: - PreparedUpdate

struct PreparedUpdate {
  static let originalContents = "old swift-mk\n"

  let options: UpdateOptions
  let targetURL: URL
  let statePath: String
}

// MARK: - StubHTTPClient

final class StubHTTPClient: ReleaseHTTPClient {
  private let responses: [String: (Data, Int)]

  init(responses: [String: (Data, Int)]) {
    self.responses = responses
  }

  func get(_ url: URL, headers: [String: String]) throws -> (Data, Int) {
    guard let response = responses[url.absoluteString] else {
      throw UpdateError.http("missing response for \(url.absoluteString)")
    }
    if url.host == "api.github.com",
      headers["Accept"] != "application/vnd.github+json"
    {
      throw UpdateError.http("missing GitHub API accept header")
    }
    if url.host == "example.test",
      headers["Accept"] != "application/octet-stream"
    {
      throw UpdateError.http("missing download accept header")
    }
    return response
  }
}

// MARK: - StubCommandRunner

final class StubCommandRunner: CommandRunner {
  enum Mode {
    case success
    case signatureFailure
    case teamMismatch
    case validateMismatch
  }

  private static let stapleArgumentCount = 2

  static let candidateContents = "new swift-mk\n"

  private let binary: String
  private let mode: Mode

  init(binary: String, mode: Mode) {
    self.binary = binary
    self.mode = mode
  }

  func run(
    _ tool: String,
    _ args: [String]
  ) -> CommandOutput {
    if tool == "shasum" {
      return CommandOutput(
        status: 0,
        stdout: "\(SwiftMkUpdateSupport.sha256)  \(args.last ?? "")\n",
        stderr: "")
    }
    if tool == "xcrun",
      args.prefix(Self.stapleArgumentCount) == ["stapler", "validate"]
    {
      if mode == .signatureFailure {
        return CommandOutput(status: 1, stdout: "", stderr: "staple failed")
      }
      return CommandOutput(status: 0, stdout: "", stderr: "")
    }
    if tool == "hdiutil",
      args.first == "attach"
    {
      return attach(args)
    }
    if tool == "hdiutil",
      args.first == "detach"
    {
      return CommandOutput(status: 0, stdout: "", stderr: "")
    }
    if tool == "codesign",
      args.first == "--verify"
    {
      if mode == .signatureFailure {
        return CommandOutput(status: 1, stdout: "", stderr: "codesign failed")
      }
      return CommandOutput(status: 0, stdout: "", stderr: "")
    }
    if tool == "codesign",
      args.first == "-dvv"
    {
      let team = mode == .teamMismatch ? "WRONGTEAM" : SwiftMkUpdateSupport.teamID
      return CommandOutput(status: 0, stdout: "", stderr: "TeamIdentifier=\(team)\n")
    }
    if tool.hasSuffix("/\(binary)") {
      if mode == .validateMismatch {
        return CommandOutput(status: 0, stdout: "version: something-else\n", stderr: "")
      }
      return CommandOutput(
        status: 0,
        stdout: "version: \(SwiftMkUpdateSupport.newerTag)\n",
        stderr: "")
    }
    return CommandOutput(
      status: 1,
      stdout: "",
      stderr: "unexpected command \(tool) \(args.joined(separator: " "))")
  }

  private func attach(_ args: [String]) -> CommandOutput {
    UpdateDiagnostics.debug("test stub attach command")
    guard
      let mountFlagIndex = args.firstIndex(of: "-mountpoint"),
      args.indices.contains(args.index(after: mountFlagIndex))
    else {
      return CommandOutput(status: 1, stdout: "", stderr: "missing mountpoint")
    }
    let mountPath = args[args.index(after: mountFlagIndex)]
    let candidatePath = URL(fileURLWithPath: mountPath).appendingPathComponent(binary)
    do {
      try FileManager.default.createDirectory(
        atPath: mountPath, withIntermediateDirectories: true)
      try Self.candidateContents.write(to: candidatePath, atomically: true, encoding: .utf8)
      return CommandOutput(status: 0, stdout: "", stderr: "")
    } catch {
      return CommandOutput(status: 1, stdout: "", stderr: "\(error)")
    }
  }
}

// MARK: - StubScheduledRunner

final class StubScheduledRunner: SchedulerUpdateRunning {
  private let checkResult: CheckResult
  private let applyResult: ApplyResult
  private let lock = NSLock()
  private var storedCheckCount = 0
  private var storedApplyCount = 0

  init(checkResult: CheckResult, applyResult: ApplyResult) {
    self.checkResult = checkResult
    self.applyResult = applyResult
  }

  var checkCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return storedCheckCount
  }

  var applyCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return storedApplyCount
  }

  func check(options _: UpdateOptions) -> CheckResult {
    lock.lock()
    storedCheckCount += 1
    lock.unlock()
    return checkResult
  }

  func apply(options _: UpdateOptions) -> ApplyResult {
    lock.lock()
    storedApplyCount += 1
    lock.unlock()
    return applyResult
  }
}

// MARK: - TestSchedulerClock

struct TestSchedulerClock: SchedulerClock {
  func sleep(for _: TimeInterval) {
    // Tests advance scheduler iterations without waiting.
  }
}

// MARK: - LockedBox

final class LockedBox<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value

  init(_ value: Value) {
    stored = value
  }

  var value: Value {
    get {
      lock.lock()
      defer { lock.unlock() }
      return stored
    }
    set {
      lock.lock()
      stored = newValue
      lock.unlock()
    }
  }
}

// MARK: - CheckResult

extension CheckResult {
  static func sample(updateAvailable: Bool) -> CheckResult {
    CheckResult(
      currentVersion: SwiftMkUpdateSupport.currentTag,
      latestTag: SwiftMkUpdateSupport.newerTag,
      assetName: "swift-mk_darwin_arm64.dmg",
      assetURL: URL(string: "https://example.test/swift-mk.dmg"),
      updateAvailable: updateAvailable)
  }
}

// MARK: - ApplyResult

extension ApplyResult {
  static func sample(applied: Bool) -> ApplyResult {
    ApplyResult(
      check: CheckResult.sample(updateAvailable: applied),
      applied: applied,
      dryRun: false,
      result: applied ? .applied : .upToDate)
  }
}
