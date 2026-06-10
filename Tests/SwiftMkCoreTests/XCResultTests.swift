//
//  XCResultTests.swift
//  SwiftMkCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-09.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Testing

@testable import SwiftMkCore

// MARK: - XCResultTests

@Suite
enum XCResultTests {
  @Test
  static func decodesBuildResultsIssues() {
    let json = """
      {
        "errorCount": 1,
        "warningCount": 2,
        "errors": [
          {
            "className": "IssueSummary",
            "issueType": "Swift Compiler Error",
            "message": "cannot find 'foo' in scope",
            "sourceURL": "file:///abs/path/File.swift#CharacterRangeLen=0&EndingColumnNumber=5&EndingLineNumber=11&StartingColumnNumber=5&StartingLineNumber=11",
            "targetName": "App"
          }
        ],
        "warnings": [
          {
            "issueType": "Swift Compiler Warning",
            "message": "immutable value was never used",
            "sourceURL": "file:///abs/path/Other.swift#CharacterRangeLen=0&EndingColumnNumber=7&EndingLineNumber=2&StartingColumnNumber=3&StartingLineNumber=2",
            "targetName": "App"
          },
          {
            "issueType": "Swift Compiler Warning",
            "message": "result of call is unused",
            "sourceURL": "file:///abs/path/Third.swift#StartingLineNumber=0",
            "targetName": "App"
          }
        ]
      }
      """

    let issues = XCResult.issuesFromBuildResultsJSON(Data(json.utf8))

    #expect(
      issues == [
        XCResult.Issue(
          severity: "error",
          message: "cannot find 'foo' in scope",
          file: "/abs/path/File.swift",
          line: 12
        ),
        XCResult.Issue(
          severity: "warning",
          message: "immutable value was never used",
          file: "/abs/path/Other.swift",
          line: 3
        ),
        XCResult.Issue(
          severity: "warning",
          message: "result of call is unused",
          file: "/abs/path/Third.swift",
          line: 1
        ),
      ]
    )
  }

  @Test
  static func decodesIssueWithoutSourceURL() {
    let json = """
      {
        "errors": [
          {
            "issueType": "Swift Compiler Error",
            "message": "failed to compile",
            "targetName": "App"
          }
        ]
      }
      """

    let issues = XCResult.issuesFromBuildResultsJSON(Data(json.utf8))

    #expect(
      issues == [
        XCResult.Issue(
          severity: "error",
          message: "failed to compile",
          file: "",
          line: 0
        )
      ]
    )
  }

  @Test
  static func returnsEmptyIssuesForUndecodableInput() {
    let garbageIssues = XCResult.issuesFromBuildResultsJSON(Data("not json".utf8))
    let emptyObjectIssues = XCResult.issuesFromBuildResultsJSON(Data("{}".utf8))

    #expect(garbageIssues.isEmpty)
    #expect(emptyObjectIssues.isEmpty)
  }

  @Test
  static func decodesSourceURLPathWithoutFragment() {
    let json = """
      {
        "warnings": [
          {
            "issueType": "Swift Compiler Warning",
            "message": "missing documentation",
            "sourceURL": "file:///abs/path/NoFragment.swift",
            "targetName": "App"
          }
        ]
      }
      """

    let issues = XCResult.issuesFromBuildResultsJSON(Data(json.utf8))

    #expect(
      issues == [
        XCResult.Issue(
          severity: "warning",
          message: "missing documentation",
          file: "/abs/path/NoFragment.swift",
          line: 0
        )
      ]
    )
  }
}
