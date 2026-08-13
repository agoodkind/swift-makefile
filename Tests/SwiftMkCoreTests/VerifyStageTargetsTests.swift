//
//  VerifyStageTargetsTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-08-12.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - VerifyStageTargetsTests

/// `verify` is a chain of three stage targets (verify-build, verify-test,
/// verify-quality) so a CI job can run each stage as its own step with its own
/// named check. These tests pin the contract that split must keep: `make verify`
/// runs generate, the gated build, the tests, the lint gates, and the audit in
/// the order the monolithic recipe always ran them, and each stage target runs
/// only its own slice.
@Suite(.serialized)
enum VerifyStageTargetsTests {
  @Test
  static func verifyRunsTheStagesInTheirHistoricalOrder() throws {
    try withConsumer(generates: true) { consumer in
      let result = consumer.runMake(target: "verify")
      try #require(result.status == 0, "verify failed: \(result.stderr)")
      let order = try consumer.order()

      #expect(
        order == [
          "generate",
          "engine:signing-xcconfig",
          "engine:build",
          "build-cmd",
          "engine:test",
          "test-cmd",
          "engine:lint",
          "engine:audit",
        ])
    }
  }

  /// The compile stage must not leak into the later stages: a workflow step that
  /// runs verify-build alone gets the generate and the gated build, and nothing
  /// of the test or quality slices.
  @Test
  static func verifyBuildRunsOnlyTheCompileSlice() throws {
    try withConsumer(generates: true) { consumer in
      let result = consumer.runMake(target: "verify-build")
      try #require(result.status == 0, "verify-build failed: \(result.stderr)")
      let order = try consumer.order()

      #expect(order.first == "generate")
      #expect(order.contains("engine:build"))
      #expect(!order.contains("engine:test"))
      #expect(!order.contains("engine:lint"))
      #expect(!order.contains("engine:audit"))
    }
  }

  /// The build subprocess must stay marked exactly as the monolithic recipe
  /// marked it: generation already ran, and the decoupled quality gates make the
  /// inline gates skippable for this one entry.
  @Test
  static func verifyBuildMarksTheCompileGeneratedWithInlineGatesSkipped() throws {
    try withConsumer(generates: true) { consumer in
      let result = consumer.runMake(target: "verify-build")
      try #require(result.status == 0, "verify-build failed: \(result.stderr)")
      let environment = try consumer.engineEnvironment()

      #expect(environment.contains("SWIFT_MK_GENERATED=1"))
      #expect(environment.contains("SWIFT_MK_SKIP_INLINE_GATES=1"))
    }
  }

  /// Without a generate command the chain is unchanged apart from the absent
  /// generate marker, so a consumer that generates nothing keeps its behavior.
  @Test
  static func verifyWithoutAGenerateCommandSkipsGeneration() throws {
    try withConsumer(generates: false) { consumer in
      let result = consumer.runMake(target: "verify")
      try #require(result.status == 0, "verify failed: \(result.stderr)")
      let order = try consumer.order()

      #expect(
        order == [
          "engine:signing-xcconfig",
          "engine:build",
          "build-cmd",
          "engine:test",
          "test-cmd",
          "engine:lint",
          "engine:audit",
        ])
    }
  }

  private static func withConsumer(
    generates: Bool,
    _ body: (Consumer) throws -> Void
  ) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "swift-mk-verify-stages-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { removeTemporary(directory.path) }
    try body(try Consumer(directory: directory, generates: generates))
  }

  private struct Consumer {
    let orderFile: URL
    let engineEnvironmentFile: URL

    private let directory: URL
    private let generateCommand: String

    init(directory: URL, generates: Bool) throws {
      self.directory = directory
      orderFile = directory.appendingPathComponent("order")
      engineEnvironmentFile = directory.appendingPathComponent("engine-environment")

      if generates {
        generateCommand = "printf 'generate\\n' >> \(orderFile.path)"
      } else {
        generateCommand = ""
      }

      // Stands in for the engine binary the verify stages invoke. It appends each
      // subcommand to the order file; for `build` and `test` it also runs the
      // configured command the way the real entries do, and for `build` it records
      // the gating environment the recipe must set.
      let engine = directory.appendingPathComponent("swift-mk")
      let engineScript = """
        #!/usr/bin/env bash
        set -euo pipefail

        subcommand="${1:-}"
        printf 'engine:%s\\n' "${subcommand}" >> "${ORDER_FILE}"
        case "${subcommand}" in
          signing-xcconfig)
            exit 0
            ;;
          build)
            printf 'SWIFT_MK_GENERATED=%s SWIFT_MK_SKIP_INLINE_GATES=%s\\n' \\
              "${SWIFT_MK_GENERATED:-}" "${SWIFT_MK_SKIP_INLINE_GATES:-}" \\
              > "${ENGINE_ENVIRONMENT_FILE}"
            eval "${SWIFT_BUILD_CMD}"
            ;;
          test)
            eval "${SWIFT_TEST_CMD}"
            ;;
          lint|audit)
            exit 0
            ;;
          *)
            printf 'unexpected engine subcommand: %s\\n' "$*" >&2
            exit 2
            ;;
        esac
        """
      try Self.writeExecutable(engineScript, to: engine)

      // The temp consumer includes only swift-build.mk, which uses swift-mk-bin as
      // a prerequisite but does not define it (swift.mk owns that rule), so the
      // consumer supplies a no-op stand-in.
      let makefile = """
        SWIFT_MK_BIN := \(engine.path)

        swift-mk-bin: ;

        include \(Self.repositoryPath(for: "swift-build.mk"))
        """
      try makefile.write(
        to: directory.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
    }

    /// SWIFT_GENERATE_CMD travels as a command-line override because the recipes
    /// expand it at make level; the verify build and test commands travel through
    /// the environment because the recipes read them with shell parameter
    /// expansion. The environment is replaced wholesale, so the engine's own
    /// exported verify commands from the outer `make test` cannot leak in, and
    /// MAKEFLAGS is cleared for the reason ReleaseBuildGenerateOrderTests records.
    func runMake(target: String) -> Shell.Result {
      Shell.run(
        "/usr/bin/make",
        [
          "-C", directory.path,
          target,
          "SWIFT_GENERATE_CMD=\(generateCommand)",
        ],
        environment: [
          "ORDER_FILE": orderFile.path,
          "ENGINE_ENVIRONMENT_FILE": engineEnvironmentFile.path,
          "SWIFT_VERIFY_BUILD_CMD": "printf 'build-cmd\\n' >> \(orderFile.path)",
          "SWIFT_VERIFY_TEST_CMD": "printf 'test-cmd\\n' >> \(orderFile.path)",
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
