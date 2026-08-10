//
//  ReleaseBuildGenerateOrderTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-08-09.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - ReleaseBuildGenerateOrderTests

/// A consumer whose sources are rendered rather than committed only compiles after its
/// generate command runs, and a release always starts from a fresh checkout. The `verify`
/// and `build` entries prepend `SWIFT_GENERATE_CMD`; `release-build` did not, so the
/// release path was the one build entry that compiled against sources that were never
/// rendered. The consumer's own release command cannot cover that, because the command
/// whose dependencies need the generated sources is the command that would have to
/// render them.
@Suite(.serialized)
enum ReleaseBuildGenerateOrderTests {
  @Test
  static func releaseBuildGeneratesBeforeItRunsTheReleaseCommand() throws {
    try withConsumer(generates: true) { consumer in
      let result = consumer.runReleaseBuild()
      try #require(result.status == 0, "release-build failed: \(result.stderr)")
      let order = try consumer.order()

      #expect(order == ["generate", "release-command"])
    }
  }

  /// The prefix is guarded, so a consumer that declares no generate command runs the same
  /// release path it ran before. Without the guard the recipe would emit a bare `&&` and
  /// break every consumer that generates nothing.
  @Test
  static func releaseBuildRunsTheReleaseCommandDirectlyWithoutAGenerateCommand() throws {
    try withConsumer(generates: false) { consumer in
      let result = consumer.runReleaseBuild()
      try #require(result.status == 0, "release-build failed: \(result.stderr)")
      let order = try consumer.order()

      #expect(order == ["release-command"])
    }
  }

  /// The build path marks the compile as already generated so the in-process gate chain
  /// does not generate a second time. The release path carries the same mark.
  @Test
  static func releaseBuildMarksTheCompileAsAlreadyGenerated() throws {
    try withConsumer(generates: true) { consumer in
      let result = consumer.runReleaseBuild()
      try #require(result.status == 0, "release-build failed: \(result.stderr)")
      let environment = try consumer.engineEnvironment()

      #expect(environment.contains("SWIFT_MK_GENERATED=1"))
    }
  }

  private static func withConsumer(
    generates: Bool,
    _ body: (Consumer) throws -> Void
  ) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "swift-mk-release-generate-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { removeTemporary(directory.path) }
    try body(try Consumer(directory: directory, generates: generates))
  }

  private struct Consumer {
    let orderFile: URL
    let engineEnvironmentFile: URL

    private let directory: URL
    private let generateCommand: String
    private let releaseBuildCommand: String

    init(directory: URL, generates: Bool) throws {
      self.directory = directory
      orderFile = directory.appendingPathComponent("order")
      engineEnvironmentFile = directory.appendingPathComponent("engine-environment")
      let distDirectory = directory.appendingPathComponent("dist", isDirectory: true)

      if generates {
        generateCommand = "printf 'generate\\n' >> \(orderFile.path)"
      } else {
        generateCommand = ""
      }
      // Records that it ran, then leaves an artifact, because release-build fails when
      // the release command leaves the dist directory empty.
      releaseBuildCommand =
        "printf 'release-command\\n' >> \(orderFile.path)"
        + " && printf 'artifact\\n' > \(distDirectory.path)/artifact.txt"

      // Stands in for the engine binary the release entry invokes. It records whether the
      // generated mark reached it, then runs the release command the way the real
      // `build --command` entry does.
      let engine = directory.appendingPathComponent("swift-mk")
      let engineScript = """
        #!/usr/bin/env bash
        set -euo pipefail

        printf 'SWIFT_MK_GENERATED=%s\\n' "${SWIFT_MK_GENERATED:-}" > "${ENGINE_ENVIRONMENT_FILE}"
        command=""
        previous=""
        for argument in "$@"; do
            if [[ "${previous}" == "--command" ]]; then
                command="${argument}"
            fi
            previous="${argument}"
        done
        if [[ -z "${command}" ]]; then
            printf 'engine called without a command: %s\\n' "$*" >&2
            exit 2
        fi
        eval "${command}"
        """
      try Self.writeExecutable(engineScript, to: engine)

      let makefile = """
        SWIFT_MK_BIN := \(engine.path)
        SWIFT_MK_DIST_DIR := \(distDirectory.path)

        include \(Self.repositoryPath(for: "swift-release.mk"))
        """
      try makefile.write(
        to: directory.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
    }

    /// The commands travel as command-line overrides and MAKEFLAGS is cleared, because
    /// this test itself runs under `make test`. swift.mk exports its own
    /// SWIFT_MK_RELEASE_BUILD_CMD, so without this an inner make inherits the engine's
    /// release command and tries to run the engine's release script from a temporary
    /// directory. A command-line override outranks both the environment and the makefile.
    func runReleaseBuild() -> Shell.Result {
      Shell.run(
        "/usr/bin/make",
        [
          "-C", directory.path,
          "release-build",
          "SWIFT_GENERATE_CMD=\(generateCommand)",
          "SWIFT_MK_RELEASE_BUILD_CMD=\(releaseBuildCommand)",
        ],
        environment: [
          "ENGINE_ENVIRONMENT_FILE": engineEnvironmentFile.path,
          "MAKEFLAGS": "",
          "PATH": ProcessInfo.processInfo.environment["PATH", default: ""],
        ])
    }

    func order() throws -> [String] {
      try String(contentsOf: orderFile, encoding: .utf8)
        .split(separator: "\n")
        .map(String.init)
    }

    func engineEnvironment() throws -> String {
      try String(contentsOf: engineEnvironmentFile, encoding: .utf8)
    }

    private static func writeExecutable(_ script: String, to url: URL) throws {
      try script.write(to: url, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private static func repositoryPath(for relativePath: String) -> String {
      URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent(relativePath)
        .path
    }
  }
}
