//
//  SwiftCheckCoreTests.swift
//  SwiftCheckCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-24.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftCheckCore

// MARK: - SwiftCheckCore Tests

@Test
func scanFindsAnyTypeUsage() throws {
  let temporaryDirectory = try createTemporaryDirectory()
  let filePath = temporaryDirectory.appendingPathComponent("Sample.swift").path
  try "struct Sample { let payload: Any }\n".write(
    toFile: filePath, atomically: true, encoding: .utf8)

  let violations = try scan(paths: [filePath], enabledRules: [.noAny])

  #expect(violations.count == 1)
  #expect(violations.first?.rule == .noAny)
}

@Test
func scanFindsDetachedTaskUsage() throws {
  let temporaryDirectory = try createTemporaryDirectory()
  let filePath = temporaryDirectory.appendingPathComponent("Sample.swift").path
  try "func startWork() { Task.detached { } }\n".write(
    toFile: filePath, atomically: true, encoding: .utf8)

  let violations = try scan(paths: [filePath], enabledRules: [.taskDetached])

  #expect(violations.count == 1)
  #expect(violations.first?.rule == .taskDetached)
}

// MARK: - Build-tool fixtures

// Fixtures hold the build-tool literal at file scope inside a larger string, so the
// test file itself does not trip the exact-match rule while still exercising it.
private let unroutedBuildFixture =
  "func build() { run(\"xcodebuild\", arguments) }\n"
private let dataMentionFixture =
  "let generator = \"xcodebuild\"\n"

@Test
func scanFlagsUnroutedBuildToolCall() throws {
  let temporaryDirectory = try createTemporaryDirectory()
  let filePath = temporaryDirectory.appendingPathComponent("Build.swift").path
  try unroutedBuildFixture.write(toFile: filePath, atomically: true, encoding: .utf8)

  let violations = try scan(paths: [filePath], enabledRules: [.unroutedBuildTooling])

  #expect(violations.count == 1)
  #expect(violations.first?.rule == .unroutedBuildTooling)
}

@Test
func scanAllowsBuildToolNameAsData() throws {
  // No opt-out: only an invocation is flagged, never a tool name used as a value.
  let temporaryDirectory = try createTemporaryDirectory()
  let filePath = temporaryDirectory.appendingPathComponent("Generator.swift").path
  try dataMentionFixture.write(toFile: filePath, atomically: true, encoding: .utf8)

  let violations = try scan(paths: [filePath], enabledRules: [.unroutedBuildTooling])

  #expect(violations.isEmpty)
}

// MARK: - Fragile package path fixtures

// Fixtures hold the `.package(path: ...)` call inside a file-scope string, so the call
// is parsed as string content and the test file itself does not trip the rule.
private let fragileSelfPathFixture =
  "let dependency: Package.Dependency = .package(path: \"..\")\n"
private let robustSelfPathFixture =
  "let dependency: Package.Dependency = .package(path: \"../.make/dev/iphone-cell-tunnel\")\n"

@Test
func scanFlagsFragileSelfPackagePath() throws {
  let temporaryDirectory = try createTemporaryDirectory()
  let filePath = temporaryDirectory.appendingPathComponent("Manifest.swift").path
  try fragileSelfPathFixture.write(toFile: filePath, atomically: true, encoding: .utf8)

  let violations = try scan(paths: [filePath], enabledRules: [.fragilePackagePath])

  #expect(violations.count == 1)
  #expect(violations.first?.rule == .fragilePackagePath)
}

@Test
func scanAllowsRobustSymlinkPackagePath() throws {
  // The worktree-robust form routes through `../.make/dev/<name>`, which is allowed.
  let temporaryDirectory = try createTemporaryDirectory()
  let filePath = temporaryDirectory.appendingPathComponent("Manifest.swift").path
  try robustSelfPathFixture.write(toFile: filePath, atomically: true, encoding: .utf8)

  let violations = try scan(paths: [filePath], enabledRules: [.fragilePackagePath])

  #expect(violations.isEmpty)
}

// MARK: - Boundary log fixtures

// A function that spawns a process without a structured log. Held at file scope so
// the rule sees it through a written fixture file, where the file name alone decides
// whether the production-only rule applies.
private let boundaryWithoutLogFixture =
  "func openConfig() { let result = Shell.run(\"cat\", [\"config\"]) }\n"

@Test
func scanFlagsBoundaryFunctionMissingLogInProductionFile() throws {
  let temporaryDirectory = try createTemporaryDirectory()
  let filePath = temporaryDirectory.appendingPathComponent("Boundary.swift").path
  try boundaryWithoutLogFixture.write(toFile: filePath, atomically: true, encoding: .utf8)

  let violations = try scan(paths: [filePath], enabledRules: [.missingBoundaryLog])

  #expect(violations.count == 1)
  #expect(violations.first?.rule == .missingBoundaryLog)
}

@Test
func scanSkipsBoundaryLogInTestFile() throws {
  // Boundary logging is a production concern, so a test that calls a boundary to
  // exercise it is out of scope, the same way `sleep_in_production` skips tests.
  let temporaryDirectory = try createTemporaryDirectory()
  let filePath = temporaryDirectory.appendingPathComponent("SampleTests.swift").path
  try boundaryWithoutLogFixture.write(toFile: filePath, atomically: true, encoding: .utf8)

  let violations = try scan(paths: [filePath], enabledRules: [.missingBoundaryLog])

  #expect(violations.isEmpty)
}

private func createTemporaryDirectory() throws -> URL {
  let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
    UUID().uuidString)
  try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
  return directoryURL
}
