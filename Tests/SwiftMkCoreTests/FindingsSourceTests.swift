//
//  FindingsSourceTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-08.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - FindingsSourceTests

/// Empty namesake type so SwiftLint `file_name` finds a declaration matching
/// `FindingsSourceTests.swift`; the suite is written as free `@Test` functions.
enum FindingsSourceTests {}

@Test
func swiftlintRunsJsonReporterAndDecodesFindings() throws {
  let scriptPath = try makeTemporaryScript(
    contents: """
      #!/bin/sh
      cat <<'JSON'
      [
        {
          "character": 5,
          "file": "/x.swift",
          "line": 2,
          "reason": "msg",
          "rule_id": "identifier_name",
          "severity": "Warning",
          "type": "Identifier Name"
        }
      ]
      JSON
      """
  )
  defer {
    removeTemporaryScript(scriptPath)
  }

  let findings = FindingsSource.swiftlint(executable: scriptPath, arguments: [])
  let finding = try #require(findings.first)

  #expect(findings.count == 1)
  #expect(finding.ruleId == "identifier_name")
  #expect(finding.tool == "swiftlint")
}

@Test
func peripheryRunsJsonFormatAndDecodesFindings() throws {
  let scriptPath = try makeTemporaryScript(
    contents: """
      #!/bin/sh
      cat <<'JSON'
      [
        {
          "kind": "unused_function",
          "name": "dead()",
          "ids": ["usr://x"],
          "hints": ["remove it"],
          "location": "/dead.swift:4:2"
        }
      ]
      JSON
      """
  )
  defer {
    removeTemporaryScript(scriptPath)
  }

  let findings = FindingsSource.periphery(executable: scriptPath, arguments: [])
  let finding = try #require(findings.first)

  #expect(findings.count == 1)
  #expect(finding.tool == "periphery")
  #expect(finding.usr == "usr://x")
}

@Test
func invalidSwiftlintJsonReturnsEmptyFindings() throws {
  let scriptPath = try makeTemporaryScript(
    contents: """
      #!/bin/sh
      printf 'not json'
      """
  )
  defer {
    removeTemporaryScript(scriptPath)
  }

  let findings = FindingsSource.swiftlint(executable: scriptPath, arguments: [])

  #expect(findings.isEmpty)
}

private func makeTemporaryScript(contents: String) throws -> String {
  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("swiftmk-findings-source-\(UUID().uuidString).sh")
    .path
  try contents.write(toFile: path, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
  return path
}

private func removeTemporaryScript(_ path: String) {
  guard FileManager.default.fileExists(atPath: path) else {
    return
  }

  do {
    try FileManager.default.removeItem(atPath: path)
  } catch {
    Output.error("findings source tests: could not remove temporary script \(path): \(error)")
  }
}
