//
//  FindingTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-08.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - FindingTests

enum FindingTests {}

@Test
func decodesSwiftlintJSON() throws {
  let json = """
    [
      {
        "character" : 5,
        "file" : "/tmp/x.swift",
        "line" : 2,
        "reason" : "Variable name 'x' should be between 3 and 40 characters long",
        "rule_id" : "identifier_name",
        "severity" : "Error",
        "type" : "Identifier Name"
      }
    ]
    """

  let findings = try Finding.fromSwiftlintJSON(Data(json.utf8))

  #expect(findings.count == 1)
  let finding = try #require(findings.first)
  #expect(finding.ruleId == "identifier_name")
  #expect(finding.line == 2)
  #expect(finding.column == 5)
  #expect(finding.severity == .error)
  #expect(finding.tool == "swiftlint")
  #expect(finding.message == "Variable name 'x' should be between 3 and 40 characters long")
  #expect(finding.usr == nil)
}

@Test
func decodesPeripheryJSON() throws {
  let json = """
    [
      {
        "kind": "class",
        "modules": ["App"],
        "name": "FooViewController",
        "modifiers": [],
        "attributes": [],
        "accessibility": "internal",
        "ids": ["s:3App17FooViewControllerC"],
        "hints": ["unused"],
        "location": "/abs/path/File.swift:10:1"
      }
    ]
    """

  let findings = try Finding.fromPeripheryJSON(Data(json.utf8))

  #expect(findings.count == 1)
  let finding = try #require(findings.first)
  #expect(finding.tool == "periphery")
  #expect(finding.ruleId == "class")
  #expect(finding.symbol == "FooViewController")
  #expect(finding.usr == "s:3App17FooViewControllerC")
  #expect(finding.file == "/abs/path/File.swift")
  #expect(finding.line == 10)
  #expect(finding.column == 1)
  #expect(finding.hints == ["unused"])
}

@Test
func decodesPeripheryLocationWithoutCoordinates() throws {
  let json = """
    [
      {
        "kind": "class",
        "modules": ["App"],
        "name": "FooViewController",
        "modifiers": [],
        "attributes": [],
        "accessibility": "internal",
        "ids": [],
        "hints": [],
        "location": "/x/File.swift"
      }
    ]
    """

  let findings = try Finding.fromPeripheryJSON(Data(json.utf8))

  #expect(findings.count == 1)
  let finding = try #require(findings.first)
  #expect(finding.file == "/x/File.swift")
  #expect(finding.line == 0)
  #expect(finding.column == 0)
}
