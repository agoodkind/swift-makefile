//
//  ReleaseMetaOverrideTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-26.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - ReleaseMetaOverrideTests

@Suite(.serialized)
enum ReleaseMetaOverrideTests {
  @Test
  static func legacyOverrideRunsWhenReleaseTrackIsOmitted() throws {
    try withHarness { harness in
      let result = try harness.run(releaseTrack: nil)

      #expect(result.status == 0)
      #expect(result.stdout == "legacy=true\n")
    }
  }

  @Test
  static func legacyOverrideRunsWhenReleaseTrackIsEmpty() throws {
    try withHarness { harness in
      let result = try harness.run(releaseTrack: "")

      #expect(result.status == 0)
      #expect(result.stdout == "legacy=true\n")
    }
  }

  @Test(arguments: ["stable", "prerelease"])
  static func explicitTrackUsesTypedMetadataInsteadOfLegacyOverride(track: String) throws {
    try withHarness { harness in
      let result = try harness.run(releaseTrack: track)
      let output = try harness.output()
      let expected =
        """
        tag=typed-\(track)
        release_tag=typed-\(track)
        release_track=\(track)
        artifact_version=typed-\(track)
        build_version=123
        marketing_version=1.2.3
        """ + "\n"

      #expect(result.status == 0)
      #expect(output == expected)
    }
  }

  private static func withHarness(_ body: (Harness) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "swift-mk-release-meta-\(UUID().uuidString)", isDirectory: true)
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
    let legacyMeta: URL
    let outputFile: URL
    let swiftMk: URL

    init(directory: URL) throws {
      self.directory = directory
      legacyMeta = directory.appendingPathComponent("legacy-meta")
      outputFile = directory.appendingPathComponent("output")
      swiftMk = directory.appendingPathComponent("swift-mk")
      try writeLegacyMeta()
      try writeSwiftMk()
    }

    func run(releaseTrack: String?) throws -> Shell.Result {
      var environment = [
        "GITHUB_OUTPUT": outputFile.path,
        "PATH": ProcessInfo.processInfo.environment["PATH", default: ""],
        "SWIFT_MK_BIN": swiftMk.path,
        "SWIFT_MK_RELEASE_META_CMD": legacyMeta.path,
      ]
      if let releaseTrack {
        environment["RELEASE_TRACK"] = releaseTrack
      }

      return Shell.run(
        "make",
        [
          "-f", try releaseMakefilePath(), "release-meta",
        ],
        environment: environment)
    }

    func output() throws -> String {
      try String(contentsOf: outputFile, encoding: .utf8)
    }

    private func releaseMakefilePath() throws -> String {
      var searchDirectory = (#filePath as NSString).deletingLastPathComponent
      while searchDirectory != "/" {
        let candidate = (searchDirectory as NSString).appendingPathComponent("swift-release.mk")
        if FileManager.default.fileExists(atPath: candidate) {
          return candidate
        }
        searchDirectory = (searchDirectory as NSString).deletingLastPathComponent
      }
      throw ReleaseMetaOverrideTestError.makefileNotFound
    }

    private func writeLegacyMeta() throws {
      let script = """
        #!/usr/bin/env bash
        set -euo pipefail

        printf 'legacy=true\\n'
        """
      try writeExecutable(script, to: legacyMeta)
    }

    private func writeSwiftMk() throws {
      let script = """
        #!/usr/bin/env bash
        set -euo pipefail

        if [[ "${1:-}" != "version-meta" ]]; then
            printf 'unexpected swift-mk command: %s\\n' "$*" >&2
            exit 2
        fi

        printf 'tag=typed-%s\\n' "${RELEASE_TRACK}"
        printf 'release_tag=typed-%s\\n' "${RELEASE_TRACK}"
        printf 'release_track=%s\\n' "${RELEASE_TRACK}"
        printf 'artifact_version=typed-%s\\n' "${RELEASE_TRACK}"
        printf 'build_version=123\\n'
        printf 'marketing_version=1.2.3\\n'
        """
      try writeExecutable(script, to: swiftMk)
    }

    private func writeExecutable(_ script: String, to executable: URL) throws {
      try script.write(to: executable, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: executable.path)
    }
  }

  private enum ReleaseMetaOverrideTestError: Error {
    case makefileNotFound
  }
}
