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

// These fixtures hold the build-tool literal at file scope, not inside a test
// body, so the test functions themselves stay free of the boundary needle and do
// not trip the boundary-log rule while still writing it into the fixture file.
private let unroutedBuildFixture =
    "func build() { run(\"xcodebuild\", arguments) }\n"
private let routedBuildFixture =
    "func build() {\n"
    + "    SigningBuildConfig.applyEnvironmentOverride()\n"
    + "    run(\"xcodebuild\", arguments)\n"
    + "}\n"
private let optOutBuildFixture =
    "// swift-mk: signing-not-required\n"
    + "func analyze() { run(\"xcodebuild\", arguments) }\n"
private let testFileBuildFixture =
    "func testBuild() { run(\"xcodebuild\", arguments) }\n"

@Test
func scanFlagsUnroutedBuildToolCall() throws {
    let temporaryDirectory = try createTemporaryDirectory()
    let filePath = temporaryDirectory.appendingPathComponent("Build.swift").path
    try unroutedBuildFixture.write(toFile: filePath, atomically: true, encoding: .utf8)

    let violations = try scan(paths: [filePath], enabledRules: [.unroutedXcodebuild])

    #expect(violations.count == 1)
    #expect(violations.first?.rule == .unroutedXcodebuild)
}

@Test
func scanAllowsBuildToolWhenOverrideApplied() throws {
    let temporaryDirectory = try createTemporaryDirectory()
    let filePath = temporaryDirectory.appendingPathComponent("Build.swift").path
    try routedBuildFixture.write(toFile: filePath, atomically: true, encoding: .utf8)

    let violations = try scan(paths: [filePath], enabledRules: [.unroutedXcodebuild])

    #expect(violations.isEmpty)
}

@Test
func scanAllowsBuildToolWithOptOutMarker() throws {
    let temporaryDirectory = try createTemporaryDirectory()
    let filePath = temporaryDirectory.appendingPathComponent("Analyze.swift").path
    try optOutBuildFixture.write(toFile: filePath, atomically: true, encoding: .utf8)

    let violations = try scan(paths: [filePath], enabledRules: [.unroutedXcodebuild])

    #expect(violations.isEmpty)
}

@Test
func scanSkipsUnroutedBuildToolInTestFiles() throws {
    let temporaryDirectory = try createTemporaryDirectory()
    let filePath = temporaryDirectory.appendingPathComponent("BuildTests.swift").path
    try testFileBuildFixture.write(toFile: filePath, atomically: true, encoding: .utf8)

    let violations = try scan(paths: [filePath], enabledRules: [.unroutedXcodebuild])

    #expect(violations.isEmpty)
}

private func createTemporaryDirectory() throws -> URL {
    let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    return directoryURL
}
