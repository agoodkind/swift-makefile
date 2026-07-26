//
//  StageAppcastAssetsScriptTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-26.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - StageAppcastAssetsScriptTests

@Suite(.serialized)
enum StageAppcastAssetsScriptTests {
  @Test
  static func prereleaseDeploymentPreservesTheStableFeed() throws {
    try withHarness { harness in
      let result = try harness.run(track: "prerelease")

      #expect(result.status == 0)
      #expect(try harness.publicAppcast(path: "prerelease/appcast.xml") == Harness.current)
      #expect(try harness.publicAppcast(path: "appcast.xml") == Harness.stable)
      #expect(try harness.requestedURLs() == [Harness.stableURL])
    }
  }

  @Test
  static func stableDeploymentPreservesThePrereleaseFeed() throws {
    try withHarness { harness in
      let result = try harness.run(track: "stable")

      #expect(result.status == 0)
      #expect(try harness.publicAppcast(path: "appcast.xml") == Harness.current)
      #expect(try harness.publicAppcast(path: "prerelease/appcast.xml") == Harness.prerelease)
      #expect(try harness.requestedURLs() == [Harness.prereleaseURL])
    }
  }

  @Test
  static func failedPreservationLeavesTheExistingAssetsUntouched() throws {
    try withHarness { harness in
      try harness.writeExistingAssets()

      let result = try harness.run(track: "prerelease", curlFails: true)

      #expect(result.status != 0)
      #expect(result.stderr.contains("could not preserve stable appcast"))
      #expect(try harness.publicAppcast(path: "appcast.xml") == Harness.previousStable)
      #expect(
        try harness.publicAppcast(path: "prerelease/appcast.xml")
          == Harness.previousPrerelease)
    }
  }

  @Test
  static func rejectsAnUnknownReleaseTrack() throws {
    try withHarness { harness in
      let result = try harness.run(track: "nightly")

      #expect(result.status != 0)
      #expect(result.stderr.contains("RELEASE_TRACK must be prerelease or stable"))
      #expect(try harness.requestedURLs().isEmpty)
    }
  }

  @Test
  static func compositeActionExposesTheStagingContract() throws {
    let action = try String(contentsOfFile: actionPath(), encoding: .utf8)

    #expect(action.contains("release-track:"))
    #expect(action.contains("appcast-source:"))
    #expect(action.contains("public-directory:"))
    #expect(action.contains("stable-feed-url:"))
    #expect(action.contains("prerelease-feed-url:"))
    #expect(action.contains("${GITHUB_ACTION_PATH}/stage-appcast-assets.sh"))
  }

  private static func withHarness(_ body: (Harness) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "swift-mk-stage-appcast-\(UUID().uuidString)", isDirectory: true)
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

  private static func actionPath() throws -> String {
    try repositoryPath(
      components: [".github", "actions", "stage-appcast-assets", "action.yml"])
  }

  private static func repositoryPath(components: [String]) throws -> String {
    var searchDirectory = (#filePath as NSString).deletingLastPathComponent
    while searchDirectory != "/" {
      var candidate = searchDirectory
      for component in components {
        candidate = (candidate as NSString).appendingPathComponent(component)
      }
      if FileManager.default.fileExists(atPath: candidate) {
        return candidate
      }
      searchDirectory = (searchDirectory as NSString).deletingLastPathComponent
    }
    let repositoryPath = components.joined(separator: "/")
    throw StageAppcastAssetsScriptTestError.repositoryPathNotFound(repositoryPath)
  }

  private struct Harness {
    static let current = "<rss>current</rss>\n"
    static let prerelease = "<rss>prerelease</rss>\n"
    static let prereleaseURL = "https://example.test/prerelease/appcast.xml"
    static let previousPrerelease = "<rss>previous-prerelease</rss>\n"
    static let previousStable = "<rss>previous-stable</rss>\n"
    static let stable = "<rss>stable</rss>\n"
    static let stableURL = "https://example.test/appcast.xml"

    let directory: URL
    let binDirectory: URL
    let curlCallsFile: URL
    let publicDirectory: URL
    let sourceAppcast: URL

    init(directory: URL) throws {
      self.directory = directory
      binDirectory = directory.appendingPathComponent("bin", isDirectory: true)
      curlCallsFile = directory.appendingPathComponent("curl-calls")
      publicDirectory = directory.appendingPathComponent("public", isDirectory: true)
      sourceAppcast = directory.appendingPathComponent("generated-appcast.xml")
      try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(
        at: publicDirectory, withIntermediateDirectories: true)
      try Self.current.write(to: sourceAppcast, atomically: true, encoding: .utf8)
      try writeFakeCurl()
    }

    func run(track: String, curlFails: Bool = false) throws -> Shell.Result {
      Shell.run(
        "bash",
        [try scriptPath()],
        environment: [
          "APPCAST_SOURCE": sourceAppcast.path,
          "CURL_CALLS_FILE": curlCallsFile.path,
          "FAKE_CURL_FAILS": curlFails ? "true" : "false",
          "FAKE_PRERELEASE_APPCAST": Self.prerelease,
          "FAKE_STABLE_APPCAST": Self.stable,
          "PATH":
            binDirectory.path + ":" + ProcessInfo.processInfo.environment["PATH", default: ""],
          "PRERELEASE_FEED_URL": Self.prereleaseURL,
          "PUBLIC_DIRECTORY": publicDirectory.path,
          "RELEASE_TRACK": track,
          "STABLE_FEED_URL": Self.stableURL,
        ])
    }

    func publicAppcast(path: String) throws -> String {
      try String(
        contentsOf: publicDirectory.appendingPathComponent(path),
        encoding: .utf8)
    }

    func requestedURLs() throws -> [String] {
      guard FileManager.default.fileExists(atPath: curlCallsFile.path) else {
        return []
      }
      let calls = try String(contentsOf: curlCallsFile, encoding: .utf8)
      return calls.split(whereSeparator: \.isNewline).map(String.init)
    }

    func writeExistingAssets() throws {
      try Self.previousStable.write(
        to: publicDirectory.appendingPathComponent("appcast.xml"),
        atomically: true,
        encoding: .utf8)
      let prereleaseDirectory = publicDirectory.appendingPathComponent(
        "prerelease", isDirectory: true)
      try FileManager.default.createDirectory(
        at: prereleaseDirectory, withIntermediateDirectories: true)
      try Self.previousPrerelease.write(
        to: prereleaseDirectory.appendingPathComponent("appcast.xml"),
        atomically: true,
        encoding: .utf8)
    }

    private func scriptPath() throws -> String {
      try StageAppcastAssetsScriptTests.repositoryPath(
        components: [
          ".github", "actions", "stage-appcast-assets", "stage-appcast-assets.sh",
        ])
    }

    private func writeFakeCurl() throws {
      let executable = binDirectory.appendingPathComponent("curl")
      let script = """
        #!/usr/bin/env bash
        set -euo pipefail

        output_path=""
        request_url=""
        while [[ "$#" -gt 0 ]]; do
            case "$1" in
                --output)
                    shift
                    output_path="${1:?curl output path is missing}"
                    ;;
                https://*)
                    request_url="$1"
                    ;;
            esac
            shift
        done

        printf '%s\\n' "${request_url}" >> "${CURL_CALLS_FILE}"
        if [[ "${FAKE_CURL_FAILS}" == "true" ]]; then
            printf 'simulated curl failure\\n' >&2
            exit 22
        fi

        case "${request_url}" in
            "${STABLE_FEED_URL}")
                printf '%s' "${FAKE_STABLE_APPCAST}" > "${output_path}"
                ;;
            "${PRERELEASE_FEED_URL}")
                printf '%s' "${FAKE_PRERELEASE_APPCAST}" > "${output_path}"
                ;;
            *)
                printf 'unexpected URL: %s\\n' "${request_url}" >&2
                exit 2
                ;;
        esac
        """
      try script.write(to: executable, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: executable.path)
    }
  }

  private enum StageAppcastAssetsScriptTestError: Error {
    case repositoryPathNotFound(String)
  }
}
