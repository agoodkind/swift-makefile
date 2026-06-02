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

private func createTemporaryDirectory() throws -> URL {
    let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    return directoryURL
}
