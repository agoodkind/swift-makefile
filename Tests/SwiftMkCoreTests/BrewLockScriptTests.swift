//
//  BrewLockScriptTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-08.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - BrewLockScriptTests

@Suite(.serialized)
enum BrewLockScriptTests {
  private static let executablePermission = 0o755

  @Test(.timeLimit(.minutes(1)))
  static func retriesHomebrewLockContentionAndReturnsSuccess() throws {
    try withBrewLockHarness(mode: "contention-then-success") { harness in
      let result = harness.run("brew_locked update --quiet")
      let invocationCount = try harness.invocationCount()
      let environmentLines = try harness.environmentLines()

      #expect(result.status == 0)
      #expect(result.stderr.contains("Another 'brew update' process is already running"))
      #expect(result.stderr.contains("retrying brew update"))
      #expect(invocationCount == 2)
      #expect(environmentLines == ["update=", "update="])
    }
  }

  @Test(.timeLimit(.minutes(1)))
  static func doesNotRetryNonContentionHomebrewFailures() throws {
    try withBrewLockHarness(mode: "real-failure") { harness in
      let result = harness.run("brew_locked install definitely-not-real")
      let invocationCount = try harness.invocationCount()

      #expect(result.status == 1)
      #expect(result.stderr.contains("No such formula"))
      #expect(!result.stderr.contains("retrying brew install"))
      #expect(invocationCount == 1)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  static func disablesHomebrewAutoUpdateForInstallAndUpgradeOnly() throws {
    try withBrewLockHarness(mode: "success") { harness in
      let result = harness.run(
        """
        brew_locked install swiftlint
        brew_locked upgrade swiftlint
        brew_locked update --quiet
        """)
      let environmentLines = try harness.environmentLines()

      #expect(result.status == 0)
      #expect(environmentLines == ["install=1", "upgrade=1", "update="])
    }
  }

  @Test(.timeLimit(.minutes(1)))
  static func skipsBrewUpdateWhenBootRefreshMarkerPresent() throws {
    try withBrewLockHarness(mode: "success") { harness in
      let marker = harness.directory.appendingPathComponent("boot-refreshed").path
      let result = harness.run(
        """
        export SWIFT_MK_BREW_BOOT_REFRESH_MARKER="\(marker)"
        : > "${SWIFT_MK_BREW_BOOT_REFRESH_MARKER}"
        brew_locked_update
        """)
      let invocationCount = try harness.invocationCount()

      #expect(result.status == 0)
      #expect(result.stderr.contains("skipping brew update"))
      #expect(invocationCount == 0)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  static func runsBrewUpdateWhenBootRefreshMarkerAbsent() throws {
    try withBrewLockHarness(mode: "success") { harness in
      let marker = harness.directory.appendingPathComponent("absent-marker").path
      let result = harness.run(
        """
        export SWIFT_MK_BREW_BOOT_REFRESH_MARKER="\(marker)"
        brew_locked_update
        """)
      let invocationCount = try harness.invocationCount()
      let environmentLines = try harness.environmentLines()

      #expect(result.status == 0)
      #expect(invocationCount == 1)
      #expect(environmentLines == ["update="])
    }
  }

  private static func withBrewLockHarness(
    mode: String,
    _ run: (BrewLockHarness) throws -> Void
  ) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "swift-mk-brew-lock-\(UUID().uuidString)",
      isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
      do {
        try FileManager.default.removeItem(at: directory)
      } catch {
        Output.error("test: could not remove \(directory.path): \(error)")
      }
    }

    let harness = try BrewLockHarness(directory: directory, mode: mode)
    try run(harness)
  }

  private static func brewLockScriptPath() throws -> String {
    var directory = (#filePath as NSString).deletingLastPathComponent
    while directory != "/" {
      let candidate = (directory as NSString)
        .appendingPathComponent(".github/actions/brew-lock/brew-lock.sh")
      if FileManager.default.fileExists(atPath: candidate) {
        return candidate
      }
      directory = (directory as NSString).deletingLastPathComponent
    }
    throw BrewLockTestError.scriptNotFound
  }

  // MARK: BrewLockHarness

  struct BrewLockHarness {
    let directory: URL
    let mode: String
    let binDirectory: URL
    let countFile: URL
    let environmentFile: URL
    let lockDirectory: URL
    let scriptPath: String

    init(directory: URL, mode: String) throws {
      self.directory = directory
      self.mode = mode
      binDirectory = directory.appendingPathComponent("bin", isDirectory: true)
      countFile = directory.appendingPathComponent("count")
      environmentFile = directory.appendingPathComponent("environment")
      lockDirectory = directory.appendingPathComponent("brew.lock.d", isDirectory: true)
      scriptPath = try BrewLockScriptTests.brewLockScriptPath()

      try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
      try writeFakeBrew()
    }

    func run(_ body: String) -> Shell.Result {
      let command = """
        set -euo pipefail
        source "\(scriptPath)"
        \(body)
        """
      return Shell.run(
        "bash",
        ["-c", command],
        environment: [
          "FAKE_BREW_COUNT_FILE": countFile.path,
          "FAKE_BREW_ENV_FILE": environmentFile.path,
          "FAKE_BREW_MODE": mode,
          // The runner inherits the ambient environment, and GitHub's hosted
          // macOS images export HOMEBREW_NO_AUTO_UPDATE=1 globally. Pin it empty
          // so the fake brew records what swift_mk_run_brew sets per command
          // (empty for update, 1 for install/upgrade), not the runner's value.
          "HOMEBREW_NO_AUTO_UPDATE": "",
          "PATH": binDirectory.path + ":" + ProcessInfo.processInfo.environment["PATH", default: ""],
          "SWIFT_MK_BREW_LOCK_DIR": lockDirectory.path,
          "SWIFT_MK_BREW_RETRY_BASE_SECONDS": "0",
          "SWIFT_MK_BREW_RETRY_CAP_SECONDS": "0",
        ])
    }

    func invocationCount() throws -> Int {
      guard FileManager.default.fileExists(atPath: countFile.path) else {
        return 0
      }
      let contents = try String(contentsOf: countFile, encoding: .utf8)
      return Int(contents.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    func environmentLines() throws -> [String] {
      guard FileManager.default.fileExists(atPath: environmentFile.path) else {
        return []
      }
      let contents = try String(contentsOf: environmentFile, encoding: .utf8)
      return contents.split(separator: "\n").map(String.init)
    }

    private func writeFakeBrew() throws {
      let fakeBrew = binDirectory.appendingPathComponent("brew")
      let script = """
        #!/usr/bin/env bash
        set -euo pipefail

        count=0
        if [[ -f "${FAKE_BREW_COUNT_FILE:?}" ]]; then
            count="$(<"${FAKE_BREW_COUNT_FILE}")"
        fi
        count=$((count + 1))
        printf '%s\\n' "${count}" > "${FAKE_BREW_COUNT_FILE}"
        printf '%s=%s\\n' "${1:-}" "${HOMEBREW_NO_AUTO_UPDATE:-}" >> "${FAKE_BREW_ENV_FILE:?}"

        case "${FAKE_BREW_MODE:?}" in
            contention-then-success)
                if ((count == 1)); then
                    printf "Error: Another 'brew update' process is already running\\n" >&2
                    exit 1
                fi
                printf 'ok %s\\n' "$*"
                ;;
            real-failure)
                printf 'Error: No such formula: definitely-not-real\\n' >&2
                exit 1
                ;;
            success)
                printf 'ok %s\\n' "$*"
                ;;
            *)
                printf 'unknown fake brew mode: %s\\n' "${FAKE_BREW_MODE}" >&2
                exit 2
                ;;
        esac
        """
      try script.write(to: fakeBrew, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: BrewLockScriptTests.executablePermission)],
        ofItemAtPath: fakeBrew.path)
    }
  }

  enum BrewLockTestError: Error {
    case scriptNotFound
  }
}
